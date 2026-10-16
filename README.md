# argoport

Multi-protocol Xray node fronted by a Cloudflare quick tunnel. Built to sit on
PaaS platforms (Railway, Fly.io, Render) where you get a container, not a VM —
and where no inbound ports are open to the internet.

Cloudflare Argo tunnel is **outbound-only**. The platform never needs to expose
a port; `cloudflared` dials out to Cloudflare and CF hands traffic back down that
same connection. Your origin IP never appears in a DNS record.

## Protocols

All four share one public listener, demultiplexed by WebSocket path:

| Protocol     | Path                    |
|--------------|-------------------------|
| VLESS        | `/{root}-vless`         |
| VMess        | `/{root}-vmess`         |
| Trojan       | `/{root}-trojan`        |
| Shadowsocks  | `/{root}-shadowsocks`   |

VLESS is the one to use. VMess and Shadowsocks are deprecated in current Xray
cores and are kept for client compatibility only.

## Deploy on Railway

1. Push this directory to a GitHub repo.
2. Railway → **New Project → Deploy from GitHub repo**. The `Dockerfile` is
   detected automatically; there is no Nixpacks config to fight with.
3. Open the deployment logs. After ~20s you'll see a block of client links.
4. Copy a link into your client.

### Variables

Everything is optional. Deploy it with zero configuration and you get a working
node with a stable identity.

| Var | Default | Purpose |
|-----|---------|---------|
| `ARGOPORT_ID` | derived | Node identity. Set only if you want to override the derived value. |
| `ARGOPORT_PATH` | `argo` | WebSocket path root. No leading slash. |
| `ARGOPORT_LOG` | `warning` | Xray log level. |
| `ARGOPORT_BIND` | `0.0.0.0` | Bind address. Railway needs `0.0.0.0`. |
| `PORT` | `8080` | Injected by Railway. Don't set it yourself. |

### How the identity is chosen

The node needs a UUID, and it has to survive redeploys or every saved link dies.
Resolution runs in this order — first match wins:

1. **`ARGOPORT_ID`** — explicit override. Wins outright.
2. **Saved state** — a previously resolved id persisted to the run directory.
3. **`RAILWAY_SERVICE_ID`** — Railway exposes this to every deployment, and it
   is stable across redeploys (only the deployment id changes). The UUID is
   derived deterministically from it via SHA-1, so the same service always
   yields the same UUID. This is the path a normal Railway deploy takes.
4. **Random** — last resort, used when running outside Railway with no override.

Result: two people cloning this repo get different UUIDs, and one person's
redeploys keep the same UUID. Nobody has to configure anything.

If you want to pin an identity by hand:

```bash
cat /proc/sys/kernel/random/uuid   # paste into Railway → Variables → ARGOPORT_ID
```

## Run it anywhere else

```bash
docker build -t argoport .
docker run --rm -e ARGOPORT_ID=$(cat /proc/sys/kernel/random/uuid) -p 8080:8080 argoport
```

Or straight on a host with `xray` and `cloudflared` on `PATH`:

```bash
ARGOPORT_ID=$(cat /proc/sys/kernel/random/uuid) PORT=8080 ./entrypoint.sh
```

## How traffic flows

```
client ──TLS/SNI *.trycloudflare.com──▶ Cloudflare edge
                                            │
                                   argo tunnel (outbound)
                                            │
                                   cloudflared ──▶ xray :8080
                                                      │ path match
                                      ┌───────────────┼───────────────┐
                                 :4101 vless     :4102 vmess    :4103 trojan  :4104 ss
```

Xray's single inbound on `$PORT` carries VLESS with `fallbacks`. Anything whose
WebSocket path matches a protocol routes to that protocol's loopback inbound;
everything else falls through to `:4105`. The camouflage host in emitted links
is `www.digitalocean.com` — clients connect there, but the TLS SNI and Host
header carry the Cloudflare domain, which is what the tunnel actually answers to.

## Limits worth knowing

- **Quick tunnel hostnames are ephemeral.** `*.trycloudflare.com` exists only
  while the process runs. Every restart mints a new hostname. For a stable
  hostname you need a named tunnel bound to a domain you own in Cloudflare —
  set `CF_TUNNEL_TOKEN` and swap `start_tunnel` for `cloudflared tunnel run`.
- **VMESS and Shadowsocks are deprecated** in Xray 26.x. They still work; the
  warnings in the logs are real advice, not errors.
- **Rate limits.** Free Cloudflare tunnels are not a backbone. Fine for personal
  traffic; don't build a business on it.

## Files

```
Dockerfile       multi-stage build, binaries baked at build time
entrypoint.sh    config render, process supervision, link emission
railway.json     service config: Dockerfile, single instance
```

## License

MIT. Written from scratch — no code derived from other tunnel-deploy repos.
