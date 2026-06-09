#!/usr/bin/env bash
# Install codegraph-autoinit git hooks into ONE repo (and its worktrees, which
# share the repo's common git-hooks dir).
#
# Repo-scoped by design: installs only into the given repo — no ~/Project sweep
# and no global git init.templateDir. The executable is pinned to a fixed
# install dir and hooks point there, so a git hook never references a
# transient/dev copy of the script.
#
# Usage: install.sh [REPO]
#   REPO defaults to $CODEGRAPH_AUTOINIT_REPO, else the current repo ($PWD).
#   Optionally export CODEGRAPH_AUTOINIT_REPOS to restrict the runtime scope.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)"
MAIN="$SCRIPT_DIR/codegraph-autoinit.sh"
REPO="${1:-${CODEGRAPH_AUTOINIT_REPO:-$PWD}}"
INSTALL_DIR="${CODEGRAPH_AUTOINIT_INSTALL_DIR:-$HOME/.codegraph-autoinit/bin}"
INSTALLED="$INSTALL_DIR/codegraph-autoinit.sh"

if [ ! -x "$MAIN" ]; then
  echo "Missing executable: $MAIN" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
src="$(cd "$(dirname "$MAIN")" && pwd -P)/$(basename "$MAIN")"
dst="$(cd "$INSTALL_DIR" && pwd -P)/codegraph-autoinit.sh"
if [ "$src" != "$dst" ]; then
  cp "$MAIN" "$INSTALLED" || { echo "Failed to copy $MAIN -> $INSTALLED" >&2; exit 1; }
fi
chmod +x "$INSTALLED"

"$INSTALLED" install-repo-hook "$REPO"

echo "Installed codegraph-autoinit (repo-scoped)"
echo "  exec: $INSTALLED"
echo "  repo: $REPO"
