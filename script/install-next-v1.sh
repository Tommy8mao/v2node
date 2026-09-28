#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly PROGRAM="${0##*/}"
readonly INSTALL_DIR="/usr/local/v2node"
readonly V2NODE_CONFIG_DIR="/etc/v2node"
readonly NEXTV1_ROOT="/etc/next-v1"
readonly NEXTV1_NODES_DIR="$NEXTV1_ROOT/nodes"
readonly HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"
readonly DEFAULT_RELEASE_REPOSITORY="Tommy8mao/v2node"
readonly DEFAULT_RELEASE_VERSION="v0.4.4-next-v1.6"

frontend_port=443
backend_host="127.0.0.1"
backend_port=24443
server_name="next-v1.local"
cert_mode="self-signed"
letsencrypt_email=""
existing_server_cert=""
existing_server_key=""
binary_path=""
release_repository="${NEXT_V1_RELEASE_REPOSITORY:-$DEFAULT_RELEASE_REPOSITORY}"
release_version="${NEXT_V1_VERSION:-$DEFAULT_RELEASE_VERSION}"
archive_sha256_amd64="${NEXT_V1_SHA256_AMD64:-}"
archive_sha256_arm64="${NEXT_V1_SHA256_ARM64:-}"
api_host=""
node_id=""
api_key="${V2NODE_API_KEY:-}"
api_key_file=""
bootstrap_token=""
bootstrap_token_file=""
staged_binary=""
rotate_client=false
rotate_server=false
replace_haproxy_config=false
bootstrap_published=false
node_key=""
NEXTV1_DIR=""
activation_rollback_dir=""
identity_rollback_dir=""
port_check_token_file=""
panel_identity_dir=""
bootstrap_config_dir=""
bootstrap_publish_dir=""
panel_identity_state="unknown"
panel_certificate_mode="unknown"
legacy_identity_verified=false
manual_credential_file=""

cleanup_runtime_files() {
    if [[ -n "$identity_rollback_dir" ]]; then
        rollback_identity || true
    fi
    if [[ -n "$activation_rollback_dir" ]]; then
        rollback_activation || true
    fi
    [[ -n "$api_key_file" ]] && rm -f "$api_key_file" "$api_key_file.next"
    if [[ -n "$manual_credential_file" &&
          "$manual_credential_file" == "$NEXTV1_DIR/private/panel-api-key.manual.tmp" ]]; then
        rm -f "$manual_credential_file"
    fi
    [[ -n "$bootstrap_token_file" ]] && rm -f "$bootstrap_token_file" "$bootstrap_token_file.next"
    [[ -n "$port_check_token_file" ]] && rm -f "$port_check_token_file"
    if [[ -n "$bootstrap_config_dir" &&
          "$bootstrap_config_dir" == "$NEXTV1_DIR/private"/bootstrap-config.* ]]; then
        rm -rf -- "$bootstrap_config_dir"
    fi
    if [[ -n "$bootstrap_publish_dir" &&
          "$bootstrap_publish_dir" == "$NEXTV1_DIR/private"/bootstrap-publish.* ]]; then
        rm -rf -- "$bootstrap_publish_dir"
    fi
    if [[ -n "$panel_identity_dir" &&
          "$panel_identity_dir" == "$NEXTV1_DIR/private"/panel-identity.* ]]; then
        rm -rf -- "$panel_identity_dir"
    fi
    [[ -n "$staged_binary" ]] && rm -f "$staged_binary"
    rm -f "$INSTALL_DIR/geoip.dat.next-v1.new" "$INSTALL_DIR/geosite.dat.next-v1.new"
    rm -f "$V2NODE_CONFIG_DIR/config.json.next-v1.new" \
        "$V2NODE_CONFIG_DIR/config.json.next-v1.upsert" \
        /etc/systemd/system/v2node.service.next-v1.new
    if [[ -n "$activation_rollback_dir" &&
          "$activation_rollback_dir" == "$NEXTV1_ROOT"/activation-rollback.* ]]; then
        rm -rf -- "$activation_rollback_dir"
    fi
    if [[ -n "$identity_rollback_dir" &&
          "$identity_rollback_dir" == "$NEXTV1_ROOT"/identity-rollback.* ]]; then
        rm -rf -- "$identity_rollback_dir"
    fi
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap cleanup_runtime_files EXIT
fi

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
  --rotate-client               Renew the shared client leaf with its existing CA
  --rotate-server               Renew the self-signed server leaf with its existing CA
  --replace-haproxy-config      Authorize takeover of a non-Next-V1 HAProxy config

Service options:
  --frontend-port PORT          HAProxy public port (default: 443)
  --backend-port PORT           Loopback v2node port (default: 24443)
  --binary FILE                 Install this v2node binary instead of downloading
  --release-repository REPO     GitHub release repository (default: Tommy8mao/v2node)
  --version TAG                 Install a release tag instead of latest
  --archive-sha256-amd64 HASH   Pin the Linux amd64 release archive
  --archive-sha256-arm64 HASH   Pin the Linux arm64 release archive
  --api-host URL                Panel URL for a new v2node config
  --node-id ID                  Panel node ID for a new v2node config
  --api-key KEY                 Legacy existing-machine credential; not for first install
  --bootstrap-token-stdin       Read the one-time node token from standard input
  -h, --help                    Show this help

Each panel node is added to the shared v2node process and receives an isolated
certificate directory and HAProxy frontend/backend. Re-running a node command
updates only that node. The panel backend port must equal --backend-port.
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

is_managed_haproxy_config() {
    [[ -f "$HAPROXY_CONFIG" ]] || return 1
    local header=""
    IFS= read -r header < "$HAPROXY_CONFIG" || true
    case "$header" in
        '# Managed by Next-V1 installer'|'# Managed by Next-V1 v2node HAProxy manager'|'# Managed by v2node Next-V1 HAProxy manager') return 0 ;;
        *) return 1 ;;
    esac
}

