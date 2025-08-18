#!/usr/bin/env bash
# Purge backend and both Payment Processors
# Usage:
#   TOKEN=123 ./purge_all.sh
#   ./purge_all.sh 123
# Optional overrides:
#   BACKEND_URL, PP_DEFAULT_URL, PP_FALLBACK_URL

set -euo pipefail

# Inputs with sensible defaults
TOKEN="${TOKEN:-${1:-123}}"
BACKEND_URL="${BACKEND_URL:-http://localhost:9999}"
PP_DEFAULT_URL="${PP_DEFAULT_URL:-http://localhost:8001}"
PP_FALLBACK_URL="${PP_FALLBACK_URL:-http://localhost:8002}"

red() { printf "\033[0;31m%s\033[0m\n" "$*"; }
green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }

call_post() {
  local url="$1"; shift
  local tmp
  tmp="$(mktemp)"
  local code
  if ! code=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$url" "$@" 2>/dev/null); then
    red "ERROR calling $url"
    rm -f "$tmp"
    return 1
  fi
  local body
  body="$(cat "$tmp")"
  rm -f "$tmp"
  if [[ "$code" =~ ^2 ]]; then
    green "OK  $url ($code): $body"
  else
    red "FAIL $url ($code): $body"
    return 1
  fi
}

main() {
  yellow "Purging backend at $BACKEND_URL ..."
  call_post "$BACKEND_URL/purge-payments" -H 'Content-Type: application/json' || true

  yellow "Purging Payment Processor DEFAULT at $PP_DEFAULT_URL ..."
  call_post "$PP_DEFAULT_URL/admin/purge-payments" -H "X-Rinha-Token: $TOKEN" || true

  yellow "Purging Payment Processor FALLBACK at $PP_FALLBACK_URL ..."
  call_post "$PP_FALLBACK_URL/admin/purge-payments" -H "X-Rinha-Token: $TOKEN" || true

  green "Purge sequence completed."

  yellow "Check payments summary"

  green "Payment Processor DEFAULT:"
  curl -s "http://localhost:8001/admin/payments-summary" -H "X-Rinha-Token: 123" | jq .

  green "Payment Processor FALLBACK:"
  curl -s "http://localhost:8002/admin/payments-summary" -H "X-Rinha-Token: 123" | jq .

  green "Payment Processor BACKEND:"
  curl -s "http://localhost:9999/payments-summary" | jq .
}

main "$@"
