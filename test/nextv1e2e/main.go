package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: nextv1e2e panel|target|probe [flags]")
	}
	var err error
	switch os.Args[1] {
	case "panel":
		err = runPanel(os.Args[2:])
	case "target":
		err = runTarget(os.Args[2:])
	case "probe":
		err = runProbe(os.Args[2:])
	default:
		err = fmt.Errorf("unknown mode %q", os.Args[1])
	}
	if err != nil {
		log.Fatal(err)
	}
}

func runPanel(args []string) error {
	fs := flag.NewFlagSet("panel", flag.ContinueOnError)
	listen := fs.String("listen", "127.0.0.1:18080", "HTTP listen address")
	backendPort := fs.Int("backend-port", 24443, "Next-V1 loopback port")
	password := fs.String("password", "next-v1-e2e-user", "test user password")
	if err := fs.Parse(args); err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v2/server/config", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{
			"protocol":    "next-v1",
			"listen_ip":   "127.0.0.1",
			"server_port": *backendPort,
			"routes":      []any{},
			"base_config": map[string]any{
				"push_interval":             3600,
				"pull_interval":             3600,
				"device_online_min_traffic": 0,
				"node_report_min_traffic":   0,
			},
			"tls":              0,
			"tls_settings":     map[string]any{},
			"network":          "tcp",
			"network_settings": map[string]any{"acceptProxyProtocol": true},
			"padding_scheme":   []string{"0", "64"},
		})
	})
	mux.HandleFunc("/api/v1/server/UniProxy/user", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"users": []any{map[string]any{
			"id": 1, "uuid": *password, "speed_limit": 0, "device_limit": 0,
		}}})
	})
	mux.HandleFunc("/api/v1/server/UniProxy/alivelist", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"alive": map[string]int{}})
	})
	mux.HandleFunc("/api/v1/server/UniProxy/alive", acceptJSON)
	mux.HandleFunc("/api/v1/server/UniProxy/push", acceptJSON)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	log.Printf("fake panel listening on %s", *listen)
	return http.ListenAndServe(*listen, mux)
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write JSON: %v", err)
	}
}

func acceptJSON(w http.ResponseWriter, r *http.Request) {
	_, _ = io.Copy(io.Discard, r.Body)
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte("{}\n"))
}

func runTarget(args []string) error {
	fs := flag.NewFlagSet("target", flag.ContinueOnError)
	tcpAddress := fs.String("tcp", "127.0.0.1:18081", "TCP echo address")
	udpAddress := fs.String("udp", "127.0.0.1:18082", "UDP echo address")
	if err := fs.Parse(args); err != nil {
		return err
	}

	tcpListener, err := net.Listen("tcp", *tcpAddress)
	if err != nil {
		return err
	}
	defer tcpListener.Close()
	udpListener, err := net.ListenPacket("udp", *udpAddress)
	if err != nil {
		return err
	}
	defer udpListener.Close()

	go func() {
		for {
			conn, err := tcpListener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()
	log.Printf("echo targets listening on tcp=%s udp=%s", *tcpAddress, *udpAddress)
	buffer := make([]byte, 65535)
	for {
		n, peer, err := udpListener.ReadFrom(buffer)
		if err != nil {
			return err
		}
		if _, err := udpListener.WriteTo(buffer[:n], peer); err != nil {
			return err
		}
	}
}

func runProbe(args []string) error {
	fs := flag.NewFlagSet("probe", flag.ContinueOnError)
	socksAddress := fs.String("socks", "127.0.0.1:17890", "Mihomo SOCKS/mixed address")
	tcpTarget := fs.String("tcp", "127.0.0.1:18081", "TCP echo target")
	udpTarget := fs.String("udp", "127.0.0.1:18082", "UDP echo target")
	timeout := fs.Duration("timeout", 10*time.Second, "per-probe timeout")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if err := probeTCP(*socksAddress, *tcpTarget, *timeout); err != nil {
		return fmt.Errorf("TCP probe: %w", err)
	}
	if err := probeUDP(*socksAddress, *udpTarget, *timeout); err != nil {
		return fmt.Errorf("UDP-over-TCP probe: %w", err)
	}
	log.Print("Next-V1 TCP and UDP-over-TCP probes passed")
	return nil
}

func socksGreeting(conn net.Conn) error {
	if _, err := conn.Write([]byte{5, 1, 0}); err != nil {
		return err
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return err
	}
	if !bytes.Equal(reply, []byte{5, 0}) {
		return fmt.Errorf("unexpected greeting reply %x", reply)
	}
	return nil
}

func probeTCP(socksAddress, target string, timeout time.Duration) error {
	conn, err := net.DialTimeout("tcp", socksAddress, timeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))
	if err := socksGreeting(conn); err != nil {
		return err
	}
	destination, err := encodeSocksAddress(target)
	if err != nil {
		return err
	}
	request := append([]byte{5, 1, 0}, destination...)
	if _, err := conn.Write(request); err != nil {
		return err
	}
	if _, err := readSocksReply(conn); err != nil {
		return err
	}
	payload := []byte("next-v1-tcp-e2e")
	if _, err := conn.Write(payload); err != nil {
		return err
	}
	reply := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, reply); err != nil {
		return err
	}
	if !bytes.Equal(reply, payload) {
		return fmt.Errorf("echo mismatch: got %q", reply)
	}
	return nil
}

