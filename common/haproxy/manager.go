// Package haproxy owns the dedicated HAProxy configuration used by Next-V1.
package haproxy

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	panel "github.com/wyx2685/v2node/api/v2board"
)

const (
	defaultConfigPath   = "/etc/haproxy/haproxy.cfg"
	defaultNodesDir     = "/etc/next-v1/nodes"
	defaultMarkerPath   = "/etc/next-v1/manage-haproxy"
	defaultLockPath     = "/run/lock/v2node-next-v1-haproxy.lock"
	managedHeader       = "# Managed by Next-V1 v2node HAProxy manager"
	installerHeader     = "# Managed by Next-V1 installer"
	legacyManagerHeader = "# Managed by v2node Next-V1 HAProxy manager"
	modeEnvironment     = "NEXT_V1_HAPROXY_MODE"
)

// Runner executes the small set of operating-system commands needed to check
// and activate HAProxy. It is an interface to keep configuration generation
// and rollback behavior unit-testable.
type Runner interface {
	Run(name string, args ...string) ([]byte, error)
}

type commandRunner struct{}

func (commandRunner) Run(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

// Manager atomically reconciles one dedicated HAProxy process with all of the
// Next-V1 nodes configured in this v2node process.
type Manager struct {
	ConfigPath       string
	NodesDir         string
	MarkerPath       string
	LockPath         string
	Runner           Runner
	RequireRootOwner bool
	Now              func() time.Time
	External         bool
}

// NewManager creates the production HAProxy manager.
func NewManager() *Manager {
	return &Manager{
		ConfigPath:       defaultConfigPath,
		NodesDir:         defaultNodesDir,
		MarkerPath:       defaultMarkerPath,
		LockPath:         defaultLockPath,
		Runner:           commandRunner{},
		RequireRootOwner: true,
		Now:              time.Now,
		External:         strings.EqualFold(strings.TrimSpace(os.Getenv(modeEnvironment)), "external"),
	}
}

type route struct {
	key          string
	frontendPort int
	backendPort  int
	certificate  string
	clientCA     string
	description  string
}

// NodeKey is the stable directory identifier shared with the installer.
func NodeKey(apiHost string, nodeID int) string {
	normalized := panel.NormalizeAPIHost(apiHost)
	sum := sha256.Sum256([]byte(normalized + ":" + strconv.Itoa(nodeID)))
	return fmt.Sprintf("%x", sum[:8])
}

// Apply validates and activates HAProxy for all Next-V1 nodes. When the final
// managed route disappears, it removes the listeners and disables HAProxy.
func (m *Manager) Apply(infos []*panel.NodeInfo) error {
	// External mode is an explicit escape hatch for tests and installations
	// where HAProxy is intentionally managed by another system.
	if m.External {
		return nil
	}
	routes, err := m.routes(infos)
	if err != nil {
		return err
	}
	if err := m.setDefaults(); err != nil {
		return err
	}
	unlock, err := lockFile(m.LockPath)
	if err != nil {
		return fmt.Errorf("lock Next-V1 HAProxy configuration: %w", err)
	}
	defer unlock()

	oldConfig, oldMode, existed, err := readExisting(m.ConfigPath)
	if err != nil {
		return err
	}
	unmanaged := existed && !isManaged(oldConfig)
	if len(routes) == 0 {
		if !existed || unmanaged {
			return nil
		}
		candidate := render(nil)
		candidatePath, writeErr := writeCandidate(m.ConfigPath, candidate, 0644)
		if writeErr != nil {
			return fmt.Errorf("write empty HAProxy candidate: %w", writeErr)
		}
		defer os.Remove(candidatePath)
		if output, checkErr := m.Runner.Run("haproxy", "-c", "-f", candidatePath); checkErr != nil {
			return fmt.Errorf("validate empty HAProxy candidate: %w: %s", checkErr, strings.TrimSpace(string(output)))
		}
		if !bytes.Equal(oldConfig, candidate) {
			if err := os.Rename(candidatePath, m.ConfigPath); err != nil {
				return fmt.Errorf("activate empty HAProxy candidate: %w", err)
			}
			if err := syncDir(filepath.Dir(m.ConfigPath)); err != nil {
				_ = m.restore(oldConfig, oldMode, true)
				return fmt.Errorf("sync empty HAProxy configuration: %w", err)
			}
		}
		if output, stopErr := m.Runner.Run("systemctl", "disable", "--now", "haproxy"); stopErr != nil {
			recoveryErr := m.restoreAndReactivate(oldConfig, oldMode, true)
			return activationError("disable empty HAProxy", stopErr, output, recoveryErr)
		}
		return nil
	}
	if unmanaged {
		if err := m.authorizedToTakeOver(); err != nil {
			return err
		}
	}

	candidate := render(routes)
	candidatePath, err := writeCandidate(m.ConfigPath, candidate, 0644)
	if err != nil {
		return fmt.Errorf("write HAProxy candidate: %w", err)
	}
	defer os.Remove(candidatePath)
	if output, checkErr := m.Runner.Run("haproxy", "-c", "-f", candidatePath); checkErr != nil {
		return fmt.Errorf("validate HAProxy candidate: %w: %s", checkErr, strings.TrimSpace(string(output)))
	}

	consumedMarker := ""
	restoreTakeoverMarker := func() error {
		if consumedMarker == "" {
			return nil
		}
		if err := os.Rename(consumedMarker, m.MarkerPath); err != nil {
			return fmt.Errorf("restore HAProxy takeover marker: %w", err)
		}
		consumedMarker = ""
		return syncDir(filepath.Dir(m.MarkerPath))
	}
	if unmanaged {
		backup := fmt.Sprintf("%s.next-v1.backup.%s", m.ConfigPath, m.Now().UTC().Format("20060102T150405.000000000Z"))
		if err := writeAtomic(backup, oldConfig, oldMode); err != nil {
			return fmt.Errorf("back up existing HAProxy configuration: %w", err)
		}
		consumedMarker = m.MarkerPath + ".consuming"
		if err := os.Rename(m.MarkerPath, consumedMarker); err != nil {
			return fmt.Errorf("consume HAProxy takeover marker: %w", err)
		}
		if err := syncDir(filepath.Dir(m.MarkerPath)); err != nil {
			return errors.Join(fmt.Errorf("sync HAProxy takeover authorization: %w", err), restoreTakeoverMarker())
		}
	}
	changed := !existed || !bytes.Equal(oldConfig, candidate)
	if changed {
		if err := os.Rename(candidatePath, m.ConfigPath); err != nil {
			return errors.Join(fmt.Errorf("activate HAProxy candidate: %w", err), restoreTakeoverMarker())
		}
	}
	if err := syncDir(filepath.Dir(m.ConfigPath)); err != nil {
		if changed {
			_ = m.restore(oldConfig, oldMode, existed)
		}
		return errors.Join(fmt.Errorf("sync HAProxy configuration directory: %w", err), restoreTakeoverMarker())
	}

	if output, enableErr := m.Runner.Run("systemctl", "enable", "haproxy"); enableErr != nil {
		recoveryErr := errors.Join(m.restoreAndReactivate(oldConfig, oldMode, existed), restoreTakeoverMarker())
		return activationError("enable HAProxy", enableErr, output, recoveryErr)
	}
	if output, activateErr := m.Runner.Run("systemctl", "reload-or-restart", "haproxy"); activateErr != nil {
		recoveryErr := errors.Join(m.restoreAndReactivate(oldConfig, oldMode, existed), restoreTakeoverMarker())
		return activationError("reload or start HAProxy", activateErr, output, recoveryErr)
	}
	if consumedMarker != "" {
		_ = os.Remove(consumedMarker)
		_ = syncDir(filepath.Dir(consumedMarker))
	}
	return nil
}

// Validate checks the complete topology and certificate inputs without
// changing HAProxy. Reload uses it before stopping the current working core.
func (m *Manager) Validate(infos []*panel.NodeInfo) error {
	if m.External {
		return nil
	}
	_, err := m.routes(infos)
	return err
}

func (m *Manager) setDefaults() error {
	if m.ConfigPath == "" || m.NodesDir == "" || m.MarkerPath == "" || m.LockPath == "" {
		return errors.New("HAProxy manager paths must not be empty")
	}
	if m.Runner == nil {
		return errors.New("HAProxy manager runner must not be nil")
	}
	if m.Now == nil {
		m.Now = time.Now
	}
	return nil
}

func (m *Manager) routes(infos []*panel.NodeInfo) ([]route, error) {
	var routes []route
	hasNextV1 := false
	for _, info := range infos {
		if info != nil && info.Type == "next-v1" {
			hasNextV1 = true
			break
		}
	}
	if !hasNextV1 {
		return nil, nil
	}

	allInnerPorts := make(map[int][]string)
	frontendPorts := make(map[int]string)
	seenNodes := make(map[string]struct{})

	for _, info := range infos {
		if info == nil || info.Common == nil {
			continue
		}
		port := info.Common.ServerPort
		if info.Type == "next-v1" && port == 0 {
			port = 24443
		}
		if port == 0 {
			continue
		}
		if err := validPort(port); err != nil {
			// HAProxy only owns Next-V1. Leave invalid ports on unrelated
			// protocols to the core that creates those listeners.
			if info.Type == "next-v1" {
				return nil, fmt.Errorf("node %s inner port: %w", nodeDescription(info), err)
			}
			continue
		}
		allInnerPorts[port] = append(allInnerPorts[port], nodeDescription(info))
	}

	for _, info := range infos {
		if info == nil || info.Type != "next-v1" {
			continue
		}
		if info.Common == nil {
			return nil, fmt.Errorf("Next-V1 node %s has no common configuration", nodeDescription(info))
		}
		if info.Id <= 0 || panel.NormalizeAPIHost(info.APIHost) == "" {
			return nil, fmt.Errorf("Next-V1 node has invalid panel identity %q:%d", info.APIHost, info.Id)
		}
		key := NodeKey(info.APIHost, info.Id)
		if _, exists := seenNodes[key]; exists {
			return nil, fmt.Errorf("duplicate Next-V1 node identity %s", nodeDescription(info))
		}
		seenNodes[key] = struct{}{}
		backendPort := info.Common.ServerPort
		if backendPort == 0 {
			backendPort = 24443
		}
		if owners := allInnerPorts[backendPort]; len(owners) > 1 {
			return nil, fmt.Errorf("inner port %d is shared by %s", backendPort, strings.Join(owners, " and "))
		}

		frontendPort := info.Common.OuterTLS.FrontendPort
		if frontendPort == 0 {
			frontendPort = 443
		}
		if err := validPort(frontendPort); err != nil {
			return nil, fmt.Errorf("node %s HAProxy frontend port: %w", nodeDescription(info), err)
		}
		if owner, exists := frontendPorts[frontendPort]; exists {
			return nil, fmt.Errorf("HAProxy frontend port %d is shared by %s and %s", frontendPort, owner, nodeDescription(info))
		}
		if owners := allInnerPorts[frontendPort]; len(owners) > 0 {
			return nil, fmt.Errorf("HAProxy frontend port %d for %s conflicts with inner port used by %s", frontendPort, nodeDescription(info), strings.Join(owners, ", "))
		}
		frontendPorts[frontendPort] = nodeDescription(info)

		dir := filepath.Join(m.NodesDir, key)
		certificate := filepath.Join(dir, "private", "haproxy.pem")
		clientCA := filepath.Join(dir, "client-ca.crt")
		routes = append(routes, route{
			key:          key,
			frontendPort: frontendPort,
			backendPort:  backendPort,
			certificate:  certificate,
			clientCA:     clientCA,
			description:  nodeDescription(info),
		})
	}
	for _, route := range routes {
		if err := validateCertificateFile(route.certificate); err != nil {
			return nil, fmt.Errorf("node %s HAProxy certificate: %w", route.description, err)
		}
		if err := validateCertificateFile(route.clientCA); err != nil {
			return nil, fmt.Errorf("node %s client CA: %w", route.description, err)
		}
	}
	sort.Slice(routes, func(i, j int) bool { return routes[i].key < routes[j].key })
	return routes, nil
}

func validPort(port int) error {
	if port < 1 || port > 65535 {
		return fmt.Errorf("invalid port %d", port)
	}
	return nil
}

func nodeDescription(info *panel.NodeInfo) string {
	if info == nil {
		return "<nil>"
	}
	return fmt.Sprintf("%s:%d", panel.NormalizeAPIHost(info.APIHost), info.Id)
}

func validateCertificateFile(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", path)
	}
	if info.Size() == 0 {
		return fmt.Errorf("%s is empty", path)
	}
	return nil
}

