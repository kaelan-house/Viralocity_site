#!/usr/bin/env bash
# Set up the Bricks MCP stack on a local machine: skills pack + MCP server config.
#
# Usage:
#   ./scripts/setup-local.sh                 # prompts for client and password
#   ./scripts/setup-local.sh --client codex
#   ./scripts/setup-local.sh --client both
#
# The application password is read from a hidden prompt or the WP_API_PASSWORD
# environment variable. It is never passed as an argument, so it stays out of
# your shell history and out of the process list.

set -euo pipefail

SITE_URL="https://viralocitymedia.ca"
MCP_URL="$SITE_URL/wp-json/mcp/mcp-adapter-default-server"
SERVER_NAME="viralocitymedia-ca"
WP_USER="${WP_API_USERNAME:-kaelanhouse@icloud.com}"
SKILLS_SRC="$HOME/.bricks/skills/bricks-skills"
REPO="https://github.com/codeerhq/bricks-skills.git"

CLIENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) CLIENT="${2:-}"; shift 2;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    ok: %s\n' "$1"; }
die()  { printf '\n\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisites
step "Checking prerequisites"
for cmd in git node curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed. On macOS: brew install $cmd"
  ok "$cmd $("$cmd" --version 2>&1 | head -1 | tr -d '\n')"
done

# ------------------------------------------------------------- pick the client
if [[ -z "$CLIENT" ]]; then
  echo
  echo "Which client are you setting up?"
  echo "  1) Claude Code"
  echo "  2) Codex CLI"
  echo "  3) both"
  read -r -p "Choice [1]: " choice
  case "${choice:-1}" in
    1) CLIENT=claude;; 2) CLIENT=codex;; 3) CLIENT=both;;
    *) die "invalid choice";;
  esac
fi
[[ "$CLIENT" =~ ^(claude|codex|both)$ ]] || die "--client must be claude, codex, or both"

# ------------------------------------------------------------------- password
if [[ -z "${WP_API_PASSWORD:-}" ]]; then
  echo
  echo "WordPress application password for $WP_USER"
  echo "(Users > Profile > Application Passwords; spaces are optional)"
  read -r -s -p "Password: " WP_API_PASSWORD
  echo
