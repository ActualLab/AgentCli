# AgentCli

AgentCli is the **single** home of the multi-CLI launcher (`c.ps1`), its
PowerShell helpers (`scripts/Common.ps1`), the shared `claude.Dockerfile`,
the shared `AGENTS-Suffix.md`, and the shared `.claude/commands/` +
`.claude/skills/` folders. Nothing AgentCli-related lives in any other
repo — the only per-project file is `AGENTS-Source.md`, which holds the
project's local content and is appended in front of AgentCli's suffix
when `c update-md` regenerates `AGENTS.md` / `CLAUDE.md`.

`c.ps1` works from any current directory and operates on whatever folder
it was started in — the launched CLI session targets the caller's working
directory, not AgentCli's. The Docker image (`claude-agentcli`) bundles
Claude Code, OpenAI Codex, and xAI Grok side by side; `c.ps1` picks which
one to run via its first positional arg (`c claude` / `c codex` / `c grok`,
default `claude`).

## Status

Active development. Treat this repo as the upstream source of truth for
all launcher-related files; consumer projects never carry a copy.

## Scope of this project

In scope:
- `c.ps1` and its PowerShell helpers (`scripts/`)
- `claude.Dockerfile` — the **single shared** Docker image used by every
  project (Claude + Codex + Grok CLIs all pre-installed)
- WSL and direct-on-host launch paths
- Worktree detection (`AC_Worktree`, `c wt …`)
- Out-of-tree launch support (sanitized `/proj/<path>` mount + extra
  mount inside Docker; OS/WSL just use the real path)
- Environment-variable contract documented in the launcher section of
  `AGENTS-Suffix.md` (`AC_OS`, `AC_ProjectRoot`, `AC_ProjectPath`, …)
- The shared `AGENTS-Suffix.md` that gets appended to every consumer
  project's generated docs
- The shared `.claude/commands/` and `.claude/skills/` folders, linked
  into `~/.claude/{commands,skills}/agent-cli/` on the host (junction
  on Windows, symlink elsewhere) and bind-mounted to the same path
  inside Docker. Anything you drop here becomes a globally-available
  AgentCli slash command or skill.

Out of scope:
- Per-project `AGENTS-Source.md` content — each consumer project owns its
  own. AgentCli's own `AGENTS-Source.md` (this file) describes AgentCli
  itself, not the launcher contract.
- Project-specific build/test/deploy logic — AgentCli is launcher
  infrastructure, not a build system.
