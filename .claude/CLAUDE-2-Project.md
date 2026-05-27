# AgentCli

AgentCli is the standalone home of the Claude launcher (`c.ps1`) and its
shared support files (`scripts/Common.ps1`, `claude.Dockerfile`, the shared
`.claude/CLAUDE-1-Common.md` and `.claude/CLAUDE-3-Launcher.md` parts).

Historically, `c.ps1` has been duplicated into every project that wanted to
launch Claude. The goal of this repo is to make that copy unnecessary:
once AgentCli is ready, `c.ps1` will be removed from individual project
repos and invoked from AgentCli instead. It should work from any current
directory and operate on whatever folder it was started in — the launched
Claude session targets the caller's working directory, not AgentCli's.

## Status

Active development. Treat this repo as the upstream source of truth for
all launcher-related files; other projects will eventually consume them
from here rather than carry their own copies.

## Scope of this project

In scope:
- `c.ps1` and its PowerShell helpers (`scripts/`)
- `claude.Dockerfile` and the Docker-based launch path
- WSL and direct-on-host launch paths
- Worktree detection (`AC_Worktree`, `c wt …`)
- Environment-variable contract documented in `CLAUDE-3-Launcher.md`
  (`AC_OS`, `AC_ProjectRoot`, `AC_ProjectPath`, …)
- The shared `.claude/CLAUDE-1-Common.md` and `.claude/CLAUDE-3-Launcher.md`
  parts that get copied into consumer projects

Out of scope:
- Per-project `.claude/CLAUDE-2-Project.md` content — each consumer owns
  its own project part. Never copy this file across projects.
- Project-specific build/test/deploy logic — AgentCli is launcher
  infrastructure, not a build system.
