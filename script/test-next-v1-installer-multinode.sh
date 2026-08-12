#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install-next-v1.sh
source "$SCRIPT_DIR/install-next-v1.sh"

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/next-v1-installer-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

config="$test_dir/config.json"
candidate="$test_dir/config.json.new"
key_a="$test_dir/key-a"
key_b="$test_dir/key-b"
printf '%s' 'key-a-original' > "$key_a"
printf '%s' 'key-b' > "$key_b"
jq -n '{Log:{Level:"warning"},Nodes:[]}' > "$config"

upsert_v2node_node "$config" "$candidate" 'https://panel.example' 1 "$key_a"
upsert_v2node_node "$config" "$candidate" 'https://panel.example' 2 "$key_b"
printf '%s' 'key-a-rotated' > "$key_a"
upsert_v2node_node "$config" "$candidate" '  https://panel.example///  ' 1 "$key_a"

jq -e '
    (.Nodes | length) == 2 and
    (.Nodes[0] | .ApiHost == "https://panel.example" and .NodeID == 1 and .ApiKey == "key-a-rotated") and
    (.Nodes[1] | .ApiHost == "https://panel.example" and .NodeID == 2 and .ApiKey == "key-b")
' "$config" >/dev/null

curl() {
    printf '%s\n' '{"protocol":"next-v1","server_port":24443,"outer_tls":{"frontend_port":443}}'
}
api_host='https://new-panel.example'
node_id=3
frontend_port=443
backend_port=34443
if (validate_requested_port_conflicts "$config" >/dev/null 2>&1); then
    printf '%s\n' 'expected HAProxy frontend conflict to be rejected' >&2
    exit 1
fi
frontend_port=9443
backend_port=34443
validate_requested_port_conflicts "$config" >/dev/null

client_ca_key="$test_dir/client-ca.key"
client_ca_cert="$test_dir/client-ca.crt"
client_key="$test_dir/client.key"
client_csr="$test_dir/client.csr"
client_cert="$test_dir/client.crt"
client_ext="$test_dir/client.ext"
wrong_key="$test_dir/wrong.key"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$client_ca_key" >/dev/null 2>&1
openssl req -x509 -new -sha256 -days 365 -key "$client_ca_key" -subj '/CN=Test Client CA' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' -out "$client_ca_cert" >/dev/null 2>&1
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$client_key" >/dev/null 2>&1
openssl req -new -sha256 -key "$client_key" -subj '/CN=Shared Test Client' \
    -out "$client_csr" >/dev/null 2>&1
printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=clientAuth' > "$client_ext"
openssl x509 -req -sha256 -days 365 -in "$client_csr" -CA "$client_ca_cert" \
    -CAkey "$client_ca_key" -CAcreateserial -extfile "$client_ext" \
    -out "$client_cert" >/dev/null 2>&1
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$wrong_key" >/dev/null 2>&1
client_identity_is_valid "$client_ca_cert" "$client_cert" "$client_key"
if client_identity_is_valid "$client_ca_cert" "$client_cert" "$wrong_key"; then
    printf '%s\n' 'expected mismatched reusable client identity to be rejected' >&2
    exit 1
fi

printf '%s\n' 'Next-V1 installer multi-node config test passed'
