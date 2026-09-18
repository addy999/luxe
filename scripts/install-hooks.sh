#!/bin/bash
# Install git hooks from the tracked hooks/ directory into .git/hooks/.
# Keeps the pre-commit GDExtension rebuild gate version-controlled instead
# of living only on one machine.
#
# Usage: scripts/install-hooks.sh   (run from the repo root)

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOKS_SRC="$ROOT/hooks"
HOOKS_DST="$ROOT/.git/hooks"

[ -d "$HOOKS_SRC" ] || { echo "install-hooks: no hooks/ dir at $HOOKS_SRC" >&2; exit 1; }

installed=0
for hook in "$HOOKS_SRC"/*; do
  [ -f "$hook" ] || continue
  name="$(basename "$hook")"
  if [ -e "$HOOKS_DST/$name" ] && ! cmp -s "$hook" "$HOOKS_DST/$name"; then
    echo "install-hooks: $name already exists and differs, overwriting (was not identical)"
  fi
  cp "$hook" "$HOOKS_DST/$name"
  chmod +x "$HOOKS_DST/$name"
  echo "install-hooks: installed $name"
  installed=$((installed + 1))
done

if [ "$installed" -eq 0 ]; then
  echo "install-hooks: nothing to install"
else
  echo "install-hooks: done ($installed hook(s))"
fi
