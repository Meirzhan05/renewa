#!/usr/bin/env bash
#
# Terminal end-to-end inbox scan — the app's "Scan" button, without the simulator.
#
# It signs in as the Renewa user (Supabase password grant → user JWT), triggers a real scan through
# the deployed `email-scan` edge function (which drives the trigger.dev agent), polls status until the
# run is terminal, and prints the discovered subscription candidates. This exercises the full deployed
# pipeline: edge → trigger.dev orchestrator → parallel page analysis → candidate bridge.
#
# Config (SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY) is read from Config.local.xcconfig, overridable by
# env vars of the same name. Credentials come from env (RENEWA_EMAIL / RENEWA_PASSWORD) or an
# interactive prompt; the password is never echoed or stored.
#
# Usage:
#   scripts/scan.sh                                  # prompts for email/password
#   RENEWA_EMAIL=you@x.com RENEWA_PASSWORD=… scripts/scan.sh
#   RENEWA_ACCESS_TOKEN=eyJ… scripts/scan.sh         # OAuth/magic-link accounts (no password)
#   POLL_SECONDS=3 MAX_MINUTES=30 scripts/scan.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/Config.local.xcconfig"
POLL_SECONDS="${POLL_SECONDS:-5}"
MAX_MINUTES="${MAX_MINUTES:-25}"

ENVFILE="$ROOT/worker/.env"

read_cfg() { # key -> value from the xcconfig (empty if absent)
  [ -f "$CONFIG" ] || return 0
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" | head -1 | sed -E "s/^[^=]*=[[:space:]]*//" | tr -d '\r'
}

read_env() { # key -> value from worker/.env (empty if absent), quotes stripped
  [ -f "$ENVFILE" ] || return 0
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$ENVFILE" | head -1 | sed -E "s/^[^=]*=[[:space:]]*//" | tr -d '\r' \
    | sed -E "s/^['\"]//; s/['\"][[:space:]]*$//"
}

# Read one top-level string field from JSON on stdin; prints empty on any error/missing key.
field() { python3 -c "import sys,json
try:
    v=json.load(sys.stdin).get(sys.argv[1], '')
    print('' if v is None else v)
except Exception:
    pass" "$1"; }

jstr() { python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$1"; } # JSON-encode a string

# Prefer the clean URL in worker/.env; fall back to the xcconfig. The key lives only in the xcconfig.
SUPABASE_URL="${SUPABASE_URL:-$(read_env SUPABASE_URL)}"
[ -n "$SUPABASE_URL" ] || SUPABASE_URL="$(read_cfg SUPABASE_URL)"
ANON_KEY="${SUPABASE_PUBLISHABLE_KEY:-$(read_cfg SUPABASE_PUBLISHABLE_KEY)}"
[ -n "$ANON_KEY" ] || ANON_KEY="$(read_env SUPABASE_PUBLISHABLE_KEY)"
# xcconfig escapes "//" as "/$()/" so Xcode won't treat it as a comment — undo that, then normalize to
# the project base URL (drop a trailing slash and any /rest/v1 suffix).
SUPABASE_URL="${SUPABASE_URL//\$()/}"; ANON_KEY="${ANON_KEY//\$()/}"
SUPABASE_URL="${SUPABASE_URL%/}"; SUPABASE_URL="${SUPABASE_URL%/rest/v1}"; SUPABASE_URL="${SUPABASE_URL%/}"
if [ -z "$SUPABASE_URL" ] || [ -z "$ANON_KEY" ]; then
  echo "✗ Missing SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY (set them in Config.local.xcconfig or env)." >&2
  exit 1
fi
echo "→ Supabase: $SUPABASE_URL"

edge() { # POST the edge function with an action + optional extra JSON body fields
  curl -fsS -X POST "$SUPABASE_URL/functions/v1/email-scan" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"action\":\"$1\"${2:+,$2}}"
}

# Auth: prefer a pre-obtained user JWT (works for OAuth/magic-link accounts with no password), else
# sign in with email + password. A JWT is short-lived (~1h) — fine for a single scan.
TOKEN="${RENEWA_ACCESS_TOKEN:-}"
if [ -n "$TOKEN" ]; then
  echo "→ Using RENEWA_ACCESS_TOKEN"
else
  EMAIL="${RENEWA_EMAIL:-}"
  [ -n "$EMAIL" ] || read -r -p "Renewa email: " EMAIL
  PASSWORD="${RENEWA_PASSWORD:-}"
  if [ -z "$PASSWORD" ]; then read -r -s -p "Password: " PASSWORD; echo; fi
  echo "→ Signing in as $EMAIL …"
  AUTH="$(curl -fsS -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":$(jstr "$EMAIL"),\"password\":$(jstr "$PASSWORD")}" || true)"
  TOKEN="$(printf '%s' "$AUTH" | field access_token)"
  if [ -z "$TOKEN" ]; then
    echo "✗ Sign-in failed (OAuth/magic-link account? set RENEWA_ACCESS_TOKEN instead):" >&2
    printf '%s\n' "$AUTH" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$AUTH"
    exit 1
  fi
fi

# Preflight: surface a dead/absent inbox grant as a clear message here, instead of letting it fail
# mid-scan as a cryptic "Bad Request" (an expired Google refresh token). Bypass with SKIP_PREFLIGHT=1.
if [ "${SKIP_PREFLIGHT:-}" != "1" ]; then
  PREFLIGHT="$(edge connections 2>/dev/null | python3 -c '
import sys, json
try:
    conns = (json.load(sys.stdin) or {}).get("connections") or []
except Exception:
    print("SKIP"); sys.exit(0)
if not conns:
    print("NONE"); sys.exit(0)
bad = []
for c in conns:
    if c.get("health") == "attention" or c.get("monitoring_health") == "reconnect_required":
        who = c.get("redacted_email") or c.get("provider") or "inbox"
        why = c.get("monitoring_error") or "authorization needs attention"
        bad.append("%s (%s)" % (who, why))
if bad:
    print("BAD:" + " | ".join(bad))
else:
    print("OK:" + ", ".join((c.get("redacted_email") or c.get("provider") or "inbox") for c in conns))
' || echo SKIP)"
  case "$PREFLIGHT" in
    NONE) echo "⚠  No inbox connected — connect one in the app, then re-run." >&2; exit 1 ;;
    BAD:*)
      echo "⚠  Inbox needs reconnection: ${PREFLIGHT#BAD:}" >&2
      echo "   Re-authorize it in the app (Inbox → Reconnect), then re-run.  (SKIP_PREFLIGHT=1 to bypass.)" >&2
      exit 1 ;;
    OK:*) echo "→ Inbox: ${PREFLIGHT#OK:}" ;;
    *)    echo "→ (preflight skipped — could not read connection health)" ;;
  esac
