#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM="${0##*/}"
readonly INSTALL_DIR="/usr/local/v2node"
readonly V2NODE_CONFIG_DIR="/etc/v2node"
readonly NEXTV1_DIR="/etc/next-v1"
readonly HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"

frontend_port=443
backend_host="127.0.0.1"
backend_port=24443
server_name="next-v1.local"
cert_mode="self-signed"
letsencrypt_email=""
existing_server_cert=""
existing_server_key=""
binary_path=""
api_host=""
node_id=""
api_key="${V2NODE_API_KEY:-}"
rotate_client=false
replace_haproxy_config=false

usage() {
    cat <<'EOF'
Install v2node Next-V1 behind HAProxy TLS 1.3 mutual TLS.

Usage:
  sudo ./install-next-v1.sh [options]

TLS options:
  --self-signed                 Generate a private server CA (default)
  --letsencrypt                 Request a public server certificate
  --existing-cert FILE          Use an existing server certificate/full chain
  --existing-key FILE           Use the matching existing private key
  --server-name NAME            Certificate DNS name (default: next-v1.local)
  --email ADDRESS               Required with --letsencrypt
  --rotate-client               Replace the shared mTLS client certificate
  --replace-haproxy-config      Replace an HAProxy config with existing routes

Service options:
  --frontend-port PORT          HAProxy public port (default: 443)
  --backend-port PORT           Loopback v2node port (default: 24443)
  --binary FILE                 Install this Next-V1 v2node binary
  --api-host URL                Panel URL for a new v2node config
  --node-id ID                  Panel node ID for a new v2node config
  --api-key KEY                 Panel API key (or set V2NODE_API_KEY)
  -h, --help                    Show this help

The three panel options are only required when /etc/v2node/config.json does not
already exist. The panel node's Next-V1 backend port must equal --backend-port.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

require_value() {
    [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "invalid port: $1"
    (( 1 <= 10#$1 && 10#$1 <= 65535 )) || die "port out of range: $1"
}

validate_server_name() {
    [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid server name: $1"
    [[ "$1" != .* && "$1" != *. && "$1" != *..* ]] || die "invalid server name: $1"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --self-signed)
                cert_mode="self-signed"; shift ;;
            --letsencrypt)
                cert_mode="letsencrypt"; shift ;;
            --existing-cert)
                require_value "$@"; cert_mode="existing"; existing_server_cert="$2"; shift 2 ;;
            --existing-key)
                require_value "$@"; existing_server_key="$2"; shift 2 ;;
            --server-name)
                require_value "$@"; server_name="$2"; shift 2 ;;
            --email)
                require_value "$@"; letsencrypt_email="$2"; shift 2 ;;
            --frontend-port)
                require_value "$@"; frontend_port="$2"; shift 2 ;;
            --backend-port)
                require_value "$@"; backend_port="$2"; shift 2 ;;
            --binary)
                require_value "$@"; binary_path="$2"; shift 2 ;;
            --api-host)
                require_value "$@"; api_host="$2"; shift 2 ;;
            --node-id)
                require_value "$@"; node_id="$2"; shift 2 ;;
            --api-key)
                require_value "$@"; api_key="$2"; shift 2 ;;
            --rotate-client)
                rotate_client=true; shift ;;
            --replace-haproxy-config)
                replace_haproxy_config=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "unknown argument: $1" ;;
        esac
    done
}