func probeUDP(socksAddress, target string, timeout time.Duration) error {
	control, err := net.DialTimeout("tcp", socksAddress, timeout)
	if err != nil {
		return err
	}
	defer control.Close()
	_ = control.SetDeadline(time.Now().Add(timeout))
	if err := socksGreeting(control); err != nil {
		return err
	}
	if _, err := control.Write([]byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		return err
	}
	relay, err := readSocksReply(control)
	if err != nil {
		return err
	}
	relayHost, relayPort, err := net.SplitHostPort(relay)
	if err != nil {
		return err
	}
	if relayHost == "0.0.0.0" || relayHost == "::" || relayHost == "" {
		relayHost, _, err = net.SplitHostPort(socksAddress)
		if err != nil {
			return err
		}
		relay = net.JoinHostPort(relayHost, relayPort)
	}
	packetConn, err := net.DialTimeout("udp", relay, timeout)
	if err != nil {
		return err
	}
	defer packetConn.Close()
	_ = packetConn.SetDeadline(time.Now().Add(timeout))
	destination, err := encodeSocksAddress(target)
	if err != nil {
		return err
	}
	payload := []byte("next-v1-udp-over-tcp-e2e")
	packet := append([]byte{0, 0, 0}, destination...)
	packet = append(packet, payload...)
	if _, err := packetConn.Write(packet); err != nil {
		return err
	}
	reply := make([]byte, 65535)
	n, err := packetConn.Read(reply)
	if err != nil {
		return err
	}
	if n < 4 || reply[0] != 0 || reply[1] != 0 || reply[2] != 0 {
		return fmt.Errorf("invalid SOCKS UDP reply %x", reply[:n])
	}
	consumed, err := socksAddressLength(reply[3:n])
	if err != nil {
		return err
	}
	dataOffset := 3 + consumed
	if dataOffset > n || !bytes.Equal(reply[dataOffset:n], payload) {
		return fmt.Errorf("UDP echo mismatch: got %q", reply[dataOffset:n])
	}
	return nil
}

func encodeSocksAddress(address string) ([]byte, error) {
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, fmt.Errorf("invalid port %q", portText)
	}
	result := make([]byte, 0, 1+16+2)
	if ip := net.ParseIP(host); ip != nil {
		if ipv4 := ip.To4(); ipv4 != nil {
			result = append(result, 1)
			result = append(result, ipv4...)
		} else {
			result = append(result, 4)
			result = append(result, ip.To16()...)
		}
	} else {
		if len(host) == 0 || len(host) > 255 {
			return nil, errors.New("invalid domain length")
		}
		result = append(result, 3, byte(len(host)))
		result = append(result, host...)
	}
	result = binary.BigEndian.AppendUint16(result, uint16(port))
	return result, nil
}

func readSocksReply(reader io.Reader) (string, error) {
	header := make([]byte, 3)
	if _, err := io.ReadFull(reader, header); err != nil {
		return "", err
	}
	if header[0] != 5 || header[1] != 0 || header[2] != 0 {
		return "", fmt.Errorf("SOCKS request failed: %x", header)
	}
	return readSocksAddress(reader)
}

func readSocksAddress(reader io.Reader) (string, error) {
	atyp := make([]byte, 1)
	if _, err := io.ReadFull(reader, atyp); err != nil {
		return "", err
	}
	var host string
	switch atyp[0] {
	case 1:
		address := make([]byte, 4)
		if _, err := io.ReadFull(reader, address); err != nil {
			return "", err
		}
		host = net.IP(address).String()
	case 3:
		length := make([]byte, 1)
		if _, err := io.ReadFull(reader, length); err != nil {
			return "", err
		}
		address := make([]byte, int(length[0]))
		if _, err := io.ReadFull(reader, address); err != nil {
			return "", err
		}
		host = string(address)
	case 4:
		address := make([]byte, 16)
		if _, err := io.ReadFull(reader, address); err != nil {
			return "", err
		}
		host = net.IP(address).String()
	default:
		return "", fmt.Errorf("unknown SOCKS address type %d", atyp[0])
	}
	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(reader, portBytes); err != nil {
		return "", err
	}
	return net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(portBytes)))), nil
}

func socksAddressLength(data []byte) (int, error) {
	if len(data) < 1 {
		return 0, io.ErrUnexpectedEOF
	}
	switch data[0] {
	case 1:
		if len(data) < 7 {
			return 0, io.ErrUnexpectedEOF
		}
		return 7, nil
	case 3:
		if len(data) < 2 || len(data) < 1+1+int(data[1])+2 {
			return 0, io.ErrUnexpectedEOF
		}
		return 1 + 1 + int(data[1]) + 2, nil
	case 4:
		if len(data) < 19 {
			return 0, io.ErrUnexpectedEOF
		}
		return 19, nil
	default:
		return 0, fmt.Errorf("unknown SOCKS address type %d", data[0])
	}
}