fi

echo "→ Starting scan …"
START="$(edge start || true)"
SCAN_ID="$(printf '%s' "$START" | field scan_id)"
if [ -z "$SCAN_ID" ]; then
  echo "✗ Could not start scan:" >&2
  printf '%s\n' "$START" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$START"
  exit 1
fi
echo "  scan_id=$SCAN_ID reused=$(printf '%s' "$START" | field reused)"

echo "→ Polling (every ${POLL_SECONDS}s, max ${MAX_MINUTES}m) — Ctrl-C to stop:"
STARTED=$(date +%s)
DEADLINE=$(( STARTED + MAX_MINUTES * 60 ))
STATUS_JSON="{}"
while :; do
  STATUS_JSON="$(edge status "\"scan_id\":$(jstr "$SCAN_ID")" || echo '{}')"
  STATUS="$(printf '%s' "$STATUS_JSON" | field status)"
  STAGE="$(printf '%s' "$STATUS_JSON" | field stage)"
  SCANNED="$(printf '%s' "$STATUS_JSON" | field scanned)"
  LIKELY="$(printf '%s' "$STATUS_JSON" | field candidate_messages)"
  DETECTED="$(printf '%s' "$STATUS_JSON" | field detected)"
  PENDING="$(printf '%s' "$STATUS_JSON" | field pending_count)"
  ELAPSED=$(( $(date +%s) - STARTED ))
  printf "  [%4ds] %-9s %-12s checked=%-6s likely=%-5s detected=%-4s pending=%-4s\n" \
    "$ELAPSED" "${STATUS:-?}" "${STAGE:-?}" "${SCANNED:-0}" "${LIKELY:-0}" "${DETECTED:-0}" "${PENDING:-0}"
  case "$STATUS" in
    completed|failed|partial|cancelled) break ;;
  esac
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then echo "  ⏱  stopped after ${MAX_MINUTES}m (still $STATUS)"; break; fi
  sleep "$POLL_SECONDS"
done

echo ""
echo "→ Result: $STATUS ($STAGE)"
printf '%s' "$STATUS_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (no status JSON to parse)"); sys.exit(0)
errs = [str(e) for e in (d.get("errors") or []) if e]
if errs:
    print("  errors:")
    for e in errs:
        print("    - " + e)
cands = d.get("candidates") or []
print(("  candidates (%d):" % len(cands)) if cands else "  candidates: (none)")
for c in cands:
    amt = c.get("amount")
    cur = c.get("currency") or ""
    cyc = c.get("billing_cycle") or "one-off"
    money = (cur + " " + str(amt)).strip() if amt is not None else "amount n/a"
    print("    - %s  --  %s  %s  [%s]" % (c.get("merchant_name", "?"), money, cyc, c.get("suggested_action", "")))
'