fi
# strip the spaces WordPress displays it with
WP_API_PASSWORD="${WP_API_PASSWORD// /}"
[[ -n "$WP_API_PASSWORD" ]] || die "no password provided"
[[ ${#WP_API_PASSWORD} -eq 24 ]] || echo "    note: expected 24 characters, got ${#WP_API_PASSWORD} — continuing anyway"

# --------------------------------------------------------------- skills pack
step "Installing the Bricks skills pack"
if [[ -d "$SKILLS_SRC/.git" ]]; then
  ok "checkout already exists at $SKILLS_SRC"
else
  mkdir -p "$(dirname "$SKILLS_SRC")"
  git clone --quiet "$REPO" "$SKILLS_SRC"
  ok "cloned to $SKILLS_SRC"
fi

if "$SKILLS_SRC/scripts/bricks-skills-upgrade" >/dev/null 2>&1; then
  ok "pinned to latest release: $(cat "$SKILLS_SRC/VERSION")"
else
  # API unreachable or rate-limited: fall back to the highest stable git tag
  TAG="$(git -C "$SKILLS_SRC" tag -l 'v*' | grep -v -- '-' | sort -V | tail -1)"
  [[ -n "$TAG" ]] || die "no stable release tag found"
  git -C "$SKILLS_SRC" checkout --quiet "tags/$TAG"
  ok "release API unavailable; pinned to highest stable tag: $TAG"
fi

# ----------------------------------------------------------------- Claude Code
if [[ "$CLIENT" == "claude" || "$CLIENT" == "both" ]]; then
  step "Configuring Claude Code"
  command -v claude >/dev/null 2>&1 || die "the 'claude' CLI is not on your PATH"

  claude plugin marketplace add "$SKILLS_SRC" >/dev/null 2>&1 \
    || claude plugin marketplace update bricks-skills >/dev/null 2>&1 || true
  claude plugin install bricks@bricks-skills >/dev/null 2>&1 || true
  ok "skills plugin installed ($(ls "$SKILLS_SRC/skills" | wc -l | tr -d ' ') skills)"

  WP_API_PASSWORD="$WP_API_PASSWORD" MCP_URL="$MCP_URL" WP_USER="$WP_USER" \
  SERVER_NAME="$SERVER_NAME" node -e '
    const fs = require("fs"), os = require("os"), path = require("path");
    const f = path.join(os.homedir(), ".claude.json");
    const j = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : {};
    j.mcpServers = j.mcpServers || {};
    j.mcpServers[process.env.SERVER_NAME] = {
      type: "stdio",
      command: "npx",
      args: ["-y", "@automattic/mcp-wordpress-remote@latest"],
      env: {
        WP_API_URL: process.env.MCP_URL,
        WP_API_USERNAME: process.env.WP_USER,
        WP_API_PASSWORD: process.env.WP_API_PASSWORD,
        OAUTH_ENABLED: "false",
      },
    };
    fs.writeFileSync(f, JSON.stringify(j, null, 2));
    fs.chmodSync(f, 0o600);
  '
  ok "MCP server '$SERVER_NAME' written to ~/.claude.json (user scope)"
fi

# ----------------------------------------------------------------- Codex CLI
if [[ "$CLIENT" == "codex" || "$CLIENT" == "both" ]]; then
  step "Configuring Codex CLI"
  mkdir -p "$HOME/.codex"

  WP_API_PASSWORD="$WP_API_PASSWORD" MCP_URL="$MCP_URL" WP_USER="$WP_USER" \
  SERVER_NAME="$SERVER_NAME" node -e '
    const fs = require("fs"), os = require("os"), path = require("path");
    const f = path.join(os.homedir(), ".codex", "config.toml");
    const name = process.env.SERVER_NAME;
    let text = fs.existsSync(f) ? fs.readFileSync(f, "utf8") : "";

    // drop any previous block for this server, keeping every other entry
    const lines = text.split("\n");
    const out = [];
    let skipping = false;
    for (const line of lines) {
      if (/^\s*\[/.test(line)) {
        skipping = new RegExp(`^\\s*\\[mcp_servers\\.${name}(\\.|\\])`).test(line);
      }
      if (!skipping) out.push(line);
    }
    text = out.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd();

    const block = [
      `[mcp_servers.${name}]`,
      `command = "npx"`,
      `args = ["-y", "@automattic/mcp-wordpress-remote@latest"]`,
      ``,
      `[mcp_servers.${name}.env]`,
      `WP_API_URL = ${JSON.stringify(process.env.MCP_URL)}`,
      `WP_API_USERNAME = ${JSON.stringify(process.env.WP_USER)}`,
      `WP_API_PASSWORD = ${JSON.stringify(process.env.WP_API_PASSWORD)}`,
      `OAUTH_ENABLED = "false"`,
    ].join("\n");

    fs.writeFileSync(f, (text ? text + "\n\n" : "") + block + "\n");
    fs.chmodSync(f, 0o600);
  '
  ok "MCP server '$SERVER_NAME' written to ~/.codex/config.toml"

  SKILLS_DIR="$HOME/.agents/skills"
  mkdir -p "$SKILLS_DIR"
  n=0
  for skill in "$SKILLS_SRC"/skills/bricks-*; do
    ln -sfn "$skill" "$SKILLS_DIR/$(basename "$skill")"
    n=$((n+1))
  done
  ok "$n skills symlinked into $SKILLS_DIR"
fi

# -------------------------------------------------------------- connectivity
step "Testing the connection to $SITE_URL"
if [[ -x "$(dirname "$0")/check-wp-mcp.sh" ]]; then
  WP_API_USERNAME="$WP_USER" WP_API_PASSWORD="$WP_API_PASSWORD" \
    "$(dirname "$0")/check-wp-mcp.sh" || true
else
  echo "    check-wp-mcp.sh not found next to this script; skipping"
fi

step "Done"
echo "Restart your client (or start a new chat) so it loads the skills and MCP server."
[[ "$CLIENT" != "codex" ]] && echo "In Claude Code, run /mcp to confirm '$SERVER_NAME' connected."
echo "Then ask it to list the available Bricks abilities."