validate_args() {
    [[ ${EUID} -eq 0 ]] || die "run as root"
    [[ -r /etc/os-release ]] || die "only Ubuntu and Debian are supported"
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "only Ubuntu and Debian are supported (found ${ID:-unknown})" ;;
    esac

    validate_port "$frontend_port"
    validate_port "$backend_port"
    validate_server_name "$server_name"
    [[ "$frontend_port" != "$backend_port" ]] || die "frontend and backend ports must differ"

    case "$cert_mode" in
        self-signed) ;;
        letsencrypt)
            [[ "$server_name" == *.* && "$server_name" != "next-v1.local" ]] ||
                die "--letsencrypt requires a public --server-name"
            [[ "$letsencrypt_email" == *@* ]] || die "--letsencrypt requires --email"
            ;;
        existing)
            [[ -r "$existing_server_cert" ]] || die "cannot read --existing-cert"
            [[ -r "$existing_server_key" ]] || die "cannot read --existing-key"
            ;;
        *) die "invalid certificate mode" ;;
    esac

    if [[ -n "$binary_path" ]]; then
        [[ -f "$binary_path" && -r "$binary_path" ]] || die "cannot read --binary $binary_path"
    fi
    if [[ -n "$node_id" ]]; then
        [[ "$node_id" =~ ^[0-9]+$ && "$node_id" != 0 ]] || die "invalid --node-id"
    fi
    if [[ (-n "$binary_path" || -x "$INSTALL_DIR/v2node") && ! -f "$V2NODE_CONFIG_DIR/config.json" ]]; then
        [[ -n "$api_host" && -n "$node_id" && -n "$api_key" ]] ||
            die "new v2node install requires --api-host, --node-id and --api-key"
    fi
    if [[ -f "$HAPROXY_CONFIG" ]] &&
          ! grep -q '^# Managed by Next-V1 installer$' "$HAPROXY_CONFIG" &&
          grep -Eq '^[[:space:]]*(frontend|listen|backend)[[:space:]]+' "$HAPROXY_CONFIG" &&
          [[ "$replace_haproxy_config" != true ]]; then
        die "HAProxy already has routes; use a dedicated server or pass --replace-haproxy-config"
    fi
}

install_packages() {
    local packages=(haproxy openssl ca-certificates jq iproute2)
    [[ "$cert_mode" == "letsencrypt" ]] && packages+=(certbot)
    info "Installing required packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${packages[@]}"
}

prepare_directories() {
    install -d -m 0755 "$INSTALL_DIR" "$V2NODE_CONFIG_DIR"
    install -d -m 0700 "$NEXTV1_DIR" "$NEXTV1_DIR/private"
}

certificate_matches_key() {
    local certificate="$1"
    local private_key="$2"
    local certificate_public_key private_public_key
    certificate_public_key=$(openssl x509 -in "$certificate" -pubkey -noout |
        openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256) || return 1
    private_public_key=$(openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null |
        openssl sha256) || return 1
    [[ "$certificate_public_key" == "$private_public_key" ]]
}

generate_client_identity() {
    local ca_key="$NEXTV1_DIR/private/client-ca.key"
    local ca_cert="$NEXTV1_DIR/client-ca.crt"
    local client_key="$NEXTV1_DIR/private/shared-client.key"
    local client_csr="$NEXTV1_DIR/private/shared-client.csr"
    local client_cert="$NEXTV1_DIR/shared-client.crt"
    local client_ext="$NEXTV1_DIR/private/client.ext"

    if [[ "$rotate_client" == false && (-e "$ca_key" || -e "$ca_cert" || -e "$client_key" || -e "$client_cert") ]]; then
        if [[ -s "$ca_key" && -s "$ca_cert" && -s "$client_key" && -s "$client_cert" ]] &&
              openssl x509 -in "$ca_cert" -noout -checkend 2592000 >/dev/null 2>&1 &&
              openssl x509 -in "$client_cert" -noout -checkend 2592000 >/dev/null 2>&1 &&
              openssl verify -CAfile "$ca_cert" "$client_cert" >/dev/null 2>&1 &&
              certificate_matches_key "$client_cert" "$client_key" &&
              certificate_matches_key "$ca_cert" "$ca_key"; then
            info "Keeping existing shared mTLS client identity"
            return
        fi
        die "existing client identity is incomplete, mismatched, or expires within 30 days; inspect it and use --rotate-client"
    fi

    if [[ "$rotate_client" == true ]]; then
        info "Rotating shared mTLS client CA and certificate"
    else
        info "Generating shared mTLS client CA and certificate"
    fi
    umask 077
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ca_key"
    openssl req -x509 -new -sha256 -days 3650 -key "$ca_key" \
        -subj "/CN=Next-V1 Client CA" \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' -out "$ca_cert"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$client_key"
    openssl req -new -sha256 -key "$client_key" \
        -subj "/CN=Next-V1 Shared Client" -out "$client_csr"
    printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
        'keyUsage=critical,digitalSignature' \
        'extendedKeyUsage=clientAuth' > "$client_ext"
    openssl x509 -req -sha256 -days 825 -in "$client_csr" \
        -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -extfile "$client_ext" -out "$client_cert"
    chmod 0600 "$ca_key" "$client_key"
    chmod 0644 "$ca_cert" "$client_cert"
}

