package nextv1

import (
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/xtls/xray-core/common/net"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

const (
	Version = 1

	CommandTCP byte = 1
	CommandUDP byte = 2

	RecordOpen  byte = 0x01
	RecordAck   byte = 0x02
	RecordData  byte = 0x03
	RecordClose byte = 0x04
	RecordError byte = 0x7f

	HelloSize         = 64
	MaxCiphertextSize = 65535
	MaxDataSize       = 32768
	MaxPaddingSize    = 1024
	MaxReasonSize     = 256
)

var (
	helloMagic = [4]byte{'N', 'X', 'V', '1'}
	c2sPrefix  = [4]byte{'N', 'X', 'C', '1'}
	s2cPrefix  = [4]byte{'N', 'X', 'S', '1'}
)

type sessionKeys struct {
	c2s [chacha20poly1305.KeySize]byte
	s2c [chacha20poly1305.KeySize]byte
}

type parsedHello struct {
	command  byte
	time     time.Time
	nonce    [16]byte
	userHash [16]byte
	tag      [16]byte
	raw      [HelloSize]byte
}

type Record struct {
	Type    byte
	Payload []byte
}

type RecordReader struct {
	aead   cipher.AEAD
	prefix [4]byte
	seq    uint64
}

type RecordWriter struct {
	mu         sync.Mutex
	aead       cipher.AEAD
	prefix     [4]byte
	seq        uint64
	paddingMax int
	random     io.Reader
}

func normalizePassword(password string) string {
	return strings.Trim(password, " \t\r\n\f\v")
}

func deriveBaseKey(password string) [sha256.Size]byte {
	return sha256.Sum256(append([]byte("Next-V1/user-key\x00"), []byte(normalizePassword(password))...))
}

func deriveUserHash(password string) [16]byte {
	sum := sha256.Sum256([]byte(normalizePassword(password)))
	var result [16]byte
	copy(result[:], sum[:16])
	return result
}

func deriveAuthKey(password string) ([sha256.Size]byte, error) {
	base := deriveBaseKey(password)
	var result [sha256.Size]byte
	if _, err := io.ReadFull(hkdf.New(sha256.New, base[:], nil, []byte("Next-V1/auth")), result[:]); err != nil {
		return result, err
	}
	return result, nil
}

func deriveSessionKeys(password string, nonce [16]byte) (sessionKeys, error) {
	base := deriveBaseKey(password)
	var keys sessionKeys
	if _, err := io.ReadFull(hkdf.New(sha256.New, base[:], nonce[:], []byte("Next-V1/c2s")), keys.c2s[:]); err != nil {
		return keys, err
	}
	if _, err := io.ReadFull(hkdf.New(sha256.New, base[:], nonce[:], []byte("Next-V1/s2c")), keys.s2c[:]); err != nil {
		return keys, err
	}
	return keys, nil
}

func parseClientHello(raw [HelloSize]byte) (parsedHello, error) {
	var hello parsedHello
	hello.raw = raw
	if string(raw[:4]) != string(helloMagic[:]) {
		return hello, errors.New("invalid Next-V1 magic")
	}
	if raw[4] != Version {
		return hello, fmt.Errorf("unsupported Next-V1 version %d", raw[4])
	}
	if raw[5] != CommandTCP && raw[5] != CommandUDP {
		return hello, fmt.Errorf("unsupported Next-V1 command %d", raw[5])
	}
	if binary.BigEndian.Uint16(raw[6:8]) != 0 {
		return hello, errors.New("unsupported Next-V1 hello flags")
	}
	hello.command = raw[5]
	hello.time = time.Unix(int64(binary.BigEndian.Uint64(raw[8:16])), 0)
	copy(hello.nonce[:], raw[16:32])
	copy(hello.userHash[:], raw[32:48])
	copy(hello.tag[:], raw[48:64])
	return hello, nil
}

func verifyClientHello(hello parsedHello, password string) bool {
	userHash := deriveUserHash(password)
	if !hmac.Equal(hello.userHash[:], userHash[:]) {
		return false
	}
	authKey, err := deriveAuthKey(password)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, authKey[:])
	_, _ = mac.Write(hello.raw[:48])
	return hmac.Equal(hello.tag[:], mac.Sum(nil)[:16])
}