func render(routes []route) []byte {
	var b strings.Builder
	b.WriteString(managedHeader + "\n")
	b.WriteString("global\n")
	b.WriteString("    log /dev/log local0\n")
	b.WriteString("    log /dev/log local1 notice\n")
	b.WriteString("    user haproxy\n")
	b.WriteString("    group haproxy\n")
	b.WriteString("    daemon\n")
	b.WriteString("    ssl-default-bind-options ssl-min-ver TLSv1.3 no-tls-tickets\n\n")
	b.WriteString("defaults\n")
	b.WriteString("    log global\n")
	b.WriteString("    mode tcp\n")
	b.WriteString("    option tcplog\n")
	b.WriteString("    timeout connect 5s\n")
	b.WriteString("    timeout client 1h\n")
	b.WriteString("    timeout server 1h\n")
	for _, r := range routes {
		fmt.Fprintf(&b, "\nfrontend next_v1_frontend_%s\n", r.key)
		fmt.Fprintf(&b, "    bind :%d ssl crt %s ca-file %s verify required alpn next-v1\n", r.frontendPort, r.certificate, r.clientCA)
		fmt.Fprintf(&b, "    default_backend next_v1_backend_%s\n", r.key)
		fmt.Fprintf(&b, "\nbackend next_v1_backend_%s\n", r.key)
		fmt.Fprintf(&b, "    server next_v1_%s 127.0.0.1:%d send-proxy-v2 check inter 3s fall 3 rise 2\n", r.key, r.backendPort)
	}
	return []byte(b.String())
}

