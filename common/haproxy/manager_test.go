package haproxy

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	panel "github.com/wyx2685/v2node/api/v2board"
)

type runnerCall struct {
	name string
	args []string
}

type fakeRunner struct {
	calls       []runnerCall
	failAction  string
	failCount   int
	actionCalls int
}

func (r *fakeRunner) Run(name string, args ...string) ([]byte, error) {
	r.calls = append(r.calls, runnerCall{name: name, args: append([]string(nil), args...)})
	action := name + " " + strings.Join(args, " ")
	if r.failAction != "" && strings.Contains(action, r.failAction) {
		r.actionCalls++
		if r.actionCalls <= r.failCount {
			return []byte("injected failure"), errors.New("command failed")
		}
	}
	return []byte("ok"), nil
}

func testManager(t *testing.T, runner Runner) *Manager {
	t.Helper()
	root := t.TempDir()
	return &Manager{
		ConfigPath:       filepath.Join(root, "haproxy", "haproxy.cfg"),
		NodesDir:         filepath.Join(root, "next-v1", "nodes"),
		MarkerPath:       filepath.Join(root, "next-v1", "manage-haproxy"),
		LockPath:         filepath.Join(root, "lock", "haproxy.lock"),
		Runner:           runner,
		RequireRootOwner: false,
		Now: func() time.Time {
			return time.Date(2026, 8, 5, 1, 2, 3, 4, time.UTC)
		},
	}
}

func nextNode(host string, id, frontend, backend int) *panel.NodeInfo {
	return &panel.NodeInfo{
		Id:      id,
		APIHost: host,
		Type:    "next-v1",
		Common: &panel.CommonNode{
			ServerPort: backend,
			OuterTLS: panel.OuterTLS{
				FrontendPort: frontend,
			},
		},
	}
}

func regularNode(host string, id, port int, protocol string) *panel.NodeInfo {
	return &panel.NodeInfo{
		Id:      id,
		APIHost: host,
		Type:    protocol,
		Common: &panel.CommonNode{
			ServerPort: port,
		},
	}
}

