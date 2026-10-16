#!/usr/bin/env bash
# argoport-entry — bring up Xray + a Cloudflare quick tunnel, then emit client links.
# Rewritten from scratch. Streams everything to stdout for Railway's log viewer.
set -Eeuo pipefail

# ---- runtime knobs (env-overridable) ----
# NODE_ID is resolved later by resolve_identity() — see the cascade there.
WS_ROOT="${ARGOPORT_PATH:-argo}"       # no leading slash
TAG="${ARGOPORT_TAG:-}"                # optional suffix on emitted node names
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"     # optional: DM the links on startup
TG_CHAT="${TELEGRAM_CHAT_ID:-}"
BIND="${ARGOPORT_BIND:-0.0.0.0}"
LOG_LEVEL="${ARGOPORT_LOG:-warning}"
RUN_DIR="${ARGOPORT_RUN_DIR:-/run}"

# Railway hands us PORT. Fall back to 8080 when running bare.
HOST_PORT="${PORT:-${ARGOPORT_PORT:-8080}}"

# Internal loopback sinks. Kept well clear of anything Railway binds.
SINK_BASE=4100
SINK_VLESS=$((SINK_BASE + 1))
SINK_VMESS=$((SINK_BASE + 2))
SINK_TROJAN=$((SINK_BASE + 3))
SINK_SS=$((SINK_BASE + 4))
SINK_FALLBACK=$((SINK_BASE + 5))

say()  { printf '[argoport] %s\n' "$*"; }
warn() { printf '[argoport] WARN: %s\n' "$*" >&2; }
die()  { printf '[argoport] FATAL: %s\n' "$*" >&2; exit 1; }

