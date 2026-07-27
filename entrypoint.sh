#!/usr/bin/env bash
set -euo pipefail

: "${DOT_HOSTNAME:?DOT_HOSTNAME must be set, e.g. -e DOT_HOSTNAME=your-gateway-dot-hostname}"
DOT_PORT="${DOT_PORT:-853}"
BOOTSTRAP_RESOLVER="${BOOTSTRAP_RESOLVER:-8.8.8.8}"

echo "[entrypoint] bootstrap-resolving ${DOT_HOSTNAME} via ${BOOTSTRAP_RESOLVER} (udp/53)..."
DOT_IP="$(dig @"${BOOTSTRAP_RESOLVER}" +short A "${DOT_HOSTNAME}" | head -n1)"

if [[ -z "${DOT_IP}" ]]; then
  echo "[entrypoint] ERROR: could not resolve ${DOT_HOSTNAME} via ${BOOTSTRAP_RESOLVER}" >&2
  exit 1
fi

echo "[entrypoint] ${DOT_HOSTNAME} -> ${DOT_IP}, configuring stubby for DoT on port ${DOT_PORT}"

export DOT_IP DOT_HOSTNAME DOT_PORT
envsubst '${DOT_IP} ${DOT_HOSTNAME} ${DOT_PORT}' < /etc/stubby/stubby.yml.tpl > /etc/stubby/stubby.yml

echo "nameserver 127.0.0.1" > /etc/resolv.conf

stubby -C /etc/stubby/stubby.yml -g

for i in $(seq 1 20); do
  if nc -z 127.0.0.1 53 2>/dev/null; then
    echo "[entrypoint] stubby is up, listening on 127.0.0.1:53"
    break
  fi
  sleep 0.25
  if [[ "$i" -eq 20 ]]; then
    echo "[entrypoint] ERROR: stubby did not start listening on 127.0.0.1:53" >&2
    exit 1
  fi
done

exec "$@"
