#!/usr/bin/env bash
# Install the GEO audit skill globally into ~/.claude/.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/fathanabds/geo-seo/main/install.sh | bash
#
# What it does:
#   1. Copies agents/ → ~/.claude/agents/
#   2. Copies skills/ → ~/.claude/skills/
#   3. Creates an isolated Python venv at ~/.claude/skills/geo/.venv/
#   4. Installs Python dependencies into that venv
#   5. Patches script shebangs + markdown placeholders to point at the venv

set -euo pipefail

REPO_URL="https://github.com/fathanabds/geo-seo.git"

# --- Paths ---
CLAUDE_DIR="${HOME}/.claude"
SKILLS_DIR="${CLAUDE_DIR}/skills"
AGENTS_DIR="${CLAUDE_DIR}/agents"
INSTALL_DIR="${SKILLS_DIR}/geo"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
VENV_DIR="${INSTALL_DIR}/.venv"
VENV_PY="${VENV_DIR}/bin/python3"

# Tilde-form path for patched references inside skill/agent .md files.
# The tilde is intentionally kept literal — Claude Code's Bash expands
# it when running the command later. Do NOT replace with $HOME here.
# shellcheck disable=SC2088
VENV_MD_PY='~/.claude/skills/geo/.venv/bin/python3'
# shellcheck disable=SC2088
SCRIPTS_MD_DIR='~/.claude/skills/geo/scripts'

# --- Resolve bundle source: local checkout OR shallow clone to temp dir ---
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "bash" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
fi

TEMP_DIR=""
cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/skills/geo-audit/SKILL.md" ]; then
  BUNDLE_DIR="$SCRIPT_DIR"
  echo "→ Using local bundle: $BUNDLE_DIR"
else
  if ! command -v git >/dev/null 2>&1; then
    echo "Error: git is required to fetch the bundle (not found on PATH)."
    exit 1
  fi
  TEMP_DIR="$(mktemp -d)"
  echo "→ Cloning $REPO_URL → $TEMP_DIR"
  git clone --depth 1 --quiet "$REPO_URL" "$TEMP_DIR/repo"
  BUNDLE_DIR="$TEMP_DIR/repo"
fi

# --- Pick python ---
PY=""
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "Error: python3 not found on PATH"
  exit 1
fi

echo "→ Installing into: $CLAUDE_DIR"
echo "→ Using python:    $($PY --version)"

# --- 1. Copy agents ---
mkdir -p "$AGENTS_DIR"
cp "$BUNDLE_DIR/agents/"*.md "$AGENTS_DIR/"
echo "✓ Agents copied to $AGENTS_DIR ($(ls "$AGENTS_DIR" | wc -l | tr -d ' ') files)"

# --- 2. Copy skills (geo-audit orchestrator + geo helper skill with scripts) ---
mkdir -p "$SKILLS_DIR"
cp -R "$BUNDLE_DIR/skills/"* "$SKILLS_DIR/"
echo "✓ Skills copied to $SKILLS_DIR"

# --- 3. Create venv ---
rm -rf "$VENV_DIR"
if command -v uv >/dev/null 2>&1; then
  uv venv "$VENV_DIR" --python "$PY" --quiet
  uv pip install --python "$VENV_PY" -r "$INSTALL_DIR/requirements.txt" --quiet
else
  $PY -m venv "$VENV_DIR"
  "$VENV_PY" -m pip install --upgrade pip --quiet
  "$VENV_PY" -m pip install -r "$INSTALL_DIR/requirements.txt" --quiet
fi
echo "✓ Venv created at $VENV_DIR"

# --- 4. Patch script shebangs (absolute path — shebangs don't expand ~) ---
for f in "$SCRIPTS_DIR"/*.py; do
  [ -f "$f" ] || continue
  sed -i.bak "1s|^#!.*|#!${VENV_PY}|" "$f" && rm -f "${f}.bak"
  chmod +x "$f"
done
echo "✓ Script shebangs patched"

# --- 5. Substitute placeholders in agent + skill markdown (tilde-form — Bash expands later) ---
patch_md() {
  local f="$1"
  sed -i.bak \
    -e "s|__GEO_SCRIPTS__|${SCRIPTS_MD_DIR}|g" \
    -e "s|__GEO_VENV_PY__|${VENV_MD_PY}|g" \
    "$f" && rm -f "${f}.bak"
}
PATCH_COUNT=0
for f in "$AGENTS_DIR"/geo-*.md "$SKILLS_DIR"/geo-*/SKILL.md; do
  [ -f "$f" ] || continue
  if grep -qE '__GEO_SCRIPTS__|__GEO_VENV_PY__' "$f"; then
    patch_md "$f"
    PATCH_COUNT=$((PATCH_COUNT + 1))
  fi
done
echo "✓ ${PATCH_COUNT} markdown file(s) patched"

# --- Done ---
echo ""
echo "Installation complete."
echo ""
echo "Next steps:"
echo "  1. Open Claude Code in any project"
echo "  2. Run: /geo-audit <url>"
