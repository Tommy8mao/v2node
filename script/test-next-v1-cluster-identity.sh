#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=install-next-v1.sh
source "$repo_root/script/install-next-v1.sh"

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/next-v1-cluster-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

server_name="cluster.example.com"
cert_mode="self-signed"
panel_identity_state="empty"
NEXTV1_DIR="$test_dir/machine-a"
install -d -m 0700 "$NEXTV1_DIR/private"
generate_client_identity >/dev/null
generate_self_signed_server >/dev/null

panel_identity_dir="$test_dir/panel"
install -d -m 0700 "$panel_identity_dir"
cp "$NEXTV1_DIR/client-ca.crt" "$panel_identity_dir/client-ca.crt"
cp "$NEXTV1_DIR/shared-client.crt" "$panel_identity_dir/client.crt"
cp "$NEXTV1_DIR/private/shared-client.key" "$panel_identity_dir/client.key"
cp "$NEXTV1_DIR/server-ca.crt" "$panel_identity_dir/server-ca.crt"
cp "$NEXTV1_DIR/server.crt" "$panel_identity_dir/server.crt"
cp "$NEXTV1_DIR/private/server.key" "$panel_identity_dir/server.key"
printf '%s\n' "$server_name" > "$panel_identity_dir/server-name"

client_cert_fingerprint=$(openssl x509 -in "$panel_identity_dir/client.crt" -noout -fingerprint -sha256)
client_key_fingerprint=$(openssl pkey -in "$panel_identity_dir/client.key" -pubout -outform DER |
    openssl sha256)
server_cert_fingerprint=$(openssl x509 -in "$panel_identity_dir/server.crt" -noout -fingerprint -sha256)
server_key_fingerprint=$(openssl pkey -in "$panel_identity_dir/server.key" -pubout -outform DER |
    openssl sha256)

panel_identity_state="complete"
NEXTV1_DIR="$test_dir/machine-b"
install -d -m 0700 "$NEXTV1_DIR/private"
generate_client_identity >/dev/null
generate_self_signed_server >/dev/null

restored_client_cert_fingerprint=$(openssl x509 -in "$NEXTV1_DIR/shared-client.crt" \
    -noout -fingerprint -sha256)
restored_client_key_fingerprint=$(openssl pkey -in "$NEXTV1_DIR/private/shared-client.key" \
    -pubout -outform DER | openssl sha256)
restored_server_cert_fingerprint=$(openssl x509 -in "$NEXTV1_DIR/server.crt" \
    -noout -fingerprint -sha256)
restored_server_key_fingerprint=$(openssl pkey -in "$NEXTV1_DIR/private/server.key" \
    -pubout -outform DER | openssl sha256)
[[ "$restored_client_cert_fingerprint" == "$client_cert_fingerprint" ]]
[[ "$restored_client_key_fingerprint" == "$client_key_fingerprint" ]]
[[ "$restored_server_cert_fingerprint" == "$server_cert_fingerprint" ]]
[[ "$restored_server_key_fingerprint" == "$server_key_fingerprint" ]]
[[ ! -e "$NEXTV1_DIR/private/client-ca.key" ]]
[[ ! -e "$NEXTV1_DIR/private/server-ca.key" ]]

# Client renewal changes only the leaf. Both the cached old leaf and the new
# leaf remain valid against the unchanged CA trusted by every HAProxy member.
NEXTV1_DIR="$test_dir/machine-a"
rotate_client=true
old_ca_fingerprint=$(openssl x509 -in "$NEXTV1_DIR/client-ca.crt" -noout -fingerprint -sha256)
generate_client_identity >/dev/null
new_ca_fingerprint=$(openssl x509 -in "$NEXTV1_DIR/client-ca.crt" -noout -fingerprint -sha256)
new_client_fingerprint=$(openssl x509 -in "$NEXTV1_DIR/shared-client.crt" -noout -fingerprint -sha256)
[[ "$old_ca_fingerprint" == "$new_ca_fingerprint" ]]
[[ "$client_cert_fingerprint" != "$new_client_fingerprint" ]]
openssl verify -purpose sslclient -CAfile "$NEXTV1_DIR/client-ca.crt" \
    "$test_dir/machine-b/shared-client.crt" >/dev/null
openssl verify -purpose sslclient -CAfile "$NEXTV1_DIR/client-ca.crt" \
    "$NEXTV1_DIR/shared-client.crt" >/dev/null
rotate_client=false

# If the panel already holds a newer leaf after an interrupted run, recovery
# must preserve the original machine's matching CA signing keys.
cp "$NEXTV1_DIR/shared-client.crt" "$panel_identity_dir/client.crt"
cp "$NEXTV1_DIR/private/shared-client.key" "$panel_identity_dir/client.key"
cp "$NEXTV1_DIR/private/server-ca.key" "$test_dir/server-ca-key.before"
cp "$NEXTV1_DIR/private/client-ca.key" "$test_dir/client-ca-key.before"
cp "$test_dir/machine-b/shared-client.crt" "$NEXTV1_DIR/shared-client.crt"
cp "$test_dir/machine-b/private/shared-client.key" "$NEXTV1_DIR/private/shared-client.key"
generate_client_identity >/dev/null
same_private_key "$NEXTV1_DIR/private/client-ca.key" "$test_dir/client-ca-key.before"

cp "$NEXTV1_DIR/server.crt" "$panel_identity_dir/server.crt"
cp "$NEXTV1_DIR/private/server.key" "$panel_identity_dir/server.key"
cp "$test_dir/machine-b/server.crt" "$NEXTV1_DIR/server.crt"
cp "$test_dir/machine-b/private/server.key" "$NEXTV1_DIR/private/server.key"
generate_self_signed_server >/dev/null
same_private_key "$NEXTV1_DIR/private/server-ca.key" "$test_dir/server-ca-key.before"

# A stale/different SNI may never trigger a fresh self-signed CA when the
# panel already owns a complete identity.
NEXTV1_DIR="$test_dir/wrong-sni"
install -d -m 0700 "$NEXTV1_DIR/private"
server_name="replacement.example.com"
if (generate_self_signed_server >/dev/null 2>&1); then
    printf '%s\n' 'expected a complete panel identity with a different SNI to fail closed' >&2
    exit 1
fi
server_name="cluster.example.com"

# Partial local identities must fail closed instead of silently creating a new CA.
NEXTV1_DIR="$test_dir/incomplete"
install -d -m 0700 "$NEXTV1_DIR/private"
cp "$panel_identity_dir/server.crt" "$NEXTV1_DIR/server.crt"
if (panel_identity_dir=""; panel_identity_state="empty"; generate_self_signed_server >/dev/null 2>&1); then
    printf '%s\n' 'expected an incomplete self-signed identity to fail closed' >&2
    exit 1
fi

printf '%s\n' 'Next-V1 cluster identity recovery test passed'
