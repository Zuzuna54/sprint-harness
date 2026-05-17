#!/usr/bin/env bash
# sprint-pii-redact.sh — strip PII patterns from input before WebSearch / external query.
#
# Per spec §J: "WebSearch (if any) redacts user-id/email/token patterns before search."
# This script is the primitive. Hook integration into PreToolUse:WebSearch is separate.
#
# Usage:
#   echo "search me for gio@example.com password=hunter2" | bash scripts/sprint-pii-redact.sh
#   bash scripts/sprint-pii-redact.sh "user 8f7e1c44-... lost their JWT eyJhbGciOiJIUzI1..."
#
# Patterns redacted (replaced with [REDACTED-<type>]):
#   - email addresses
#   - UUIDs (v4-ish)
#   - JWT tokens (eyJ... three base64-like segments)
#   - API keys (sk-..., AIza..., gh[ps]_..., xoxb-...)
#   - password / secret / token = value
#   - postgresql:// connection strings
#
# Exit 0 always. Output: redacted text on stdout. Match count on stderr.
set -u

if [ $# -gt 0 ]; then
  INPUT="$*"
else
  INPUT="$(cat)"
fi

# Use perl for portable -p inline replacements (macOS sed has issues with \b)
OUT="$INPUT"
MATCHES=0

# Email
NEW=$(printf '%s' "$OUT" | perl -pe 's/\b[A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/[REDACTED-EMAIL]/g')
[ "$NEW" != "$OUT" ] && MATCHES=$((MATCHES+1)) && OUT="$NEW"

# UUID
NEW=$(printf '%s' "$OUT" | perl -pe 's/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/[REDACTED-UUID]/gi')
[ "$NEW" != "$OUT" ] && MATCHES=$((MATCHES+1)) && OUT="$NEW"

# JWT (three base64-like segments separated by dots)
NEW=$(printf '%s' "$OUT" | perl -pe 's/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b/[REDACTED-JWT]/g')
[ "$NEW" != "$OUT" ] && MATCHES=$((MATCHES+1)) && OUT="$NEW"

# API keys: OpenAI sk-, Google AIza, GitHub ghp_/ghs_, Slack xoxb-
NEW=$(printf '%s' "$OUT" | perl -pe 's/\b(sk-[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{30,}|gh[ps]_[A-Za-z0-9]{30,}|xox[abprs]-[A-Za-z0-9-]{20,})\b/[REDACTED-APIKEY]/g')
[ "$NEW" != "$OUT" ] && MATCHES=$((MATCHES+1)) && OUT="$NEW"

# password= / secret= / token= value pairs
NEW=$(printf '%s' "$OUT" | perl -pe 's/\b(password|secret|token|apikey|api_key)\s*=\s*\S+/$1=[REDACTED]/gi')
[ "$NEW" != "$OUT" ] && MATCHES=$((MATCHES+1)) && OUT="$NEW"

# postgresql connection string
NEW=$(printf '%s' "$OUT" | perl -pe 's|postgresql://[^\s\"'\'']+|[REDACTED-DBURL]|g')
[ "$NEW" != "$OUT" ] && MATCHES=$((MATCHES+1)) && OUT="$NEW"

echo "$OUT"
echo "[pii-redact] $MATCHES pattern class(es) matched" >&2
