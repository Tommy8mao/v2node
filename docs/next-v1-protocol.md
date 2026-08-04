# Next-V1 wire protocol

Status: implementation contract for Nextin, Mihomo and v2node.

Next-V1 is an authenticated, encrypted stream protocol carried inside an outer
TLS 1.3 connection. Production deployments terminate TLS at HAProxy and require
one shared mTLS client certificate. The inner protocol remains independently
authenticated and encrypted after HAProxy terminates TLS.

All integers are unsigned and big-endian. Text is UTF-8. A connection carries
either one TCP stream or one UDP-over-TCP association to one destination.

## Credentials and keys

`password` is the exact UTF-8 user UUID/string delivered by the panel. It is
trimmed for surrounding ASCII whitespace and is otherwise case-sensitive.

```text
base_key = SHA-256("Next-V1/user-key\x00" || password)
user_hash = SHA-256(password)[0:16]
auth_key = HKDF-SHA256(base_key, salt=nil, info="Next-V1/auth", length=32)
c2s_key = HKDF-SHA256(base_key, salt=client_nonce,
                      info="Next-V1/c2s", length=32)
s2c_key = HKDF-SHA256(base_key, salt=client_nonce,
                      info="Next-V1/s2c", length=32)
```

The record cipher is ChaCha20-Poly1305.

## Client hello

The client writes exactly 64 bytes before any encrypted record:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII magic `NXV1` |
| 4 | 1 | Version, currently `1` |
| 5 | 1 | Command: `1` TCP, `2` UDP-over-TCP |
| 6 | 2 | Flags, currently zero |
| 8 | 8 | Unix timestamp in seconds |
| 16 | 16 | Cryptographically random client nonce |
| 32 | 16 | `user_hash` |
| 48 | 16 | HMAC-SHA256 over bytes 0..47 with `auth_key`, truncated |

The server rejects unknown users, invalid authentication, a clock difference
greater than 120 seconds, and replayed `(user_hash, client_nonce)` pairs. Replay
entries are retained for at least 240 seconds in a bounded cache.

## Encrypted records

Each direction has an independent sequence number starting at zero. The AEAD
nonce is a four-byte prefix followed by the uint64 sequence:

```text
client to server: "NXC1" || sequence
server to client: "NXS1" || sequence
```

A record begins with a two-byte ciphertext length. The same two bytes are the
AEAD associated data. The ciphertext decrypts to:

| Size | Field |
| ---: | --- |
| 1 | Record type |
| 1 | Flags, currently zero |
| 2 | Payload length |
| 2 | Padding length |
| N | Payload |
| P | Random padding |

Ciphertext length must be at most 65535 bytes. DATA payloads are at most 32768
bytes and padding is at most 1024 bytes. Implementations may choose random
padding between configured bounds; the default is 0..64 bytes.

Record types:

| Value | Name | Meaning |
| ---: | --- | --- |
| `0x01` | OPEN | Client's first record; contains the destination |
| `0x02` | ACK | Server accepted OPEN; empty payload |
| `0x03` | DATA | TCP bytes or exactly one UDP datagram |
| `0x04` | CLOSE | Graceful end; optional UTF-8 reason |
| `0x7f` | ERROR | Rejection; UTF-8 message of at most 256 bytes |

The first encrypted client record must be OPEN. The server replies with ACK
before application DATA is exchanged. A malformed record closes the connection.

## Destination encoding

The OPEN payload contains one SOCKS-style destination followed by no extra data:

```text
ATYP=1: 1 || IPv4(4) || port(2)
ATYP=2: 2 || domain_length(1) || domain || port(2)
ATYP=3: 3 || IPv6(16) || port(2)
```

Domain length is 1..255 and port is 1..65535.

## TCP

After ACK, DATA payloads form an ordered byte stream. CLOSE or transport EOF
ends the stream. Implementations should preserve half-close when their host
network API supports it.

## UDP-over-TCP

Each connection is one association to the OPEN destination. Every DATA record
contains exactly one complete UDP datagram. Each client-side packet socket may
open and cache multiple Next-V1 associations, one per destination. It must return
response packets with that association's destination address to the caller.

Native UDP transport is intentionally unsupported in Next-V1 version 1.

## Outer HAProxy mTLS

The outer TLS layer is deployment policy, not part of the wire bytes above.
HAProxy listens on port 443, requires TLS 1.3 and a trusted client certificate,
then forwards the decrypted stream to a loopback-only v2node listener. It sends
PROXY protocol v2 so v2node can retain the original client address. Local tests
use a generated self-signed CA/server/client certificate set; production setup
may use an existing public server certificate while retaining the private CA for
client authentication.
