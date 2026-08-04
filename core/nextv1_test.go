package core

import (
	"encoding/json"
	"testing"

	panel "github.com/wyx2685/v2node/api/v2board"
	"github.com/wyx2685/v2node/core/proxy/nextv1"
	"github.com/xtls/xray-core/app/proxyman"
)

func TestBuildNextV1InboundUsesInnerLoopbackPort(t *testing.T) {
	networkSettings := json.RawMessage(`{"acceptProxyProtocol":true}`)
	config, err := buildInbound(&panel.NodeInfo{
		Type:     "next-v1",
		Security: panel.Tls,
		Common: &panel.CommonNode{
			ListenIP:        "0.0.0.0",
			ServerPort:      24443,
			Network:         "tcp",
			NetworkSettings: networkSettings,
		},
	}, "next-v1-test")
	if err != nil {
		t.Fatal(err)
	}
	if config.Tag != "next-v1-test" {
		t.Fatalf("unexpected tag %q", config.Tag)
	}
	receiverInstance, err := config.ReceiverSettings.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	receiver, ok := receiverInstance.(*proxyman.ReceiverConfig)
	if !ok {
		t.Fatalf("unexpected receiver type %T", receiverInstance)
	}
	ports := receiver.PortList.Ports()
	if len(ports) != 1 || ports[0] != 24443 {
		t.Fatalf("Next-V1 listens on ports %v, want inner 24443", ports)
	}
	if got := receiver.Listen.AsAddress().String(); got != "127.0.0.1" {
		t.Fatalf("Next-V1 listen address = %q, want loopback", got)
	}
	if receiver.StreamSettings.ProtocolName != "tcp" {
		t.Fatalf("Next-V1 transport = %q, want tcp", receiver.StreamSettings.ProtocolName)
	}
	if !receiver.StreamSettings.SocketSettings.AcceptProxyProtocol {
		t.Fatal("Next-V1 receiver did not enable HAProxy PROXY protocol")
	}
	if receiver.StreamSettings.SecurityType != "" || len(receiver.StreamSettings.SecuritySettings) != 0 {
		t.Fatal("Next-V1 core must not terminate outer TLS")
	}
	proxyInstance, err := config.ProxySettings.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	proxyConfig, ok := proxyInstance.(*nextv1.Config)
	if !ok {
		t.Fatalf("unexpected proxy config type %T", proxyInstance)
	}
	if proxyConfig.MaxTimeSkewSeconds != 120 || proxyConfig.ReplayCapacity != 65536 {
		t.Fatalf("unexpected Next-V1 security config: %v", proxyConfig)
	}
}

func TestBuildNextV1DefaultsAndExplicitRawTestMode(t *testing.T) {
	config, err := buildInbound(&panel.NodeInfo{
		Type: "next-v1",
		Common: &panel.CommonNode{
			NetworkSettings: json.RawMessage(`{"acceptProxyProtocol":false}`),
		},
	}, "next-v1-defaults")
	if err != nil {
		t.Fatal(err)
	}
	receiverInstance, err := config.ReceiverSettings.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	receiver := receiverInstance.(*proxyman.ReceiverConfig)
	if ports := receiver.PortList.Ports(); len(ports) != 1 || ports[0] != 24443 {
		t.Fatalf("default inner port = %v", ports)
	}
	if receiver.StreamSettings.SocketSettings.AcceptProxyProtocol {
		t.Fatal("explicit raw local-test mode still expects a PROXY header")
	}
}
