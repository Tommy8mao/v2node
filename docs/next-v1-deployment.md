# Next-V1 deployment

The supported server layout is:

```text
Nextin/Mihomo -> TCP 443 HAProxy (TLS 1.3 + required client cert)
               -> 127.0.0.1:24443 v2node (Next-V1 + PROXY v2)
```

The loopback port is configured on the Next-V1 panel node and must match the
installer's `--backend-port`. Do not expose that port in the firewall.
The installer expects a dedicated HAProxy instance. If it detects existing
frontend/listen/backend routes, it stops without changing them; inspect the
timestamped backup and explicitly pass `--replace-haproxy-config` only when
replacing those routes is intentional.

## First panel bootstrap

Create the Next-V1 node first. If the shared client certificate and key are
blank, the panel deliberately saves it as a hidden draft so it cannot leak an
unusable subscription. Configure `NEXT_V1_RELEASE_BASE_URL` on the panel and
run the node's generated install command; that command carries the node's
public server name, public port and loopback backend port into the installer.

After installation, open `/etc/next-v1/client.yaml` as root and copy its
`certificate`, `private-key`, `ca`/`fingerprint`, `servername` and `alpn`
values into the draft node. Save it again, verify the subscription, and only
then enable the node. The panel validates that the client certificate and
private key match. Keeping this one-time copy explicit avoids sending the
shared private key back through a server API or exposing it in shell history.

## Local or first test

Build v2node, copy the Linux binary and the installer to the server, then run:

```bash
sudo bash install-next-v1.sh \
  --self-signed \
  --server-name next-v1.test \
  --binary ./v2node \
  --api-host https://panel.example.com/ \
  --node-id 1 \
  --api-key 'panel-node-key'
```

The script creates a private server CA, a separate private client CA, and one
shared client certificate. Self-signed server verification uses both the private
server CA and the SHA-256 pin written into `/etc/next-v1/client.yaml`;
`skip-cert-verify` remains false. Re-running with the same server name keeps the
same identities unless `--rotate-client` is explicitly supplied.

## Production with Let's Encrypt

Point the domain's A/AAAA record at the server and allow inbound TCP port 80 for
the ACME challenge, then run:

```bash
sudo bash install-next-v1.sh \
  --letsencrypt \
  --server-name edge.example.com \
  --email admin@example.com \
  --binary ./v2node \
  --api-host https://panel.example.com/ \
  --node-id 1 \
  --api-key 'panel-node-key'
```

The installer adds a Certbot deployment hook that rebuilds HAProxy's PEM and
reloads HAProxy after renewal. Publicly trusted certificates are not pinned in
the generated client bundle, so normal renewal does not break clients. The
private client CA is independent of Let's Encrypt and is never sent to
subscribers.

To use an existing certificate instead:

```bash
sudo bash install-next-v1.sh \
  --existing-cert /path/to/fullchain.pem \
  --existing-key /path/to/privkey.pem \
  --server-name edge.example.com
```

## Shared client certificate rotation

Re-run the same command with `--rotate-client`. This replaces the client CA and
shared certificate, updates HAProxy, and invalidates all previously delivered
client certificates immediately. Redistribute `/etc/next-v1/client.yaml` only
through the protected panel subscription path.

## Checks

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl status haproxy v2node
sudo journalctl -u haproxy -u v2node --since '10 minutes ago'
```

HAProxy deliberately sends PROXY protocol v2. A non-Next-V1 service or a
v2node listener without `accept-proxy-protocol` will not understand this stream.
