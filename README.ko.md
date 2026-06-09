# codegraph-autoinit

CodeGraph 인덱스를 Git hook으로 자동 준비하는 로컬 도구입니다.

## 목적

CodeGraph 인덱스는 각 worktree의 `.codegraph/` 디렉토리에 저장됩니다. 이 디렉토리는 gitignore 대상이라서 새 worktree를 만들면 보통 인덱스가 없습니다.

Git에는 `worktree 생성 전용 hook`은 없지만, `git worktree add`는 새 worktree 안에서 `post-checkout` hook을 실행합니다. 브랜치 전환(`git switch`, `git checkout`)도 같은 hook을 실행합니다. 이 도구는 branch/worktree checkout만 처리하고, 파일 단위 checkout은 무시합니다.

## 동작 방식

- checkout/switch/worktree add에서는 `.codegraph`가 있으면 `codegraph sync`를 background로 예약합니다.
- `.codegraph`가 없으면 같은 git repo의 다른 clean worktree에서 seed를 찾습니다.
- seed가 있으면 SQLite snapshot으로 복사한 뒤 target에서 `codegraph sync`로 검증합니다.
- seed가 없으면 background에서 `codegraph init`을 실행합니다.
- worker lock으로 작업을 직렬화해서 여러 터미널이 동시에 무거운 CodeGraph 작업을 돌리지 않게 합니다.
- seed가 이미 fresh이면 다시 sync하지 않습니다. fresh하지 않을 때만 seed 쪽 `codegraph sync`를 먼저 실행합니다.

## 설치

```bash
~/.codegraph-autoinit/bin/install.sh
```

기본으로 `~/Project` 아래 기존 repo에 hook을 설치하고, 새로 clone/init 되는 repo를 위해 `~/.git-template-codegraph`도 설정합니다.

다른 프로젝트 디렉토리를 스캔하려면:

```bash
~/.codegraph-autoinit/bin/install.sh /path/to/projects
```

## 설치되는 Git Hook

- `post-checkout`: 브랜치 전환, checkout, `git worktree add`. 있으면 sync, 없으면 생성.
- `post-merge`: pull/merge 이후, 단 `.codegraph`가 없을 때만 생성
- `post-rewrite`: rebase/amend 이후, 단 `.codegraph`가 없을 때만 생성

pull/merge/rebase에서 이미 `.codegraph`가 있으면 hook은 sync를 하지 않습니다. 이 경우 CodeGraph MCP의 watcher와 connect-time catch-up에 맡깁니다.

## 명령어

```bash
~/.codegraph-autoinit/bin/codegraph-autoinit.sh ensure [PATH]
~/.codegraph-autoinit/bin/codegraph-autoinit.sh status [PATH]
~/.codegraph-autoinit/bin/codegraph-autoinit.sh install-repo-hook [PATH]
~/.codegraph-autoinit/bin/codegraph-autoinit.sh install-project-hooks ~/Project
~/.codegraph-autoinit/bin/codegraph-autoinit.sh install-template-hook
```

## 로그

```bash
tail -f ~/.cache/codegraph-autoinit/runner.log
ls ~/.cache/codegraph-autoinit/logs
```

## Seed 무결성 조건

seed는 다음 조건을 통과해야만 사용됩니다.

- target과 같은 git common-dir에 속함
- seed worktree가 clean 상태임(untracked file은 무시)
- seed CodeGraph status가 fresh임
- seed index 안에 `.worktrees/`, `.claude/worktrees/`, `.superset/worktrees/` 같은 nested worktree가 섞여 있지 않음
- `git worktree list --porcelain`에 잡히는 다른 worktree가 seed 내부 경로에 있으면, 그 상대 경로가 seed index에 섞여 있지 않음
- target에서 `codegraph sync` 후 pending changes와 worktree mismatch가 없음

## 주의

기존 hook은 덮어쓰지 않고 marker block만 append/replace합니다. 삭제가 필요하면 hook 파일에서 `# >>> codegraph-autoinit >>>` 부터 `# <<< codegraph-autoinit <<<` 까지만 지우면 됩니다.

`install-project-hooks`의 기본 검색 깊이는 5입니다. 더 깊은 디렉토리를 스캔하려면 다음처럼 실행합니다.

```bash
CODEGRAPH_AUTOINIT_FIND_MAX_DEPTH=8 ~/.codegraph-autoinit/bin/install.sh ~/Project
```

## CodeGraph upstream과의 관계

CodeGraph 자체에는 watcher와 MCP 시작 시 catch-up sync가 있습니다. 그래서 이미 `.codegraph`가 있는 repo에서는 pull/merge/rebase 후 이 도구가 강제로 sync하지 않고 CodeGraph에게 맡깁니다.

이 도구가 보완하는 부분은 `.codegraph`가 없는 새 worktree/checkout의 bootstrap입니다. upstream에도 git worktree별 init 마찰과 global template auto-init 제안이 논의되어 있지만, 현재 mainline은 worktree-local index를 직접 만들어야 하는 방향입니다.
