#!/usr/bin/env bash
# codegraph-autoinit
#
# Keeps per-worktree CodeGraph indexes available without blocking git commands.
# Hooks (post-checkout/merge/rewrite) skip when the index is already fresh,
# otherwise sync a stale index or init a missing one. Work runs in a background
# worker so git is never blocked. status_fresh — not mere DB existence — decides.

set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Resolve our own path so the worker re-dispatch and hook-baked paths stay
# consistent regardless of where install.sh pinned the executable.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
[ -f "$SELF" ] || SELF="$HOME/.codegraph-autoinit/bin/codegraph-autoinit.sh"
BASE_DIR="${CODEGRAPH_AUTOINIT_HOME:-$HOME/.cache/codegraph-autoinit}"
LOG_DIR="$BASE_DIR/logs"
QUEUE_DIR="$BASE_DIR/queue"
RUN_LOG="$BASE_DIR/runner.log"
PROJECTS_DIR="${CODEGRAPH_AUTOINIT_PROJECTS_DIR:-$HOME/Project}"
TEMPLATE_DIR="${CODEGRAPH_AUTOINIT_TEMPLATE_DIR:-$HOME/.git-template-codegraph}"
FIND_MAX_DEPTH="${CODEGRAPH_AUTOINIT_FIND_MAX_DEPTH:-5}"
# Optional scope guard. Set CODEGRAPH_AUTOINIT_REPOS to a space-separated list of
# repo roots to restrict every action entrypoint to those repos and their
# worktrees (matched by shared git-common-dir); anything else becomes a no-op.
# Useful when relying on the global git template hook but wanting only a subset
# of repos handled. Empty (default) = act wherever a hook is installed — you
# scope by where you install hooks, not by this list.
ALLOWED_REPOS="${CODEGRAPH_AUTOINIT_REPOS:-}"
HOOK_MARKER_BEGIN="# >>> codegraph-autoinit >>>"
HOOK_MARKER_END="# <<< codegraph-autoinit <<<"
ACTIVE_LOCK=""

mkdir -p "$LOG_DIR" "$QUEUE_DIR" 2>/dev/null || exit 0

cleanup_lock() {
  [ -n "${ACTIVE_LOCK:-}" ] && rm -rf "$ACTIVE_LOCK" 2>/dev/null || true
}
trap cleanup_lock EXIT HUP INT TERM

log_msg() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$*" >> "$RUN_LOG" 2>/dev/null || true
}

hash_key() {
  # shasum on macOS, sha1sum on most Linux. Either yields a stable per-path key.
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | LC_ALL=C LANG=C shasum | awk '{print $1}'
  else
    printf '%s' "$1" | LC_ALL=C LANG=C sha1sum | awk '{print $1}'
  fi
}

canonical_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  (cd "$dir" 2>/dev/null && pwd -P)
}

repo_root_for() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

git_common_dir_for() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

git_head_for() {
  git -C "$1" rev-parse HEAD 2>/dev/null
}

repo_is_clean_for_seed() {
  # Ignore untracked files when judging a seed candidate: agent/Superset/Claude
  # worktrees routinely carry temporary untracked files, and being stricter would
  # leave almost no eligible seed. The copied DB is always followed by sync +
  # status_fresh validation, so tracked-file cleanliness is the signal that
  # matters here; final correctness comes from that validation, not from this.
  [ -z "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" ]
}

repo_root_canonical() {
  local root
  root="$(repo_root_for "$1")" || return 1
  canonical_dir "$root"
}

repo_in_scope() {
  local root="$1" common p c
  [ -n "$ALLOWED_REPOS" ] || return 0
  common="$(git_common_dir_for "$root" 2>/dev/null)" || return 1
  common="$(canonical_dir "$common" 2>/dev/null)" || return 1
  for p in $ALLOWED_REPOS; do
    c="$(git_common_dir_for "$p" 2>/dev/null)" || continue
    c="$(canonical_dir "$c" 2>/dev/null)" || continue
    [ "$common" = "$c" ] && return 0
  done
  return 1
}