generate_self_signed_server() {
    local ca_key="$NEXTV1_DIR/private/server-ca.key"
    local ca_cert="$NEXTV1_DIR/server-ca.crt"
    local server_key="$NEXTV1_DIR/private/server.key"
    local server_csr="$NEXTV1_DIR/private/server.csr"
    local server_cert="$NEXTV1_DIR/server.crt"
    local server_ext="$NEXTV1_DIR/private/server.ext"
    local fullchain="$NEXTV1_DIR/server-fullchain.pem"
    local identity_name="$NEXTV1_DIR/private/server-name"

    if [[ -s "$server_key" && -s "$server_cert" && -s "$ca_cert" &&
          -s "$fullchain" && -s "$identity_name" &&
          "$(cat "$identity_name")" == "$server_name" ]] &&
          openssl x509 -in "$server_cert" -noout -checkend 86400 >/dev/null 2>&1; then
        info "Keeping existing self-signed server identity for $server_name"
        install -m 0600 "$server_key" "$NEXTV1_DIR/private/haproxy-server.key"
        return
    fi

    info "Generating self-signed server certificate for $server_name"
    umask 077
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ca_key"
    openssl req -x509 -new -sha256 -days 3650 -key "$ca_key" \
        -subj "/CN=Next-V1 Server CA" \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' -out "$ca_cert"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$server_key"
    openssl req -new -sha256 -key "$server_key" \
        -subj "/CN=$server_name" -out "$server_csr"
    printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
        'keyUsage=critical,digitalSignature,keyEncipherment' \
        'extendedKeyUsage=serverAuth' \
        "subjectAltName=DNS:$server_name" > "$server_ext"
    openssl x509 -req -sha256 -days 825 -in "$server_csr" \
        -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -extfile "$server_ext" -out "$server_cert"
    {
        sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$server_cert"
        sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$ca_cert"
    } > "$fullchain"
    printf '%s\n' "$server_name" > "$identity_name"
    install -m 0600 "$server_key" "$NEXTV1_DIR/private/haproxy-server.key"
}

request_letsencrypt_server() {
    info "Requesting Let's Encrypt certificate for $server_name"
    if ! certbot certonly --standalone --non-interactive --agree-tos \
        --preferred-challenges http --email "$letsencrypt_email" -d "$server_name"; then
        die "Let's Encrypt request failed; verify DNS and that inbound port 80 is free"
    fi
    install -m 0644 "/etc/letsencrypt/live/$server_name/fullchain.pem" \
        "$NEXTV1_DIR/server-fullchain.pem"
    install -m 0600 "/etc/letsencrypt/live/$server_name/privkey.pem" \
        "$NEXTV1_DIR/private/haproxy-server.key"

    local hook="/etc/letsencrypt/renewal-hooks/deploy/next-v1-haproxy"
    cat > "$hook" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
install -m 0644 "/etc/letsencrypt/live/$server_name/fullchain.pem" "$NEXTV1_DIR/server-fullchain.pem"
install -m 0600 "/etc/letsencrypt/live/$server_name/privkey.pem" "$NEXTV1_DIR/private/haproxy-server.key"
cat "$NEXTV1_DIR/server-fullchain.pem" "$NEXTV1_DIR/private/haproxy-server.key" > "$NEXTV1_DIR/private/haproxy.pem.new"
chmod 0600 "$NEXTV1_DIR/private/haproxy.pem.new"
mv "$NEXTV1_DIR/private/haproxy.pem.new" "$NEXTV1_DIR/private/haproxy.pem"
haproxy -c -f "$HAPROXY_CONFIG"
systemctl reload haproxy
EOF
    chmod 0755 "$hook"
}

