package nextv1

import (
	"bytes"
	"encoding/hex"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/net"
)

func TestKeyDerivation(t *testing.T) {
	base := deriveBaseKey(" \texample-password\r\n")
	if got := hex.EncodeToString(base[:]); got != "beab6d3b7533ca8e89eb91ab26374aa1235238422bdf482892830641f78895d8" {
		t.Fatalf("unexpected base key: %s", got)
	}
	userHash := deriveUserHash("example-password")
	if got := hex.EncodeToString(userHash[:]); got != "a4b7fbda9179055ba005b83fe1d9d558" {
		t.Fatalf("unexpected user hash: %s", got)
	}
	var nonce [16]byte
	copy(nonce[:], "fixed-test-nonce")
	keys, err := deriveSessionKeys("example-password", nonce)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(keys.c2s[:], keys.s2c[:]) {
		t.Fatal("directional session keys must differ")
	}
}

func TestKeyDerivationGoldenVector(t *testing.T) {
	const password = "test-user-001"
	nonceBytes, err := hex.DecodeString("000102030405060708090a0b0c0d0e0f")
	if err != nil {
		t.Fatal(err)
	}
	var nonce [16]byte
	copy(nonce[:], nonceBytes)
	userHash := deriveUserHash(password)
	if got := hex.EncodeToString(userHash[:]); got != "aa5670d9986e847825ff7bfb230217b6" {
		t.Fatalf("user_hash = %s", got)
	}
	authKey, err := deriveAuthKey(password)
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(authKey[:]); got != "dda1bc12e02e5136b640e8af2b8b768299511e55064b53ce3fcc705ca84aec7c" {
		t.Fatalf("auth_key = %s", got)
	}
	keys, err := deriveSessionKeys(password, nonce)
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(keys.c2s[:]); got != "0dfacaaac10a641245d8269014b7189cacf07115634c1ecf90109c57a78b8cb6" {
		t.Fatalf("c2s_key = %s", got)
	}
	if got := hex.EncodeToString(keys.s2c[:]); got != "e015906e418c58e0335b3fa7da0f3dc2fddfc41cd82bf3c1142e271b34d75c8a" {
		t.Fatalf("s2c_key = %s", got)
	}
}

func TestClientHelloAuthentication(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var nonce [16]byte
	copy(nonce[:], "hello-test-nonce")
	raw, err := buildClientHello(CommandTCP, "test-password", now, nonce)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != HelloSize {
		t.Fatalf("hello length = %d", len(raw))
	}
	hello, err := parseClientHello(raw)
	if err != nil {
		t.Fatal(err)
	}
	if hello.command != CommandTCP || !hello.time.Equal(now) || hello.nonce != nonce {
		t.Fatalf("unexpected parsed hello: %#v", hello)
	}
	if !verifyClientHello(hello, "test-password") {
		t.Fatal("valid hello was rejected")
	}
	raw[12] ^= 0x01
	tampered, err := parseClientHello(raw)
	if err != nil {
		t.Fatal(err)
	}
	if verifyClientHello(tampered, "test-password") {
		t.Fatal("tampered hello was accepted")
	}
}

func TestRecordRoundTripAndTamper(t *testing.T) {
	var nonce [16]byte
	copy(nonce[:], "record-test-key!")
	keys, err := deriveSessionKeys("record-password", nonce)
	if err != nil {
		t.Fatal(err)
	}
	writer, err := NewRecordWriter(keys.c2s[:], true, 8)
	if err != nil {
		t.Fatal(err)
	}
	writer.random = bytes.NewReader(make([]byte, 32))
	var wire bytes.Buffer
	if err := writer.WriteRecord(&wire, RecordData, []byte("hello record")); err != nil {
		t.Fatal(err)
	}
	reader, err := NewRecordReader(keys.c2s[:], true)
	if err != nil {
		t.Fatal(err)
	}
	record, err := reader.ReadRecord(&wire)
	if err != nil {
		t.Fatal(err)
	}
	if record.Type != RecordData || string(record.Payload) != "hello record" {
		t.Fatalf("unexpected record: %#v", record)
	}

	writer, _ = NewRecordWriter(keys.s2c[:], false, 0)
	wire.Reset()
	if err := writer.WriteRecord(&wire, RecordAck, nil); err != nil {
		t.Fatal(err)
	}
	tampered := append([]byte(nil), wire.Bytes()...)
	tampered[len(tampered)-1] ^= 1
	reader, _ = NewRecordReader(keys.s2c[:], false)
	if _, err := reader.ReadRecord(bytes.NewReader(tampered)); err == nil {
		t.Fatal("tampered record was accepted")
	}
}

