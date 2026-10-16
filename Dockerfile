# syntax=docker/dockerfile:1
# argoport — multi-protocol Xray node behind a Cloudflare quick tunnel.
# Baked at build time so the container starts in seconds, not minutes.

ARG XRAY_VERSION=26.3.27
ARG CF_VERSION=2026.10.1

# ---- fetch stage: pull both binaries, no runtime download ----
FROM alpine:3.20 AS grab
ARG XRAY_VERSION
ARG CF_VERSION
RUN apk add --no-cache curl unzip
WORKDIR /grab

RUN curl -fsSL --retry 3 -o xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip" \
 && unzip -oq xray.zip xray geoip.dat geosite.dat \
 && rm xray.zip \
 && curl -fsSL --retry 3 -o cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-amd64" \
 && chmod +x xray cloudflared \
 && ./xray version \
 && ./cloudflared --version

# ---- runtime stage: minimal, non-root ----
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home argoport

COPY --from=grab /grab/xray /grab/geoip.dat /grab/geosite.dat /grab/cloudflared /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/argoport-entry
RUN chmod +x /usr/local/bin/argoport-entry /usr/local/bin/xray /usr/local/bin/cloudflared

# Railway injects PORT; default keeps it runnable elsewhere.
ENV PORT=8080 \
    ARGOPORT_BIND=0.0.0.0 \
    ARGOPORT_PATH=argo \
    ARGOPORT_LOG=warning

WORKDIR /run
USER argoport
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD sh -c 'exec 3<>/dev/tcp/127.0.0.1/${PORT:-8080}' || exit 1

ENTRYPOINT ["/usr/local/bin/argoport-entry"]