validate_server_name() {
    [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid server name: $1"
    [[ "$1" != .* && "$1" != *. && "$1" != *..* ]] || die "invalid server name: $1"
}

server_subject_alt_name() {
    local value="$1" octet
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local -a octets
        IFS=. read -r -a octets <<<"$value"
        for octet in "${octets[@]}"; do
            ((10#$octet <= 255)) || die "invalid IPv4 server name: $value"
        done
        printf 'IP:%s\n' "$value"
    else
        printf 'DNS:%s\n' "$value"
    fi
}

normalize_api_host() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done
    printf '%s\n' "$value"
}

initialize_node_context() {
    if [[ -z "$api_host" || -z "$node_id" ]]; then
        if [[ -f "$V2NODE_CONFIG_DIR/config.json" ]] && command -v jq >/dev/null 2>&1 &&
              [[ "$(jq -r '(.Nodes // []) | length' "$V2NODE_CONFIG_DIR/config.json" 2>/dev/null)" == "1" ]]; then
            api_host="${api_host:-$(jq -er '.Nodes[0].ApiHost' "$V2NODE_CONFIG_DIR/config.json")}"
            node_id="${node_id:-$(jq -er '.Nodes[0].NodeID' "$V2NODE_CONFIG_DIR/config.json")}"
        fi
    fi
    [[ -n "$api_host" && -n "$node_id" ]] ||
        die "--api-host and --node-id are required when managing multiple nodes"
    api_host=$(normalize_api_host "$api_host")
    node_key=$(printf '%s:%s' "$api_host" "$node_id" | sha256sum | awk '{print substr($1,1,16)}')
    [[ "$node_key" =~ ^[a-f0-9]{16}$ ]] || die "could not derive the node instance key"
    NEXTV1_DIR="$NEXTV1_NODES_DIR/$node_key"
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
            --release-repository)
                require_value "$@"; release_repository="$2"; shift 2 ;;
            --version)
                require_value "$@"; release_version="$2"; shift 2 ;;
            --archive-sha256-amd64)
                require_value "$@"; archive_sha256_amd64="${2,,}"; shift 2 ;;
            --archive-sha256-arm64)
                require_value "$@"; archive_sha256_arm64="${2,,}"; shift 2 ;;
            --api-host)
                require_value "$@"; api_host="$2"; shift 2 ;;
            --node-id)
                require_value "$@"; node_id="$2"; shift 2 ;;
            --api-key)
                require_value "$@"; api_key="$2"; shift 2 ;;
            --bootstrap-token-stdin)
                IFS= read -r bootstrap_token || die "could not read bootstrap token from stdin"
                shift ;;
            --rotate-client)
                rotate_client=true; shift ;;
            --rotate-server)
                rotate_server=true; shift ;;
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
    [[ "$release_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
        die "invalid GitHub --release-repository"
    [[ "$release_version" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid --version"
    [[ -z "$archive_sha256_amd64" || "$archive_sha256_amd64" =~ ^[a-f0-9]{64}$ ]] ||
        die "invalid --archive-sha256-amd64"
    [[ -z "$archive_sha256_arm64" || "$archive_sha256_arm64" =~ ^[a-f0-9]{64}$ ]] ||
        die "invalid --archive-sha256-arm64"
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
    if [[ "$rotate_server" == true && "$cert_mode" != "self-signed" ]]; then
        die "--rotate-server is only valid with --self-signed"
    fi

    if [[ -n "$binary_path" ]]; then
        [[ -f "$binary_path" && -r "$binary_path" ]] || die "cannot read --binary $binary_path"
    fi
    if [[ -n "$node_id" ]]; then
        [[ "$node_id" =~ ^[0-9]+$ && "$node_id" != 0 ]] || die "invalid --node-id"
    fi
    if [[ -n "$bootstrap_token" ]]; then
        [[ "$bootstrap_token" =~ ^[a-f0-9]{64}$ ]] || die "invalid --bootstrap-token"
        # A one-time bootstrap must fetch the panel-authoritative cluster identity.
        # Ignore a stale environment API key instead of silently skipping recovery.
        api_key=""
    fi
    [[ -n "$api_host" && -n "$node_id" ]] || die "panel host and node ID are required"
    if [[ -n "$api_key" && -z "$bootstrap_token" ]]; then
        die "--api-key/V2NODE_API_KEY cannot create or recover cluster identity; use the panel one-time command"
    fi
    if [[ ! -f "$V2NODE_CONFIG_DIR/config.json" ]]; then
        [[ -n "$api_key" || -n "$bootstrap_token" ]] ||
            die "new v2node install requires bootstrap credentials"
    fi
    if [[ -n "$bootstrap_token" ]]; then
        if [[ ! "$api_host" =~ ^https:// ]] &&
              [[ ! "$api_host" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/|$) ]]; then
            die "--api-host must use HTTPS when bootstrap credentials are uploaded"
        fi
    fi
    if [[ -f "$HAPROXY_CONFIG" ]] &&
          ! is_managed_haproxy_config &&
          grep -Eq '^[[:space:]]*(frontend|listen|backend)[[:space:]]+' "$HAPROXY_CONFIG" &&
          [[ "$replace_haproxy_config" != true ]]; then
        die "HAProxy already has routes; use a dedicated server or pass --replace-haproxy-config"
    fi
}

validate_existing_v2node_config() {
    [[ -f "$V2NODE_CONFIG_DIR/config.json" ]] || return 0
    command -v jq >/dev/null || die "jq is required to validate the existing v2node config"
    jq -e '.Nodes | type == "array" and all(.[]; (.ApiHost | type == "string" and length > 0) and (.NodeID | type == "number"))' \
        "$V2NODE_CONFIG_DIR/config.json" >/dev/null || die "existing v2node config has an invalid Nodes array"
    local matches
    matches=$(jq --arg host "$api_host" --argjson id "$node_id" \
        '[.Nodes[] | select((.ApiHost | sub("/+$"; "")) == $host and .NodeID == $id)] | length' \
        "$V2NODE_CONFIG_DIR/config.json")
    (( matches <= 1 )) || die "existing v2node config contains a duplicate panel node"
}

install_packages() {
    local packages=(haproxy openssl ca-certificates jq iproute2 curl unzip util-linux)
    [[ "$cert_mode" == "letsencrypt" ]] && packages+=(certbot)
    info "Installing required packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 update -y
    apt-get -o DPkg::Lock::Timeout=300 install -y "${packages[@]}"
}

ensure_install_lock_tool() {
    command -v flock >/dev/null 2>&1 && return
    apt-get -o DPkg::Lock::Timeout=300 update -y
    apt-get -o DPkg::Lock::Timeout=300 install -y util-linux
}

acquire_install_lock() {
    install -d -m 0700 "$NEXTV1_ROOT"
    exec 9>"$NEXTV1_ROOT/install.lock"
    flock -w 300 9 || die "another Next-V1 installation is still running"
}

release_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' 'v2node-linux-64.zip' ;;
        aarch64|arm64) printf '%s\n' 'v2node-linux-arm64-v8a.zip' ;;
        *) die "unsupported CPU architecture: $(uname -m)" ;;
    esac
}

download_v2node() {
    local asset version_path url checksum_url download_dir archive checksum extracted expected pinned actual
    asset=$(release_asset_name)
    case "$asset" in
        v2node-linux-64.zip) pinned="$archive_sha256_amd64" ;;
        v2node-linux-arm64-v8a.zip) pinned="$archive_sha256_arm64" ;;
        *) die "no checksum slot for release asset $asset" ;;
    esac
    if [[ "$release_version" == "latest" ]]; then
        version_path="latest/download"
    else
        version_path="download/$release_version"
    fi
    url="https://github.com/$release_repository/releases/$version_path/$asset"
    checksum_url="$url.sha256"
    download_dir=$(mktemp -d "${TMPDIR:-/tmp}/next-v1-download.XXXXXX")
    archive="$download_dir/$asset"
    checksum="$archive.sha256"
    extracted="$download_dir/extracted"
    mkdir -p "$extracted"
    info "Downloading v2node from $release_repository ($release_version)"
    if ! curl --fail --location --silent --show-error --retry 3 \
          --connect-timeout 15 "$url" -o "$archive"; then
        rm -rf "$download_dir"
        die "download failed: $url"
    fi
    if ! curl --fail --location --silent --show-error --retry 3 \
          --connect-timeout 15 "$checksum_url" -o "$checksum"; then
        rm -rf "$download_dir"
        die "checksum download failed: $checksum_url"
    fi
    expected=$(awk 'NF {print $1; exit}' "$checksum")
    if [[ ! "$expected" =~ ^[a-fA-F0-9]{64}$ ]] ||
          ! printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null; then
        rm -rf "$download_dir"
        die "v2node release SHA-256 verification failed"
    fi
    actual=$(sha256sum "$archive" | awk '{print $1}')
    if [[ -n "$pinned" && "$actual" != "$pinned" ]]; then
        rm -rf "$download_dir"
        die "v2node release does not match the panel-pinned SHA-256"
    fi
    if ! unzip -p "$archive" v2node > "$extracted/v2node"; then
        rm -rf "$download_dir"
        die "invalid v2node release archive: $asset"
    fi
    if [[ ! -f "$extracted/v2node" ]]; then
        rm -rf "$download_dir"
        die "release archive does not contain v2node"
    fi
    staged_binary="$INSTALL_DIR/v2node.next-v1.new"
    install -m 0755 "$extracted/v2node" "$staged_binary"
    local data_file
    for data_file in geoip.dat geosite.dat; do
        if unzip -Z1 "$archive" "$data_file" >/dev/null 2>&1; then
            unzip -p "$archive" "$data_file" > "$extracted/$data_file"
            install -m 0644 "$extracted/$data_file" "$INSTALL_DIR/$data_file.next-v1.new"
        fi
    done
    rm -rf "$download_dir"
}

