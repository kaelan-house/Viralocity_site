#!/usr/bin/env bash
# Diagnose the WordPress MCP endpoint from the machine that will run the client.
#
# Usage:
#   export WP_API_USERNAME='kaelanhouse@icloud.com'
#   export WP_API_PASSWORD='your-application-password'
#   ./scripts/check-wp-mcp.sh
#
# Credentials are read from the environment only — never pass them as arguments.

set -uo pipefail

SITE="${WP_SITE:-https://viralocitymedia.ca}"
MCP_URL="${WP_API_URL:-$SITE/wp-json/mcp/mcp-adapter-default-server}"

if [[ -z "${WP_API_USERNAME:-}" || -z "${WP_API_PASSWORD:-}" ]]; then
  echo "error: set WP_API_USERNAME and WP_API_PASSWORD in the environment first." >&2
  exit 2
fi

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

body=$(mktemp); trap 'rm -f "$body"' EXIT

echo
echo "1. Is the site reachable without a bot challenge?"
code=$(curl -sS -o "$body" -w '%{http_code}' -m 25 "$SITE/wp-json/")
if grep -qi 'sgcaptcha\|captcha' "$body"; then
  bad "blocked by a bot challenge (HTTP $code). Allowlist this machine's IP in"
  echo "        SiteGround Site Tools > Security, or exempt /wp-json/ from the challenge."
  echo; echo "Nothing else can be tested until this passes."; exit 1
elif [[ "$code" == "200" ]]; then ok "REST API reachable (HTTP 200)"
else bad "unexpected HTTP $code from /wp-json/"; fi

echo
echo "2. Do the credentials authenticate?"
code=$(curl -sS -o "$body" -w '%{http_code}' -m 25 -u "$WP_API_USERNAME:$WP_API_PASSWORD" "$SITE/wp-json/wp/v2/users/me")
case "$code" in
  200) ok "authenticated as $(grep -o '"name":"[^"]*"' "$body" | head -1 | cut -d'"' -f4)";;
  401) bad "401 — wrong username or application password, or basic auth is disabled";;
  *)   bad "unexpected HTTP $code";;
esac

echo
echo "3. Is the MCP Adapter plugin registering its namespace?"
curl -sS -o "$body" -m 25 -u "$WP_API_USERNAME:$WP_API_PASSWORD" "$SITE/wp-json/"
if grep -q '"mcp' "$body"; then ok "an 'mcp' namespace is registered"
else bad "no 'mcp' namespace — install and activate the MCP Adapter plugin:"; echo "        https://github.com/WordPress/mcp-adapter"; fi

echo
echo "4. Does the MCP endpoint itself respond?"
code=$(curl -sS -o "$body" -w '%{http_code}' -m 25 -u "$WP_API_USERNAME:$WP_API_PASSWORD" \
  -H 'Content-Type: application/json' -X POST "$MCP_URL" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
if [[ "$code" == "200" ]] && grep -q '"tools"' "$body"; then
  ok "endpoint returned a tool list"
  echo
  echo "  Abilities exposed:"
  grep -o '"name":"[^"]*"' "$body" | cut -d'"' -f4 | sed 's/^/    - /'
  echo
  echo "  Bricks abilities found: $(grep -oc '"name":"[^"]*bricks[^"]*"' "$body" 2>/dev/null || echo 0)"
else
  bad "HTTP $code — endpoint did not return a tool list"
  echo "        response: $(head -c 200 "$body")"
fi

echo
echo "-----------------------------------------"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] && echo "Ready — the MCP server should connect." || echo "Fix the FAIL items above, then re-run."