func readExisting(path string) ([]byte, os.FileMode, bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0644, false, nil
	}
	if err != nil {
		return nil, 0, false, fmt.Errorf("inspect existing HAProxy configuration: %w", err)
	}
	if !info.Mode().IsRegular() {
		return nil, 0, false, fmt.Errorf("existing HAProxy configuration %s is not a regular file", path)
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, false, fmt.Errorf("read existing HAProxy configuration: %w", err)
	}
	return contents, info.Mode().Perm(), true, nil
}

func isManaged(config []byte) bool {
	first, _, _ := bytes.Cut(config, []byte("\n"))
	header := string(bytes.TrimSpace(first))
	return header == managedHeader || header == installerHeader || header == legacyManagerHeader
}

func (m *Manager) authorizedToTakeOver() error {
	info, err := os.Lstat(m.MarkerPath)
	if err != nil {
		return fmt.Errorf("refusing to replace unmanaged HAProxy configuration without %s: %w", m.MarkerPath, err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("HAProxy takeover marker %s must be a root-only regular file", m.MarkerPath)
	}
	if m.RequireRootOwner {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 {
			return fmt.Errorf("HAProxy takeover marker %s must be owned by root", m.MarkerPath)
		}
	}
	return nil
}

func lockFile(path string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	}, nil
}