install_existing_server() {
    info "Installing existing server certificate"
    openssl x509 -in "$existing_server_cert" -noout >/dev/null
    openssl pkey -in "$existing_server_key" -noout >/dev/null
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$existing_server_cert" -pubkey -noout | openssl pkey -pubin -outform DER | openssl sha256)
    key_pub=$(openssl pkey -in "$existing_server_key" -pubout -outform DER | openssl sha256)
    [[ "$cert_pub" == "$key_pub" ]] || die "existing certificate and key do not match"
    install -m 0644 "$existing_server_cert" "$NEXTV1_DIR/server-fullchain.pem"
    install -m 0600 "$existing_server_key" "$NEXTV1_DIR/private/haproxy-server.key"
}

prepare_server_identity() {
    if [[ "$cert_mode" != "letsencrypt" ]]; then
        rm -f /etc/letsencrypt/renewal-hooks/deploy/next-v1-haproxy
    fi
    case "$cert_mode" in
        self-signed) generate_self_signed_server ;;
        letsencrypt) request_letsencrypt_server ;;
        existing) install_existing_server ;;
    esac
    {
        sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$NEXTV1_DIR/server-fullchain.pem"
        cat "$NEXTV1_DIR/private/haproxy-server.key"
    } > "$NEXTV1_DIR/private/haproxy.pem"
    chmod 0600 "$NEXTV1_DIR/private/haproxy.pem"
    openssl x509 -in "$NEXTV1_DIR/server-fullchain.pem" -noout -checkend 86400 >/dev/null ||
        die "server certificate expires in less than 24 hours"
}

configure_haproxy() {
    info "Configuring HAProxy mTLS on port $frontend_port"
    local backup=""
    local candidate="$HAPROXY_CONFIG.next-v1.new"
    if [[ -f "$HAPROXY_CONFIG" ]]; then
        if ! grep -q '^# Managed by Next-V1 installer$' "$HAPROXY_CONFIG" &&
              grep -Eq '^[[:space:]]*(frontend|listen|backend)[[:space:]]+' "$HAPROXY_CONFIG" &&
              [[ "$replace_haproxy_config" != true ]]; then
            die "HAProxy already has routes; re-run with --replace-haproxy-config on a dedicated server"
        fi
        backup="$HAPROXY_CONFIG.next-v1.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$HAPROXY_CONFIG" "$backup"
    fi
    cat > "$candidate" <<EOF
# Managed by Next-V1 installer
global
    log /dev/log local0
    log /dev/log local1 notice
    user haproxy
    group haproxy
    daemon
    ssl-default-bind-options ssl-min-ver TLSv1.3 no-tls-tickets

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend next_v1_mtls
    bind :$frontend_port ssl crt $NEXTV1_DIR/private/haproxy.pem ca-file $NEXTV1_DIR/client-ca.crt verify required alpn next-v1
    default_backend next_v1_backend

backend next_v1_backend
    server next_v1 $backend_host:$backend_port send-proxy-v2 check inter 3s fall 3 rise 2
EOF
    if ! haproxy -c -f "$candidate"; then
        rm -f "$candidate"
        die "new HAProxy configuration did not validate; existing configuration was not changed"
    fi
    chmod 0644 "$candidate"
    mv "$candidate" "$HAPROXY_CONFIG"
    if ! systemctl enable haproxy; then
        if [[ -n "$backup" ]]; then
            cp -a "$backup" "$HAPROXY_CONFIG"
        else
            mv "$HAPROXY_CONFIG" "$HAPROXY_CONFIG.next-v1.failed"
        fi
        die "could not enable HAProxy; the previous configuration was restored when available"
    fi
    if systemctl is-active --quiet haproxy; then
        if ! systemctl reload haproxy; then
            if [[ -n "$backup" ]]; then
                cp -a "$backup" "$HAPROXY_CONFIG"
                systemctl restart haproxy || true
            else
                mv "$HAPROXY_CONFIG" "$HAPROXY_CONFIG.next-v1.failed"
            fi
            die "HAProxy reload failed; the previous configuration was restored"
        fi
    else
        if ! systemctl start haproxy; then
            if [[ -n "$backup" ]]; then
                cp -a "$backup" "$HAPROXY_CONFIG"
                systemctl restart haproxy || true
            else
                mv "$HAPROXY_CONFIG" "$HAPROXY_CONFIG.next-v1.failed"
            fi
            die "HAProxy start failed; the previous configuration was restored when available"
        fi
    fi
}

