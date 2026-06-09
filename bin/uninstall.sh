#!/usr/bin/env bash
# Uninstall codegraph-autoinit.
#
# Default (no flags): remove all WIRING so the system stops acting —
#   - managed git hooks in the target repo,
#   - any stray managed hooks left under ~/Project,
#   - the global template hooks + git init.templateDir (if ours),
#   - the Claude SessionStart 'ensure' hook in ~/.claude/settings.json.
# Your built .codegraph indexes, the program files, and the runtime cache are
# LEFT in place — codegraph keeps working, nothing re-indexes.
#
# --purge additionally DELETES:
#   - the .codegraph index of the target repo and every worktree,
#   - the runtime cache (~/.cache/codegraph-autoinit),
#   - the program dir (~/.codegraph-autoinit).
#
# Usage: uninstall.sh [--purge] [REPO]
#   REPO defaults to $CODEGRAPH_AUTOINIT_REPO, else the current repo ($PWD).

set -u

PURGE=0
REPO=""
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "Unknown flag: $a" >&2; exit 2 ;;
    *) REPO="$a" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)"
INSTALL_DIR="${CODEGRAPH_AUTOINIT_INSTALL_DIR:-$HOME/.codegraph-autoinit/bin}"
INSTALLED="$INSTALL_DIR/codegraph-autoinit.sh"
CACHE_DIR="${CODEGRAPH_AUTOINIT_HOME:-$HOME/.cache/codegraph-autoinit}"
PROJECTS_DIR="${CODEGRAPH_AUTOINIT_PROJECTS_DIR:-$HOME/Project}"
SETTINGS="$HOME/.claude/settings.json"
REPO="${REPO:-${CODEGRAPH_AUTOINIT_REPO:-$PWD}}"

# Prefer the local script; fall back to the installed copy.
RUN="$SCRIPT_DIR/codegraph-autoinit.sh"
[ -x "$RUN" ] || RUN="$INSTALLED"

echo "codegraph-autoinit uninstall (purge=$PURGE)"
echo "  repo: $REPO"

# 1) git hooks: target repo + stray ~/Project hooks + global template.
if [ -x "$RUN" ]; then
  "$RUN" uninstall-repo-hook "$REPO" || true
  "$RUN" uninstall-project-hooks "$PROJECTS_DIR" || true
  "$RUN" uninstall-template-hook || true
  echo "  removed: git hooks (repo + ~/Project sweep + global template)"
else
  echo "  WARN: script not found ($RUN); skipped git-hook removal" >&2
fi

# 2) Claude SessionStart 'ensure' hook.
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    sys.exit(0)
ss = d.get("hooks", {}).get("SessionStart", [])
new = [g for g in ss
       if not any("codegraph-autoinit" in h.get("command", "")
                  for h in g.get("hooks", []))]
if len(new) != len(ss):
    d.setdefault("hooks", {})["SessionStart"] = new
    json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
    print("  removed: Claude SessionStart 'ensure' hook")
PY
fi

if [ "$PURGE" = "1" ]; then
  # 3) .codegraph indexes for the repo + every worktree.
  if command -v git >/dev/null 2>&1 && { [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ]; }; then
    git -C "$REPO" worktree list --porcelain 2>/dev/null |
      awk '/^worktree /{print substr($0, 10)}' |
      while IFS= read -r wt; do
        if [ -e "$wt/.codegraph" ]; then
          rm -rf "$wt/.codegraph" 2>/dev/null && echo "  purged index: $wt/.codegraph"
        fi
      done
  fi

  # 4) runtime cache.
  if [ -d "$CACHE_DIR" ]; then
    rm -rf "$CACHE_DIR" 2>/dev/null && echo "  purged cache: $CACHE_DIR"
  fi

  # 5) program dir — LAST, since this script may live inside it. The kernel keeps
  #    our open fd valid after unlink, so bash finishes reading fine.
  PROG_DIR="$(cd "$INSTALL_DIR/.." 2>/dev/null && pwd -P || true)"
  case "$PROG_DIR" in
    "$HOME"/.codegraph-autoinit)
      rm -rf "$PROG_DIR" 2>/dev/null && echo "  purged program: $PROG_DIR" ;;
    *) [ -n "$PROG_DIR" ] && echo "  skipped program dir (unexpected path: $PROG_DIR)" >&2 ;;
  esac
fi

echo "done."