# Deterministic UUIDv5-style from a seed. Stable across restarts, unique per seed.
# Lets Railway users get a persistent identity with zero configuration.
derive_uuid() {
  local h a b c d e vb
  h=$(printf '%s' "argoport:$1" | sha1sum | cut -c1-32)
  a=${h:0:8}; b=${h:8:4}; c=${h:12:4}; d=${h:16:4}; e=${h:20:12}
  c="5${c:1:3}"                                   # version 5
  vb=$(( (16#${d:0:1} & 0x3) | 0x8 ))             # variant 10xx
  d=$(printf '%x' "$vb")${d:1:3}
  printf '%s-%s-%s-%s-%s\n' "$a" "$b" "$c" "$d" "$e"
}

# Pick the node identity. Explicit wins, then a saved one, then a deterministic
# derive from Railway's stable service id, and only then a fresh random.
resolve_identity() {
  local state="${RUN_DIR}/.argoport-id"
  local seed=""

  if [[ -n "${ARGOPORT_ID:-}" ]]; then
    NODE_ID="$ARGOPORT_ID"
    save_identity "$state"
    say "identity: explicit ARGOPORT_ID"
    return
  fi

  if [[ -s "$state" ]]; then
    NODE_ID=$(<"$state")
    say "identity: restored from state file"
    return
  fi

  if [[ -n "${RAILWAY_SERVICE_ID:-}" ]]; then
    seed="$RAILWAY_SERVICE_ID"
    say "identity: derived from RAILWAY_SERVICE_ID"
  else
    seed=$(cat /proc/sys/kernel/random/uuid)
    say "identity: fresh random (no Railway service id)"
  fi

  NODE_ID=$(derive_uuid "$seed")
  save_identity "$state"
}

# Persisting is best-effort. The node works fine without it — worst case the
# id is re-derived from RAILWAY_SERVICE_ID on next boot. Never fatal.
save_identity() {
  if ! printf '%s' "$NODE_ID" > "$1" 2>/dev/null; then
    warn "cannot persist identity to $1 — continuing without it"
  fi
}

# Fail with a readable message rather than a bare "No such file or directory"
# from deep inside set -e. Verify writability up front — a dir we can cd into
# but not write to would otherwise blow up later, mid-script.
if ! mkdir -p "$RUN_DIR" 2>/dev/null || ! cd "$RUN_DIR" 2>/dev/null; then
  die "RUN_DIR '$RUN_DIR' is not a usable directory (running as uid $(id -u))"
fi
if ! : > .write-probe 2>/dev/null; then
  die "RUN_DIR '$RUN_DIR' is not writable by uid $(id -u) — check volume/dir ownership"
fi
rm -f .write-probe

# ---- config ----
# One public inbound on $HOST_PORT. Path-based fallbacks fan out to
# per-protocol loopback inbounds so all four protocols share one listener.
render_config() {
  cat > xray.json <<JSON
{
  "log": { "access": "none", "error": "/dev/stderr", "loglevel": "${LOG_LEVEL}" },
  "inbounds": [
    {
      "listen": "${BIND}",
      "port": ${HOST_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${NODE_ID}" } ],
        "decryption": "none",
        "fallbacks": [
          { "dest": ${SINK_FALLBACK} },
          { "path": "/${WS_ROOT}-vless", "dest": ${SINK_VLESS} },
          { "path": "/${WS_ROOT}-vmess", "dest": ${SINK_VMESS} },
          { "path": "/${WS_ROOT}-trojan", "dest": ${SINK_TROJAN} },
          { "path": "/${WS_ROOT}-shadowsocks", "dest": ${SINK_SS} }
        ]
      },
      "streamSettings": { "network": "tcp" },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "metadataOnly": false }
    },
    {
      "listen": "127.0.0.1", "port": ${SINK_FALLBACK}, "protocol": "vless",
      "settings": { "clients": [ { "id": "${NODE_ID}" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/" } }
    },
    {
      "listen": "127.0.0.1", "port": ${SINK_VLESS}, "protocol": "vless",
      "settings": { "clients": [ { "id": "${NODE_ID}" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/${WS_ROOT}-vless" } },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "metadataOnly": false }
    },
    {
      "listen": "127.0.0.1", "port": ${SINK_VMESS}, "protocol": "vmess",
      "settings": { "clients": [ { "id": "${NODE_ID}", "alterId": 0 } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/${WS_ROOT}-vmess" } },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "metadataOnly": false }
    },
    {
      "listen": "127.0.0.1", "port": ${SINK_TROJAN}, "protocol": "trojan",
      "settings": { "clients": [ { "password": "${NODE_ID}" } ] },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/${WS_ROOT}-trojan" } },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "metadataOnly": false }
    },
    {
      "listen": "127.0.0.1", "port": ${SINK_SS}, "protocol": "shadowsocks",
      "settings": { "method": "chacha20-ietf-poly1305", "password": "${NODE_ID}", "network": "tcp,udp" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/${WS_ROOT}-shadowsocks" } },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "metadataOnly": false }
    }
  ],
  "dns": { "servers": [ "https+local://1.1.1.1/dns-query" ] },
  "outbounds": [ { "protocol": "freedom" } ]
}
JSON
}

# ---- process supervision ----
CF_PID=""
XRAY_PID=""

cleanup() {
  say "shutting down"
  [[ -n "$XRAY_PID" ]] && kill "$XRAY_PID" 2>/dev/null || true
  [[ -n "$CF_PID" ]] && kill "$CF_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

start_xray() {
  render_config
  xray run -config xray.json &
  XRAY_PID=$!

  for _ in $(seq 1 20); do
    kill -0 "$XRAY_PID" 2>/dev/null || die "xray exited at startup"
    (exec 3<>/dev/tcp/127.0.0.1/"$HOST_PORT") 2>/dev/null && { exec 3>&- 3<&-; say "xray listening on :${HOST_PORT}"; return; }
    sleep 0.5
  done
  die "xray never bound :${HOST_PORT}"
}

start_tunnel() {
  cloudflared tunnel --url "http://127.0.0.1:${HOST_PORT}" --no-autoupdate > argo.log 2>&1 &
  CF_PID=$!

  for _ in $(seq 1 45); do
    kill -0 "$CF_PID" 2>/dev/null || { warn "cloudflared exited:"; tail -5 argo.log >&2; die "tunnel failed"; }
    ARGO=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' argo.log 2>/dev/null | head -n1 | sed 's|https://||' || true)
    [[ -n "${ARGO:-}" ]] && { say "tunnel up: ${ARGO}"; return; }
    sleep 1
  done
  warn "tunnel log:"; tail -5 argo.log >&2
  die "no tunnel URL after 45s"
}

# ---- client links ----
emit_links() {
  local camo="www.digitalocean.com"
  local ss_cred ss_b64 ss_plugin vmess_json vmess_b64
  # Node display names. ARGOPORT_TAG appends -[tag] so several deployments
  # can share one client without their entries being indistinguishable.
  local vless_name="argoport-vless" vmess_name="argoport-vmess"
  local trojan_name="argoport-trojan" ss_name="argoport-ss"
  if [[ -n "$TAG" ]]; then
    vless_name="${vless_name}-[${TAG}]"
    vmess_name="${vmess_name}-[${TAG}]"
    trojan_name="${trojan_name}-[${TAG}]"
    ss_name="${ss_name}-[${TAG}]"
  fi

  ss_cred="chacha20-ietf-poly1305:${NODE_ID}"
  ss_b64=$(printf '%s' "$ss_cred" | base64 -w0)
  # SIP002: the plugin option string must be percent-encoded as a single value.
  ss_plugin=$(printf '%s' "v2ray-plugin;tls;mux=0;mode=websocket;host=${ARGO};path=/${WS_ROOT}-shadowsocks" | jq -sRr @uri)

  vmess_json=$(jq -nc \
    --arg id "$NODE_ID" --arg host "$camo" --arg argo "$ARGO" --arg path "/${WS_ROOT}-vmess" --arg ps "$vmess_name" \
    '{v:"2",ps:$ps,add:$host,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",
      host:$argo,path:$path,tls:"tls",sni:$argo,alpn:""}')
  vmess_b64=$(printf '%s' "$vmess_json" | base64 -w0)

  # Written to a file as well as stdout: notify_telegram() reads it back.
  cat > list <<LINKS

================ argoport · node links ================
identity : ${NODE_ID}
tunnel   : ${ARGO}
path root: /${WS_ROOT}-<protocol>

--- VLESS (recommended) ---
vless://${NODE_ID}@${camo}:443?encryption=none&security=tls&sni=${ARGO}&type=ws&host=${ARGO}&path=%2F${WS_ROOT}-vless#${vless_name}

--- TROJAN ---
trojan://${NODE_ID}@${camo}:443?security=tls&sni=${ARGO}&type=ws&host=${ARGO}&path=%2F${WS_ROOT}-trojan#${trojan_name}

--- VMESS ---
vmess://${vmess_b64}

--- SHADOWSOCKS (SIP002) ---
ss://${ss_b64}@${camo}:443?plugin=${ss_plugin}&security=tls&sni=${ARGO}&type=ws&host=${ARGO}&path=%2F${WS_ROOT}-shadowsocks#${ss_name}

  kalau client kamu tidak menerima link di atas, isi manual:
  Server:      ${camo}
  Port:        443
  Password:    ${NODE_ID}
  Method:      chacha20-ietf-poly1305
  Plugin:      v2ray-plugin
  Plugin Opts: mode=websocket;tls=1;host=${ARGO};path=/${WS_ROOT}-shadowsocks
  SNI:         ${ARGO}

--- CLASH META ---
- { name: ${vless_name}, type: vless, server: ${camo}, port: 443, uuid: ${NODE_ID}, tls: true, servername: ${ARGO}, skip-cert-verify: false, network: ws, ws-opts: { path: /${WS_ROOT}-vless, headers: { Host: ${ARGO} } }, udp: true }
- { name: ${trojan_name}, type: trojan, server: ${camo}, port: 443, password: ${NODE_ID}, tls: true, sni: ${ARGO}, skip-cert-verify: false, network: ws, ws-opts: { path: /${WS_ROOT}-trojan, headers: { Host: ${ARGO} } }, udp: true }
- { name: ${ss_name}, type: ss, server: ${camo}, port: 443, cipher: chacha20-ietf-poly1305, password: ${NODE_ID}, plugin: v2ray-plugin, plugin-opts: { mode: websocket, host: ${ARGO}, path: /${WS_ROOT}-shadowsocks, tls: true, skip-cert-verify: false, mux: false } }
======================================================

LINKS
  cat list
}

# ---- telegram (optional) ----
# Fire-and-forget. The node is already up and the links are already printed by
# the time this runs, so nothing here is allowed to kill the container.
notify_telegram() {
  if [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]]; then
    say "telegram: not configured, skipping"
    return 0
  fi

  # One message. The list file is ~3.3KB, under Telegram's 4096 cap, but the
  # chunker below still splits it correctly if the tag or path ever pushes it over.
  local msg
  msg="⚡️ argoport node
identity: ${NODE_ID}
tunnel  : ${ARGO}

$(cat list)"

  local chunk="" line sent=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ${#chunk} + ${#line} + 1 > 3900 )); then
      if ! tg_send "$chunk"; then
        warn "telegram: send failed (non-fatal)"
        return 0
      fi
      sent=$((sent + 1))
      chunk="${line}"$'\n'
    else
      chunk+="${line}"$'\n'
    fi
  done <<< "$msg"

  if [[ -n "${chunk//[$'\n']/}" ]]; then
    if ! tg_send "$chunk"; then
      warn "telegram: send failed (non-fatal)"
      return 0
    fi
    sent=$((sent + 1))
  fi
  say "telegram: sent ${sent} message(s) to chat ${TG_CHAT}"
}

# Send one chunk. stderr is discarded — curl echoes the request URL on
# failure, and that URL carries the bot token.
tg_send() {
  curl -fsS --max-time 20 -X POST \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=$1" >/dev/null 2>&1
}

# ---- main ----
main() {
  resolve_identity
  say "listen   ${BIND}:${HOST_PORT}"
  command -v xray >/dev/null || die "xray not on PATH"
  command -v cloudflared >/dev/null || die "cloudflared not on PATH"

  start_xray
  start_tunnel
  emit_links
  notify_telegram

  say "handing off — following xray (tunnel stays in background)"
  wait "$XRAY_PID"
}

main "$@"