# Returns true only when a codegraph DB file exists.
# This does NOT mean the index is fresh or valid for the current worktree —
# use status_fresh() for that. indexed() only distinguishes init vs sync.
indexed() {
  [ -s "$1/.codegraph/codegraph.db" ]
}

worktree_relative_prefixes_inside() {
  local dir="$1"
  local root_real wt wt_real

  root_real="$(canonical_dir "$dir")" || return 1
  wt=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        wt="${line#worktree }"
        wt_real="$(canonical_dir "$wt" 2>/dev/null || true)"
        case "$wt_real" in
          "$root_real"/*) printf '%s\n' "${wt_real#$root_real/}" ;;
        esac
        ;;
    esac
  done < <(git -C "$dir" worktree list --porcelain 2>/dev/null)
}

sqlite_count_path_prefix() {
  local db="$1"
  local prefix="$2"
  local escaped

  [ -n "$prefix" ] || return 1
  escaped="${prefix//\'/\'\'}"
  sqlite3 "$db" "
    select count(*)
    from files
    where path = '$escaped'
       or path like '$escaped/%';
  " 2>/dev/null
}

index_shape_safe() {
  local dir="$1"
  local db nested_count prefix

  indexed "$dir" || return 1
  db="$dir/.codegraph/codegraph.db"

  nested_count="$(sqlite3 "$db" "
    select count(*)
    from files
    where path = '.worktrees'
       or path like '.worktrees/%'
       or path = '.claude/worktrees'
       or path like '.claude/worktrees/%'
       or path = '.superset/worktrees'
       or path like '.superset/worktrees/%';
  " 2>/dev/null)" || return 1

  [ "${nested_count:-1}" = "0" ] || return 1

  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    nested_count="$(sqlite_count_path_prefix "$db" "$prefix")" || return 1
    [ "${nested_count:-1}" = "0" ] || return 1
  done < <(worktree_relative_prefixes_inside "$dir")
}

status_fresh() {
  local status
  indexed "$1" || return 1
  status="$(codegraph status --json "$1" 2>/dev/null)" || return 1
  printf '%s' "$status" | jq -e '
    .initialized == true
    and (.worktreeMismatch == null)
    and ((.pendingChanges.added // 0) == 0)
    and ((.pendingChanges.modified // 0) == 0)
    and ((.pendingChanges.removed // 0) == 0)
  ' >/dev/null 2>&1
}

acquire_lock() {
  local lock="$1"
  local pid

  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
    ACTIVE_LOCK="$lock"
    return 0
  fi

  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  rm -rf "$lock" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
    ACTIVE_LOCK="$lock"
    return 0
  fi

  return 1
}

release_lock() {
  cleanup_lock
  ACTIVE_LOCK=""
}

sync_index() {
  local root="$1"
  local log="$LOG_DIR/$(hash_key "$root").log"

  log_msg "sync start path=$root"
  nice -n 10 codegraph sync --quiet "$root" >> "$log" 2>&1 || return 1
  status_fresh "$root"
}

init_index() {
  local root="$1"
  local log="$LOG_DIR/$(hash_key "$root").log"

  log_msg "init start path=$root"
  # Run from inside the repo so we don't depend on the CLI's path-arg handling.
  # -i is a deprecated no-op on current codegraph (init indexes by default) but
  # kept explicit for intent and older versions. status_fresh is the real gate
  # that confirms a real, current index was produced — not just an empty DB.
  (
    cd "$root" || exit 1
    nice -n 10 codegraph init -i
  ) >> "$log" 2>&1 || return 1
  status_fresh "$root"
}

seed_candidate_ready() {
  local seed="$1"
  local target_common="$2"
  local target_head="${3:-}"

  [ -n "$seed" ] || return 1
  [ "$(git_common_dir_for "$seed" 2>/dev/null || true)" = "$target_common" ] || return 1
  if [ -n "$target_head" ]; then
    [ "$(git_head_for "$seed" 2>/dev/null || true)" = "$target_head" ] || return 1
  fi
  repo_is_clean_for_seed "$seed" || return 1
  indexed "$seed" || return 1
  status_fresh "$seed" || sync_index "$seed" || return 1
  index_shape_safe "$seed" || return 1
}

find_seed_for() {
  local root="$1"
  local target_common target_head wt head seed

  target_common="$(git_common_dir_for "$root")" || return 1
  target_head="$(git_head_for "$root")" || return 1

  wt=""
  head=""
  seed=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wt="${line#worktree }"; head="" ;;
      HEAD\ *) head="${line#HEAD }" ;;
      "")
        if [ -n "$wt" ] &&
          [ "$wt" != "$root" ] &&
          [ "$head" = "$target_head" ] &&
          seed_candidate_ready "$wt" "$target_common" "$target_head"; then
          seed="$wt"
          break
        fi
        wt=""
        head=""
        ;;
    esac
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)

  if [ -z "$seed" ] &&
    [ -n "$wt" ] &&
    [ "$wt" != "$root" ] &&
    [ "$head" = "$target_head" ] &&
    seed_candidate_ready "$wt" "$target_common" "$target_head"; then
    seed="$wt"
  fi

  if [ -z "$seed" ]; then
    wt=""
    while IFS= read -r line; do
      case "$line" in
        worktree\ *) wt="${line#worktree }" ;;
        "")
          if [ -n "$wt" ] &&
            [ "$wt" != "$root" ] &&
            seed_candidate_ready "$wt" "$target_common"; then
            seed="$wt"
            break
          fi
          wt=""
          ;;
      esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null)

    if [ -z "$seed" ] &&
      [ -n "$wt" ] &&
      [ "$wt" != "$root" ] &&
      seed_candidate_ready "$wt" "$target_common"; then
      seed="$wt"
    fi
  fi

  [ -n "$seed" ] || return 1
  printf '%s\n' "$seed"
}

sqlite_snapshot() {
  local source_db="$1"
  local target_db="$2"
  local escaped_target

  escaped_target="${target_db//\'/\'\'}"
  sqlite3 "$source_db" "VACUUM INTO '$escaped_target';" >/dev/null 2>&1 ||
    sqlite3 "$source_db" ".backup '$escaped_target'" >/dev/null 2>&1
}

seed_then_sync() {
  local root="$1"
  local seed="$2"
  local tmp="$root/.codegraph.seed.$$"

  rm -rf "$tmp" 2>/dev/null || true
  mkdir -p "$tmp" 2>/dev/null || return 1

  log_msg "seed start target=$root source=$seed"
  if ! sqlite_snapshot "$seed/.codegraph/codegraph.db" "$tmp/codegraph.db"; then
    rm -rf "$tmp" 2>/dev/null || true
    return 1
  fi

  if [ -f "$seed/.codegraph/.gitignore" ]; then
    cp "$seed/.codegraph/.gitignore" "$tmp/.gitignore" 2>/dev/null || true
  else
    printf '%s\n' '*' > "$tmp/.gitignore" 2>/dev/null || true
  fi

  rm -rf "$root/.codegraph" 2>/dev/null || true
  mv "$tmp" "$root/.codegraph" 2>/dev/null || {
    rm -rf "$tmp" 2>/dev/null || true
    return 1
  }

  if sync_index "$root"; then
    log_msg "seed ok target=$root source=$seed"
    return 0
  fi

  rm -rf "$root/.codegraph" 2>/dev/null || true
  log_msg "seed validation failed target=$root source=$seed"
  return 1
}

init_one() {
  local root seed lock

  command -v codegraph >/dev/null 2>&1 || exit 0
  root="$(repo_root_canonical "$1")" || exit 0
  repo_in_scope "$root" || exit 0
  indexed "$root" && exit 0

  lock="$BASE_DIR/$(hash_key "$root").lock"
  acquire_lock "$lock" || exit 0
  indexed "$root" && exit 0

  if seed="$(find_seed_for "$root" 2>/dev/null)" && seed_then_sync "$root" "$seed"; then
    exit 0
  fi

  init_index "$root" || true
}

sync_one() {
  local root lock

  command -v codegraph >/dev/null 2>&1 || exit 0
  root="$(repo_root_canonical "$1")" || exit 0
  repo_in_scope "$root" || exit 0

  if ! indexed "$root"; then
    "$SELF" init-one "$root"
    exit 0
  fi

  lock="$BASE_DIR/$(hash_key "$root").lock"
  acquire_lock "$lock" || exit 0
  sync_index "$root" || true
}

enqueue() {
  local action="$1"
  local root="$2"
  local queue_file

  queue_file="$QUEUE_DIR/$(hash_key "$action:$root").task"
  printf '%s\t%s\n' "$action" "$root" > "$queue_file" 2>/dev/null || return 0
  log_msg "queued action=$action path=$root"
  nohup "$SELF" worker >/dev/null 2>&1 &
}

ensure_current() {
  local root

  command -v codegraph >/dev/null 2>&1 || exit 0
  root="$(repo_root_canonical "${1:-$PWD}")" || exit 0
  repo_in_scope "$root" || exit 0
  # Trust codegraph's own freshness check, not mere DB existence: a stale,
  # branch-mismatched, or seed-but-unsynced DB must not be mistaken for ready.
  status_fresh "$root" && exit 0
  if indexed "$root"; then
    enqueue sync "$root"
  else
    enqueue init "$root"
  fi
}

hook_git_update() {
  local hook_name="${1:-}"
  local checkout_flag="${4:-}"

  case "$hook_name" in
    post-checkout)
      if [ -n "$checkout_flag" ] && [ "$checkout_flag" != "1" ]; then
        exit 0
      fi
      ensure_current "$PWD"
      ;;
    post-merge|post-rewrite)
      ensure_current "$PWD"
      ;;
    *)
      ensure_current "$PWD"
      ;;
  esac
}

worker() {
  local lock item line action root processed

  lock="$BASE_DIR/worker.lock"
  acquire_lock "$lock" || exit 0

  processed=0
  while item="$(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.task' -print 2>/dev/null | sort | head -1)" && [ -n "$item" ]; do
    line="$(cat "$item" 2>/dev/null || true)"
    rm -f "$item" 2>/dev/null || true
    case "$line" in
      sync$'\t'*|init$'\t'*)
        action="${line%%	*}"
        root="${line#*	}"
        ;;
      *)
        action="init"
        root="$line"
        ;;
    esac
    [ -n "$root" ] || continue
    case "$action" in
      sync) "$SELF" sync-one "$root" ;;
      *) "$SELF" init-one "$root" ;;
    esac
    processed=$((processed + 1))
  done
  log_msg "worker done processed=$processed"
}

hooks_dir_for_repo() {
  local root common hooks_path

  root="$(repo_root_canonical "$1")" || return 1
  hooks_path="$(git -C "$root" config --path --get core.hooksPath 2>/dev/null || true)"
  if [ -n "$hooks_path" ]; then
    case "$hooks_path" in
      /*) printf '%s\n' "$hooks_path" ;;
      *) printf '%s\n' "$root/$hooks_path" ;;
    esac
    return 0
  fi

  common="$(git_common_dir_for "$root")" || return 1
  printf '%s\n' "$common/hooks"
}

write_managed_hook() {
  local hook_file="$1"
  local hook_name="$2"
  local base block

  block="$(cat <<EOF
$HOOK_MARKER_BEGIN
  "$SELF" hook-git-update "$hook_name" "\$@" >/dev/null 2>&1 || true
$HOOK_MARKER_END
EOF
)"

  if [ -f "$hook_file" ]; then
    base="$(strip_autoinit_hook_block < "$hook_file" 2>/dev/null || true)"
  else
    base=""
  fi

  if printf '%s\n' "$base" | hook_effectively_empty; then
    cat > "$hook_file" <<EOF
#!/bin/sh
$block
EOF
  else
    cat > "$hook_file" <<EOF
$base

$block
EOF
  fi
  chmod +x "$hook_file" 2>/dev/null || true
}

strip_autoinit_hook_block() {
  awk -v begin="$HOOK_MARKER_BEGIN" -v end="$HOOK_MARKER_END" '
    $0 == begin { in_block = 1; next }
    $0 == end && in_block { in_block = 0; next }
    in_block { next }
    /codegraph-autoinit managed hook/ { legacy = 1; next }
    legacy {
      legacy = 0
      if ($0 ~ /codegraph-autoinit.*hook-git-update/) next
    }
    { print }
  '
}

hook_effectively_empty() {
  awk '
    {
      line = $0
      sub(/^[ \t\r]+/, "", line)
      sub(/[ \t\r]+$/, "", line)
      if (line != "" && line !~ /^#!/) nonempty = 1
    }
    END { exit nonempty ? 1 : 0 }
  '
}

install_repo_hook() {
  local hooks_dir hook_name hook_file

  hooks_dir="$(hooks_dir_for_repo "${1:-$PWD}")" || return 1
  mkdir -p "$hooks_dir" 2>/dev/null || return 1

  for hook_name in post-checkout post-merge post-rewrite; do
    hook_file="$hooks_dir/$hook_name"
    write_managed_hook "$hook_file" "$hook_name"
    log_msg "installed hook=$hook_file"
  done
}

install_project_hooks() {
  local base="${1:-$PROJECTS_DIR}"
  local git_dir repo

  [ -d "$base" ] || return 0
  find "$base" -maxdepth "$FIND_MAX_DEPTH" \( -type d -name .git -o -type f -name .git \) -print 2>/dev/null |
    while IFS= read -r git_dir; do
      repo="${git_dir%/.git}"
      install_repo_hook "$repo" || true
    done
}

install_template_hook() {
  local hook_dir="$TEMPLATE_DIR/hooks"
  local current_template
  local hook_name

  mkdir -p "$hook_dir" 2>/dev/null || return 1
  for hook_name in post-checkout post-merge post-rewrite; do
    write_managed_hook "$hook_dir/$hook_name" "$hook_name"
  done

  current_template="$(git config --global --get init.templateDir 2>/dev/null || true)"
  if [ -z "$current_template" ]; then
    git config --global init.templateDir "$TEMPLATE_DIR" >/dev/null 2>&1 || return 1
  elif [ "$current_template" != "$TEMPLATE_DIR" ]; then
    log_msg "template hook written but global init.templateDir already set to $current_template"
  fi
}

uninstall_repo_hook() {
  local hooks_dir hook_name hook_file stripped

  hooks_dir="$(hooks_dir_for_repo "${1:-$PWD}")" || return 0
  [ -d "$hooks_dir" ] || return 0

  for hook_name in post-checkout post-merge post-rewrite; do
    hook_file="$hooks_dir/$hook_name"
    [ -f "$hook_file" ] || continue
    grep -q "codegraph-autoinit" "$hook_file" 2>/dev/null || continue
    stripped="$(strip_autoinit_hook_block < "$hook_file" 2>/dev/null || true)"
    if printf '%s\n' "$stripped" | hook_effectively_empty; then
      rm -f "$hook_file" 2>/dev/null || true
      log_msg "uninstalled hook=$hook_file (removed)"
    else
      printf '%s\n' "$stripped" > "$hook_file" 2>/dev/null || true
      chmod +x "$hook_file" 2>/dev/null || true
      log_msg "uninstalled hook=$hook_file (stripped)"
    fi
  done
}

uninstall_project_hooks() {
  local base="${1:-$PROJECTS_DIR}"
  local git_dir repo

  [ -d "$base" ] || return 0
  find "$base" -maxdepth "$FIND_MAX_DEPTH" \( -type d -name .git -o -type f -name .git \) -print 2>/dev/null |
    while IFS= read -r git_dir; do
      repo="${git_dir%/.git}"
      uninstall_repo_hook "$repo" || true
    done
}

uninstall_template_hook() {
  local hook_dir="$TEMPLATE_DIR/hooks"
  local hook_name current_template

  for hook_name in post-checkout post-merge post-rewrite; do
    rm -f "$hook_dir/$hook_name" 2>/dev/null || true
  done
  rmdir "$hook_dir" "$TEMPLATE_DIR" 2>/dev/null || true

  current_template="$(git config --global --get init.templateDir 2>/dev/null || true)"
  if [ "$current_template" = "$TEMPLATE_DIR" ]; then
    git config --global --unset init.templateDir 2>/dev/null || true
    log_msg "unset global init.templateDir ($TEMPLATE_DIR)"
  fi
}

status_report() {
  local root

  root="$(repo_root_canonical "${1:-$PWD}")" || exit 1
  codegraph status --json "$root" 2>/dev/null || {
    printf '{"initialized":false,"projectPath":"%s"}\n' "$root"
  }
}

usage() {
  cat <<EOF
Usage: codegraph-autoinit <command> [args]

Commands:
  ensure [PATH]              Queue seed/init only when .codegraph is missing.
  hook-git-update HOOK ...   Git hook entrypoint.
  worker                     Process queued jobs.
  init-one PATH              Seed/init PATH immediately in this process.
  sync-one PATH              Sync PATH immediately in this process.
  install-repo-hook [PATH]   Install managed git hooks for ONE repo (default).
  status [PATH]              Print CodeGraph status JSON.

Advanced (wide blast radius — NOT part of normal install; use with care):
  install-project-hooks DIR  Install hooks for ALL repos under DIR (default:
                             ~/Project). Affects repos beyond the scope guard's
                             intent on disk.
  install-template-hook      Install a GLOBAL git init.templateDir hook so every
                             future 'git init'/'git clone' gets it. Easy to
                             forget; hard to debug later.

Uninstall (reverse of the above; safe/idempotent, indexes left intact):
  uninstall-repo-hook [PATH]   Remove managed git hooks from ONE repo.
  uninstall-project-hooks DIR  Remove managed hooks from ALL repos under DIR.
  uninstall-template-hook      Remove the global template hooks + unset the
                               global init.templateDir (if it points at ours).

Notes:
  - All hooks (post-checkout/merge/rewrite) skip when the index is already fresh
    (status_fresh), otherwise sync a stale index or init a missing one.
  - Optional scope guard: set CODEGRAPH_AUTOINIT_REPOS (space-separated repo
    roots) to restrict every action to those repos; empty = act wherever a hook
    is installed. install.sh installs into one repo (no global blast radius).
EOF
}

case "${1:-ensure}" in
  ensure)
    shift || true
    ensure_current "${1:-$PWD}"
    ;;
  hook-git-update|hook-post-checkout)
    shift || true
    hook_git_update "$@"
    ;;
  worker)
    worker
    ;;
  init-one)
    [ -n "${2:-}" ] || exit 0
    init_one "$2"
    ;;
  sync-one)
    [ -n "${2:-}" ] || exit 0
    sync_one "$2"
    ;;
  install-repo-hook)
    install_repo_hook "${2:-$PWD}"
    ;;
  install-project-hooks)
    install_project_hooks "${2:-$PROJECTS_DIR}"
    ;;
  install-template-hook)
    install_template_hook
    ;;
  uninstall-repo-hook)
    uninstall_repo_hook "${2:-$PWD}"
    ;;
  uninstall-project-hooks)
    uninstall_project_hooks "${2:-$PROJECTS_DIR}"
    ;;
  uninstall-template-hook)
    uninstall_template_hook
    ;;
  status)
    status_report "${2:-$PWD}"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
