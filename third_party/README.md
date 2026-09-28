# Xray dependency

`xray-core/` is a local copy of `github.com/wyx2685/xray-core` at
`v0.0.0-20260713170150-b17a88f9b46d`, which the original `go.mod` used as a
replacement for `github.com/xtls/xray-core v1.260711.0`.

The local change in `transport/internet/system_listener.go` uses the optional
PROXY protocol policy for listeners with `acceptProxyProtocol: true`. Connections
with no PROXY header retain their original bytes; connections with a valid header
use its supplied source address. A client that can reach this listener can forge
that address. Keep this copy synchronized when updating Xray.
