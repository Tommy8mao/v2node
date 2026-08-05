#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly MIHOMO_DIR="${MIHOMO_DIR:-/Users/maoxinyu/Library/Mobile Documents/com~apple~CloudDocs/Xcode/Nextin/mihomo-Meta-changed}"
readonly MIHOMO_BIN="${MIHOMO_BIN:-}"
readonly PASSWORD="next-v1-e2e-user"
readonly PORT_BASE="${NEXTV1_E2E_PORT_BASE:-$((20000 + (RANDOM * 32768 + RANDOM) % 20000))}"
readonly PANEL_PORT=$PORT_BASE
readonly TARGET_TCP_PORT=$((PORT_BASE + 1))
readonly TARGET_UDP_PORT=$((PORT_BASE + 2))
readonly PUBLIC_PORT=$((PORT_BASE + 3))
readonly BACKEND_PORT=$((PORT_BASE + 4))
readonly MIXED_PORT=$((PORT_BASE + 5))

[[ -n "$MIHOMO_BIN" && -x "$MIHOMO_BIN" ]] || [[ -f "$MIHOMO_DIR/go.mod" ]] || {
    echo "Set MIHOMO_DIR to the modified Mihomo checkout" >&2
    exit 1
}
command -v haproxy >/dev/null || { echo "haproxy is required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
[[ "$PORT_BASE" =~ ^[0-9]+$ ]] && ((PORT_BASE >= 1024 && PORT_BASE <= 65530)) || {
    echo "NEXTV1_E2E_PORT_BASE must be between 1024 and 65530" >&2
    exit 1
}

for test_port in "$PANEL_PORT" "$TARGET_TCP_PORT" "$TARGET_UDP_PORT" "$PUBLIC_PORT" "$BACKEND_PORT" "$MIXED_PORT"; do
    if nc -z 127.0.0.1 "$test_port" >/dev/null 2>&1; then
        echo "E2E port $test_port is already in use" >&2
        exit 1
    fi
done

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/next-v1-e2e.XXXXXX")
pids=()

cleanup() {
    local pid
    for pid in "${pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -rf "$test_dir"
}
trap cleanup EXIT INT TERM

start_process() {
    local log_file="$1"
    shift
    "$@" >"$log_file" 2>&1 &
    pids+=("$!")
}

wait_for_tcp() {
    local port="$1"
    local name="$2"
    local log_file="$3"
    local attempt
    for attempt in $(seq 1 100); do
        if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
            return
        fi
        sleep 0.1
    done
    echo "$name failed to listen on port $port" >&2
    sed -n '1,240p' "$log_file" >&2 || true
    exit 1
}

echo "==> Building v2node, Mihomo and E2E helper"
(cd "$REPO_DIR" && GOTOOLCHAIN=auto GOEXPERIMENT=jsonv2 go build -o "$test_dir/v2node" .)
(cd "$REPO_DIR" && GOTOOLCHAIN=auto go build -o "$test_dir/nextv1e2e" ./test/nextv1e2e)
if [[ -n "$MIHOMO_BIN" ]]; then
    cp "$MIHOMO_BIN" "$test_dir/mihomo-bin"
else
    (cd "$MIHOMO_DIR" && GOTOOLCHAIN=auto go build -o "$test_dir/mihomo-bin" .)
fi

echo "==> Generating disposable server and client certificates"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj '/CN=next-v1.test' -addext 'subjectAltName=DNS:next-v1.test' \
    -addext 'extendedKeyUsage=serverAuth' \
    -keyout "$test_dir/server.key" -out "$test_dir/server.crt" >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj '/CN=Next-V1 E2E Client' -addext 'extendedKeyUsage=clientAuth' \
    -keyout "$test_dir/client.key" -out "$test_dir/client.crt" >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj '/CN=Untrusted E2E Client' -addext 'extendedKeyUsage=clientAuth' \
    -keyout "$test_dir/untrusted-client.key" -out "$test_dir/untrusted-client.crt" >/dev/null 2>&1
cp "$test_dir/server.crt" "$test_dir/server.pem"
chmod 0600 "$test_dir/server.pem"
printf '\n' >> "$test_dir/server.pem"
sed -n '1,$p' "$test_dir/server.key" >> "$test_dir/server.pem"

cat > "$test_dir/haproxy.cfg" <<EOF
global
    maxconn 256

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend next_v1_mtls
    bind 127.0.0.1:$PUBLIC_PORT ssl crt $test_dir/server.pem ca-file $test_dir/client.crt verify required ssl-min-ver TLSv1.3 alpn next-v1
    default_backend next_v1_backend

backend next_v1_backend
    server next_v1 127.0.0.1:$BACKEND_PORT send-proxy-v2
EOF

mkdir -p "$test_dir/mihomo"
cp "$test_dir/server.crt" "$test_dir/client.crt" "$test_dir/client.key" "$test_dir/mihomo/"
cat > "$test_dir/mihomo/config.yaml" <<EOF
mixed-port: $MIXED_PORT
allow-lan: false
mode: rule
log-level: debug
ipv6: false
proxies:
  - name: next-v1-e2e
    type: next-v1
    server: 127.0.0.1
    port: $PUBLIC_PORT
    password: $PASSWORD
    udp: true
    tls: true
    servername: next-v1.test
    alpn: [next-v1]
    ca: server.crt
    certificate: client.crt
    private-key: client.key
    skip-cert-verify: false
    padding-min: 0
    padding-max: 64
proxy-groups:
  - name: PROXY
    type: select
    proxies: [next-v1-e2e]
rules:
  - MATCH,PROXY
EOF

cat > "$test_dir/v2node.json" <<EOF
{
  "Log": {"Level": "debug", "Output": "", "Access": "none"},
  "Nodes": [{
    "ApiHost": "http://127.0.0.1:$PANEL_PORT",
    "NodeID": 1,
    "ApiKey": "e2e-token",
    "Timeout": 5,
    "RetryCount": 0
  }]
}
EOF

echo "==> Starting fake panel and echo targets on port base $PORT_BASE"
start_process "$test_dir/panel.log" "$test_dir/nextv1e2e" panel \
    --listen "127.0.0.1:$PANEL_PORT" --backend-port "$BACKEND_PORT" --password "$PASSWORD"
start_process "$test_dir/target.log" "$test_dir/nextv1e2e" target \
    --tcp "127.0.0.1:$TARGET_TCP_PORT" --udp "127.0.0.1:$TARGET_UDP_PORT"
wait_for_tcp "$PANEL_PORT" "fake panel" "$test_dir/panel.log"
wait_for_tcp "$TARGET_TCP_PORT" "echo target" "$test_dir/target.log"

echo "==> Starting v2node, HAProxy mTLS and Mihomo"
start_process "$test_dir/v2node.log" "$test_dir/v2node" server -c "$test_dir/v2node.json" -w=false
wait_for_tcp "$BACKEND_PORT" "v2node" "$test_dir/v2node.log"
start_process "$test_dir/haproxy.log" haproxy -db -f "$test_dir/haproxy.cfg"
wait_for_tcp "$PUBLIC_PORT" "HAProxy" "$test_dir/haproxy.log"

echo "==> Verifying HAProxy rejects missing and untrusted client certificates"
if openssl s_client -brief -tls1_3 -connect "127.0.0.1:$PUBLIC_PORT" \
    -servername next-v1.test -CAfile "$test_dir/server.crt" -verify_return_error \
    </dev/null >"$test_dir/no-client-cert.log" 2>&1; then
    echo "HAProxy accepted a TLS client without a certificate" >&2
    exit 1
fi
if openssl s_client -brief -tls1_3 -connect "127.0.0.1:$PUBLIC_PORT" \
    -servername next-v1.test -CAfile "$test_dir/server.crt" -verify_return_error \
    -cert "$test_dir/untrusted-client.crt" -key "$test_dir/untrusted-client.key" \
    </dev/null >"$test_dir/untrusted-client.log" 2>&1; then
    echo "HAProxy accepted an untrusted client certificate" >&2
    exit 1
fi
start_process "$test_dir/mihomo.log" "$test_dir/mihomo-bin" -d "$test_dir/mihomo" -f "$test_dir/mihomo/config.yaml"
wait_for_tcp "$MIXED_PORT" "Mihomo" "$test_dir/mihomo.log"

echo "==> Probing TCP and UDP-over-TCP through the complete chain"
if ! "$test_dir/nextv1e2e" probe \
    --socks "127.0.0.1:$MIXED_PORT" \
    --tcp "127.0.0.1:$TARGET_TCP_PORT" \
    --udp "127.0.0.1:$TARGET_UDP_PORT"; then
    for log_file in panel target v2node haproxy mihomo; do
        echo "--- $log_file.log ---" >&2
        sed -n '1,260p' "$test_dir/$log_file.log" >&2 || true
    done
    exit 1
fi

echo "Next-V1 full-chain E2E passed: TCP + UDP-over-TCP + TLS 1.3 mTLS + PROXY v2"