stage_v2node() {
    if [[ -n "$binary_path" ]]; then
        info "Staging the supplied Next-V1 v2node binary"
        staged_binary="$INSTALL_DIR/v2node.next-v1.new"
        install -m 0755 "$binary_path" "$staged_binary"
    else
        download_v2node
    fi
    [[ -x "$staged_binary" ]] || die "v2node binary was not staged"
}

fetch_panel_api_key() {
    local endpoint payload response next_token_file
    [[ -z "$bootstrap_token" ]] && return
    [[ -n "$bootstrap_token" ]] || die "no panel API key or bootstrap token is available"
    endpoint="${api_host%/}/api/v2/server/next-v1/bootstrap/config"
    bootstrap_config_dir=$(mktemp -d "$NEXTV1_DIR/private/bootstrap-config.XXXXXX")
    payload="$bootstrap_config_dir/payload.json"
    bootstrap_token_file="$NEXTV1_DIR/private/bootstrap-token.tmp"
    printf '%s' "$bootstrap_token" > "$bootstrap_token_file"
    chmod 0600 "$bootstrap_token_file"
    bootstrap_token=""
    chmod 0700 "$bootstrap_config_dir"
    jq -n --argjson node_id "$node_id" --rawfile bootstrap_token "$bootstrap_token_file" \
        '{node_id:$node_id,bootstrap_token:$bootstrap_token}' > "$payload"
    chmod 0600 "$payload"
    info "Fetching the authenticated v2node configuration credential"
    if ! response=$(curl --fail --silent --show-error --retry 3 \
          --connect-timeout 15 -H 'Content-Type: application/json' \
          --data-binary "@$payload" "$endpoint"); then
        rm -rf -- "$bootstrap_config_dir"
        bootstrap_config_dir=""
        die "panel bootstrap configuration request failed"
    fi
    rm -rf -- "$bootstrap_config_dir"
    bootstrap_config_dir=""
    api_key_file="$NEXTV1_DIR/private/panel-api-key.tmp"
    if ! jq -jer '.data.api_key | select(type == "string" and length > 0)' \
          <<<"$response" > "$api_key_file"; then
        rm -f "$api_key_file"
        die "panel returned an invalid v2node credential"
    fi
    chmod 0600 "$api_key_file"
    next_token_file="$bootstrap_token_file.next"
    if ! jq -jer '.data.bootstrap_token | select(type == "string" and test("^[a-f0-9]{64}$"))' \
          <<<"$response" > "$next_token_file"; then
        rm -f "$api_key_file" "$bootstrap_token_file" "$next_token_file"
        die "panel returned an invalid completion token"
    fi
    chmod 0600 "$next_token_file"
    mv "$next_token_file" "$bootstrap_token_file"

    panel_identity_state=$(jq -er '.data.identity_state |
        select(. == "empty" or . == "legacy" or . == "complete")' <<<"$response") ||
        die "panel did not return a valid cluster identity state; update the panel before installing"
    panel_certificate_mode=$(jq -er '.data.certificate_mode |
        select(. == "self-signed" or . == "letsencrypt" or . == "existing")' <<<"$response") ||
        die "panel did not return a valid server certificate mode"
    if [[ "$cert_mode" == "self-signed" && "$panel_certificate_mode" != "self-signed" ]]; then
        die "this node uses a public or externally managed server certificate; do not replace it with self-signed TLS"
    fi
    if [[ "$cert_mode" != "self-signed" && "$panel_certificate_mode" == "self-signed" &&
          "$panel_identity_state" != "empty" ]]; then
        die "this node uses a panel-managed self-signed server identity"
    fi

    if jq -e '.data.client_identity != null or .data.server_identity != null' \
          >/dev/null 2>&1 <<<"$response"; then
        panel_identity_dir=$(mktemp -d "$NEXTV1_DIR/private/panel-identity.XXXXXX")
        chmod 0700 "$panel_identity_dir"
    fi
    if jq -e '
          .data.client_identity |
          type == "object" and
          (.client_certificate | type == "string" and length > 0) and
          (.client_private_key | type == "string" and length > 0) and
          (.client_ca_certificate | type == "string" and length > 0)
        ' >/dev/null 2>&1 <<<"$response"; then
        jq -jer '.data.client_identity.client_certificate' <<<"$response" > "$panel_identity_dir/client.crt"
        jq -jer '.data.client_identity.client_private_key' <<<"$response" > "$panel_identity_dir/client.key"
        jq -jer '.data.client_identity.client_ca_certificate' <<<"$response" > "$panel_identity_dir/client-ca.crt"
        chmod 0600 "$panel_identity_dir/client.crt" "$panel_identity_dir/client.key" \
            "$panel_identity_dir/client-ca.crt"
    elif jq -e '.data.client_identity != null' >/dev/null 2>&1 <<<"$response"; then
        die "panel returned an incomplete reusable mTLS client identity"
    fi
    if jq -e '
          .data.server_identity |
          type == "object" and
          (.server_name | type == "string" and length > 0) and
          (.server_certificate | type == "string" and length > 0) and
          (.server_private_key | type == "string" and length > 0) and
          (.server_ca_certificate | type == "string" and length > 0)
        ' >/dev/null 2>&1 <<<"$response"; then
        jq -jer '.data.server_identity.server_name' <<<"$response" > "$panel_identity_dir/server-name"
        jq -jer '.data.server_identity.server_certificate' <<<"$response" > "$panel_identity_dir/server.crt"
        jq -jer '.data.server_identity.server_private_key' <<<"$response" > "$panel_identity_dir/server.key"
        jq -jer '.data.server_identity.server_ca_certificate' <<<"$response" > "$panel_identity_dir/server-ca.crt"
        chmod 0600 "$panel_identity_dir/server-name" "$panel_identity_dir/server.crt" \
            "$panel_identity_dir/server.key" "$panel_identity_dir/server-ca.crt"
    elif jq -e '.data.server_identity != null' >/dev/null 2>&1 <<<"$response"; then
        die "panel returned an incomplete reusable self-signed server identity"
    fi

    if [[ "$panel_identity_state" == "legacy" ]]; then
        [[ -n "$panel_identity_dir" ]] || {
            panel_identity_dir=$(mktemp -d "$NEXTV1_DIR/private/panel-identity.XXXXXX")
            chmod 0700 "$panel_identity_dir"
        }
        if jq -e '.data.legacy_identity.client_certificate | type == "string" and length > 0' \
              >/dev/null 2>&1 <<<"$response"; then
            jq -jer '.data.legacy_identity.client_certificate' <<<"$response" > \
                "$panel_identity_dir/legacy-client.crt"
        fi
        if jq -e '.data.legacy_identity.ca_certificate | type == "string" and length > 0' \
              >/dev/null 2>&1 <<<"$response"; then
            jq -jer '.data.legacy_identity.ca_certificate' <<<"$response" > \
                "$panel_identity_dir/legacy-server-ca.crt"
        fi
        jq -jr '.data.legacy_identity.fingerprint // ""' <<<"$response" > \
            "$panel_identity_dir/legacy-server-fingerprint"
        jq -jr '.data.legacy_identity.server_name // ""' <<<"$response" > \
            "$panel_identity_dir/legacy-server-name"
        chmod 0600 "$panel_identity_dir"/legacy-*
    fi
}

validate_requested_port_conflicts() {
    local config_path="${1:-$V2NODE_CONFIG_DIR/config.json}"
    [[ -f "$config_path" ]] || return 0
    local entry existing_host existing_id existing_key response protocol
    local existing_backend existing_frontend token_dir="$NEXTV1_ROOT"
    [[ -d "$token_dir" ]] || token_dir=$(dirname "$config_path")
    while IFS= read -r entry; do
        existing_host=$(normalize_api_host "$(jq -er '.ApiHost' <<<"$entry")")
        existing_id=$(jq -er '.NodeID' <<<"$entry")
        if [[ "$existing_host" == "$api_host" && "$existing_id" == "$node_id" ]]; then
            continue
        fi
        existing_key=$(jq -er '.ApiKey | select(type == "string" and length > 0)' <<<"$entry") ||
            die "existing node $existing_host:$existing_id has no API credential"
        port_check_token_file=$(mktemp "$token_dir/port-check-token.XXXXXX")
        printf '%s' "$existing_key" > "$port_check_token_file"
        chmod 0600 "$port_check_token_file"
        info "Checking ports used by existing node $existing_host:$existing_id"
        if ! response=$(curl --fail --silent --show-error --retry 2 \
              --connect-timeout 10 --max-time 30 --get \
              --data-urlencode 'node_type=v2node' \
              --data-urlencode "node_id=$existing_id" \
              --data-urlencode "token@$port_check_token_file" \
              "$existing_host/api/v2/server/config"); then
            die "could not verify ports for existing node $existing_host:$existing_id"
        fi
        rm -f "$port_check_token_file"
        port_check_token_file=""
        protocol=$(jq -er '.protocol | select(type == "string" and length > 0)' <<<"$response") ||
            die "existing node $existing_host:$existing_id returned an invalid protocol"
        existing_backend=$(jq -er '(.server_port // 0) | select(type == "number")' <<<"$response") ||
            die "existing node $existing_host:$existing_id returned an invalid backend port"
        if [[ "$protocol" == "next-v1" && "$existing_backend" == 0 ]]; then
            existing_backend=24443
        fi
        if (( existing_backend != 0 )); then
            validate_port "$existing_backend"
            if [[ "$backend_port" == "$existing_backend" || "$frontend_port" == "$existing_backend" ]]; then
                die "requested ports conflict with backend $existing_backend used by $existing_host:$existing_id"
            fi
        fi
        if [[ "$protocol" == "next-v1" ]]; then
            existing_frontend=$(jq -er '(.outer_tls.frontend_port // 443) | select(type == "number")' <<<"$response") ||
                die "existing node $existing_host:$existing_id returned an invalid HAProxy port"
            (( existing_frontend != 0 )) || existing_frontend=443
            validate_port "$existing_frontend"
            if [[ "$frontend_port" == "$existing_frontend" || "$backend_port" == "$existing_frontend" ]]; then
                die "requested ports conflict with HAProxy port $existing_frontend used by $existing_host:$existing_id"
            fi
        fi
    done < <(jq -c '.Nodes[]' "$config_path")
}

prepare_directories() {
    install -d -m 0755 "$INSTALL_DIR" "$V2NODE_CONFIG_DIR"
    install -d -m 0700 "$NEXTV1_ROOT" "$NEXTV1_NODES_DIR" "$NEXTV1_DIR" "$NEXTV1_DIR/private"
}

migrate_legacy_single_node() {
    [[ -f "$V2NODE_CONFIG_DIR/config.json" && -s "$NEXTV1_ROOT/private/haproxy.pem" ]] || return 0
    local legacy_host legacy_id legacy_key target file legacy_hook migrated_hook
    legacy_host=$(jq -er '.Nodes[0].ApiHost | select(type == "string" and length > 0)' \
        "$V2NODE_CONFIG_DIR/config.json") || return 0
    legacy_id=$(jq -er '.Nodes[0].NodeID | select(type == "number")' \
        "$V2NODE_CONFIG_DIR/config.json") || return 0
    legacy_host=$(normalize_api_host "$legacy_host")
    legacy_key=$(printf '%s:%s' "$legacy_host" "$legacy_id" | sha256sum | awk '{print substr($1,1,16)}')
    target="$NEXTV1_NODES_DIR/$legacy_key"
    [[ ! -e "$target/private/haproxy.pem" ]] || return 0
    info "Migrating the existing single-node identity into $legacy_key"
    install -d -m 0700 "$target" "$target/private"
    for file in client-ca.crt client-ca.srl shared-client.crt server-ca.crt server-ca.srl \
          server.crt server-fullchain.pem client.yaml; do
        [[ -e "$NEXTV1_ROOT/$file" ]] && cp -a "$NEXTV1_ROOT/$file" "$target/$file"
    done
    for file in client-ca.key shared-client.key shared-client.csr client.ext server-ca.key \
          server.key server.csr server.ext server-name haproxy-server.key haproxy.pem; do
        [[ -e "$NEXTV1_ROOT/private/$file" ]] && cp -a "$NEXTV1_ROOT/private/$file" "$target/private/$file"
    done
    legacy_hook="/etc/letsencrypt/renewal-hooks/deploy/next-v1-haproxy"
    migrated_hook="/etc/letsencrypt/renewal-hooks/deploy/next-v1-haproxy-$legacy_key"
    if [[ -f "$legacy_hook" && ! -e "$migrated_hook" ]]; then
        sed "s|$NEXTV1_ROOT|$target|g" "$legacy_hook" > "$migrated_hook"
        chmod 0755 "$migrated_hook"
    fi
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

client_identity_is_valid() {
    local ca_certificate="$1" client_certificate="$2" client_private_key="$3"
    openssl x509 -in "$ca_certificate" -noout -checkend 2592000 >/dev/null 2>&1 &&
        openssl x509 -in "$client_certificate" -noout -checkend 2592000 >/dev/null 2>&1 &&
        openssl verify -purpose sslclient -CAfile "$ca_certificate" \
            "$client_certificate" >/dev/null 2>&1 &&
        certificate_matches_key "$client_certificate" "$client_private_key"
}

certificate_matches_server_name() {
    local certificate="$1" expected_server_name="$2"
    if [[ "$expected_server_name" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        openssl x509 -in "$certificate" -noout -checkip "$expected_server_name" >/dev/null 2>&1
    else
        openssl x509 -in "$certificate" -noout -checkhost "$expected_server_name" >/dev/null 2>&1
    fi
}

server_identity_is_valid() {
    local ca_certificate="$1" server_certificate="$2" server_private_key="$3" expected_server_name="$4"
    openssl x509 -in "$ca_certificate" -noout -checkend 2592000 >/dev/null 2>&1 &&
        openssl x509 -in "$server_certificate" -noout -checkend 2592000 >/dev/null 2>&1 &&
        certificate_matches_server_name "$server_certificate" "$expected_server_name" &&
        openssl verify -purpose sslserver -CAfile "$ca_certificate" \
            "$server_certificate" >/dev/null 2>&1 &&
        certificate_matches_key "$server_certificate" "$server_private_key"
}

same_certificate() {
    local left="$1" right="$2" left_fingerprint right_fingerprint
    left_fingerprint=$(openssl x509 -in "$left" -noout -fingerprint -sha256 2>/dev/null) || return 1
    right_fingerprint=$(openssl x509 -in "$right" -noout -fingerprint -sha256 2>/dev/null) || return 1
    [[ "$left_fingerprint" == "$right_fingerprint" ]]
}

same_private_key() {
    local left="$1" right="$2" left_public_key right_public_key
    left_public_key=$(openssl pkey -in "$left" -pubout -outform DER 2>/dev/null | openssl sha256) || return 1
    right_public_key=$(openssl pkey -in "$right" -pubout -outform DER 2>/dev/null | openssl sha256) || return 1
    [[ "$left_public_key" == "$right_public_key" ]]
}

validate_legacy_local_identity() {
    [[ "$panel_identity_state" == "legacy" ]] || return 0
    local local_client_ca="$NEXTV1_DIR/client-ca.crt"
    local local_client_cert="$NEXTV1_DIR/shared-client.crt"
    local local_client_key="$NEXTV1_DIR/private/shared-client.key"
    local legacy_client_cert="$panel_identity_dir/legacy-client.crt"

    [[ -s "$legacy_client_cert" ]] ||
        die "panel has an incomplete legacy identity; repair it before adding another machine"
    [[ -s "$local_client_ca" && -s "$local_client_cert" && -s "$local_client_key" ]] ||
        die "this is a legacy node: run the new command on the original machine first to publish its cluster identity"
    openssl x509 -in "$local_client_cert" -noout -checkend 0 >/dev/null 2>&1 &&
        openssl verify -purpose sslclient -CAfile "$local_client_ca" \
            "$local_client_cert" >/dev/null 2>&1 &&
        certificate_matches_key "$local_client_cert" "$local_client_key" &&
        same_certificate "$local_client_cert" "$legacy_client_cert" ||
        die "local mTLS identity does not match the panel; use the original issuing machine to complete the upgrade"

    if [[ "$cert_mode" == "self-signed" ]]; then
        local local_server_ca="$NEXTV1_DIR/server-ca.crt"
        local local_server_cert="$NEXTV1_DIR/server.crt"
        local local_server_key="$NEXTV1_DIR/private/server.key"
        local legacy_server_ca="$panel_identity_dir/legacy-server-ca.crt"
        local legacy_fingerprint expected_fingerprint legacy_name
        legacy_fingerprint=$(cat "$panel_identity_dir/legacy-server-fingerprint")
        legacy_name=$(cat "$panel_identity_dir/legacy-server-name")
        [[ -s "$legacy_server_ca" && "$legacy_fingerprint" =~ ^[a-f0-9]{64}$ &&
              "$legacy_name" == "$server_name" ]] ||
            die "panel legacy server identity is incomplete or uses a different SNI"
        [[ -s "$local_server_ca" && -s "$local_server_cert" && -s "$local_server_key" ]] ||
            die "the original self-signed server identity is missing on this machine"
        expected_fingerprint=$(openssl x509 -in "$local_server_cert" -outform DER |
            openssl dgst -sha256 -hex | awk '{print $2}')
        [[ "$expected_fingerprint" == "$legacy_fingerprint" ]] &&
            same_certificate "$local_server_ca" "$legacy_server_ca" &&
            openssl x509 -in "$local_server_cert" -noout -checkend 0 >/dev/null 2>&1 &&
            openssl verify -purpose sslserver -CAfile "$local_server_ca" \
                "$local_server_cert" >/dev/null 2>&1 &&
            certificate_matches_server_name "$local_server_cert" "$server_name" &&
            certificate_matches_key "$local_server_cert" "$local_server_key" ||
            die "local self-signed server identity does not match the panel legacy identity"
    fi
    legacy_identity_verified=true
    info "Verified the original machine; its legacy identity will be upgraded for cluster recovery"
}

generate_client_identity() {
    local ca_key="$NEXTV1_DIR/private/client-ca.key"
    local ca_cert="$NEXTV1_DIR/client-ca.crt"
    local client_key="$NEXTV1_DIR/private/shared-client.key"
    local client_csr="$NEXTV1_DIR/private/shared-client.csr"
    local client_cert="$NEXTV1_DIR/shared-client.crt"
    local client_ext="$NEXTV1_DIR/private/client.ext"

    if [[ "$panel_identity_state" == "complete" &&
          ( ! -s "$panel_identity_dir/client-ca.crt" ||
            ! -s "$panel_identity_dir/client.crt" ||
            ! -s "$panel_identity_dir/client.key" ) ]]; then
        die "panel cluster identity is complete but has no reusable mTLS client bundle"
    fi

    if [[ "$rotate_client" == false && -n "$panel_identity_dir" &&
          -s "$panel_identity_dir/client-ca.crt" &&
          -s "$panel_identity_dir/client.crt" && -s "$panel_identity_dir/client.key" ]]; then
        if ! client_identity_is_valid "$panel_identity_dir/client-ca.crt" \
              "$panel_identity_dir/client.crt" "$panel_identity_dir/client.key"; then
            die "panel mTLS client identity is invalid or expires within 30 days; renew it on the original issuing machine with --rotate-client"
        fi
        if [[ ! -s "$ca_cert" || ! -s "$client_cert" || ! -s "$client_key" ]] ||
              ! same_certificate "$ca_cert" "$panel_identity_dir/client-ca.crt" ||
              ! same_certificate "$client_cert" "$panel_identity_dir/client.crt" ||
              ! same_private_key "$client_key" "$panel_identity_dir/client.key"; then
            info "Restoring the panel-authoritative shared mTLS client identity"
            if [[ -s "$ca_key" ]] &&
                  certificate_matches_key "$panel_identity_dir/client-ca.crt" "$ca_key"; then
                info "Preserving the matching local client CA signing key"
            else
                rm -f "$ca_key" "$NEXTV1_DIR/client-ca.srl"
            fi
            install -m 0644 "$panel_identity_dir/client-ca.crt" "$ca_cert"
            install -m 0644 "$panel_identity_dir/client.crt" "$client_cert"
            install -m 0600 "$panel_identity_dir/client.key" "$client_key"
        fi
    fi

    if [[ "$legacy_identity_verified" == true && "$rotate_client" == false ]]; then
        info "Keeping the verified legacy mTLS client identity for recovery backfill"
        return
    fi

    if [[ "$rotate_client" == true ]]; then
        [[ "$panel_identity_state" != "legacy" ]] ||
            die "backfill the legacy identity first, then save the node and run --rotate-client again"
        [[ -s "$ca_key" && -s "$ca_cert" && -s "$client_cert" && -s "$client_key" ]] ||
            die "client renewal must run on the original issuing machine that still has client-ca.key"
        openssl x509 -in "$ca_cert" -noout -checkend 2592000 >/dev/null 2>&1 &&
            certificate_matches_key "$ca_cert" "$ca_key" &&
            openssl verify -no_check_time -purpose sslclient -CAfile "$ca_cert" \
                "$client_cert" >/dev/null 2>&1 &&
            certificate_matches_key "$client_cert" "$client_key" ||
            die "the local client CA or current leaf identity is invalid"
        if [[ -s "$panel_identity_dir/client-ca.crt" ]]; then
            same_certificate "$ca_cert" "$panel_identity_dir/client-ca.crt" &&
                same_certificate "$client_cert" "$panel_identity_dir/client.crt" ||
                die "local client identity is not the panel-authoritative generation"
        fi
        info "Renewing the shared mTLS client leaf with the existing cluster CA"
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
        return
    fi

    if [[ "$rotate_client" == false && (-e "$ca_key" || -e "$ca_cert" || -e "$client_key" || -e "$client_cert") ]]; then
        if [[ -s "$ca_key" && -s "$ca_cert" && -s "$client_key" && -s "$client_cert" ]] &&
              client_identity_is_valid "$ca_cert" "$client_cert" "$client_key" &&
              certificate_matches_key "$ca_cert" "$ca_key"; then
            info "Keeping existing shared mTLS client identity"
            return
        fi
        if [[ ! -e "$ca_key" && -s "$ca_cert" && -s "$client_key" && -s "$client_cert" ]] &&
              client_identity_is_valid "$ca_cert" "$client_cert" "$client_key"; then
            info "Keeping restored shared mTLS client identity"
            return
        fi
        die "existing client identity is incomplete, mismatched, or expires within 30 days; inspect it and use --rotate-client"
    fi

    [[ "$panel_identity_state" == "empty" ]] ||
        die "refusing to generate a new client CA for a non-empty panel node"
    info "Generating shared mTLS client CA and certificate"
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
    local identity_name="$NEXTV1_DIR/private/server-name" subject_alt_name

    if [[ "$panel_identity_state" == "complete" &&
          ( ! -s "$panel_identity_dir/server-name" ||
            ! -s "$panel_identity_dir/server.crt" ||
            ! -s "$panel_identity_dir/server.key" ||
            ! -s "$panel_identity_dir/server-ca.crt" ) ]]; then
        die "panel cluster identity is complete but has no reusable self-signed server bundle"
    fi
    if [[ "$panel_identity_state" == "complete" &&
          "$(cat "$panel_identity_dir/server-name")" != "$server_name" ]]; then
        die "requested SNI does not match the panel-authoritative self-signed server identity"
    fi

    if [[ "$rotate_server" == false && -n "$panel_identity_dir" &&
          -s "$panel_identity_dir/server-name" &&
          -s "$panel_identity_dir/server.crt" && -s "$panel_identity_dir/server.key" &&
          -s "$panel_identity_dir/server-ca.crt" &&
          "$(cat "$panel_identity_dir/server-name")" == "$server_name" ]]; then
        if ! server_identity_is_valid "$panel_identity_dir/server-ca.crt" \
              "$panel_identity_dir/server.crt" "$panel_identity_dir/server.key" "$server_name"; then
            die "panel self-signed server identity is invalid or expires within 30 days"
        fi
        if [[ ! -s "$ca_cert" || ! -s "$server_cert" || ! -s "$server_key" ]] ||
              ! same_certificate "$ca_cert" "$panel_identity_dir/server-ca.crt" ||
              ! same_certificate "$server_cert" "$panel_identity_dir/server.crt" ||
              ! same_private_key "$server_key" "$panel_identity_dir/server.key"; then
            info "Restoring the panel-authoritative shared self-signed server identity"
            if [[ -s "$NEXTV1_DIR/private/server-ca.key" ]] &&
                  certificate_matches_key "$panel_identity_dir/server-ca.crt" \
                      "$NEXTV1_DIR/private/server-ca.key"; then
                info "Preserving the matching local server CA signing key"
            else
                rm -f "$NEXTV1_DIR/private/server-ca.key" "$NEXTV1_DIR/server-ca.srl"
            fi
            install -m 0644 "$panel_identity_dir/server-ca.crt" "$ca_cert"
            install -m 0644 "$panel_identity_dir/server.crt" "$server_cert"
            install -m 0600 "$panel_identity_dir/server.key" "$server_key"
        fi
        {
            sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$server_cert"
            sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$ca_cert"
        } > "$fullchain"
        printf '%s\n' "$server_name" > "$identity_name"
    fi

    if [[ "$legacy_identity_verified" == true && "$rotate_server" == false ]]; then
        {
            sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$server_cert"
            sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$ca_cert"
        } > "$fullchain"
        printf '%s\n' "$server_name" > "$identity_name"
        install -m 0600 "$server_key" "$NEXTV1_DIR/private/haproxy-server.key"
        info "Keeping the verified legacy self-signed server identity for recovery backfill"
        return
    fi

    if [[ "$rotate_server" == true ]]; then
        [[ "$panel_identity_state" != "legacy" ]] ||
            die "backfill the legacy identity before renewing its server certificate"
        [[ -s "$ca_key" && -s "$ca_cert" && -s "$server_key" && -s "$server_cert" ]] ||
            die "server renewal must run on the original issuing machine that still has server-ca.key"
        openssl x509 -in "$ca_cert" -noout -checkend 2592000 >/dev/null 2>&1 &&
            certificate_matches_key "$ca_cert" "$ca_key" &&
            openssl verify -no_check_time -purpose sslserver -CAfile "$ca_cert" \
                "$server_cert" >/dev/null 2>&1 &&
            certificate_matches_server_name "$server_cert" "$server_name" &&
            certificate_matches_key "$server_cert" "$server_key" ||
            die "the local server CA or current server leaf identity is invalid"
        if [[ -n "$panel_identity_dir" && -s "$panel_identity_dir/server-ca.crt" ]]; then
            same_certificate "$ca_cert" "$panel_identity_dir/server-ca.crt" &&
                same_certificate "$server_cert" "$panel_identity_dir/server.crt" ||
                die "local server identity is not the panel-authoritative generation"
        fi
        info "Renewing the self-signed server leaf with the existing cluster CA"
        subject_alt_name=$(server_subject_alt_name "$server_name")
        openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$server_key"
        openssl req -new -sha256 -key "$server_key" \
            -subj "/CN=$server_name" -out "$server_csr"
        printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
            'keyUsage=critical,digitalSignature,keyEncipherment' \
            'extendedKeyUsage=serverAuth' \
            "subjectAltName=$subject_alt_name" > "$server_ext"
        openssl x509 -req -sha256 -days 825 -in "$server_csr" \
            -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
            -extfile "$server_ext" -out "$server_cert"
        {
            sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$server_cert"
            sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$ca_cert"
        } > "$fullchain"
        printf '%s\n' "$server_name" > "$identity_name"
        install -m 0600 "$server_key" "$NEXTV1_DIR/private/haproxy-server.key"
        return
    fi

    if [[ -s "$server_key" && -s "$server_cert" && -s "$ca_cert" &&
          -s "$fullchain" && -s "$identity_name" &&
          "$(cat "$identity_name")" == "$server_name" ]] &&
          server_identity_is_valid "$ca_cert" "$server_cert" "$server_key" "$server_name"; then
        info "Keeping existing self-signed server identity for $server_name"
        install -m 0600 "$server_key" "$NEXTV1_DIR/private/haproxy-server.key"
        return
    fi

    if [[ -e "$ca_key" || -e "$ca_cert" || -e "$server_key" || -e "$server_cert" ||
          -e "$fullchain" || -e "$identity_name" ]]; then
        die "existing self-signed server identity is incomplete, mismatched, or expires within 30 days; inspect it and use --rotate-server on the original issuing machine"
    fi

    [[ "$panel_identity_state" == "empty" ]] ||
        die "refusing to generate a new self-signed identity for a non-empty panel node"
    info "Generating self-signed server certificate for $server_name"
    subject_alt_name=$(server_subject_alt_name "$server_name")
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
        "subjectAltName=$subject_alt_name" > "$server_ext"
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

    local hook="/etc/letsencrypt/renewal-hooks/deploy/next-v1-haproxy-$node_key"
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
        rm -f "/etc/letsencrypt/renewal-hooks/deploy/next-v1-haproxy-$node_key"
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

authorize_haproxy_management() {
    if [[ -f "$HAPROXY_CONFIG" ]] &&
          ! is_managed_haproxy_config &&
          grep -Eq '^[[:space:]]*(frontend|listen|backend)[[:space:]]+' "$HAPROXY_CONFIG" &&
          [[ "$replace_haproxy_config" != true ]]; then
        die "HAProxy already has routes; use a dedicated server or pass --replace-haproxy-config"
    fi
    if [[ -f "$HAPROXY_CONFIG" ]] && ! is_managed_haproxy_config; then
        if grep -Eq '^[[:space:]]*(frontend|listen|backend)[[:space:]]+' "$HAPROXY_CONFIG"; then
            [[ "$replace_haproxy_config" == true ]] ||
                die "HAProxy takeover requires --replace-haproxy-config"
        fi
        install -m 0600 /dev/null "$NEXTV1_ROOT/manage-haproxy"
    else
        rm -f "$NEXTV1_ROOT/manage-haproxy"
    fi
}

upsert_v2node_node() {
    local config_path="$1"
    local candidate_path="$2"
    local host
    host=$(normalize_api_host "$3")
    local id="$4"
    local credential_path="$5"
    jq --arg host "$host" --argjson id "$id" --rawfile key "$credential_path" '
        def same_node: ((.ApiHost | sub("/+$"; "")) == $host and .NodeID == $id);
        .Nodes = ((.Nodes // []) |
            if any(.[]; same_node) then
                map(if same_node then
                    .ApiHost = $host | .ApiKey = $key | .Timeout = (.Timeout // 15)
                else . end)
            else
                . + [{ApiHost:$host,NodeID:$id,ApiKey:$key,Timeout:15}]
            end)
    ' "$config_path" > "$candidate_path" || return 1
    chmod 0600 "$candidate_path"
    mv "$candidate_path" "$config_path"
}

validate_identity_target() {
    [[ "$node_key" =~ ^[a-f0-9]{16}$ && "$NEXTV1_DIR" == "$NEXTV1_NODES_DIR/$node_key" ]]
}

snapshot_identity_state() {
    validate_identity_target || die "refusing to snapshot an invalid node identity path"
    local snapshot
    snapshot=$(mktemp -d "$NEXTV1_ROOT/identity-rollback.XXXXXX") ||
        die "could not create the certificate rollback snapshot"
    chmod 0700 "$snapshot" || {
        rm -rf -- "$snapshot"
        die "could not protect the certificate rollback snapshot"
    }
    if [[ -d "$NEXTV1_DIR" ]]; then
        cp -a "$NEXTV1_DIR" "$snapshot/node" || {
            rm -rf -- "$snapshot"
            die "could not snapshot the current certificate identity"
        }
        : > "$snapshot/node.exists" || {
            rm -rf -- "$snapshot"
            die "could not finish the certificate rollback manifest"
        }
    fi
    local hook="/etc/letsencrypt/renewal-hooks/deploy/next-v1-haproxy-$node_key"
    if [[ -f "$hook" ]]; then
        cp -a "$hook" "$snapshot/certbot-hook" || {
            rm -rf -- "$snapshot"
            die "could not snapshot the certificate renewal hook"
        }
        : > "$snapshot/certbot-hook.exists" || {
            rm -rf -- "$snapshot"
            die "could not finish the renewal-hook rollback manifest"
        }
    fi
    identity_rollback_dir="$snapshot"
}

rollback_identity() {
    [[ -n "$identity_rollback_dir" &&
       "$identity_rollback_dir" == "$NEXTV1_ROOT"/identity-rollback.* ]] || return 1
    validate_identity_target || return 1
    info "Restoring the previous certificate identity for node $node_key"
    rm -rf -- "$NEXTV1_DIR"
    if [[ -f "$identity_rollback_dir/node.exists" ]]; then
        install -d -m 0700 "$NEXTV1_NODES_DIR"
        cp -a "$identity_rollback_dir/node" "$NEXTV1_DIR"
    fi
    local hook="/etc/letsencrypt/renewal-hooks/deploy/next-v1-haproxy-$node_key"
    if [[ -f "$identity_rollback_dir/certbot-hook.exists" ]]; then
        cp -a "$identity_rollback_dir/certbot-hook" "$hook"
    else
        rm -f "$hook"
    fi
}

snapshot_activation_file() {
    local snapshot="$1" path="$2" name="$3"
    if [[ -e "$path" ]]; then
        cp -a "$path" "$snapshot/$name" || return 1
        : > "$snapshot/$name.exists" || return 1
    fi
}

restore_activation_file() {
    local path="$1" name="$2"
    if [[ -f "$activation_rollback_dir/$name.exists" ]]; then
        cp -a "$activation_rollback_dir/$name" "$path"
    else
        rm -f "$path"
    fi
}

snapshot_activation_state() {
    local snapshot
    snapshot=$(mktemp -d "$NEXTV1_ROOT/activation-rollback.XXXXXX") ||
        die "could not create the service rollback snapshot"
    chmod 0700 "$snapshot" || {
        rm -rf -- "$snapshot"
        die "could not protect the service rollback snapshot"
    }
    if ! snapshot_activation_file "$snapshot" "$INSTALL_DIR/v2node" v2node ||
          ! snapshot_activation_file "$snapshot" "$V2NODE_CONFIG_DIR/config.json" config.json ||
          ! snapshot_activation_file "$snapshot" /etc/systemd/system/v2node.service v2node.service ||
          ! snapshot_activation_file "$snapshot" "$HAPROXY_CONFIG" haproxy.cfg ||
          ! snapshot_activation_file "$snapshot" "$INSTALL_DIR/geoip.dat" geoip.dat ||
          ! snapshot_activation_file "$snapshot" "$INSTALL_DIR/geosite.dat" geosite.dat; then
        rm -rf -- "$snapshot"
        die "could not snapshot the current service state"
    fi
    if systemctl is-active --quiet v2node; then
        : > "$snapshot/v2node.active" || { rm -rf -- "$snapshot"; die "could not snapshot v2node state"; }
    fi
    if systemctl is-enabled --quiet v2node; then
        : > "$snapshot/v2node.enabled" || { rm -rf -- "$snapshot"; die "could not snapshot v2node enablement"; }
    fi
    if systemctl is-active --quiet haproxy; then
        : > "$snapshot/haproxy.active" || { rm -rf -- "$snapshot"; die "could not snapshot HAProxy state"; }
    fi
    if systemctl is-enabled --quiet haproxy; then
        : > "$snapshot/haproxy.enabled" || { rm -rf -- "$snapshot"; die "could not snapshot HAProxy enablement"; }
    fi
    activation_rollback_dir="$snapshot"
}

rollback_activation() {
    [[ -n "$activation_rollback_dir" &&
       "$activation_rollback_dir" == "$NEXTV1_ROOT"/activation-rollback.* ]] || return 1
    info "Restoring the previous v2node and HAProxy state"
    systemctl stop v2node >/dev/null 2>&1 || true
    restore_activation_file "$INSTALL_DIR/v2node" v2node
    restore_activation_file "$V2NODE_CONFIG_DIR/config.json" config.json
    restore_activation_file /etc/systemd/system/v2node.service v2node.service
    restore_activation_file "$HAPROXY_CONFIG" haproxy.cfg
    rm -f "$NEXTV1_ROOT/manage-haproxy"
    restore_activation_file "$INSTALL_DIR/geoip.dat" geoip.dat
    restore_activation_file "$INSTALL_DIR/geosite.dat" geosite.dat
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ -f "$activation_rollback_dir/v2node.enabled" ]]; then
        systemctl enable v2node >/dev/null 2>&1 || true
    else
        systemctl disable v2node >/dev/null 2>&1 || true
    fi
    if [[ -f "$activation_rollback_dir/v2node.active" ]]; then
        systemctl restart v2node >/dev/null 2>&1 || true
    else
        systemctl stop v2node >/dev/null 2>&1 || true
    fi
    if [[ -f "$activation_rollback_dir/haproxy.enabled" ]]; then
        systemctl enable haproxy >/dev/null 2>&1 || true
    else
        systemctl disable haproxy >/dev/null 2>&1 || true
    fi
    if [[ -f "$activation_rollback_dir/haproxy.active" ]]; then
        systemctl reload-or-restart haproxy >/dev/null 2>&1 || true
    else
        systemctl stop haproxy >/dev/null 2>&1 || true
    fi
}

commit_installation_transaction() {
    [[ -n "$activation_rollback_dir" &&
       "$activation_rollback_dir" == "$NEXTV1_ROOT"/activation-rollback.* ]] || return 1
    [[ -n "$identity_rollback_dir" &&
       "$identity_rollback_dir" == "$NEXTV1_ROOT"/identity-rollback.* ]] || return 1
    local activation_snapshot="$activation_rollback_dir"
    local identity_snapshot="$identity_rollback_dir"
    activation_rollback_dir=""
    identity_rollback_dir=""
    rm -rf -- "$activation_snapshot" "$identity_snapshot"
}

activate_v2node_files() {
    local updated_config="$1" unit_candidate="$2" data_file
    mv "$staged_binary" "$INSTALL_DIR/v2node" || return 1
    for data_file in geoip.dat geosite.dat; do
        if [[ -f "$INSTALL_DIR/$data_file.next-v1.new" ]]; then
            mv "$INSTALL_DIR/$data_file.next-v1.new" "$INSTALL_DIR/$data_file" || return 1
        fi
    done
    mv "$updated_config" "$V2NODE_CONFIG_DIR/config.json" || return 1
    mv "$unit_candidate" /etc/systemd/system/v2node.service || return 1
    systemctl daemon-reload || return 1
    systemctl enable v2node || return 1
    systemctl restart v2node || return 1
}

install_v2node() {
    local updated_config="$V2NODE_CONFIG_DIR/config.json.next-v1.new"
    local upsert_candidate="$V2NODE_CONFIG_DIR/config.json.next-v1.upsert"
    local unit_candidate=/etc/systemd/system/v2node.service.next-v1.new

    local credential_file="$api_key_file"
    if [[ -z "$credential_file" && -n "$api_key" ]]; then
        manual_credential_file="$NEXTV1_DIR/private/panel-api-key.manual.tmp"
        printf '%s' "$api_key" > "$manual_credential_file"
        chmod 0600 "$manual_credential_file"
        credential_file="$manual_credential_file"
    fi
    if [[ -f "$V2NODE_CONFIG_DIR/config.json" ]]; then
        cp -a "$V2NODE_CONFIG_DIR/config.json" "$updated_config"
    else
        jq -n '{Log:{Level:"warning",Output:"",Access:"none"},Nodes:[]}' \
            > "$updated_config"
        chmod 0600 "$updated_config"
    fi
    local node_exists
    node_exists=$(jq --arg host "$api_host" --argjson id "$node_id" \
        '[.Nodes[] | select((.ApiHost | sub("/+$"; "")) == $host and .NodeID == $id)] | length' \
        "$updated_config")
    if [[ -z "$credential_file" ]]; then
        (( node_exists == 1 )) || die "adding a panel node requires bootstrap credentials"
    else
        upsert_v2node_node "$updated_config" "$upsert_candidate" \
            "$api_host" "$node_id" "$credential_file" ||
            die "could not add or update the v2node panel node"
    fi
    if [[ -n "$manual_credential_file" ]]; then
        rm -f "$manual_credential_file"
        manual_credential_file=""
    fi
    if [[ -n "$api_key_file" ]]; then
        rm -f "$api_key_file"
        api_key_file=""
    fi

    cat > "$unit_candidate" <<EOF
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
    chmod 0644 "$unit_candidate"

    snapshot_activation_state
    info "Activating the verified Next-V1 v2node binary and multi-node config"
    if ! activate_v2node_files "$updated_config" "$unit_candidate"; then
        die "could not activate v2node; automatic rollback will run, then inspect both services"
    fi
    staged_binary=""
    local attempt
    for attempt in $(seq 1 15); do
        if systemctl is-active --quiet v2node &&
              ss -ltnH | awk '{print $4}' | grep -Eq "127\\.0\\.0\\.1:$backend_port$"; then
            return
        fi
        sleep 1
    done
    journalctl -u v2node -n 30 --no-pager >&2 || true
    die "v2node did not become active on 127.0.0.1:$backend_port; automatic rollback will run, then inspect both services"
}

publish_client_bundle() {
    local endpoint payload server_ca_file server_cert_file server_key_file fingerprint response
    [[ -n "$api_host" && -n "$node_id" && -s "$bootstrap_token_file" ]] || return 0
    endpoint="${api_host%/}/api/v2/server/next-v1/bootstrap"
    bootstrap_publish_dir=$(mktemp -d "$NEXTV1_DIR/private/bootstrap-publish.XXXXXX")
    payload="$bootstrap_publish_dir/payload.json"
    server_ca_file="$bootstrap_publish_dir/server-ca.crt"
    server_cert_file="$bootstrap_publish_dir/server.crt"
    server_key_file="$bootstrap_publish_dir/server.key"
    if [[ "$cert_mode" == "self-signed" ]]; then
        cp "$NEXTV1_DIR/server-ca.crt" "$server_ca_file"
        cp "$NEXTV1_DIR/server.crt" "$server_cert_file"
        cp "$NEXTV1_DIR/private/server.key" "$server_key_file"
        fingerprint=$(openssl x509 -in "$NEXTV1_DIR/server-fullchain.pem" -outform DER |
            openssl dgst -sha256 -hex | awk '{print $2}')
    else
        : > "$server_ca_file"
        : > "$server_cert_file"
        : > "$server_key_file"
        fingerprint=""
    fi
    chmod 0700 "$bootstrap_publish_dir"
    jq -n \
        --argjson node_id "$node_id" \
        --rawfile bootstrap_token "$bootstrap_token_file" \
        --arg server_name "$server_name" \
        --arg certificate_mode "$cert_mode" \
        --arg fingerprint "$fingerprint" \
        --argjson alpn '["next-v1"]' \
        --rawfile certificate "$NEXTV1_DIR/shared-client.crt" \
        --rawfile private_key "$NEXTV1_DIR/private/shared-client.key" \
        --rawfile client_ca_certificate "$NEXTV1_DIR/client-ca.crt" \
        --rawfile ca_certificate "$server_ca_file" \
        --rawfile server_certificate "$server_cert_file" \
        --rawfile server_private_key "$server_key_file" \
        --rawfile server_ca_certificate "$server_ca_file" \
        '{node_id:$node_id,bootstrap_token:$bootstrap_token,server_name:$server_name,
          certificate_mode:$certificate_mode,
          fingerprint:$fingerprint,alpn:$alpn,client_certificate:$certificate,
          client_private_key:$private_key,client_ca_certificate:$client_ca_certificate,
          ca_certificate:$ca_certificate,
          server_certificate:(if $server_certificate == "" then null else $server_certificate end),
          server_private_key:(if $server_private_key == "" then null else $server_private_key end),
          server_ca_certificate:(if $server_ca_certificate == "" then null else $server_ca_certificate end)}' > "$payload"
    chmod 0600 "$payload"
    info "Publishing the generated mTLS client identity to the panel"
    if ! response=$(curl --fail --silent --show-error --retry 3 \
          --connect-timeout 15 -H 'Content-Type: application/json' \
          --data-binary "@$payload" "$endpoint"); then
        rm -rf -- "$bootstrap_publish_dir"
        bootstrap_publish_dir=""
        die "panel bootstrap request failed: $endpoint"
    fi
    rm -rf -- "$bootstrap_publish_dir"
    bootstrap_publish_dir=""
    if ! jq -e '.data == true' >/dev/null 2>&1 <<<"$response"; then
        die "panel rejected the Next-V1 bootstrap identity"
    fi
    rm -f "$bootstrap_token_file"
    bootstrap_token_file=""
    bootstrap_published=true
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

EOF
    if [[ "$bootstrap_published" == true ]]; then
        printf '%s\n' 'The generated client identity was sent back to the authenticated panel node.'
    else
        printf '%s\n' 'Copy the client.yaml TLS fields to the panel before enabling this node.'
    fi
    printf '%s\n' 'Keep client.yaml secret; it is a local recovery copy and must not be published.'
}

main() {
    parse_args "$@"
    initialize_node_context
    validate_args
    ensure_install_lock_tool
    acquire_install_lock
    install_packages
    validate_existing_v2node_config
    validate_requested_port_conflicts
    snapshot_identity_state
    prepare_directories
    migrate_legacy_single_node
    fetch_panel_api_key
    validate_legacy_local_identity
    stage_v2node
    generate_client_identity
    prepare_server_identity
    authorize_haproxy_management
    install_v2node
    write_client_bundle
    publish_client_bundle
    commit_installation_transaction
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
