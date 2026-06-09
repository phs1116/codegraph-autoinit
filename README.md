# codegraph-autoinit

Keeps [CodeGraph](https://github.com/colbymchenry/codegraph) indexes up to date across git worktrees — automatically, in the background, without blocking git commands.

## The problem

CodeGraph stores its index at `.codegraph/codegraph.db` inside each worktree directory. When you create a new worktree (`git worktree add`, Superset, Claude Code, etc.) that directory starts empty and has no index. MCP tools that rely on the index report "Not initialized" until you manually run `codegraph init`.

codegraph-autoinit wires git hooks (`post-checkout`, `post-merge`, `post-rewrite`) so this happens automatically.

## How it works

When a hook fires:

1. **Already fresh?** `codegraph status --json` checks `initialized`, `worktreeMismatch`, and `pendingChanges`. If all clear → skip.
2. **Stale index?** → queue `sync`.
3. **No index?** → queue `init`. Before running a full init, the worker looks for a sibling worktree that shares the same git commit and has a verified, clean index. If found, it copies that DB via `VACUUM INTO` (a few seconds) instead of re-indexing from scratch (~18s for a typical repo).

All work runs in a background worker (`nohup`) so git is never blocked. The queue is file-based; only one worker runs per machine at a time.

## Install

```sh
# Install hooks for the current repo
./bin/install.sh

# Or specify a repo path
./bin/install.sh ~/path/to/your-repo
```

`install.sh` copies the script to `~/.codegraph-autoinit/bin/` and wires `post-checkout`, `post-merge`, and `post-rewrite` hooks into the repo. The hooks point to the pinned installed copy so your dev checkout of this repo doesn't affect a running installation.

### Multiple repos

Run `install.sh` for each repo:

```sh
./bin/install.sh ~/repos/repo-a
./bin/install.sh ~/repos/repo-b
```

Or install into every git repo under a directory at once:

```sh
~/.codegraph-autoinit/bin/codegraph-autoinit.sh install-project-hooks ~/repos
```

### Global template (optional)

To auto-install hooks into every future `git init` / `git clone`:

```sh
~/.codegraph-autoinit/bin/codegraph-autoinit.sh install-template-hook
```

This sets `init.templateDir` globally. Existing repos are not affected.

## Claude Code / AI assistant integration

To ensure every session starts with a fresh index, add an `ensure` call to Claude Code's `SessionStart` hook in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.codegraph-autoinit/bin/codegraph-autoinit.sh ensure"
          }
        ]
      }
    ]
  }
}
```

To restrict to specific repos, inject the scope env var:

```json
"command": "CODEGRAPH_AUTOINIT_REPOS=\"$HOME/repos/my-repo\" ~/.codegraph-autoinit/bin/codegraph-autoinit.sh ensure"
```

## Scope guard

By default the runtime acts wherever hooks are installed — scope is determined by where you install hooks, not by the script. To add an extra runtime restriction, set `CODEGRAPH_AUTOINIT_REPOS` to a space-separated list of repo roots:

```sh
export CODEGRAPH_AUTOINIT_REPOS="$HOME/repos/repo-a $HOME/repos/repo-b"
```

Repos are matched by their shared git common-dir, so all worktrees of a repo are covered by a single entry.

## Files

```
~/.codegraph-autoinit/
└── bin/
    ├── codegraph-autoinit.sh   # Main script: hooks, worker, install/uninstall
    ├── install.sh              # Copies script + wires repo hooks
    └── uninstall.sh            # Removes wiring (optionally purges indexes)

~/.cache/codegraph-autoinit/
├── runner.log                  # All activity log
├── logs/<hash>.log             # Per-repo init/sync output
├── queue/                      # Pending tasks (file-based queue)
└── <hash>.lock                 # Per-repo mutex (mkdir-based, stale-safe)
```

## Uninstall

Remove wiring only (indexes and program files are kept):

```sh
~/.codegraph-autoinit/bin/uninstall.sh [/path/to/repo]
```

Remove everything including `.codegraph` indexes and the program itself:

```sh
~/.codegraph-autoinit/bin/uninstall.sh --purge [/path/to/repo]
```

## Debugging

```sh
# Check index status for the current directory
~/.codegraph-autoinit/bin/codegraph-autoinit.sh status

# Tail the activity log
tail -f ~/.cache/codegraph-autoinit/runner.log

# Per-repo init/sync output
ls ~/.cache/codegraph-autoinit/logs/

# Force re-index (removes existing index and triggers a fresh init)
rm -rf .codegraph
~/.codegraph-autoinit/bin/codegraph-autoinit.sh init-one "$PWD"
```

## Seed safety rules

A sibling worktree is used as a seed only when all of these pass:

- Same git common-dir as the target worktree
- Working tree is clean (tracked files only; untracked files are ignored)
- `codegraph status` reports `initialized=true`, no `worktreeMismatch`, zero `pendingChanges`
- Index contains no nested worktree paths (`.worktrees/`, `.superset/worktrees/`, `.claude/worktrees/`, etc.)
- After the `VACUUM INTO` copy, `codegraph sync` completes and `status_fresh` passes — otherwise the copy is discarded and a full `init` runs

## Command reference

```
codegraph-autoinit <command> [args]

ensure [PATH]              Check freshness and queue work if needed.
hook-git-update HOOK ...   Git hook entrypoint (called by post-checkout/merge/rewrite).
worker                     Process queued jobs (spawned automatically).
init-one PATH              Seed/init PATH immediately (blocking).
sync-one PATH              Sync PATH immediately (blocking).
install-repo-hook [PATH]   Wire hooks into ONE repo (default: current dir).
status [PATH]              Print CodeGraph status JSON.

Advanced (wide blast radius — use with care):
  install-project-hooks DIR  Wire hooks into ALL repos under DIR.
  install-template-hook      Set a global git init.templateDir hook.

Uninstall (safe/idempotent; existing hooks outside our marker block are preserved):
  uninstall-repo-hook [PATH]   Remove managed hooks from ONE repo.
  uninstall-project-hooks DIR  Remove managed hooks from ALL repos under DIR.
  uninstall-template-hook      Remove global template hooks + unset templateDir.
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CODEGRAPH_AUTOINIT_REPOS` | *(empty)* | Space-separated repo roots for scope restriction. Empty = act wherever hooks are installed. |
| `CODEGRAPH_AUTOINIT_HOME` | `~/.cache/codegraph-autoinit` | Runtime cache directory (queue, locks, logs). |
| `CODEGRAPH_AUTOINIT_PROJECTS_DIR` | `~/repos` | Base dir for `install-project-hooks` sweep. |
| `CODEGRAPH_AUTOINIT_INSTALL_DIR` | `~/.codegraph-autoinit/bin` | Where `install.sh` pins the executable. |
| `CODEGRAPH_AUTOINIT_FIND_MAX_DEPTH` | `5` | Max directory depth for `install-project-hooks`. |

## Requirements

- bash 3.2+
- git
- `codegraph` on `$PATH`
- `sqlite3` — used for seed validation; gracefully skipped if absent
- `jq` — used for `status_fresh` check; gracefully skipped if absent (falls back to full init)