func installTestCertificates(t *testing.T, m *Manager, nodes ...*panel.NodeInfo) {
	t.Helper()
	for _, node := range nodes {
		dir := filepath.Join(m.NodesDir, NodeKey(node.APIHost, node.Id))
		if err := os.MkdirAll(filepath.Join(dir, "private"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "private", "haproxy.pem"), []byte("certificate-and-key"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "client-ca.crt"), []byte("client-ca"), 0644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestNodeKeyNormalizesTrailingSlash(t *testing.T) {
	withSlash := NodeKey(" https://panel.example/ ", 42)
	withoutSlash := NodeKey("https://panel.example", 42)
	if withSlash != withoutSlash {
		t.Fatalf("NodeKey mismatch: %q != %q", withSlash, withoutSlash)
	}
	if len(withSlash) != 16 {
		t.Fatalf("NodeKey length = %d, want 16", len(withSlash))
	}
}

func TestApplyGeneratesStableMultipleNodeConfiguration(t *testing.T) {
	runner := &fakeRunner{}
	m := testManager(t, runner)
	nodeB := nextNode("https://panel.example/", 2, 8443, 25443)
	nodeA := nextNode("https://panel.example", 1, 443, 24443)
	installTestCertificates(t, m, nodeA, nodeB)

	if err := m.Apply([]*panel.NodeInfo{nodeB, nodeA}); err != nil {
		t.Fatal(err)
	}
	config, err := os.ReadFile(m.ConfigPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(config)
	keyA := NodeKey(nodeA.APIHost, nodeA.Id)
	keyB := NodeKey(nodeB.APIHost, nodeB.Id)
	positionA := strings.Index(text, "frontend next_v1_frontend_"+keyA)
	positionB := strings.Index(text, "frontend next_v1_frontend_"+keyB)
	if positionA < 0 || positionB < 0 || ((positionA < positionB) != (keyA < keyB)) {
		t.Fatalf("routes were not sorted by stable key:\n%s", text)
	}
	for _, want := range []string{
		"bind :443 ssl crt " + filepath.Join(m.NodesDir, keyA, "private", "haproxy.pem"),
		"127.0.0.1:24443 send-proxy-v2",
		"bind :8443 ssl crt " + filepath.Join(m.NodesDir, keyB, "private", "haproxy.pem"),
		"127.0.0.1:25443 send-proxy-v2",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("generated configuration does not contain %q:\n%s", want, text)
		}
	}
	if len(runner.calls) != 3 {
		t.Fatalf("commands = %v, want check, enable, reload-or-restart", runner.calls)
	}
	if got := runner.calls[1].name + " " + strings.Join(runner.calls[1].args, " "); got != "systemctl enable haproxy" {
		t.Fatalf("second command = %q", got)
	}
	if got := runner.calls[2].name + " " + strings.Join(runner.calls[2].args, " "); got != "systemctl reload-or-restart haproxy" {
		t.Fatalf("third command = %q", got)
	}
}

func TestApplyRejectsNextV1PortConflicts(t *testing.T) {
	tests := []struct {
		name  string
		nodes []*panel.NodeInfo
		want  string
	}{
		{
			name:  "duplicate frontends",
			nodes: []*panel.NodeInfo{nextNode("https://a", 1, 443, 24443), nextNode("https://a", 2, 443, 25443)},
			want:  "frontend port 443 is shared",
		},
		{
			name:  "frontend and another backend",
			nodes: []*panel.NodeInfo{nextNode("https://a", 1, 443, 24443), nextNode("https://a", 2, 24443, 25443)},
			want:  "conflicts with inner port",
		},
		{
			name:  "duplicate backends",
			nodes: []*panel.NodeInfo{nextNode("https://a", 1, 443, 24443), nextNode("https://a", 2, 8443, 24443)},
			want:  "inner port 24443 is shared",
		},
		{
			name:  "backend shared with AnyTLS",
			nodes: []*panel.NodeInfo{nextNode("https://a", 1, 443, 24443), regularNode("https://a", 5, 24443, "anytls")},
			want:  "inner port 24443 is shared",
		},
		{
			name: "frontend conflicts with shared AnyTLS port",
			nodes: []*panel.NodeInfo{
				nextNode("https://a", 1, 12009, 24443),
				regularNode("https://a", 5, 12009, "anytls"),
				regularNode("https://a", 17, 12009, "anytls"),
			},
			want: "conflicts with inner port",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := testManager(t, &fakeRunner{})
			err := m.Apply(tt.nodes)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("Apply() error = %v, want containing %q", err, tt.want)
			}
		})
	}
}

func TestApplyAllowsSharedInnerPortForNonNextV1Nodes(t *testing.T) {
	sharedA := regularNode("https://panel.example", 5, 12009, "anytls")
	sharedB := regularNode("https://panel.example", 17, 12009, "anytls")

	t.Run("without Next-V1", func(t *testing.T) {
		runner := &fakeRunner{}
		m := testManager(t, runner)
		if err := m.Validate([]*panel.NodeInfo{sharedA, sharedB}); err != nil {
			t.Fatalf("Validate() rejected unrelated shared port: %v", err)
		}
		if err := m.Apply([]*panel.NodeInfo{sharedA, sharedB}); err != nil {
			t.Fatalf("Apply() rejected unrelated shared port: %v", err)
		}
		if len(runner.calls) != 0 {
			t.Fatalf("unexpected HAProxy commands: %v", runner.calls)
		}
	})

	t.Run("alongside Next-V1", func(t *testing.T) {
		runner := &fakeRunner{}
		m := testManager(t, runner)
		next := nextNode("https://panel.example", 23, 40443, 24443)
		installTestCertificates(t, m, next)
		if err := m.Apply([]*panel.NodeInfo{sharedA, sharedB, next}); err != nil {
			t.Fatalf("Apply() rejected unrelated shared port: %v", err)
		}
		if len(runner.calls) != 3 {
			t.Fatalf("commands = %v, want check, enable, reload-or-restart", runner.calls)
		}
	})
}

func TestApplyDoesNothingWithoutNextV1Nodes(t *testing.T) {
	runner := &fakeRunner{}
	m := testManager(t, runner)
	if err := m.Apply([]*panel.NodeInfo{{Id: 1, Type: "shadowsocks", Common: &panel.CommonNode{ServerPort: 1234}}}); err != nil {
		t.Fatal(err)
	}
	if len(runner.calls) != 0 {
		t.Fatalf("unexpected commands: %v", runner.calls)
	}
	if _, err := os.Stat(m.ConfigPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("HAProxy config was unexpectedly touched: %v", err)
	}
}

func TestApplyDisablesManagedHAProxyAfterLastNextV1NodeIsRemoved(t *testing.T) {
	runner := &fakeRunner{}
	m := testManager(t, runner)
	if err := os.MkdirAll(filepath.Dir(m.ConfigPath), 0755); err != nil {
		t.Fatal(err)
	}
	old := []byte(managedHeader + "\nfrontend stale\n    bind :443\n")
	if err := os.WriteFile(m.ConfigPath, old, 0644); err != nil {
		t.Fatal(err)
	}

	if err := m.Apply([]*panel.NodeInfo{{Id: 1, Type: "shadowsocks", Common: &panel.CommonNode{ServerPort: 1234}}}); err != nil {
		t.Fatal(err)
	}
	config, err := os.ReadFile(m.ConfigPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(config), "frontend ") {
		t.Fatalf("stale frontend remains:\n%s", config)
	}
	if len(runner.calls) != 2 {
		t.Fatalf("commands = %v, want validation and disable --now", runner.calls)
	}
	if got := runner.calls[1].name + " " + strings.Join(runner.calls[1].args, " "); got != "systemctl disable --now haproxy" {
		t.Fatalf("second command = %q", got)
	}
}

func TestApplyDoesNothingInExternalMode(t *testing.T) {
	runner := &fakeRunner{}
	m := testManager(t, runner)
	m.External = true
	if err := m.Apply([]*panel.NodeInfo{nextNode("https://panel.example", 1, 443, 24443)}); err != nil {
		t.Fatal(err)
	}
	if len(runner.calls) != 0 {
		t.Fatalf("unexpected commands: %v", runner.calls)
	}
	if _, err := os.Stat(m.ConfigPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("HAProxy config was unexpectedly touched: %v", err)
	}
}

func TestApplyRefusesUnmanagedConfigurationWithoutMarker(t *testing.T) {
	m := testManager(t, &fakeRunner{})
	node := nextNode("https://panel.example", 1, 443, 24443)
	installTestCertificates(t, m, node)
	if err := os.MkdirAll(filepath.Dir(m.ConfigPath), 0755); err != nil {
		t.Fatal(err)
	}
	old := []byte("global\n    daemon\n")
	if err := os.WriteFile(m.ConfigPath, old, 0640); err != nil {
		t.Fatal(err)
	}
	err := m.Apply([]*panel.NodeInfo{node})
	if err == nil || !strings.Contains(err.Error(), "refusing to replace unmanaged") {
		t.Fatalf("Apply() error = %v", err)
	}
	got, readErr := os.ReadFile(m.ConfigPath)
	if readErr != nil || string(got) != string(old) {
		t.Fatalf("unmanaged configuration changed: %q, %v", got, readErr)
	}
}

func TestApplyTakesOverWithRootOnlyMarkerAndBacksUp(t *testing.T) {
	m := testManager(t, &fakeRunner{})
	node := nextNode("https://panel.example", 1, 443, 24443)
	installTestCertificates(t, m, node)
	if err := os.MkdirAll(filepath.Dir(m.ConfigPath), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(m.MarkerPath), 0700); err != nil {
		t.Fatal(err)
	}
	old := []byte("global\n    daemon\n")
	if err := os.WriteFile(m.ConfigPath, old, 0640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.MarkerPath, []byte("authorized\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := m.Apply([]*panel.NodeInfo{node}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(m.MarkerPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("takeover marker was not consumed: %v", err)
	}
	backups, err := filepath.Glob(m.ConfigPath + ".next-v1.backup.*")
	if err != nil || len(backups) != 1 {
		t.Fatalf("backups = %v, err = %v", backups, err)
	}
	backup, err := os.ReadFile(backups[0])
	if err != nil || string(backup) != string(old) {
		t.Fatalf("backup = %q, err = %v", backup, err)
	}
}

func TestApplyRestoresOneTimeTakeoverMarkerWhenActivationFails(t *testing.T) {
	runner := &fakeRunner{failAction: "reload-or-restart haproxy", failCount: 1}
	m := testManager(t, runner)
	node := nextNode("https://panel.example", 1, 443, 24443)
	installTestCertificates(t, m, node)
	if err := os.MkdirAll(filepath.Dir(m.ConfigPath), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(m.MarkerPath), 0700); err != nil {
		t.Fatal(err)
	}
	old := []byte("global\n    daemon\n")
	if err := os.WriteFile(m.ConfigPath, old, 0640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.MarkerPath, []byte("authorized\n"), 0600); err != nil {
		t.Fatal(err)
	}

	err := m.Apply([]*panel.NodeInfo{node})
	if err == nil || !strings.Contains(err.Error(), "reload or start HAProxy") {
		t.Fatalf("Apply() error = %v", err)
	}
	if _, err := os.Stat(m.MarkerPath); err != nil {
		t.Fatalf("takeover marker was not restored: %v", err)
	}
	got, err := os.ReadFile(m.ConfigPath)
	if err != nil || string(got) != string(old) {
		t.Fatalf("unmanaged config was not restored: %q, %v", got, err)
	}
}

func TestApplyRestoresPreviousConfigurationWhenReloadFails(t *testing.T) {
	runner := &fakeRunner{failAction: "reload-or-restart haproxy", failCount: 1}
	m := testManager(t, runner)
	node := nextNode("https://panel.example", 1, 443, 24443)
	installTestCertificates(t, m, node)
	if err := os.MkdirAll(filepath.Dir(m.ConfigPath), 0755); err != nil {
		t.Fatal(err)
	}
	old := []byte(managedHeader + "\n# previous known-good configuration\n")
	if err := os.WriteFile(m.ConfigPath, old, 0640); err != nil {
		t.Fatal(err)
	}
	err := m.Apply([]*panel.NodeInfo{node})
	if err == nil || !strings.Contains(err.Error(), "reload or start HAProxy") {
		t.Fatalf("Apply() error = %v", err)
	}
	got, readErr := os.ReadFile(m.ConfigPath)
	if readErr != nil || string(got) != string(old) {
		t.Fatalf("previous config not restored: %q, %v", got, readErr)
	}
	if len(runner.calls) != 4 {
		t.Fatalf("commands = %v, want validation, enable, failed reload, recovery reload", runner.calls)
	}
}

func TestRenderedMultipleNodeConfigurationPassesInstalledHAProxy(t *testing.T) {
	haproxyPath, err := exec.LookPath("haproxy")
	if err != nil {
		t.Skip("haproxy is not installed")
	}
	root := t.TempDir()
	cert, ca := createTestIdentity(t, root)
	config := render([]route{
		{key: "0011223344556677", frontendPort: 443, backendPort: 24443, certificate: cert, clientCA: ca},
		{key: "8899aabbccddeeff", frontendPort: 8443, backendPort: 25443, certificate: cert, clientCA: ca},
	})
	// The production package creates the haproxy account. Homebrew's macOS
	// package does not, so only substitute known local identities there.
	if runtime.GOOS == "darwin" {
		current, lookupErr := user.Current()
		if lookupErr != nil {
			t.Fatal(lookupErr)
		}
		group, lookupErr := user.LookupGroupId(current.Gid)
		if lookupErr != nil {
			t.Fatal(lookupErr)
		}
		config = bytesReplace(config, "    user haproxy\n", "    user "+current.Username+"\n")
		config = bytesReplace(config, "    group haproxy\n", "    group "+group.Name+"\n")
	}
	configPath := filepath.Join(root, "haproxy.cfg")
	if err := os.WriteFile(configPath, config, 0600); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(haproxyPath, "-c", "-f", configPath).CombinedOutput()
	if err != nil {
		t.Fatalf("haproxy rejected generated multi-node config: %v\n%s\n%s", err, output, config)
	}
}

func createTestIdentity(t *testing.T, dir string) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Next-V1 test CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	serverTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "next-v1.test"},
		DNSNames:     []string{"next-v1.test"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	serverDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caTemplate, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	caPath := filepath.Join(dir, "client-ca.crt")
	certPath := filepath.Join(dir, "haproxy.pem")
	if err := os.WriteFile(caPath, pemEncode("CERTIFICATE", caDER), 0600); err != nil {
		t.Fatal(err)
	}
	combined := append(pemEncode("CERTIFICATE", serverDER), pemEncode("PRIVATE KEY", keyDER)...)
	if err := os.WriteFile(certPath, combined, 0600); err != nil {
		t.Fatal(err)
	}
	return certPath, caPath
}

func pemEncode(kind string, contents []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: contents})
}

func bytesReplace(contents []byte, old, replacement string) []byte {
	return []byte(strings.ReplaceAll(string(contents), old, replacement))
}
