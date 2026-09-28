package internet

import (
	"context"
	"io"
	"net"
	"testing"
	"time"
)

func TestAcceptProxyProtocolAlsoAcceptsRawTCP(t *testing.T) {
	for _, tc := range []struct {
		name       string
		wire       string
		wantRemote string
	}{
		{name: "raw", wire: "hello", wantRemote: "127.0.0.1"},
		{name: "proxy_v1", wire: "PROXY TCP4 192.0.2.10 127.0.0.1 12345 443\r\nhello", wantRemote: "192.0.2.10"},
		{name: "proxy_v2", wire: "\r\n\r\n\x00\r\nQUIT\n\x21\x11\x00\x0c\xc0\x00\x02\x0b\x7f\x00\x00\x01\x30\x39\x01\xbbhello", wantRemote: "192.0.2.11"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			listener, err := (&DefaultListener{}).Listen(context.Background(), &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)}, &SocketConfig{AcceptProxyProtocol: true})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()

			client, err := net.Dial("tcp", listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if _, err := io.WriteString(client, tc.wire); err != nil {
				t.Fatal(err)
			}

			server, err := listener.Accept()
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			if err := server.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			payload := make([]byte, len("hello"))
			if _, err := io.ReadFull(server, payload); err != nil {
				t.Fatal(err)
			}
			if string(payload) != "hello" {
				t.Fatalf("payload = %q, want hello", payload)
			}
			if got := server.RemoteAddr().(*net.TCPAddr).IP.String(); got != tc.wantRemote {
				t.Fatalf("remote IP = %s, want %s", got, tc.wantRemote)
			}
		})
	}
}