func TestRecordSequenceAndDirectionAreAuthenticated(t *testing.T) {
	key := bytes.Repeat([]byte{7}, 32)
	writer, _ := NewRecordWriter(key, true, 0)
	var wire bytes.Buffer
	if err := writer.WriteRecord(&wire, RecordData, []byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := writer.WriteRecord(&wire, RecordData, []byte("second")); err != nil {
		t.Fatal(err)
	}
	reader, _ := NewRecordReader(key, true)
	first, err := reader.ReadRecord(&wire)
	if err != nil || string(first.Payload) != "first" {
		t.Fatalf("read first record: %q, %v", first.Payload, err)
	}
	second, err := reader.ReadRecord(&wire)
	if err != nil || string(second.Payload) != "second" {
		t.Fatalf("read second record: %q, %v", second.Payload, err)
	}

	writer, _ = NewRecordWriter(key, true, 0)
	wire.Reset()
	_ = writer.WriteRecord(&wire, RecordAck, nil)
	wrongDirection, _ := NewRecordReader(key, false)
	if _, err := wrongDirection.ReadRecord(&wire); err == nil {
		t.Fatal("record decrypted with the wrong direction nonce")
	}
}

func TestRecordWriterSupportsConcurrentUDPResponses(t *testing.T) {
	key := bytes.Repeat([]byte{9}, 32)
	writer, err := NewRecordWriter(key, false, 0)
	if err != nil {
		t.Fatal(err)
	}
	var wire bytes.Buffer
	var writes sync.WaitGroup
	for i := byte(0); i < 32; i++ {
		payload := []byte{i}
		writes.Add(1)
		go func() {
			defer writes.Done()
			if err := writer.WriteRecord(&wire, RecordData, payload); err != nil {
				t.Errorf("write record: %v", err)
			}
		}()
	}
	writes.Wait()

	reader, err := NewRecordReader(key, false)
	if err != nil {
		t.Fatal(err)
	}
	seen := make(map[byte]bool, 32)
	for i := 0; i < 32; i++ {
		record, err := reader.ReadRecord(&wire)
		if err != nil {
			t.Fatalf("read record %d: %v", i, err)
		}
		if record.Type != RecordData || len(record.Payload) != 1 {
			t.Fatalf("unexpected record %d: %#v", i, record)
		}
		seen[record.Payload[0]] = true
	}
	if len(seen) != 32 {
		t.Fatalf("received %d unique responses, want 32", len(seen))
	}
}

func TestDestinationRoundTrips(t *testing.T) {
	tests := []net.Destination{
		net.TCPDestination(net.ParseAddress("192.0.2.9"), 443),
		net.UDPDestination(net.DomainAddress("dns.example"), 53),
		net.TCPDestination(net.ParseAddress("2001:db8::1"), 8443),
	}
	for _, destination := range tests {
		encoded, err := EncodeDestination(destination)
		if err != nil {
			t.Fatalf("encode %s: %v", destination, err)
		}
		decoded, err := ParseDestination(encoded, destination.Network)
		if err != nil {
			t.Fatalf("decode %s: %v", destination, err)
		}
		if decoded.String() != destination.String() {
			t.Fatalf("destination round trip: got %s, want %s", decoded, destination)
		}
	}
	if _, err := ParseDestination([]byte{2, 0, 0, 80}, net.Network_TCP); err == nil {
		t.Fatal("empty domain was accepted")
	}
	if _, err := ParseDestination([]byte{1, 127, 0, 0, 1, 0, 0}, net.Network_TCP); err == nil {
		t.Fatal("zero port was accepted")
	}
	if _, err := EncodeDestination(net.TCPDestination(net.DomainAddress(strings.Repeat("x", 256)), 443)); err == nil {
		t.Fatal("oversized domain was accepted")
	}
}