install_v2node() {
    if [[ -n "$binary_path" ]]; then
        info "Installing Next-V1 v2node binary"
        install -m 0755 "$binary_path" "$INSTALL_DIR/v2node"
    fi
    if [[ ! -x "$INSTALL_DIR/v2node" ]]; then
        info "No v2node binary installed; HAProxy/certificates will still be configured"
        return
    fi

    if [[ ! -f "$V2NODE_CONFIG_DIR/config.json" ]]; then
        [[ -n "$api_host" && -n "$node_id" && -n "$api_key" ]] ||
            die "new v2node install requires --api-host, --node-id and --api-key"
        umask 077
        jq -n --arg host "$api_host" --argjson id "$node_id" --arg key "$api_key" \
            '{Log:{Level:"warning",Output:"",Access:"none"},Nodes:[{ApiHost:$host,NodeID:$id,ApiKey:$key,Timeout:15}]}' \
            > "$V2NODE_CONFIG_DIR/config.json"
        chmod 0600 "$V2NODE_CONFIG_DIR/config.json"
    fi

    cat > /etc/systemd/system/v2node.service <<EOF
[Unit]
Description=v2node Next-V1 service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/v2node server --config $V2NODE_CONFIG_DIR/config.json
Restart=always
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now v2node
    local attempt
    for attempt in $(seq 1 15); do
        if systemctl is-active --quiet v2node &&
              ss -ltnH | awk '{print $4}' | grep -Eq "127\\.0\\.0\\.1:$backend_port$"; then
            return
        fi
        sleep 1
    done
    journalctl -u v2node -n 30 --no-pager >&2 || true
    die "v2node did not become active on 127.0.0.1:$backend_port"
}

write_client_bundle() {
    local fingerprint
    fingerprint=$(openssl x509 -in "$NEXTV1_DIR/server-fullchain.pem" -outform DER |
        openssl dgst -sha256 -hex | awk '{print $2}')
    local bundle="$NEXTV1_DIR/client.yaml"
    umask 077
    {
        printf 'tls: true\n'
        printf 'servername: %s\n' "$server_name"
        printf 'alpn:\n  - next-v1\n'
        if [[ "$cert_mode" == "self-signed" ]]; then
            printf 'fingerprint: %s\n' "$fingerprint"
        fi
        printf 'client-fingerprint: chrome\n'
        printf 'skip-cert-verify: false\n'
        if [[ "$cert_mode" == "self-signed" ]]; then
            printf 'ca: |-\n'
            sed 's/^/  /' "$NEXTV1_DIR/server-ca.crt"
        fi
        printf 'certificate: |-\n'
        sed 's/^/  /' "$NEXTV1_DIR/shared-client.crt"
        printf 'private-key: |-\n'
        sed 's/^/  /' "$NEXTV1_DIR/private/shared-client.key"
    } > "$bundle"
    chmod 0600 "$bundle"
}

print_summary() {
    local fingerprint
    fingerprint=$(openssl x509 -in "$NEXTV1_DIR/server-fullchain.pem" -outform DER |
        openssl dgst -sha256 -hex | awk '{print $2}')
    cat <<EOF

Next-V1 outer mTLS is ready.
  Public address:       $server_name:$frontend_port
  v2node backend:       $backend_host:$backend_port
  Server cert mode:     $cert_mode
  Server SHA-256 pin:   $fingerprint
  Client bundle:        $NEXTV1_DIR/client.yaml (secret, mode 0600)

Set the panel node backend port to $backend_port. Copy the client certificate,
private key and TLS fields from client.yaml into the panel's shared Next-V1
subscription settings. Do not publish that file or the private client CA.
EOF
}

main() {
    parse_args "$@"
    validate_args
    install_packages
    prepare_directories
    generate_client_identity
    prepare_server_identity
    configure_haproxy
    install_v2node
    write_client_bundle
    print_summary
}

main "$@"