func writeCandidate(configPath string, contents []byte, mode os.FileMode) (string, error) {
	dir := filepath.Dir(configPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(dir, ".haproxy.cfg.next-v1.*")
	if err != nil {
		return "", err
	}
	name := f.Name()
	ok := false
	defer func() {
		_ = f.Close()
		if !ok {
			_ = os.Remove(name)
		}
	}()
	if err := f.Chmod(mode); err != nil {
		return "", err
	}
	if _, err := f.Write(contents); err != nil {
		return "", err
	}
	if err := f.Sync(); err != nil {
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	ok = true
	return name, nil
}

func writeAtomic(path string, contents []byte, mode os.FileMode) error {
	candidate, err := writeCandidate(path, contents, mode)
	if err != nil {
		return err
	}
	defer os.Remove(candidate)
	if err := os.Rename(candidate, path); err != nil {
		return err
	}
	return syncDir(filepath.Dir(path))
}

func syncDir(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func (m *Manager) restoreAndReactivate(old []byte, mode os.FileMode, existed bool) error {
	if err := m.restore(old, mode, existed); err != nil {
		return err
	}
	if existed {
		output, err := m.Runner.Run("systemctl", "reload-or-restart", "haproxy")
		if err != nil {
			return fmt.Errorf("reactivate previous HAProxy configuration: %w: %s", err, strings.TrimSpace(string(output)))
		}
		return nil
	}
	output, err := m.Runner.Run("systemctl", "stop", "haproxy")
	if err != nil {
		return fmt.Errorf("stop HAProxy after rollback: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func (m *Manager) restore(old []byte, mode os.FileMode, existed bool) error {
	if existed {
		return writeAtomic(m.ConfigPath, old, mode)
	}
	if err := os.Remove(m.ConfigPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return syncDir(filepath.Dir(m.ConfigPath))
}

func activationError(action string, err error, output []byte, recovery error) error {
	activation := fmt.Errorf("%s: %w: %s", action, err, strings.TrimSpace(string(output)))
	if recovery != nil {
		return fmt.Errorf("%w; rollback failed: %v", activation, recovery)
	}
	return activation
}
