#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_SKILLS_DIR="$ROOT_DIR/plugins/nav-center/skills"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
DEST_ROOT="$CODEX_HOME_DIR/skills"

skills=(
  nav-center-codex-setup
  nav-center-beta-feedback
)

for skill in "${skills[@]}"; do
  src="$PLUGIN_SKILLS_DIR/$skill/SKILL.md"
  dest="$DEST_ROOT/$skill"

  if [[ ! -f "$src" ]]; then
    echo "missing skill source: $src" >&2
    exit 1
  fi

  mkdir -p "$dest"
  install -m 0644 "$src" "$dest/SKILL.md"
  echo "installed $skill -> $dest/SKILL.md"
done