func buildClientHello(command byte, password string, timestamp time.Time, nonce [16]byte) ([HelloSize]byte, error) {
	var raw [HelloSize]byte
	if command != CommandTCP && command != CommandUDP {
		return raw, fmt.Errorf("unsupported Next-V1 command %d", command)
	}
	copy(raw[:4], helloMagic[:])
	raw[4] = Version
	raw[5] = command
	binary.BigEndian.PutUint64(raw[8:16], uint64(timestamp.Unix()))
	copy(raw[16:32], nonce[:])
	userHash := deriveUserHash(password)
	copy(raw[32:48], userHash[:])
	authKey, err := deriveAuthKey(password)
	if err != nil {
		return raw, err
	}
	mac := hmac.New(sha256.New, authKey[:])
	_, _ = mac.Write(raw[:48])
	copy(raw[48:64], mac.Sum(nil)[:16])
	return raw, nil
}

func NewRecordReader(key []byte, clientToServer bool) (*RecordReader, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	prefix := s2cPrefix
	if clientToServer {
		prefix = c2sPrefix
	}
	return &RecordReader{aead: aead, prefix: prefix}, nil
}

func NewRecordWriter(key []byte, clientToServer bool, paddingMax int) (*RecordWriter, error) {
	if paddingMax < 0 || paddingMax > MaxPaddingSize {
		return nil, fmt.Errorf("invalid padding maximum %d", paddingMax)
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	prefix := s2cPrefix
	if clientToServer {
		prefix = c2sPrefix
	}
	return &RecordWriter{aead: aead, prefix: prefix, paddingMax: paddingMax, random: rand.Reader}, nil
}

func (r *RecordReader) ReadRecord(reader io.Reader) (Record, error) {
	var record Record
	if r.seq == ^uint64(0) {
		return record, errors.New("Next-V1 receive sequence exhausted")
	}
	var lengthBytes [2]byte
	if _, err := io.ReadFull(reader, lengthBytes[:]); err != nil {
		return record, err
	}
	length := int(binary.BigEndian.Uint16(lengthBytes[:]))
	if length < r.aead.Overhead()+6 || length > MaxCiphertextSize {
		return record, fmt.Errorf("invalid Next-V1 ciphertext length %d", length)
	}
	ciphertext := make([]byte, length)
	if _, err := io.ReadFull(reader, ciphertext); err != nil {
		return record, err
	}
	plaintext, err := r.aead.Open(nil, recordNonce(r.prefix, r.seq), ciphertext, lengthBytes[:])
	if err != nil {
		return record, errors.New("invalid Next-V1 record authentication")
	}
	r.seq++
	if len(plaintext) < 6 || plaintext[1] != 0 {
		return record, errors.New("invalid Next-V1 record header")
	}
	payloadLength := int(binary.BigEndian.Uint16(plaintext[2:4]))
	paddingLength := int(binary.BigEndian.Uint16(plaintext[4:6]))
	if paddingLength > MaxPaddingSize || 6+payloadLength+paddingLength != len(plaintext) {
		return record, errors.New("invalid Next-V1 record lengths")
	}
	record.Type = plaintext[0]
	record.Payload = append([]byte(nil), plaintext[6:6+payloadLength]...)
	if err := validateRecord(record); err != nil {
		return Record{}, err
	}
	return record, nil
}

func (w *RecordWriter) WriteRecord(writer io.Writer, recordType byte, payload []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.seq == ^uint64(0) {
		return errors.New("Next-V1 send sequence exhausted")
	}
	record := Record{Type: recordType, Payload: payload}
	if err := validateRecord(record); err != nil {
		return err
	}
	paddingLength, err := w.nextPaddingLength()
	if err != nil {
		return err
	}
	plaintextLength := 6 + len(payload) + paddingLength
	if plaintextLength+w.aead.Overhead() > MaxCiphertextSize {
		return errors.New("Next-V1 record is too large")
	}
	plaintext := make([]byte, plaintextLength)
	plaintext[0] = recordType
	binary.BigEndian.PutUint16(plaintext[2:4], uint16(len(payload)))
	binary.BigEndian.PutUint16(plaintext[4:6], uint16(paddingLength))
	copy(plaintext[6:], payload)
	if paddingLength > 0 {
		if _, err := io.ReadFull(w.random, plaintext[6+len(payload):]); err != nil {
			return fmt.Errorf("generate Next-V1 padding: %w", err)
		}
	}
	var lengthBytes [2]byte
	binary.BigEndian.PutUint16(lengthBytes[:], uint16(plaintextLength+w.aead.Overhead()))
	ciphertext := w.aead.Seal(nil, recordNonce(w.prefix, w.seq), plaintext, lengthBytes[:])
	if err := writeFull(writer, lengthBytes[:]); err != nil {
		return err
	}
	if err := writeFull(writer, ciphertext); err != nil {
		return err
	}
	w.seq++
	return nil
}

func (w *RecordWriter) nextPaddingLength() (int, error) {
	if w.paddingMax == 0 {
		return 0, nil
	}
	var randomBytes [2]byte
	if _, err := io.ReadFull(w.random, randomBytes[:]); err != nil {
		return 0, fmt.Errorf("generate Next-V1 padding length: %w", err)
	}
	return int(binary.BigEndian.Uint16(randomBytes[:])) % (w.paddingMax + 1), nil
}

func validateRecord(record Record) error {
	switch record.Type {
	case RecordOpen:
		if len(record.Payload) == 0 || len(record.Payload) > 259 {
			return errors.New("invalid Next-V1 OPEN payload")
		}
	case RecordAck:
		if len(record.Payload) != 0 {
			return errors.New("invalid Next-V1 ACK payload")
		}
	case RecordData:
		if len(record.Payload) > MaxDataSize {
			return errors.New("Next-V1 DATA payload is too large")
		}
	case RecordClose:
		if len(record.Payload) > MaxReasonSize {
			return errors.New("Next-V1 CLOSE reason is too large")
		}
		if !utf8.Valid(record.Payload) {
			return errors.New("Next-V1 CLOSE reason is not UTF-8")
		}
	case RecordError:
		if len(record.Payload) > MaxReasonSize {
			return errors.New("Next-V1 ERROR message is too large")
		}
		if !utf8.Valid(record.Payload) {
			return errors.New("Next-V1 ERROR message is not UTF-8")
		}
	default:
		return fmt.Errorf("unknown Next-V1 record type 0x%02x", record.Type)
	}
	return nil
}

func recordNonce(prefix [4]byte, sequence uint64) []byte {
	var nonce [chacha20poly1305.NonceSize]byte
	copy(nonce[:4], prefix[:])
	binary.BigEndian.PutUint64(nonce[4:], sequence)
	return nonce[:]
}

func writeFull(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := writer.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	return nil
}

func ParseDestination(payload []byte, network net.Network) (net.Destination, error) {
	var destination net.Destination
	if len(payload) < 1 {
		return destination, errors.New("empty Next-V1 destination")
	}
	var address net.Address
	var portOffset int
	switch payload[0] {
	case 1:
		if len(payload) != 1+4+2 {
			return destination, errors.New("invalid Next-V1 IPv4 destination")
		}
		address = net.IPAddress(payload[1:5])
		portOffset = 5
	case 2:
		if len(payload) < 1+1+1+2 {
			return destination, errors.New("invalid Next-V1 domain destination")
		}
		domainLength := int(payload[1])
		if domainLength == 0 || len(payload) != 2+domainLength+2 {
			return destination, errors.New("invalid Next-V1 domain destination")
		}
		address = net.DomainAddress(string(payload[2 : 2+domainLength]))
		portOffset = 2 + domainLength
	case 3:
		if len(payload) != 1+16+2 {
			return destination, errors.New("invalid Next-V1 IPv6 destination")
		}
		address = net.IPAddress(payload[1:17])
		portOffset = 17
	default:
		return destination, fmt.Errorf("unknown Next-V1 address type %d", payload[0])
	}
	port := binary.BigEndian.Uint16(payload[portOffset:])
	if port == 0 {
		return destination, errors.New("invalid Next-V1 destination port")
	}
	destination = net.Destination{Network: network, Address: address, Port: net.Port(port)}
	if !destination.IsValid() {
		return net.Destination{}, errors.New("invalid Next-V1 destination")
	}
	return destination, nil
}

func EncodeDestination(destination net.Destination) ([]byte, error) {
	if !destination.IsValid() || destination.Port == 0 {
		return nil, errors.New("invalid Next-V1 destination")
	}
	var encoded []byte
	if destination.Address.Family().IsDomain() {
		domain := destination.Address.Domain()
		if len(domain) == 0 || len(domain) > 255 {
			return nil, errors.New("invalid Next-V1 destination domain")
		}
		encoded = make([]byte, 2+len(domain)+2)
		encoded[0] = 2
		encoded[1] = byte(len(domain))
		copy(encoded[2:], domain)
	} else {
		ip := destination.Address.IP()
		if len(ip) == 4 {
			encoded = make([]byte, 1+4+2)
			encoded[0] = 1
			copy(encoded[1:], ip)
		} else if len(ip) == 16 {
			encoded = make([]byte, 1+16+2)
			encoded[0] = 3
			copy(encoded[1:], ip)
		} else {
			return nil, errors.New("invalid Next-V1 destination IP")
		}
	}
	binary.BigEndian.PutUint16(encoded[len(encoded)-2:], uint16(destination.Port))
	return encoded, nil
}
