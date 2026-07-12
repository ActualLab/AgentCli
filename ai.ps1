#!/usr/bin/env pwsh
# AgentCli launcher script - runs Claude / Codex / Grok / Goose / OpenCode in Docker, WSL, or native OS

# Auto-detect AC_ProjectRoot from the folder containing this script
# e.g., if ai.ps1 is at D:\Projects\ActualChat\ai.ps1, AC_ProjectRoot = D:\Projects
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $env:AC_ProjectRoot) {
    $env:AC_ProjectRoot = Split-Path -Parent $scriptDir
}

# Load common utilities
. (Join-Path $scriptDir "scripts/Common.ps1")

# Convert Windows path to WSL path
function ConvertTo-WSLPath {
    param([string]$WindowsPath)
    if ($WindowsPath -match "^([A-Za-z]):(.*)$") {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2] -replace "\\", "/"
        return "/mnt/$drive$rest"
    }
    return $WindowsPath
}

# Convert Windows path to Docker path (for volume mounts)
function ConvertTo-DockerPath {
    param([string]$WindowsPath)
    # Docker on Windows can use Windows paths directly with forward slashes
    return $WindowsPath -replace "\\", "/"
}

# Returns true if $Path is the same as $Root or sits underneath it.
# Case-insensitive (Windows) and tolerant of trailing slashes.
function Test-IsUnderRoot {
    param([Parameter(Mandatory)][string]$Path, [string]$Root)
    if (-not $Root) { return $false }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($pathFull -eq $rootFull) { return $true }
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    return $pathFull.StartsWith("$rootFull\", $cmp) -or $pathFull.StartsWith("$rootFull/", $cmp)
}

# Collapse an absolute host path into a single-segment folder name that can be
# used as a /proj/<name> mount target inside Docker. Drive-letter colons and
# path separators all become single underscores.
#   C:\Users\Alex\foo  ->  C_Users_Alex_foo
#   /home/user/proj    ->  home_user_proj
function ConvertTo-SanitizedProjectName {
    param([Parameter(Mandatory)][string]$Path)
    $name = $Path -replace '[\\/:]+', '_'
    $name = $name -replace '_+', '_'
    return $name.Trim('_')
}

# Returns the host directory that DIRECTLY contains goose's config.yaml, or $null
# if it doesn't exist. Layout differs by OS:
#   Windows: %APPDATA%\Block\goose\config
#   macOS/Linux: ~/.config/goose  (XDG)
# The WSL/Docker handlers pass this into the Linux goose, which always reads
# ~/.config/goose/config.yaml — so the folder maps 1:1 regardless of host layout.
function Get-GooseConfigDir {
    $dir = switch (Get-CurrentOS) {
        "Windows" { Join-Path $env:APPDATA "Block/goose/config" }
        default   { Join-Path $env:HOME ".config/goose" }
    }
    if (Test-Path (Join-Path $dir "config.yaml")) { return $dir }
    return $null
}

# Returns the host directory that DIRECTLY contains opencode's config
# (opencode.jsonc / opencode.json), or $null if none exists. opencode uses
# ~/.config/opencode on every OS (XDG-style, incl. Windows), so the folder maps
# 1:1 onto ~/.config/opencode inside WSL/Docker.
function Get-OpenCodeConfigDir {
    $ocHome = if ((Get-CurrentOS) -eq "Windows") { $env:USERPROFILE } else { $env:HOME }
    $dir = Join-Path $ocHome ".config/opencode"
    if ((Test-Path (Join-Path $dir "opencode.jsonc")) -or (Test-Path (Join-Path $dir "opencode.json"))) { return $dir }
    return $null
}

# Boot-session marker — a tiny file stamped with the current OS boot time.
# Used by the compose auto-start to avoid running `docker compose up -d`
# more than once per OS reboot (it's a no-op when nothing changed, but still
# costs ~1s of overhead per launch).
$script:ComposeMarkerPath = Join-Path ([System.IO.Path]::GetTempPath()) "agentcli-compose-started.txt"

function Get-OsBootStamp {
    $os = Get-CurrentOS
    try {
        switch ($os) {
            "Windows" {
                $bt = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
                return $bt.ToUniversalTime().ToString("o")
            }
            "macOS" {
                $raw = & sysctl -n kern.boottime 2>$null
                if ($raw -match 'sec\s*=\s*(\d+)') { return "macos-$($Matches[1])" }
            }
            default {
                # Linux / Docker / WSL: btime line in /proc/stat is the boot epoch.
                $line = Select-String -Path /proc/stat -Pattern '^btime\s+(\d+)$' -ErrorAction Stop | Select-Object -First 1
                if ($line) { return "linux-$($line.Matches[0].Groups[1].Value)" }
            }
        }
    } catch {}
    return $null
}

function Test-ComposeStartedThisBoot {
    if (-not (Test-Path $script:ComposeMarkerPath)) { return $false }
    $stored  = (Get-Content $script:ComposeMarkerPath -Raw -ErrorAction SilentlyContinue).Trim()
    $current = Get-OsBootStamp
    return ($stored -and $current -and $stored -eq $current)
}

function Set-ComposeStartedThisBoot {
    $current = Get-OsBootStamp
    if ($current) {
        Set-Content -Path $script:ComposeMarkerPath -Value $current -NoNewline
    }
}

# Starts the AgentCli docker-compose stack. Idempotent (`up -d` is a no-op when
# everything is already running). Writes the boot-session marker on success.
function Invoke-ComposeStart {
    $composeFile = Join-Path $scriptDir "docker-compose.yml"
    if (-not (Test-Path $composeFile)) {
        Write-Host "No docker-compose.yml at $composeFile — skipping compose-start." -ForegroundColor DarkGray
        return
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "docker not found in PATH — skipping compose-start." -ForegroundColor Yellow
        return
    }

    Write-Host "Starting AgentCli docker-compose stack..." -ForegroundColor Cyan
    & docker compose -f $composeFile up -d
    if ($LASTEXITCODE -eq 0) {
        Set-ComposeStartedThisBoot
        Write-Host "Compose stack ready." -ForegroundColor Green
    } else {
        Write-Host "docker compose up exited with code $LASTEXITCODE — leaving boot marker unset so it retries next launch." -ForegroundColor Yellow
    }
}

# Check if Windows Terminal is available
function Test-WindowsTerminal {
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        return [bool](Get-Command "wt.exe" -ErrorAction SilentlyContinue)
    }
    return $false
}
$hasWindowsTerminal = Test-WindowsTerminal

# Chrome remote debugging port (standard) and multi-instance defaults.
# The `chrome` command supports `chrome[:PORT][*N]` (N=1..9). When `*N` is
# given, each instance gets its own anonymous profile so cookies don't bleed
# across them — useful for testing multi-user flows.
$ChromeDebugPort           = 9222     # legacy single-port default (also exported to Docker for the chrome-devtools MCP)
$ChromeDebugStartPort      = $ChromeDebugPort
$ChromeInstanceCount       = 1
$ChromeUseAnonymousProfile = $false
$ChromeArgPattern          = '^chrome(?:[:*]\d+){0,2}$'
$ChromeExtraArgs           = @()

# Edge mirrors the Chrome shape but defaults to a different start port so the
# two can run side by side without the firewall/port-collision dance.
$EdgeDebugPort             = 9322
$EdgeDebugStartPort        = $EdgeDebugPort
$EdgeInstanceCount         = 1
$EdgeUseAnonymousProfile   = $false
$EdgeArgPattern            = '^edge(?:[:*]\d+){0,2}$'
$EdgeExtraArgs             = @()

# On Windows, if not already in Windows Terminal, relaunch in wt
# WT_SESSION is set by Windows Terminal when running inside it
# Exception: chrome command runs directly without terminal relaunch
$currentOS = Get-CurrentOS
$hasChrome = ($args | Where-Object { $_ -match $ChromeArgPattern }).Count -gt 0
$hasEdge   = ($args | Where-Object { $_ -match $EdgeArgPattern   }).Count -gt 0
if ($currentOS -eq "Windows" -and $hasWindowsTerminal -and -not $env:WT_SESSION -and -not $hasChrome -and -not $hasEdge) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $workDir = (Get-Location).Path
    # Keep terminal open for build, install, compose-start, dry-run, debug, or help (only auto-close when actually running Claude)
    $hasDebug = $args -contains "--debug"
    $hasBuild = $args -contains "build"
    $hasInstall = $args -contains "install"
    $hasUninstall = $args -contains "uninstall"
    $hasComposeStart = $args -contains "compose-start"
    $hasDryRun = $args -contains "--dry-run"
    $hasHelp = $args -contains "help" -or $args -contains "-h" -or $args -contains "--help" -or $args -contains "-?"
    if ($hasDebug -or $hasBuild -or $hasInstall -or $hasUninstall -or $hasComposeStart -or $hasDryRun -or $hasHelp) {
        $wtArgs = @("-d", $workDir, "--", "pwsh", "-NoProfile", "-NoExit", "-File", $scriptPath) + $args
    } else {
        $wtArgs = @("-d", $workDir, "--", "pwsh", "-NoProfile", "-File", $scriptPath) + $args
    }
    & wt @wtArgs
    exit 0
}

# Convert worktree git paths from absolute to relative so they work across
# Windows and Docker/Linux (where mount points differ).
function Convert-WorktreeToRelativePaths {
    param(
        [string]$WorktreePath,
        [string]$MainProjectPath,
        [switch]$Debug
    )

    $worktreeName = Split-Path -Leaf $WorktreePath

    # Fix <worktree>/.git file: convert absolute gitdir to relative
    $dotGitFile = Join-Path $WorktreePath ".git"
    if (Test-Path $dotGitFile) {
        $content = Get-Content $dotGitFile -Raw
        if ($content -match '^gitdir:\s*(.+)$') {
            $currentGitDir = $Matches[1].Trim()
            # Only fix if the path is absolute (not already relative)
            if ([System.IO.Path]::IsPathRooted(($currentGitDir -replace "/", [System.IO.Path]::DirectorySeparatorChar))) {
                $relPath = [System.IO.Path]::GetRelativePath($WorktreePath, ($currentGitDir -replace "/", [System.IO.Path]::DirectorySeparatorChar))
                $relPath = $relPath -replace "\\", "/"
                $newContent = "gitdir: $relPath`n"
                Set-Content -Path $dotGitFile -Value $newContent -NoNewline
                if ($Debug) { Write-Host "[DEBUG] Fixed $dotGitFile`: gitdir: $relPath" }
            } elseif ($Debug) {
                Write-Host "[DEBUG] $dotGitFile already has relative path: $currentGitDir"
            }
        }
    }

    # Fix <main>/.git/worktrees/<name>/gitdir: convert absolute path to relative
    $mainGitDir = Join-Path $MainProjectPath ".git"
    $worktreeGitDir = Join-Path $mainGitDir "worktrees" $worktreeName "gitdir"
    if (Test-Path $worktreeGitDir) {
        $content = (Get-Content $worktreeGitDir -Raw).Trim()
        if ([System.IO.Path]::IsPathRooted(($content -replace "/", [System.IO.Path]::DirectorySeparatorChar))) {
            $worktreeGitDirParent = Split-Path -Parent $worktreeGitDir
            $relPath = [System.IO.Path]::GetRelativePath($worktreeGitDirParent, ($content -replace "/", [System.IO.Path]::DirectorySeparatorChar))
            $relPath = $relPath -replace "\\", "/"
            Set-Content -Path $worktreeGitDir -Value "$relPath`n" -NoNewline
            if ($Debug) { Write-Host "[DEBUG] Fixed $worktreeGitDir`: $relPath" }
        } elseif ($Debug) {
            Write-Host "[DEBUG] $worktreeGitDir already has relative path: $content"
        }
    }
}

# Runs $env:AC_POST_WORKTREE_HOOK (if set) to seed a fresh worktree with private, un-versioned
# config. The repo intentionally knows only that a hook may exist, never what it does.
function Invoke-PostWorktreeHook {
    param([string]$WorktreePath)

    $hookPath = $env:AC_POST_WORKTREE_HOOK
    if (-not $hookPath) { return }

    Write-Host "Running post-worktree hook: $hookPath"
    Push-Location ([System.IO.Path]::GetDirectoryName((Resolve-Path $hookPath)))
    try {
        # The hook is a polyglot .cmd: batch on Windows (run via the call operator), bash elsewhere.
        if ($currentOS -eq "Windows") {
            & $hookPath $WorktreePath
        } else {
            & bash $hookPath $WorktreePath
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: post-worktree hook exited with code $LASTEXITCODE" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Warning: post-worktree hook failed: $_" -ForegroundColor Yellow
    } finally {
        Pop-Location
    }
}

# Detects the worktree suffix (if any) for a given project root, by asking git.
# Returns @{ ProjectName; Worktree } — both strings, worktree is "" for main.
function Get-WorktreeInfo {
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$FolderName)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $result = @{ ProjectName = $FolderName; Worktree = "" }
    $gitCommonDir = & git -C $ProjectRoot rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitCommonDir) {
        $gitCommonDirNorm = $gitCommonDir -replace "/", $sep
        if ([System.IO.Path]::IsPathRooted($gitCommonDirNorm)) {
            $mainProjectPath = Split-Path -Parent ($gitCommonDirNorm.TrimEnd('\','/'))
            $mainProjectName = Split-Path -Leaf $mainProjectPath
            if ($FolderName.StartsWith("$mainProjectName-")) {
                $result.ProjectName = $mainProjectName
                $result.Worktree    = $FolderName.Substring($mainProjectName.Length + 1)
            }
        }
    }
    return $result
}

# Find the "effective project root" for the current cwd.
#
# Resolution rules:
#   1. If cwd is exactly AC_ProjectRoot itself (the "Projects" folder), there
#      is no specific project — return AtRoot=true. Docker handler uses /proj
#      as the working dir and skips per-project mounts.
#   2. If cwd is under AC_ProjectRoot, walk up to the *direct child* of
#      AC_ProjectRoot. That's the project, regardless of where nested `.git`
#      directories live. E.g. cwd=C:\Projects\ActualChat\bin → C:\Projects\ActualChat.
#   3. Otherwise (cwd is outside AC_ProjectRoot — "out of tree"), use git's
#      `--show-toplevel` if it's a repo, else fall back to cwd itself.
function Find-ProjectRoot {
    param([switch]$Debug)

    $cwd      = (Get-Location).Path
    $sep      = [System.IO.Path]::DirectorySeparatorChar
    $cmp      = [System.StringComparison]::OrdinalIgnoreCase
    $rootFull = [System.IO.Path]::GetFullPath($env:AC_ProjectRoot).TrimEnd('\','/')
    $cwdFull  = [System.IO.Path]::GetFullPath($cwd).TrimEnd('\','/')
    if ($Debug) { Write-Host "[DEBUG] Find-ProjectRoot cwd=$cwdFull, AC_ProjectRoot=$rootFull" }

    # Rule 1 — at the Projects folder itself
    if ($cwdFull -eq $rootFull) {
        if ($Debug) { Write-Host "[DEBUG] cwd is exactly AC_ProjectRoot (AtRoot)" }
        $leaf = Split-Path -Leaf $rootFull
        return @{
            ProjectName  = $leaf
            FolderName   = $leaf
            ProjectRoot  = $rootFull
            RelativePath = ""
            Worktree     = ""
            AtRoot       = $true
        }
    }

    # Rule 2 — under AC_ProjectRoot: walk up to the direct child
    $isUnder = $cwdFull.StartsWith("$rootFull$sep", $cmp) -or $cwdFull.StartsWith("$rootFull/", $cmp)
    if ($isUnder) {
        $current = $cwdFull
        while ($true) {
            $parent = Split-Path -Parent $current
            $parentFull = if ($parent) { [System.IO.Path]::GetFullPath($parent).TrimEnd('\','/') } else { $null }
            if ($parentFull -eq $rootFull) { break }
            if (-not $parent -or $parent -eq $current) { break }
            $current = $parent
        }
        $projectRoot  = $current
        $folderName   = Split-Path -Leaf $projectRoot
        $relativePath = if ($cwdFull.Length -gt $projectRoot.Length) {
            $cwdFull.Substring($projectRoot.Length) -replace "\\", "/"
        } else { "" }
        $wt = Get-WorktreeInfo -ProjectRoot $projectRoot -FolderName $folderName
        if ($Debug) { Write-Host "[DEBUG] In-tree: projectRoot=$projectRoot, folder=$folderName, project=$($wt.ProjectName), worktree=$($wt.Worktree), rel=$relativePath" }
        return @{
            ProjectName  = $wt.ProjectName
            FolderName   = $folderName
            ProjectRoot  = $projectRoot
            RelativePath = $relativePath
            Worktree     = $wt.Worktree
            AtRoot       = $false
        }
    }

    # Rule 3 — out of tree: git's project root, or cwd if no git
    if ($Debug) { Write-Host "[DEBUG] Out of tree, trying git" }
    $gitRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $gitRoot) {
        if ($Debug) { Write-Host "[DEBUG] Not a git repo — using cwd" }
        $leaf = Split-Path -Leaf $cwd
        return @{
            ProjectName  = $leaf
            FolderName   = $leaf
            ProjectRoot  = $cwd
            RelativePath = ""
            Worktree     = ""
            AtRoot       = $false
        }
    }
    $gitRootNorm = [System.IO.Path]::GetFullPath(($gitRoot -replace "/", $sep))
    $folderName  = Split-Path -Leaf $gitRootNorm
    $relativePath = if ($cwdFull.Length -gt $gitRootNorm.Length) {
        $cwdFull.Substring($gitRootNorm.Length) -replace "\\", "/"
    } else { "" }
    $wt = Get-WorktreeInfo -ProjectRoot $gitRootNorm -FolderName $folderName
    return @{
        ProjectName  = $wt.ProjectName
        FolderName   = $folderName
        ProjectRoot  = $gitRootNorm
        RelativePath = $relativePath
        Worktree     = $wt.Worktree
        AtRoot       = $false
    }
}

# Main logic
$currentOS             = Get-CurrentOS
$cli                   = "claude" # default CLI/agent (claude | codex | grok | goose | opencode)
$mode                  = "docker"  # default mode
$fromMode              = $null     # set when self-invoked (e.g., from-docker, from-wsl)
$worktreeSuffix        = $null     # set when wt argument is used
$featureWorktreeSuffix = $null     # set when fwt/bwt argument is used
$removeWorktreeSuffix  = $null     # set when rwt argument is used
$wtType                = $null     # worktree type: "feature" or "bugfix"
$newContainer          = $false
$dryRun                = $false
$debugMode             = $false
$cliSet                = $false  # true once an explicit CLI has been consumed from args
$cliArgs               = @()

# CLI/agent registry. Each supported agent maps to:
#   Command       - the executable name
#   BaseArgs      - args ALWAYS prepended (e.g. a subcommand like `goose session`)
#   SandboxedArgs - extra args added only in "yolo" mode (inside the sandboxed
#                   Docker container). On the host OS these are never added, so
#                   each CLI runs interactively with its usual approval prompts.
#   SandboxedEnv  - env vars set only in the sandboxed Docker container (some
#                   CLIs — e.g. goose — gate auto-approval via env, not a flag).
$CliConfig = @{
    "claude" = @{
        Command       = "claude"
        BaseArgs      = @()
        SandboxedArgs = @("--dangerously-skip-permissions")
        SandboxedEnv  = @{}
    }
    "codex" = @{
        Command       = "codex"
        BaseArgs      = @()
        SandboxedArgs = @("--full-auto")
        SandboxedEnv  = @{}
    }
    "grok" = @{
        Command       = "grok"
        BaseArgs      = @()
        SandboxedArgs = @()
        SandboxedEnv  = @{}
    }
    "goose" = @{
        Command       = "goose"
        BaseArgs      = @("session")                 # interactive chat session
        SandboxedArgs = @()
        SandboxedEnv  = @{
            "GOOSE_MODE"            = "auto"          # auto-approve tool calls in the sandbox
            "GOOSE_DISABLE_KEYRING" = "1"            # no OS keyring in a headless container; use the config file
        }
    }
    "opencode" = @{
        Command       = "opencode"
        BaseArgs      = @()                          # default command launches the TUI
        SandboxedArgs = @("--auto")                  # auto-approve permissions in the sandbox
        SandboxedEnv  = @{}
    }
}

# Valid agent names — accepted both as the positional selector (`ai codex`) and
# as the --agent value (`ai --agent:codex`). The ai-codex/ai-grok/ai-goose
# entry-point shortcuts (ai-codex.cmd/…) each pin one via `ai --agent=<name>`.
$ValidAgents = @("claude", "codex", "grok", "goose", "opencode")

# Show help
function Show-Help {
    Write-Host "AgentCli Launcher - Run Claude / Codex / Grok / Goose / OpenCode in Docker, WSL, or native OS" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: ai [agent] [command] [options] [cli-args]" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Agents (first positional arg or --agent:<name>, default: claude):"
    Write-Host "  claude       Anthropic Claude Code (default)"
    Write-Host "  codex        OpenAI Codex"
    Write-Host "  grok         xAI Grok"
    Write-Host "  goose        Codename Goose (block/goose)"
    Write-Host "  opencode     OpenCode (sst/opencode)"
    Write-Host ""
    Write-Host "Entry points / shortcuts:"
    Write-Host "  ai           This launcher (Claude by default; pick agent via positional arg or --agent:)"
    Write-Host "  ai-codex     Shortcut for 'ai --agent:codex'"
    Write-Host "  ai-grok      Shortcut for 'ai --agent:grok'"
    Write-Host "  ai-goose     Shortcut for 'ai --agent:goose'"
    Write-Host "  ai-opencode  Shortcut for 'ai --agent:opencode'"
    Write-Host "  --agent:<n>  Select agent (claude|codex|grok|goose|opencode)"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  (default)    Run selected CLI in Docker container"
    Write-Host "  os           Run selected CLI directly on host OS"
    Write-Host "  wsl          Run selected CLI in WSL (Windows only)"
    Write-Host "  wt <suffix>  Create/use worktree from current branch (e.g., wt experiment)"
    Write-Host "  fwt <suffix> Create/use feature worktree with feat/<suffix> branch (e.g., fwt feature1)"
    Write-Host "  bwt <suffix> Create/use bugfix worktree with bugfix/<suffix> branch (e.g., bwt issue123)"
    Write-Host "  rwt <suffix> Remove worktree and clean up (ports, hosts, nginx config)"
    Write-Host "  chrome       Start Chrome with remote debugging enabled (for Playwright)"
    Write-Host "  build        Build the shared AgentCli Docker image (claude-<agentcli folder>)"
    Write-Host "  install      Register 'ai'/'ai-codex'/'ai-grok'/'ai-goose'/'ai-opencode' globally (user PATH on Windows, shell aliases on Unix) and build Docker image"
    Write-Host "  uninstall    Reverse 'install': unregister those entry points, remove team links, remove the AgentCli Docker image"
    Write-Host "  compose-start Start the AgentCli docker-compose stack (chrome-devtools-mcp, etc.) — auto-runs once per OS boot"
    Write-Host "  update-md    Regenerate AGENTS.md/CLAUDE.md in cwd from AGENTS-Source.md (cwd) + AGENTS-Suffix.md (AgentCli)"
    Write-Host "  help         Show this help message"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --new        Force creation of a new Docker container (skip reuse)"
    Write-Host "  --dry-run    Show environment variables and command without executing"
    Write-Host "  --debug      Show debug output for troubleshooting"
    Write-Host ""
    Write-Host "Environment variables (optional):"
    Write-Host "  AC_ProjectRoot    Override auto-detected project root directory"
    Write-Host "  AC_CLAUDE_ISOLATE Set to 'true' or '1' to isolate .claude.json per container instance"
    Write-Host "  AC_POST_WORKTREE_HOOK  Script run after fwt/bwt creates a worktree; receives the worktree path"
    Write-Host ""
    Write-Host "Environment variables set for the launched CLI:"
    Write-Host "  AC_ProjectRoot      Project root path (/proj in Docker)"
    Write-Host "  AC_ProjectPath      Full path to current project (or worktree)"
    Write-Host "  AC_OS               OS/environment description"
    Write-Host "  AC_Worktree         Worktree suffix (empty if not in a worktree)"
    Write-Host ""
    Write-Host "Docker:"
    Write-Host "  AC_ProjectRoot is mounted as /proj/ — all sibling projects are accessible"
    Write-Host "  Project detection is handled by the project's own CLAUDE.md"
    Write-Host ""
    Write-Host "Worktree support:"
    Write-Host "  Worktrees are auto-detected via git (git rev-parse --git-common-dir)"
    Write-Host "  Use wt  to create a worktree from the current branch"
    Write-Host "  Use fwt to create a feature worktree with a new feat/<suffix> branch"
    Write-Host "  Use bwt to create a bugfix worktree with a new bugfix/<suffix> branch"
    Write-Host "  Base branch for fwt/bwt: 'dev' if it exists on origin, otherwise 'master'"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  ai                 Run Claude in Docker (claude is the default agent)"
    Write-Host "  ai-codex           Shortcut: Codex in Docker (= ai --agent:codex)"
    Write-Host "  ai-grok            Shortcut: Grok in Docker (= ai --agent:grok)"
    Write-Host "  ai-goose           Shortcut: Goose in Docker (= ai --agent:goose)"
    Write-Host "  ai-opencode        Shortcut: OpenCode in Docker (= ai --agent:opencode)"
    Write-Host "  ai goose           Run Goose in Docker (positional form)"
    Write-Host "  ai --agent:goose   Select Goose explicitly"
    Write-Host "  ai --dry-run       Show what Docker would run"
    Write-Host "  ai os              Run Claude on host OS (default agent)"
    Write-Host "  ai-codex os        Run Codex on host OS"
    Write-Host "  ai-goose wsl       Run Goose in WSL"
    Write-Host "  ai wsl             Run Claude in WSL"
    Write-Host "  ai wt experiment   Run in worktree from current branch"
    Write-Host "  ai fwt feature1    Run in worktree with feat/feature1 branch"
    Write-Host "  ai bwt issue123    Run in worktree with bugfix/issue123 branch"
    Write-Host "  ai rwt feature1    Remove feature1 worktree and clean up"
    Write-Host "  ai os fwt feature1 Run on host OS in feature worktree"
    Write-Host "  ai chrome          Start Chrome with remote debugging (Playwright profile, port 9222)"
    Write-Host "  ai chrome:50000    Start Chrome on port 50000 (Playwright profile)"
    Write-Host "  ai chrome*3        Start 3 Chrome instances on 9222..9224 (anonymous profiles)"
    Write-Host "  ai chrome*3:50000  Start 3 Chrome instances on 50000..50002 (anonymous profiles)"
    Write-Host "  ai chrome --profile MyDebug"
    Write-Host "                     Launch the 'MyDebug' user-data-dir plus any 'MyDebug-*' siblings, each an"
    Write-Host "                     independent browser on a sequential port (9222, 9223, ...). No *N."
    Write-Host "  ai chrome --mute-audio --window-size=1280,720"
    Write-Host "                     Any args after chrome[*N][:PORT] are forwarded to the browser"
    Write-Host "  ai chrome --fake-media"
    Write-Host "                     Use synthetic camera/mic streams (default is real devices)"
    Write-Host "  ai edge[:PORT][*N] Same as chrome, for Microsoft Edge (default port 9322)"
    Write-Host "  ai audio           Setup/start PulseAudio for voice mode (macOS only)"
    Write-Host "  ai build           Build Docker image"
    Write-Host "  ai install         Register 'ai'/'ai-codex'/'ai-grok'/'ai-goose'/'ai-opencode' globally and build the Docker image (run once after cloning AgentCli)"
    Write-Host "  ai --resume abc    Pass --resume abc to the selected agent"
    Write-Host ""
}

# Parse arguments
# All ai.ps1 commands must come first, then all remaining args go to the selected CLI
$argIndex = 0

# Parse ai.ps1 commands (agent, mode, wt, from-*, --dry-run) - must come before CLI args
while ($argIndex -lt $args.Count) {
    $currentArg = $args[$argIndex]

    # --agent:<name> selector. Accepts full agent names only (claude, codex,
    # grok, goose, opencode). This is how the ai-codex/…/ai-opencode shortcuts pin the
    # agent (`ai --agent=codex`, …). Wins over any later positional agent token
    # (which is then treated as a CLI arg).
    #
    # Three spellings are accepted because `pwsh -File script --agent:x` SPLITS
    # the token into `--agent` + `x` (a PowerShell -File quirk), while
    # `--agent=x` stays intact:
    #   --agent:<name>   (single token — direct invocation)
    #   --agent=<name>   (single token — used by the .cmd shortcuts)
    #   --agent <name>   (two tokens — the split form -File produces)
    $agentValue = $null
    if ($currentArg -match '^--agent[:=](.+)$') {
        $agentValue = $Matches[1]
        $argIndex++
    } elseif ($currentArg -eq '--agent') {
        if ($argIndex + 1 -ge $args.Count) {
            Write-Error "--agent requires a value ($($ValidAgents -join '|'))"
            exit 1
        }
        $agentValue = $args[$argIndex + 1]
        $argIndex += 2
    }
    if ($agentValue) {
        $requested = $agentValue.ToLower()
        if ($requested -notin $ValidAgents) {
            Write-Error "Unknown agent '$agentValue'. Valid: $($ValidAgents -join ', ')"
            exit 1
        }
        $cli = $requested
        $cliSet = $true
        continue
    }

    # Positional agent selector — accepted anywhere before a mode is committed
    # and only once. Typical placement is the very first positional arg
    # (`ai codex`, `ai grok os`), but `ai --dry-run codex` also works because
    # flags are parsed in the same loop. Skipped once --agent: has pinned one.
    if ($currentArg -in $ValidAgents -and -not $cliSet -and $mode -eq "docker") {
        $cli = $currentArg
        $cliSet = $true
        $argIndex++
        continue
    }

    # Check for mode commands. "docker" is accepted as an explicit no-op (mode
    # is already the default) for symmetry with "os" / "wsl" in scripts that
    # pass the mode unconditionally.
    if ($currentArg -in "docker", "wsl", "os", "build", "audio", "update-md", "install", "uninstall", "compose-start" -and $mode -eq "docker") {
        $mode = $currentArg
        $argIndex++
        continue
    }

    # Chrome command: `chrome`, `chrome:PORT`, `chrome*N`, `chrome:PORT*N`, `chrome*N:PORT`
    # Any further args (e.g. `--mute-audio`, `--window-size=...`) are forwarded
    # verbatim to the launched browser process.
    if ($currentArg -match $ChromeArgPattern -and $mode -eq "docker") {
        $mode = "chrome"
        if ([regex]::Match($currentArg, ':(\d+)').Success) {
            $ChromeDebugStartPort = [int][regex]::Match($currentArg, ':(\d+)').Groups[1].Value
        }
        if ([regex]::Match($currentArg, '\*(\d+)').Success) {
            $n = [int][regex]::Match($currentArg, '\*(\d+)').Groups[1].Value
            if ($n -lt 1 -or $n -gt 9) {
                Write-Error "chrome: instance count must be between 1 and 9 (got $n)"
                exit 1
            }
            $ChromeInstanceCount = $n
            $ChromeUseAnonymousProfile = $true
        }
        $argIndex++
        if ($argIndex -lt $args.Count) {
            $ChromeExtraArgs = $args[$argIndex..($args.Count - 1)]
            $argIndex = $args.Count
        }
        continue
    }

    # Edge command: same shape as chrome (`edge`, `edge:PORT`, `edge*N`, `edge:PORT*N`, `edge*N:PORT`).
    # Any further args are forwarded to the browser process, same as chrome.
    if ($currentArg -match $EdgeArgPattern -and $mode -eq "docker") {
        $mode = "edge"
        if ([regex]::Match($currentArg, ':(\d+)').Success) {
            $EdgeDebugStartPort = [int][regex]::Match($currentArg, ':(\d+)').Groups[1].Value
        }
        if ([regex]::Match($currentArg, '\*(\d+)').Success) {
            $n = [int][regex]::Match($currentArg, '\*(\d+)').Groups[1].Value
            if ($n -lt 1 -or $n -gt 9) {
                Write-Error "edge: instance count must be between 1 and 9 (got $n)"
                exit 1
            }
            $EdgeInstanceCount = $n
            $EdgeUseAnonymousProfile = $true
        }
        $argIndex++
        if ($argIndex -lt $args.Count) {
            $EdgeExtraArgs = $args[$argIndex..($args.Count - 1)]
            $argIndex = $args.Count
        }
        continue
    }

    # Check for help
    if ($currentArg -in "help", "-h", "--help", "-?") {
        Show-Help
        exit 0
    }

    # Check for from-* argument (indicates self-invocation)
    if ($currentArg -match "^from-(docker|wsl)$") {
        $fromMode = $Matches[1]
        $argIndex++
        continue
    }

    # Check for wt command (regular worktree from current branch)
    if ($currentArg -eq "wt") {
        $argIndex++
        if ($argIndex -lt $args.Count) {
            $worktreeSuffix = $args[$argIndex]
            $argIndex++
        } else {
            Write-Error "The wt command requires a worktree suffix argument"
            exit 1
        }
        continue
    }

    # Check for fwt/bwt command (prefixed branch worktree)
    if ($currentArg -eq "fwt" -or $currentArg -eq "bwt") {
        $wtType = if ($currentArg -eq "fwt") { "feature" } else { "bugfix" }
        $argIndex++
        if ($argIndex -lt $args.Count) {
            # Strip feat/ or bugfix/ prefix if provided (fwt/bwt already adds the prefix)
            $featureWorktreeSuffix = $args[$argIndex] -replace '^(feat|bugfix|hotfix|fix)/', ''
            $argIndex++
        } else {
            Write-Error "The $currentArg command requires a worktree suffix argument"
            exit 1
        }
        continue
    }

    # Check for rwt command (remove worktree)
    if ($currentArg -eq "rwt") {
        $argIndex++
        if ($argIndex -lt $args.Count) {
            # Strip feat/ or bugfix/ prefix if provided (to match how fwt/bwt creates folders)
            $removeWorktreeSuffix = $args[$argIndex] -replace '^(feat|bugfix|hotfix|fix)/', ''
            $argIndex++
        } else {
            Write-Error "The rwt command requires a worktree suffix argument"
            exit 1
        }
        continue
    }

    # Check for --dry-run
    if ($currentArg -eq "--dry-run") {
        $dryRun = $true
        $argIndex++
        continue
    }

    # Check for --new (force new Docker container)
    if ($currentArg -eq "--new") {
        $newContainer = $true
        $argIndex++
        continue
    }

    # Check for --debug
    if ($currentArg -eq "--debug") {
        $debugMode = $true
        $argIndex++
        continue
    }

    # Not an ai.ps1 command - stop parsing, rest goes to the selected CLI
    break
}

# All remaining args go to the selected CLI (claude/codex/grok)
if ($argIndex -lt $args.Count) {
    $cliArgs = $args[$argIndex..($args.Count - 1)]
}

# Resolve the CLI configuration once, so the os/wsl/docker handlers below can
# stay agnostic of which CLI was picked.
$cliCommand       = $CliConfig[$cli].Command
$cliBaseArgs      = $CliConfig[$cli].BaseArgs
$cliSandboxedArgs = $CliConfig[$cli].SandboxedArgs
$cliSandboxedEnv  = $CliConfig[$cli].SandboxedEnv

# Handle install: register ai.ps1 globally (user PATH on Windows, shell aliases on Unix)
# and build the Docker image for AgentCli. Runs before project-root detection so it
# works from any directory and doesn't require being inside a git repo.
if ($mode -eq "install") {
    Write-Host "Installing AgentCli launcher..." -ForegroundColor Cyan
    Write-Host "  Launcher dir: $scriptDir"

    $installOS = Get-CurrentOS
    Write-Host "  OS:           $installOS"
    Write-Host ""

    # Entry-point shortcuts registered by install. 'ai' is the launcher itself;
    # 'ai-codex'/'ai-grok'/'ai-goose'/'ai-opencode' pin an agent via --agent: (see
    # ai-codex.cmd / ai-grok.cmd / ai-goose.cmd / ai-opencode.cmd).
    $entryPoints = @("ai", "ai-codex", "ai-grok", "ai-goose", "ai-opencode")

    if ($installOS -eq "Windows") {
        # Add launcher directory to the *user* PATH so the entry-point .cmd files
        # resolve in any new shell.
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $existingParts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
        if ($existingParts -contains $scriptDir) {
            Write-Host "User PATH already contains: $scriptDir" -ForegroundColor DarkGray
        } else {
            $newPath = if ($userPath) { "$userPath;$scriptDir" } else { $scriptDir }
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Host "Added to user PATH: $scriptDir" -ForegroundColor Green
            Write-Host "(Open a new shell for the change to take effect.)" -ForegroundColor DarkGray
        }
    } else {
        # macOS/Linux/WSL: pick the default shell's rc file and add (or refresh) an
        # alias per entry point. zsh on macOS, bash everywhere else.
        $rcFile = switch ($installOS) {
            "macOS" { Join-Path $env:HOME ".zshrc" }
            default { Join-Path $env:HOME ".bashrc" }
        }
        if (-not (Test-Path $rcFile)) {
            New-Item -ItemType File -Path $rcFile -Force | Out-Null
        }

        foreach ($ep in $entryPoints) {
            $cmdPath = Join-Path $scriptDir "$ep.cmd"
            if (-not (Test-Path $cmdPath)) {
                Write-Error "Expected launcher entry-point not found at: $cmdPath"
                exit 1
            }
            # Polyglot .cmd doubles as a bash script — must be executable for shell invocation.
            & chmod +x $cmdPath 2>$null

            $aliasLine    = "alias $ep='$cmdPath'"
            $aliasPattern = "^\s*alias\s+$ep\s*="

            $lines    = @(Get-Content -Path $rcFile -ErrorAction SilentlyContinue)
            $existing = @($lines | Where-Object { $_ -match $aliasPattern })

            if ($existing.Count -gt 0 -and $existing[0] -eq $aliasLine) {
                Write-Host "Alias '$ep' already set in $rcFile" -ForegroundColor DarkGray
            } elseif ($existing.Count -gt 0) {
                $updated = $lines | ForEach-Object {
                    if ($_ -match $aliasPattern) { $aliasLine } else { $_ }
                }
                Set-Content -Path $rcFile -Value $updated
                Write-Host "Updated alias '$ep' in $rcFile" -ForegroundColor Green
            } else {
                Add-Content -Path $rcFile -Value $aliasLine
                Write-Host "Added alias '$ep' to $rcFile" -ForegroundColor Green
            }
        }
        Write-Host "(Run 'source $rcFile' or open a new shell for the aliases to take effect.)" -ForegroundColor DarkGray
    }

    # Link AgentCli's .claude/{commands,skills} into the user's global Claude
    # config under a `team` subfolder so every Claude session (Docker, WSL,
    # or host) sees them as shared. Skipped when running inside Docker (the
    # Docker handler bind-mounts these subfolders at launch instead).
    if ($installOS -ne "Docker") {
        Write-Host ""
        Write-Host "Linking AgentCli .claude/commands and .claude/skills..." -ForegroundColor Cyan
        $homeForLinks  = if ($installOS -eq "Windows") { $env:USERPROFILE } else { $env:HOME }
        $globalClaude  = Join-Path $homeForLinks ".claude"
        foreach ($folder in @("commands", "skills")) {
            $src = Join-Path $scriptDir ".claude" $folder
            $dst = Join-Path $globalClaude $folder "team"
            Set-DirectoryLink -Source $src -Target $dst
        }
    }

    # Build the Docker image for AgentCli itself. Uses $scriptDir (not the current
    # directory) so install works from anywhere.
    Write-Host ""
    Write-Host "Building Docker image..." -ForegroundColor Cyan
    $dockerfilePath = Join-Path $scriptDir "Dockerfile"
    if (-not (Test-Path $dockerfilePath)) {
        Write-Host "No Dockerfile at $dockerfilePath — skipping build." -ForegroundColor Yellow
        exit 0
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "docker not found in PATH — skipping build. Install Docker and re-run 'ai install' or 'ai build'." -ForegroundColor Yellow
        exit 0
    }

    $installProjectName = Split-Path -Leaf $scriptDir
    $imageName = "claude-$($installProjectName.ToLower())"
    Write-Host "  Image: $imageName"
    docker build -t $imageName -f $dockerfilePath $scriptDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker build failed (exit code $LASTEXITCODE)"
        exit $LASTEXITCODE
    }

    Write-Host ""
    Write-Host "Install complete." -ForegroundColor Green
    exit 0
}

# Handle uninstall: undo everything `ai install` did — unregister `ai`/`c`/`g`
# from PATH/shell aliases, remove the team links under ~/.claude/{commands,skills},
# stop the AgentCli docker-compose stack, and remove the shared AgentCli Docker image.
# Per-project Docker containers and AGENTS.md/CLAUDE.md outputs are left alone.
if ($mode -eq "uninstall") {
    Write-Host "Uninstalling AgentCli launcher..." -ForegroundColor Cyan
    Write-Host "  Launcher dir: $scriptDir"

    $installOS = Get-CurrentOS
    Write-Host "  OS:           $installOS"
    Write-Host ""

    $entryPoints = @("ai", "ai-codex", "ai-grok", "ai-goose", "ai-opencode")

    if ($installOS -eq "Windows") {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
        $kept  = @($parts | Where-Object { $_ -ne $scriptDir })
        if ($kept.Count -eq $parts.Count) {
            Write-Host "User PATH didn't contain: $scriptDir" -ForegroundColor DarkGray
        } else {
            [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
            Write-Host "Removed from user PATH: $scriptDir" -ForegroundColor Green
            Write-Host "(Open a new shell for the change to take effect.)" -ForegroundColor DarkGray
        }
    } else {
        $rcFile = switch ($installOS) {
            "macOS" { Join-Path $env:HOME ".zshrc" }
            default { Join-Path $env:HOME ".bashrc" }
        }

        if (-not (Test-Path $rcFile)) {
            Write-Host "No $rcFile to update." -ForegroundColor DarkGray
        } else {
            foreach ($ep in $entryPoints) {
                $aliasPattern = "^\s*alias\s+$ep\s*="
                $lines    = @(Get-Content -Path $rcFile -ErrorAction SilentlyContinue)
                $filtered = @($lines | Where-Object { $_ -notmatch $aliasPattern })
                if ($filtered.Count -eq $lines.Count) {
                    Write-Host "No '$ep' alias found in $rcFile" -ForegroundColor DarkGray
                } else {
                    Set-Content -Path $rcFile -Value $filtered
                    Write-Host "Removed alias '$ep' from $rcFile" -ForegroundColor Green
                }
            }
        }
    }

    if ($installOS -ne "Docker") {
        Write-Host ""
        Write-Host "Removing AgentCli .claude/commands and .claude/skills links..." -ForegroundColor Cyan
        $homeForLinks  = if ($installOS -eq "Windows") { $env:USERPROFILE } else { $env:HOME }
        $globalClaude  = Join-Path $homeForLinks ".claude"
        foreach ($folder in @("commands", "skills")) {
            $dst = Join-Path $globalClaude $folder "team"
            Remove-DirectoryLink -Target $dst
        }
    }

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $composeFile = Join-Path $scriptDir "docker-compose.yml"
        if (Test-Path $composeFile) {
            Write-Host ""
            Write-Host "Stopping AgentCli docker-compose stack..." -ForegroundColor Cyan
            & docker compose -f $composeFile down 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Stopped compose stack." -ForegroundColor Green
            }
        }
        if (Test-Path $script:ComposeMarkerPath) {
            Remove-Item $script:ComposeMarkerPath -Force -ErrorAction SilentlyContinue
        }

        $installProjectName = Split-Path -Leaf $scriptDir
        $imageName = "claude-$($installProjectName.ToLower())"
        Write-Host ""
        Write-Host "Removing Docker image $imageName..." -ForegroundColor Cyan
        docker image inspect $imageName 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            docker image rm -f $imageName | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Removed Docker image: $imageName" -ForegroundColor Green
            } else {
                Write-Host "docker image rm exited with code $LASTEXITCODE — image may still be in use by a running container." -ForegroundColor Yellow
            }
        } else {
            Write-Host "No image $imageName to remove." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "docker not found in PATH — skipping compose-stop and image removal." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Uninstall complete." -ForegroundColor Green
    exit 0
}

# Handle update-md: regenerate byte-identical AGENTS.md and CLAUDE.md by
# concatenating two sources:
#   1. AGENTS-Source.md from the project where ai.ps1 was launched ((Get-Location).Path) —
#      optional, holds the project-specific local part.
#   2. AGENTS-Suffix.md from the AgentCli repo ($scriptDir) — required, the shared
#      boilerplate appended to every project's generated docs.
# Output AGENTS.md and CLAUDE.md are written to the launch folder. Runs before
# project-root detection so it has no side effects and works outside a git repo.
if ($mode -eq "update-md") {
    $launchDir = (Get-Location).Path
    $suffixPath = Join-Path $scriptDir "AGENTS-Suffix.md"
    $sourcePath = Join-Path $launchDir "AGENTS-Source.md"

    if (-not (Test-Path $suffixPath)) {
        Write-Error "AGENTS-Suffix.md not found in AgentCli folder at: $suffixPath"
        exit 1
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $partNames = [System.Collections.Generic.List[string]]::new()

    if (Test-Path $sourcePath) {
        $parts.Add((Get-Content -Raw -Path $sourcePath).TrimEnd())
        $partNames.Add("AGENTS-Source.md (this folder)")
    } else {
        Write-Host "Note: no AGENTS-Source.md in $launchDir — emitting suffix only." -ForegroundColor Yellow
    }
    $parts.Add((Get-Content -Raw -Path $suffixPath).TrimEnd())
    $partNames.Add("AGENTS-Suffix.md (AgentCli)")

    $sourceDesc = $partNames -join " + "
    $header = "<!-- AUTO-GENERATED — DO NOT EDIT. Built by ``ai update-md`` from $sourceDesc. To change anything below, edit the source file(s) and re-run ``ai update-md``. -->"
    $content = $header + "`n`n" + (($parts -join "`n`n")) + "`n"

    foreach ($outName in @("AGENTS.md", "CLAUDE.md")) {
        $outPath = Join-Path $launchDir $outName
        Set-Content -Path $outPath -Value $content -NoNewline -Encoding utf8NoBOM
        Write-Host "Wrote $outPath ($sourceDesc)"
    }
    exit 0
}

# Find current project
if ($fromMode -and $env:AC_ProjectPath) {
    # Re-invoked inside Docker/WSL: derive project info from env vars set by outer invocation.
    # This avoids calling git rev-parse, which fails in worktrees with absolute Windows paths.
    $projectRoot  = $env:AC_ProjectPath
    $folderName   = Split-Path -Leaf $env:AC_ProjectPath
    $worktree     = if ($env:AC_Worktree) { $env:AC_Worktree } else { "" }
    $projectName  = if ($worktree -and $folderName.EndsWith("-$worktree")) {
        $folderName.Substring(0, $folderName.Length - $worktree.Length - 1)
    } else { $folderName }
    $relativePath = ""
    if ($debugMode) {
        Write-Host "[DEBUG] Using env vars: projectRoot=$projectRoot, folderName=$folderName, worktree=$worktree, projectName=$projectName"
    }

    # Fix worktree git paths if they still have absolute Windows paths (from host)
    if ($worktree) {
        $mainProjectPath = Join-Path $env:AC_ProjectRoot $projectName
        Convert-WorktreeToRelativePaths -WorktreePath $projectRoot -MainProjectPath $mainProjectPath -Debug:$debugMode
    }
} else {
    $projectInfo = Find-ProjectRoot -Debug:$debugMode
    if (-not $projectInfo) {
        Write-Error "Could not find project root."
        Write-Error "Make sure you're inside a git repository."
        exit 1
    }

    $projectName  = $projectInfo.ProjectName
    $folderName   = $projectInfo.FolderName
    $projectRoot  = $projectInfo.ProjectRoot
    $relativePath = $projectInfo.RelativePath -replace "\\", "/"
    $worktree     = $projectInfo.Worktree
    $atRoot       = [bool]$projectInfo.AtRoot
}
if (-not (Get-Variable -Name atRoot -Scope Local -ErrorAction SilentlyContinue)) { $atRoot = $false }

# Out-of-tree detection: true when the resolved project root is NOT under
# AC_ProjectRoot (i.e. some folder outside the standard /Projects tree).
# Only the Docker handler cares — it sanitizes the path into a /proj/<name>
# mount target. OS / WSL modes just use the actual project path verbatim.
# AtRoot (cwd == AC_ProjectRoot) is in-tree by definition, never out-of-tree.
$isOutOfTree = (-not $atRoot) -and (-not (Test-IsUnderRoot $projectRoot $env:AC_ProjectRoot))
if ($debugMode -and $isOutOfTree) {
    Write-Host "[DEBUG] Project is out-of-tree: $projectRoot is not under $env:AC_ProjectRoot"
}

# AgentCli's own folder name (leaf of $scriptDir). Used to locate this script
# inside Docker (/proj/<name>/ai.ps1) and to derive the shared image name.
$agentCliFolderName = Split-Path -Leaf $scriptDir
if (-not (Test-IsUnderRoot $scriptDir $env:AC_ProjectRoot)) {
    Write-Error "AgentCli ($scriptDir) is not under AC_ProjectRoot ($env:AC_ProjectRoot). Set AC_ProjectRoot to a folder that contains AgentCli, or leave it unset to default to AgentCli's parent."
    exit 1
}

# Port registry for worktree server ports
class PortRegistry {
    [string]$ProjectPath
    [string]$RegistryPath
    [int]$BasePort = 7080
    [int]$PortIncrement = 10
    [int]$MaxPort = 7370

    PortRegistry([string]$projectPath) {
        $this.ProjectPath = $projectPath
        $this.RegistryPath = Join-Path $projectPath "artifacts" "server-ports.json"
    }

    hidden [hashtable] Load() {
        if (Test-Path $this.RegistryPath) {
            return Get-Content $this.RegistryPath -Raw | ConvertFrom-Json -AsHashtable
        }
        return @{ "dev" = $this.BasePort }
    }

    hidden [void] Save([hashtable]$registry) {
        $registry | ConvertTo-Json -Depth 10 | Set-Content $this.RegistryPath
    }

    [object] Get([string]$instanceName) {
        $registry = $this.Load()
        if ($registry.ContainsKey($instanceName)) {
            return $registry[$instanceName]
        }
        return $null
    }

    [int] Allocate([string]$instanceName) {
        $registry = $this.Load()

        # Return existing port if already allocated
        if ($registry.ContainsKey($instanceName)) {
            return $registry[$instanceName]
        }

        # Allocate new port
        $usedPorts = [System.Collections.Generic.HashSet[int]]::new([int[]]@($registry.Values))
        $port = $this.BasePort
        while ($usedPorts.Contains($port) -and $port -le $this.MaxPort) {
            $port += $this.PortIncrement
        }

        if ($port -gt $this.MaxPort) {
            throw "No more port blocks available. Maximum port $($this.MaxPort) exceeded."
        }

        $registry[$instanceName] = $port
        $this.Save($registry)

        return $port
    }

    [bool] Deallocate([string]$instanceName) {
        if (-not (Test-Path $this.RegistryPath)) {
            return $false
        }

        $registry = $this.Load()
        if (-not $registry.ContainsKey($instanceName)) {
            return $false
        }

        $registry.Remove($instanceName)
        $this.Save($registry)

        return $true
    }
}

# Worktree server configuration and registration
class WorktreeServer {
    [string]$ProjectPath
    [string]$WorktreeSuffix
    [string]$InstanceName
    [int]$Port
    [string[]]$Hostnames
    [PortRegistry]$PortRegistry
    [bool]$IsMainProject

    WorktreeServer([string]$projectPath, [string]$worktreeSuffix) {
        $this.ProjectPath = $projectPath
        $this.WorktreeSuffix = $worktreeSuffix
        $this.IsMainProject = -not $worktreeSuffix

        # Truncate suffix for domain/instance names (max 20 chars), default to "dev" for main project
        $this.InstanceName = if ($worktreeSuffix) {
            -join $worktreeSuffix[0..([Math]::Min(19, $worktreeSuffix.Length - 1))]
        } else { "dev" }

        # Build hostnames for this worktree (main project doesn't need custom hostnames).
        $this.Hostnames = if (-not $this.IsMainProject) {
            @(
                "$($this.InstanceName).local.voxt.ai",
                "cdn-$($this.InstanceName).local.voxt.ai",
                "media-$($this.InstanceName).local.voxt.ai",
                "maps-$($this.InstanceName).local.voxt.ai"
            )
        } else { @() }

        $this.PortRegistry = [PortRegistry]::new($projectPath)
        $this.Port = $this.PortRegistry.Get($this.InstanceName)
    }

    [hashtable] GetConfig() {
        return @{
            InstanceName = $this.InstanceName
            Port         = $this.Port
        }
    }

    [hashtable] Register([bool]$debug) {
        if (-not $this.Port) {
            $this.Port = $this.PortRegistry.Allocate($this.InstanceName)
            if ($debug) {
                Write-Host "[DEBUG] Allocated port $($this.Port) for instance '$($this.InstanceName)'"
            }
        }

        # Re-apply nginx config and hosts entries on every launch so a changed LAN IP
        # (e.g. after switching networks) gets propagated even when the port was already
        # allocated. The helpers no-op when nothing has changed.
        if (-not $this.IsMainProject) {
            $this.WriteNginxConfig($debug)
            $this.ReloadNginx($debug)
            $this.AddHostsEntries($debug)
        }

        return $this.GetConfig()
    }

    [void] Unregister([bool]$debug) {
        if ($this.IsMainProject) { return }

        # Remove from port registry
        $removed = $this.PortRegistry.Deallocate($this.InstanceName)
        if (-not $removed) {
            if ($debug) { Write-Host "[DEBUG] Instance '$($this.InstanceName)' not found in registry" }
            return
        }
        if ($debug) { Write-Host "[DEBUG] Removed instance '$($this.InstanceName)' from server registry" }

        $this.RemoveNginxConfig($debug)
        $this.ReloadNginx($debug)
        $this.RemoveHostsEntries($debug)

        $this.Port = 0
    }

    hidden [string] GetNginxConfigPath() {
        $worktreePortsDir = Join-Path $this.ProjectPath "artifacts" "worktree-ports.d"
        return Join-Path $worktreePortsDir "$($this.InstanceName).conf"
    }

    hidden [void] WriteNginxConfig([bool]$debug) {
        if ($this.IsMainProject) { return }

        $worktreePortsDir = Join-Path $this.ProjectPath "artifacts" "worktree-ports.d"
        if (-not (Test-Path $worktreePortsDir)) {
            New-Item -ItemType Directory -Path $worktreePortsDir -Force | Out-Null
        }

        $nginxConfPath = $this.GetNginxConfigPath()
        Set-Content -Path $nginxConfPath -Value "`"$($this.InstanceName)`" $($this.Port);"
        if ($debug) { Write-Host "[DEBUG] Wrote nginx port mapping: $nginxConfPath" }
    }

    hidden [void] RemoveNginxConfig([bool]$debug) {
        $nginxConfPath = $this.GetNginxConfigPath()
        if (Test-Path $nginxConfPath) {
            Remove-Item $nginxConfPath -Force
            if ($debug) { Write-Host "[DEBUG] Removed nginx port mapping: $nginxConfPath" }
        }
    }

    hidden [void] ReloadNginx([bool]$debug) {
        $nginxContainer = docker ps --filter "name=actual-chat-infra-nginx" --format "{{.Names}}" 2>$null | Select-Object -First 1
        if (-not $nginxContainer) {
            Write-Host "WARNING: nginx container not found — worktree routing may not work." -ForegroundColor Yellow
            return
        }

        docker exec $nginxContainer nginx -s reload 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            if ($debug) { Write-Host "[DEBUG] Reloaded nginx" }
        } else {
            # Reload can fail due to stale bind mounts; restart refreshes them
            if ($debug) { Write-Host "[DEBUG] nginx reload failed, restarting container" }
            docker restart $nginxContainer 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                if ($debug) { Write-Host "[DEBUG] Restarted nginx" }
            } else {
                Write-Host "WARNING: nginx restart failed — worktree routing may not work." -ForegroundColor Yellow
            }
        }
    }

    hidden [void] AddHostsEntries([bool]$debug) {
        if (-not $this.Hostnames) { return }
        if ($debug) { Write-Host "[DEBUG] Adding hosts entries for: $($this.Hostnames -join ', ')" }
        Update-HostEntries -Hostnames $this.Hostnames -DetectIP | Out-Null
    }

    hidden [void] RemoveHostsEntries([bool]$debug) {
        if (-not $this.Hostnames) { return }
        if ($debug) { Write-Host "[DEBUG] Removing hosts entries for: $($this.Hostnames -join ', ')" }
        Remove-HostEntries -Hostnames $this.Hostnames
    }
}

# PulseAudio setup for voice mode in Docker
class PulseAudioSetup {
    [int]$Port = 4713

    [bool] IsRunning() {
        if ((Get-CurrentOS) -eq "Windows") {
            $listening = netstat -an | Select-String ":$($this.Port)\s+.*LISTENING"
            return $null -ne $listening
        } else {
            $listening = bash -c "lsof -i :$($this.Port) -sTCP:LISTEN 2>/dev/null || ss -tln 2>/dev/null | grep -q ':$($this.Port) '"
            return $LASTEXITCODE -eq 0 -and $listening
        }
    }

    [bool] WaitForStart([int]$maxWaitSeconds) {
        $waited = 0
        while (-not $this.IsRunning() -and $waited -lt ($maxWaitSeconds * 2)) {
            Start-Sleep -Milliseconds 500
            $waited++
        }
        return $this.IsRunning()
    }

    [bool] IsInstalled() {
        $os = Get-CurrentOS
        if ($os -eq "macOS") {
            return $null -ne (Get-Command "pulseaudio" -ErrorAction SilentlyContinue)
        } elseif ($os -eq "Windows") {
            return (Test-Path "$env:LOCALAPPDATA\PulseAudio\bin\pulseaudio.exe") -or
                   (Test-Path "$env:ProgramFiles\PulseAudio\bin\pulseaudio.exe")
        }
        return $false
    }

    [void] EnsureRunning() {
        if ($this.IsRunning() -or -not $this.IsInstalled()) { return }
        Write-Host "Starting PulseAudio for voice mode..." -ForegroundColor Cyan
        $this.Setup()
    }

    [void] Setup() {
        switch (Get-CurrentOS) {
            "macOS"   { $this.SetupMacOS() }
            "Windows" { $this.SetupWindows() }
            "Linux"   { $this.SetupLinux() }
            default   { Write-Host "Unsupported OS for audio setup" -ForegroundColor Red; exit 1 }
        }
    }

    hidden [void] SetupMacOS() {
        # Check if PulseAudio is installed
        if (-not (Get-Command "pulseaudio" -ErrorAction SilentlyContinue)) {
            Write-Host "PulseAudio is not installed. Installing via Homebrew..." -ForegroundColor Cyan
            & brew install pulseaudio
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to install PulseAudio. Please install Homebrew first: https://brew.sh"
                exit 1
            }
        }

        # Check if already running
        if ($this.IsRunning()) {
            Write-Host "PulseAudio is already running on port $($this.Port)" -ForegroundColor Green
            return
        }

        # Create config directory
        $configDir = "$env:HOME/.pulse"
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        # Create config with TCP module
        $configFile = "$configDir/default.pa"
        $homebrewPrefix = if (Test-Path "/opt/homebrew") { "/opt/homebrew" } else { "/usr/local" }
        $defaultPaPath = "$homebrewPrefix/etc/pulse/default.pa"

        if (-not (Test-Path $configFile) -or -not (Select-String -Path $configFile -Pattern "module-native-protocol-tcp" -Quiet)) {
            Write-Host "Configuring PulseAudio for Docker connections..." -ForegroundColor Cyan
            $configContent = @"
.include $defaultPaPath
load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1;192.168.65.0/24 auth-anonymous=1
"@
            Set-Content -Path $configFile -Value $configContent
            Write-Host "Created config: $configFile" -ForegroundColor Green
        }

        # Start daemon
        Write-Host "Starting PulseAudio daemon..." -ForegroundColor Cyan
        & pulseaudio --load=module-native-protocol-tcp --exit-idle-time=-1 --daemon 2>&1 | Out-Null

        if ($this.WaitForStart(10)) {
            Write-Host "PulseAudio started successfully on port $($this.Port)" -ForegroundColor Green
            Write-Host "`nVoice mode should now work in Docker. Run 'c' to start Claude." -ForegroundColor Cyan
            Write-Host "`nTo stop: pulseaudio --kill" -ForegroundColor DarkGray
        } else {
            Write-Host "Failed to start PulseAudio. Try manually:" -ForegroundColor Yellow
            Write-Host "  pulseaudio --load=module-native-protocol-tcp --exit-idle-time=-1 --daemon" -ForegroundColor White
        }
    }

    hidden [void] SetupWindows() {
        $portableDir = "$env:LOCALAPPDATA\PulseAudio"
        $legacyDir = "$env:ProgramFiles\PulseAudio"
        # Prefer portable location, fall back to legacy (exe installer) location
        $installDir = if (Test-Path "$portableDir\bin\pulseaudio.exe") { $portableDir }
            elseif (Test-Path "$legacyDir\bin\pulseaudio.exe") { $legacyDir }
            else { $portableDir }
        $exePath = "$installDir\bin\pulseaudio.exe"
        $configDir = "$env:APPDATA\PulseAudio"
        $configFile = "$configDir\default.pa"

        # Install if needed
        if (-not (Test-Path $exePath)) {
            Write-Host "PulseAudio is not installed. Downloading..." -ForegroundColor Cyan
            $zipUrl = "https://github.com/pgaskin/pulseaudio-win32/releases/download/v5/pulseaudio.zip"
            $zipPath = "$env:TEMP\pulseaudio.zip"
            try {
                Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
            } catch {
                Write-Error "Failed to download PulseAudio from $zipUrl"
                exit 1
            }
            # Zip contains a "pulseaudio/" root folder, so extract to parent directory
            Expand-Archive -Path $zipPath -DestinationPath (Split-Path $installDir) -Force
            Remove-Item $zipPath -ErrorAction SilentlyContinue

            if (-not (Test-Path $exePath)) {
                Write-Error "PulseAudio installation failed."
                exit 1
            }
            Write-Host "PulseAudio installed to $installDir" -ForegroundColor Green
        }

        # Check if already running
        if ($this.IsRunning()) {
            Write-Host "PulseAudio is already running on port $($this.Port)" -ForegroundColor Green
            return
        }

        # Create config directory
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        # Create config with TCP module
        if (-not (Test-Path $configFile) -or -not (Select-String -Path $configFile -Pattern "module-native-protocol-tcp" -Quiet)) {
            Write-Host "Configuring PulseAudio for Docker connections..." -ForegroundColor Cyan
            $configContent = @"
.include $installDir/etc/pulse/default.pa
load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1;192.168.65.0/24 auth-anonymous=1
"@
            Set-Content -Path $configFile -Value $configContent
            Write-Host "Created config: $configFile" -ForegroundColor Green
        }

        # Start daemon
        Write-Host "Starting PulseAudio..." -ForegroundColor Cyan
        Start-Process -FilePath $exePath -ArgumentList "--exit-idle-time=-1", "-F", $configFile -WindowStyle Hidden

        if ($this.WaitForStart(10)) {
            Write-Host "PulseAudio started successfully on port $($this.Port)" -ForegroundColor Green
            Write-Host "`nVoice mode should now work in Docker. Run 'c' to start Claude." -ForegroundColor Cyan
            Write-Host "`nTo stop: taskkill /IM pulseaudio.exe" -ForegroundColor DarkGray
        } else {
            Write-Host "Failed to start PulseAudio. Try running manually:" -ForegroundColor Yellow
            Write-Host "  `"$exePath`" --exit-idle-time=-1 -F `"$configFile`"" -ForegroundColor White
        }
    }

    hidden [void] SetupLinux() {
        Write-Host "On Linux, PulseAudio/PipeWire should already be available." -ForegroundColor Yellow
        Write-Host "If voice mode doesn't work, ensure the TCP module is loaded:" -ForegroundColor Yellow
        Write-Host "  pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" -ForegroundColor White
    }
}

# Update .env file with server configuration
# Preserves existing file structure (comments, ordering, unrelated variables).
# Only updates lines whose values changed and appends new variables at the end.
function Update-EnvFile {
    param(
        [string]$ProjectPath,
        [hashtable]$Variables,
        [switch]$Debug
    )

    $envFilePath = Join-Path $ProjectPath ".env"
    $remaining  = [System.Collections.Generic.Dictionary[string,string]]::new()
    foreach ($k in $Variables.Keys) { $remaining[$k] = $Variables[$k] }
    $lines      = @()
    $changed    = $false

    # Read existing file, updating matching lines in place
    if (Test-Path $envFilePath) {
        $lines = @(Get-Content $envFilePath | ForEach-Object {
            $line = $_
            if ($line.Trim() -and -not $line.TrimStart().StartsWith('#')) {
                $eqIndex = $line.IndexOf('=')
                if ($eqIndex -gt 0) {
                    $key = $line.Substring(0, $eqIndex)
                    if ($remaining.ContainsKey($key)) {
                        $newValue = $remaining[$key]
                        $null = $remaining.Remove($key)
                        $newLine = "$key=$newValue"
                        if ($newLine -ne $line) { $changed = $true }
                        return $newLine
                    }
                }
            }
            return $line
        })
    }

    # Append any variables that weren't already in the file
    foreach ($entry in $remaining.GetEnumerator() | Sort-Object Key) {
        $lines += "$($entry.Key)=$($entry.Value)"
        $changed = $true
    }

    if ($changed) {
        Set-Content -Path $envFilePath -Value $lines
        if ($Debug) { Write-Host "[DEBUG] Updated .env file: $envFilePath" }
    } elseif ($Debug) {
        Write-Host "[DEBUG] .env file unchanged: $envFilePath"
    }
}

# Handle rwt command: remove worktree and its configuration
if ($removeWorktreeSuffix) {
    $mainProjectPath = Join-Path $env:AC_ProjectRoot $projectName
    $worktreePath = Join-Path $env:AC_ProjectRoot "$projectName-$removeWorktreeSuffix"

    Write-Host "Removing worktree: $projectName-$removeWorktreeSuffix" -ForegroundColor Cyan

    # Stop server and Docker containers; then remove server config
    if (Test-Path (Join-Path $mainProjectPath "ActualChat.sln")) {
        $server = [WorktreeServer]::new($mainProjectPath, $removeWorktreeSuffix)

        # Kill Docker containers for this worktree
        $containerBaseName = "$($projectName.ToLower())-$($removeWorktreeSuffix.ToLower())"
        $existingContainers = @(docker ps -a --filter "label=worktree=$containerBaseName" --format "{{.ID}}`t{{.Names}}" 2>$null | Where-Object { $_ })
        if ($existingContainers.Count -gt 0) {
            foreach ($entry in $existingContainers) {
                $parts = $entry -split "`t"
                $cId = $parts[0]
                $cName = $parts[1]
                Write-Host "Removing container: $cName" -ForegroundColor Cyan
                docker rm -f $cId 2>$null | Out-Null
            }
            Write-Host "Docker containers removed" -ForegroundColor Green
        } elseif ($debugMode) {
            Write-Host "[DEBUG] No Docker containers found for worktree '$containerBaseName'"
        }

        $server.Unregister($debugMode)

        $worktreeEnvFile = Join-Path $worktreePath ".env"
        if (Test-Path $worktreeEnvFile) {
            Remove-Item $worktreeEnvFile -Force
            if ($debugMode) { Write-Host "[DEBUG] Removed worktree .env file" }
        }
    }

    # Remove git worktree and its branch
    if (Test-Path $worktreePath) {
        $originalLocation = Get-Location
        Set-Location $mainProjectPath
        try {
            # Get branch name before removing worktree
            $worktreeBranch = $null
            $worktreeListOutput = git worktree list --porcelain 2>&1
            $inTargetWorktree = $false
            foreach ($line in $worktreeListOutput -split "`n") {
                if ($line -match "^worktree (.+)$" -and $Matches[1] -eq $worktreePath) {
                    $inTargetWorktree = $true
                } elseif ($line -match "^worktree " -and $inTargetWorktree) {
                    break
                } elseif ($inTargetWorktree -and $line -match "^branch refs/heads/(.+)$") {
                    $worktreeBranch = $Matches[1]
                    break
                }
            }

            # Remove worktree
            git worktree remove $worktreePath --force 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Git worktree removed" -ForegroundColor Green
            } else {
                Write-Host "Warning: git worktree remove failed, you may need to remove manually" -ForegroundColor Yellow
            }

            # Delete local branch if found
            if ($worktreeBranch) {
                git branch -D $worktreeBranch 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Local branch '$worktreeBranch' deleted" -ForegroundColor Green
                } else {
                    Write-Host "Warning: could not delete branch '$worktreeBranch'" -ForegroundColor Yellow
                }
            }
        } finally {
            Set-Location $originalLocation
        }
    } else {
        Write-Host "Worktree directory not found: $worktreePath" -ForegroundColor Yellow
    }

    Write-Host "Done" -ForegroundColor Green
    exit 0
}

# Handle wt argument: create regular worktree from current branch and switch to it
if ($worktreeSuffix) {
    # Always use the main project path (not another worktree)
    $mainProjectPath = Join-Path $env:AC_ProjectRoot $projectName
    $worktreePath    = Join-Path $env:AC_ProjectRoot "$projectName-$worktreeSuffix"

    if (-not (Test-Path $worktreePath)) {
        Write-Host "Creating worktree: $projectName-$worktreeSuffix"
        $originalLocation = Get-Location
        Set-Location $mainProjectPath
        try {
            # Get current branch name in the main project
            $currentBranch = git rev-parse --abbrev-ref HEAD
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to get current branch"
                Set-Location $originalLocation
                exit 1
            }

            # Create worktree from current branch
            git worktree add -b $worktreeSuffix $worktreePath $currentBranch
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to create worktree"
                Set-Location $originalLocation
                exit 1
            }

            Write-Host "Created branch '$worktreeSuffix' from '$currentBranch'"
        } finally {
            Set-Location $originalLocation
        }
    }

    # Convert worktree git paths to relative so they work in Docker
    Convert-WorktreeToRelativePaths -WorktreePath $worktreePath -MainProjectPath $mainProjectPath -Debug:$debugMode

    # Update project info for the worktree
    $projectRoot  = $worktreePath
    $folderName   = "$projectName-$worktreeSuffix"
    $worktree     = $worktreeSuffix
    $relativePath = ""
    Set-Location $worktreePath
}

# Handle fwt/bwt arguments: create worktree with prefixed branch and switch to it
if ($featureWorktreeSuffix) {
    # Always use the main project path (not another worktree)
    $mainProjectPath = Join-Path $env:AC_ProjectRoot $projectName
    $worktreePath    = Join-Path $env:AC_ProjectRoot "$projectName-$featureWorktreeSuffix"

    if (-not (Test-Path $worktreePath)) {
        Write-Host "Creating $wtType worktree: $projectName-$featureWorktreeSuffix"
        $originalLocation = Get-Location
        Set-Location $mainProjectPath
        try {
            $branchPrefix  = if ($wtType -eq "feature") { "feat" } else { "bugfix" }
            $featureBranch = "$branchPrefix/$featureWorktreeSuffix"

            # Fetch to get up-to-date remote branch info
            git fetch origin 2>$null

            # Auto-detect base branch: prefer dev if it exists on remote, else master
            $null = git rev-parse --verify "refs/remotes/origin/dev" 2>$null
            $baseBranch = if ($LASTEXITCODE -eq 0) { "dev" } else { "master" }

            # Check if the feature branch already exists (locally or remotely)
            $null = git rev-parse --verify "refs/heads/$featureBranch" 2>$null
            $localExists = $LASTEXITCODE -eq 0
            $null = git rev-parse --verify "refs/remotes/origin/$featureBranch" 2>$null
            $remoteExists = $LASTEXITCODE -eq 0

            if (-not $localExists) {
                if ($remoteExists) {
                    # Branch exists on remote but not locally - create local tracking branch
                    Write-Host "Creating local branch '$featureBranch' tracking 'origin/$featureBranch'"
                    git branch $featureBranch "origin/$featureBranch"
                } else {
                    # Branch doesn't exist anywhere - create it from base branch
                    Write-Host "Creating branch '$featureBranch' from 'origin/$baseBranch'"
                    git branch $featureBranch "origin/$baseBranch"
                }
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Failed to create branch '$featureBranch'"
                    Set-Location $originalLocation
                    exit 1
                }
            } else {
                Write-Host "Using existing branch '$featureBranch'"
            }

            # Create worktree using the existing branch (without -b flag)
            git worktree add $worktreePath $featureBranch
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to create worktree"
                Set-Location $originalLocation
                exit 1
            }

            Invoke-PostWorktreeHook -WorktreePath $worktreePath
        } finally {
            Set-Location $originalLocation
        }
    }

    # Convert worktree git paths to relative so they work in Docker
    $mainProjectPath = Join-Path $env:AC_ProjectRoot $projectName
    Convert-WorktreeToRelativePaths -WorktreePath $worktreePath -MainProjectPath $mainProjectPath -Debug:$debugMode

    # Update project info for the worktree
    $projectRoot  = $worktreePath
    $folderName   = "$projectName-$featureWorktreeSuffix"
    $worktree     = $featureWorktreeSuffix
    $relativePath = ""
    Set-Location $worktreePath
}

# Register server config and write .env file (ActualChat projects only).
$isActualChatProject = Test-Path (Join-Path $projectRoot "ActualChat.sln")
$serverConfig = $null
if ($isActualChatProject -and -not $fromMode) {
    $mainProjectPath = if ($worktree -or $worktreeSuffix -or $featureWorktreeSuffix) {
        Join-Path $env:AC_ProjectRoot $projectName
    } else {
        $projectRoot
    }
    $server = [WorktreeServer]::new($mainProjectPath, $worktree)
    $serverConfig = $server.Register($debugMode)

    # Write server configuration to .env file in the worktree directory.
    # Uses .NET configuration names so they're automatically picked up by the server.
    # Skipped for the main project (dev instance) so its .env stays untouched.
    if ($serverConfig.InstanceName -ne "dev") {
        $envVarsToSave = @{
            "CoreSettings__Instance" = $serverConfig.InstanceName
            "HostSettings__BasePort" = "$($serverConfig.Port)"
            "HostSettings__BaseUri" = "https://$($serverConfig.InstanceName).local.voxt.ai"
        }
        Update-EnvFile -ProjectPath $projectRoot -Variables $envVarsToSave -Debug:$debugMode
    }
}

# Suppress output when launching docker (inner instance will output)
if ($mode -ne "docker" -or $dryRun) {
    $displayMode = if ($fromMode) { $fromMode } else { $mode }
    Write-Host "Mode: $displayMode"
    if ($dryRun) {
        Write-Host "Dry run: yes"
    }
}

# Helper function: create a volume mount pair (-v host:container[:ro])
function New-VolumeMount {
    param(
        [string]$HostPath,
        [string]$ContainerPath,
        [switch]$ReadOnly,
        [switch]$EnsureExists
    )
    if ($EnsureExists -and -not (Test-Path $HostPath)) {
        New-Item -ItemType Directory -Path $HostPath -Force | Out-Null
    }
    if ($currentOS -eq "Windows") {
        $HostPath = ConvertTo-DockerPath $HostPath
    }
    $mount = "${HostPath}:${ContainerPath}"
    if ($ReadOnly) { $mount += ":ro" }
    return @("-v", $mount)
}

# Helper function: prompt user to select from a list of items
# Returns 0-based index of selected item
function Read-UserSelection {
    param(
        [string]$Title,
        [string[]]$Items,
        [string]$Prompt = "Select"
    )
    Write-Host "${Title}:" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Items[$i])"
    }
    Write-Host ""
    $choice = Read-Host $Prompt
    if ($choice -match '^\d+$') {
        $idx = [int]$choice - 1
        if ($idx -ge 0 -and $idx -lt $Items.Count) {
            return $idx
        }
    }
    Write-Error "Invalid selection"
    exit 1
}

# Helper function for dry run output
function Show-DryRun {
    param(
        [hashtable]$EnvVars,
        [string]$Command,
        [array]$Arguments,
        [string]$ModeName = "OS"
    )
    Write-Host ""
    Write-Host "=== DRY RUN ($ModeName) ===" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Environment variables:" -ForegroundColor Cyan
    foreach ($key in $EnvVars.Keys | Sort-Object) {
        Write-Host "  $key=$($EnvVars[$key])"
    }
    Write-Host ""
    Write-Host "Command:" -ForegroundColor Cyan
    Write-Host "  $Command $($Arguments -join ' ')"
    Write-Host ""
}

# Expose AC_GITHUB_TOKEN as GH_TOKEN so `gh` CLI picks it up automatically
if ($env:AC_GITHUB_TOKEN -and -not $env:GH_TOKEN) {
    $env:GH_TOKEN = $env:AC_GITHUB_TOKEN
}

# Shared helpers used by the `chrome` and `edge` modes below.
function Test-DebugPort {
    param([int]$Port)
    if ($currentOS -eq "Windows") {
        return $null -ne (netstat -an | Select-String ":$Port\s+.*LISTENING")
    }
    bash -c "lsof -i :$Port -sTCP:LISTEN 2>/dev/null || nc -z localhost $Port 2>/dev/null" | Out-Null
    return $LASTEXITCODE -eq 0
}

function Get-BrowserProcesses {
    param([string]$ExePath)
    $exeName = if ($currentOS -eq "Windows") {
        [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    } else {
        Split-Path -Leaf $ExePath
    }
    return @(Get-Process -Name $exeName -ErrorAction SilentlyContinue)
}

function Test-BrowserRunning {
    param([string]$ExePath)
    return (Get-BrowserProcesses -ExePath $ExePath).Count -gt 0
}

function Ensure-FirewallRule {
    param([int]$Port, [string]$BrowserName)
    if ($currentOS -ne "Windows") { return }
    $ruleName = "$BrowserName Remote Debugging (Claude) port $Port"
    netsh advfirewall firewall show rule name="$ruleName" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return }

    Write-Host "Creating firewall rule for port $Port..." -ForegroundColor Cyan
    $result = netsh advfirewall firewall add rule `
        name="$ruleName" `
        dir=in action=allow protocol=tcp `
        localport=$Port profile=private `
        description="Allow $BrowserName remote debugging connections from WSL/Docker" 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($result -match "requires elevation|Access is denied|administrator") {
            Write-Host ""
            Write-Host "Failed to create firewall rule - administrator privileges required." -ForegroundColor Yellow
            Write-Host "Run this in an elevated PowerShell, or re-run as Administrator:" -ForegroundColor Yellow
            Write-Host "  netsh advfirewall firewall add rule name=`"$ruleName`" dir=in action=allow protocol=tcp localport=$Port profile=private" -ForegroundColor White
            exit 1
        }
        Write-Host "Warning: Failed to create firewall rule for port $Port`: $result" -ForegroundColor Yellow
    }
}

# Launches one or more debug-enabled browser instances. Caller supplies the
# OS-specific executable path, the default and anonymous profile-dir bases,
# and the browser name (used for log/firewall messages).
function Start-DebugBrowsers {
    param(
        [string]$BrowserName,
        [string]$ExePath,
        [string]$DefaultProfileDir,
        [string]$AnonProfileBase,
        [int]   $StartPort,
        [int]   $Count,
        [bool]  $UseAnonymous,
        [string[]]$ExtraArgs = @()
    )
    # Pull out our own meta-flags before anything is forwarded to the browser:
    #   --fake-media       synthetic media-stream backend (mjpeg/wav fake cam+mic).
    #                      Default is REAL devices so screencast/voice testing on
    #                      actual hardware works without per-launch tweaking; the
    #                      dev rig opts in by adding this flag.
    #   --profile <name>   override the "Playwright" leaf in --user-data-dir
    #                      with <name>. Sibling of the default profile dir if
    #                      <name> is a bare name, or an absolute path if rooted.
    #                      Incompatible with multi-instance (*N) — each instance
    #                      needs its own --user-data-dir. Launches <name> plus any
    #                      "<name>-*" sibling user-data-dirs (each a normal
    #                      single-profile dir), each as an independent browser on
    #                      its own sequential port (<name> first on $StartPort,
    #                      siblings next). Separate user-data-dirs => separate
    #                      processes => separate debug ports.
    $useFakeMedia = $false
    $profileName = $null
    $forwardedArgs = @()
    $i = 0
    while ($i -lt $ExtraArgs.Count) {
        $a = $ExtraArgs[$i]
        if ($a -eq "--fake-media") {
            $useFakeMedia = $true
        } elseif ($a -eq "--profile") {
            if ($i + 1 -ge $ExtraArgs.Count) {
                Write-Error "${BrowserName}: --profile requires a name argument (e.g. --profile MyDebug)"
                exit 1
            }
            $profileName = $ExtraArgs[$i + 1]
            $i++
        } elseif ($a -like "--profile=*") {
            $profileName = $a.Substring("--profile=".Length)
        } else {
            $forwardedArgs += $a
        }
        $i++
    }
    if ($profileName -and ($UseAnonymous -or $Count -gt 1)) {
        Write-Error "${BrowserName}: --profile cannot be combined with multi-instance (*N) — each instance needs its own --user-data-dir"
        exit 1
    }
    if ($profileName) {
        $DefaultProfileDir = if ([System.IO.Path]::IsPathRooted($profileName)) {
            $profileName
        } else {
            Join-Path (Split-Path -Parent $DefaultProfileDir) $profileName
        }
    }

    Write-Host "$BrowserName path: $ExePath"
    $procs = Get-BrowserProcesses -ExePath $ExePath
    if ($procs.Count -gt 0) {
        # Different --user-data-dir → independent process and independent debug
        # port, so the new launch usually works. The failure mode is when any
        # running instance shares the dir we're about to use: the new chrome.exe
        # hands off via IPC and --remote-debugging-port is silently dropped.
        # Chrome 136+ also blocks the flag entirely on the real default profile.
        Write-Host "$BrowserName is already running ($($procs.Count) process(es))." -ForegroundColor Yellow
        Write-Host "If any existing instance uses the same profile dir as the new launch, --remote-debugging-port will be silently dropped." -ForegroundColor DarkYellow
        $reply = Read-Host "[C]ontinue, [k]ill all running $BrowserName, or e[x]it? [C/k/x]"
        switch -Regex ($reply) {
            '^(?i:k|kill)$' {
                Write-Host "Terminating $($procs.Count) $BrowserName process(es)..." -ForegroundColor Cyan
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                $waited = 0
                while ((Test-BrowserRunning -ExePath $ExePath) -and $waited -lt 20) {
                    Start-Sleep -Milliseconds 250
                    $waited++
                }
                if (Test-BrowserRunning -ExePath $ExePath) {
                    Write-Error "$BrowserName processes did not exit within 5s. Close them manually and re-run."
                    exit 1
                }
            }
            '^(?i:e|x|exit)$' {
                Write-Host "Aborted." -ForegroundColor Yellow
                exit 1
            }
            default {
                # Empty / "c" / anything else → continue
            }
        }
    }
    # Build the launch plan. Every entry is one independent browser process with
    # its own --user-data-dir and its own sequential debug port (StartPort + i):
    #  - --profile <name>: launch <name> plus any "<name>-*" sibling
    #    user-data-dirs (each a normal single-profile dir), ordered <name> first
    #    then siblings alphabetically. Separate dirs => separate processes =>
    #    separate ports, so each profile is independently debuggable.
    #  - otherwise: the prior per-instance behavior (anonymous *N = one process
    #    + port + user-data-dir each; default = a single Playwright launch).
    $plan = @()
    if ($profileName) {
        $base   = Split-Path -Leaf $DefaultProfileDir
        $parent = Split-Path -Parent $DefaultProfileDir
        $dirs = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name -eq $base -or $_.Name -like "$base-*") -and (Test-Path (Join-Path $_.FullName "Default")) })
        $uddPaths = @()
        $uddPaths += @($dirs | Where-Object { $_.Name -eq $base } | ForEach-Object { $_.FullName })
        $uddPaths += @($dirs | Where-Object { $_.Name -ne $base } | Sort-Object Name | ForEach-Object { $_.FullName })
        if ($uddPaths.Count -eq 0) { $uddPaths = @($DefaultProfileDir) }   # first run: base dir not created yet
        Write-Host "Profile dirs for '$base': $((($uddPaths | ForEach-Object { Split-Path -Leaf $_ })) -join ', ')" -ForegroundColor DarkGray
        for ($pi = 0; $pi -lt $uddPaths.Count; $pi++) {
            $plan += [pscustomobject]@{ Port = $StartPort + $pi; UserDataDir = $uddPaths[$pi] }
        }
    } else {
        for ($pi = 0; $pi -lt $Count; $pi++) {
            $udd = if ($UseAnonymous) { "$AnonProfileBase-$($StartPort + $pi)" } else { $DefaultProfileDir }
            $plan += [pscustomobject]@{ Port = $StartPort + $pi; UserDataDir = $udd }
        }
    }

    foreach ($spec in $plan) {
        $port = $spec.Port
        $profileDir = $spec.UserDataDir

        Ensure-FirewallRule -Port $port -BrowserName $BrowserName

        if (Test-DebugPort -Port $port) {
            Write-Host "$BrowserName already running on port $port — skipping" -ForegroundColor Yellow
            continue
        }

        $label = if ($UseAnonymous) { "anonymous" } else { Split-Path -Leaf $profileDir }
        Write-Host "Starting $BrowserName on port $port ($label profile: $profileDir)..." -ForegroundColor Cyan

        # Permission / capture policy for the debug profile:
        #   --disable-notifications              deny Notification API without prompting
        #                                        (the "Allow notifications?" popup blocks the UI otherwise)
        #   --use-fake-ui-for-media-stream       auto-accept mic/camera (no permission prompt) — kept
        #                                        in both modes so the test profile never blocks on a
        #                                        permission popup, regardless of fake vs real devices.
        #   --use-fake-device-for-media-stream   (--fake-media only) feed synthetic streams instead of
        #                                        real devices. Required for the --use-file-for-fake-*
        #                                        flags to take effect — without it Chrome uses real cam/mic.
        #   --use-file-for-fake-video-capture    (--fake-media only) feed mjpeg as the camera stream
        #   --use-file-for-fake-audio-capture    (--fake-media only) feed wav as the mic stream
        #   --auto-select-desktop-capture-source auto-pick a Voxt-titled window for getDisplayMedia
        #                                        (skips the share-screen picker; matches Voxt's page
        #                                        title — see <PageTitle>@CoreConstants.AppName).
        #                                        Tab-only is a separate flag if window-mode picks a
        #                                        sibling instance: --auto-select-tab-capture-source-by-title=Voxt
        #   --test-type                          quiet "controlled by automated test software" infobar
        $fakeVideo = Join-Path $ScriptDir "lib/data/test-video-1.mjpeg"
        $fakeAudio = Join-Path $ScriptDir "lib/data/test-audio-1.wav"
        # Pass the project URL as a positional arg so the browser opens it as
        # its first tab — otherwise an anonymous profile shows the "Sign in
        # to Chrome" / "Welcome to Edge" greeter and you have to navigate
        # manually.
        # Built-in flags first, caller's pass-through next, then the URL —
        # later flags override earlier ones, so user-supplied args win.
        # TEMP: dropped `--use-file-for-fake-video-capture=...mjpeg` — under
        # Chromium 147 the fake-device pipeline silently stops producing
        # frames after ~1 second of MJPEG content (verified: track stays
        # `live` but `<video>.currentTime` never advances and rVFC
        # never fires). Without the flag Chrome falls back to its
        # built-in synthetic moving-color-bars fake, which is supposed
        # to keep producing frames indefinitely.
        # If this works, the next step is to convert the test mjpeg
        # to Y4M and put the flag back with that file.
        $cmdArgs = @(
            "--remote-debugging-port=$port",
            "--remote-debugging-address=0.0.0.0",
            "--user-data-dir=`"$profileDir`"",
            "--remote-allow-origins=*",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-notifications",
            "--use-fake-ui-for-media-stream",
            "--auto-select-desktop-capture-source=Voxt",
            "--test-type"
        )
        if ($useFakeMedia) {
            $cmdArgs += @(
                "--use-fake-device-for-media-stream",
                # "--use-file-for-fake-video-capture=`"$fakeVideo`"",
                "--use-file-for-fake-audio-capture=`"$fakeAudio`""
            )
            Write-Host "  media: fake (synthetic camera, $fakeAudio mic)" -ForegroundColor DarkGray
        } else {
            Write-Host "  media: real devices (pass --fake-media for synthetic)" -ForegroundColor DarkGray
        }
        $cmdArgs = $cmdArgs + $forwardedArgs
        if (-not $profileName) {
            $cmdArgs += "https://local.voxt.ai/"
        }
        if ($forwardedArgs.Count -gt 0) {
            Write-Host "  extra args: $($forwardedArgs -join ' ')" -ForegroundColor DarkGray
        }
        Start-Process -FilePath $ExePath -ArgumentList $cmdArgs

        $maxWait = 30; $waited = 0; $printedWaiting = $false
        while (-not (Test-DebugPort -Port $port) -and $waited -lt $maxWait) {
            Start-Sleep -Seconds 1; $waited++
            if ($waited -gt 2 -and -not $printedWaiting) {
                Write-Host "  waiting for port $port`: " -NoNewline
                $printedWaiting = $true
            }
            if ($printedWaiting) { Write-Host "." -NoNewline }
        }
        if ($printedWaiting) { Write-Host "" }

        if (Test-DebugPort -Port $port) {
            Write-Host "  ready on port $port" -ForegroundColor Green
        } else {
            Write-Host "  timed out waiting for port $port" -ForegroundColor Yellow
        }
    }
}

# Auto-start the docker-compose stack once per OS boot session. Triggered only
# for the CLI-launch modes (docker/os/wsl); skipped for admin commands (build,
# audio, chrome, edge, compose-start handles itself), dry runs, and the inner
# `from-docker` / `from-wsl` self-invocation (which the outer instance already
# covered).
if ($mode -in 'docker', 'os', 'wsl' -and -not $fromMode -and -not $dryRun) {
    if (-not (Test-ComposeStartedThisBoot)) {
        Write-Host "Compose stack not yet started this boot — starting it now..." -ForegroundColor DarkGray
        Invoke-ComposeStart
    }
}

switch ($mode) {
    "compose-start" {
        Invoke-ComposeStart
    }

    "build" {
        # Build the shared AgentCli Docker image (used by every project).
        $imageName     = "claude-$($agentCliFolderName.ToLower())"
        $dockerfilePath = Join-Path $scriptDir "Dockerfile"
        Write-Host "Building Docker image: $imageName"
        Write-Host "  Dockerfile: $dockerfilePath"
        if (-not $dryRun) {
            # Capture containers based on the current image BEFORE rebuilding.
            # After rebuild the tag points to a new image ID, and containers based
            # on the old (now-dangling) image would no longer match an ancestor filter.
            # Note: the AgentCli image is shared across all projects, so this nukes
            # every running container that's still on the old image, regardless of
            # which project they belong to. That's intentional — they'd be stale.
            $staleContainers = @(docker ps -a --filter "ancestor=$imageName" --format "{{.ID}}`t{{.Names}}" 2>$null | Where-Object { $_ })

            docker build -t $imageName -f $dockerfilePath $scriptDir
            if ($LASTEXITCODE -eq 0 -and $staleContainers.Count -gt 0) {
                Write-Host ""
                Write-Host "Removing $($staleContainers.Count) container(s) based on the previous image:" -ForegroundColor Cyan
                foreach ($entry in $staleContainers) {
                    $parts = $entry -split "`t"
                    $cId = $parts[0]
                    $cName = $parts[1]
                    Write-Host "  $cName" -ForegroundColor DarkGray
                    docker rm -f $cId 2>$null | Out-Null
                }
            }
        } else {
            Write-Host ""
            Write-Host "=== DRY RUN ===" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Command:" -ForegroundColor Cyan
            Write-Host "  docker build -t $imageName -f `"$dockerfilePath`" $scriptDir"
            Write-Host ""
        }
    }

    "wsl" {
        if ($currentOS -ne "Windows") {
            Write-Error "WSL mode is only available on Windows"
            exit 1
        }

        # Convert paths for WSL
        $wslProjectRoot = ConvertTo-WSLPath $env:AC_ProjectRoot
        $wslWorkDir = "/mnt/" + ((Get-Location).ToString().Substring(0, 1).ToLower()) + ((Get-Location).ToString().Substring(2) -replace "\\", "/")
        # Always re-invoke AgentCli's ai.ps1 (consumer projects no longer carry a copy).
        $wslScriptPath = (ConvertTo-WSLPath $scriptDir) + "/ai.ps1"

        Write-Host "Working Directory: $wslWorkDir @ $wslProjectRoot"

        # Build args for the script running in WSL. The agent selector is prepended so
        # the inner pwsh ai.ps1 invocation parses it back into $cli.
        $wslArgs = @($cli, "os", "from-wsl")
        if ($dryRun) { $wslArgs += "--dry-run" }
        if ($debugMode) { $wslArgs += "--debug" }
        $wslArgs += $cliArgs

        # Copy the selected agent's host config into the WSL user's home before
        # launch so its provider setup (e.g. a local LM Studio endpoint) carries
        # over. Best-effort — skipped if the host has no such config.
        $wslConfigPrefix = ""
        if ($cli -eq "goose") {
            $gooseConfigDir = Get-GooseConfigDir
            if ($gooseConfigDir) {
                $wslGooseSrc = ConvertTo-WSLPath (Join-Path $gooseConfigDir "config.yaml")
                $wslConfigPrefix = "mkdir -p ~/.config/goose && cp -f '$wslGooseSrc' ~/.config/goose/config.yaml 2>/dev/null; "
                Write-Host "Goose config: copying $gooseConfigDir/config.yaml into WSL ~/.config/goose/" -ForegroundColor DarkGray
            } else {
                Write-Host "Goose config: none found on host — WSL goose will use its own config." -ForegroundColor DarkGray
            }
        } elseif ($cli -eq "opencode") {
            $openCodeConfigDir = Get-OpenCodeConfigDir
            if ($openCodeConfigDir) {
                $ocSrc     = ConvertTo-WSLPath (Join-Path $openCodeConfigDir "opencode.jsonc")
                $ocSrcJson = ConvertTo-WSLPath (Join-Path $openCodeConfigDir "opencode.json")
                $wslConfigPrefix = "mkdir -p ~/.config/opencode && cp -f '$ocSrc' '$ocSrcJson' ~/.config/opencode/ 2>/dev/null; "
                Write-Host "OpenCode config: copying $openCodeConfigDir/opencode.json(c) into WSL ~/.config/opencode/" -ForegroundColor DarkGray
            } else {
                Write-Host "OpenCode config: none found on host — WSL opencode will use its own config." -ForegroundColor DarkGray
            }
        }

        # Collect propagated env vars for WSL (same rules as Docker)
        $wslPropagatedParts = @()
        Get-ChildItem env: | ForEach-Object {
            $name  = $_.Name
            $value = $_.Value
            if ($name -match '__' -or
                $name -eq 'AC_GITHUB_TOKEN' -or
                $name -eq 'GH_TOKEN' -or
                $name -eq 'NPM_READ_TOKEN' -or
                $name -eq 'GOOGLE_CLOUD_PROJECT' -or
                $name -like 'ActualChat_*' -or
                $name -like 'ActualLab_*' -or
                $name -like 'Claude_*') {
                $escapedValue = $value -replace "'", "'\''"
                $wslPropagatedParts += "$name='$escapedValue'"
            }
        }

        # Build env vars for WSL (explicit vars after propagated ones to override)
        $wslProjectPath = ConvertTo-WSLPath $projectRoot
        $wslPropagatedString = $wslPropagatedParts -join ' '
        $wslEnvString = ("$wslPropagatedString AC_ProjectRoot='$wslProjectRoot' DISABLE_AUTOUPDATER=1 AC_ProjectPath='$wslProjectPath' AC_Worktree='$worktree'").Trim()

        $wslCommandFull = "$wslConfigPrefix" + "cd '$wslWorkDir' && export $wslEnvString && pwsh '$wslScriptPath' $($wslArgs -join ' ')"

        $wslEnvVars = @{
            "AC_ProjectRoot" = $wslProjectRoot
            "AC_ProjectPath" = $wslProjectPath
            "AC_OS"          = "Linux on WSL"
            "AC_Worktree"    = $worktree
        }

        if ($dryRun) {
            Write-Host ""
            Write-Host "=== DRY RUN (WSL) ===" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Environment variables:" -ForegroundColor Cyan
            foreach ($key in $wslEnvVars.Keys | Sort-Object) {
                Write-Host "  $key=$($wslEnvVars[$key])"
            }
            Write-Host ""
            Write-Host "Command:" -ForegroundColor Cyan
            $cmdLine = ("$cliCommand " + ((@($cliBaseArgs) + $cliArgs) -join ' ')).Trim()
            Write-Host "  $cmdLine"
            Write-Host ""
            Write-Host "WSL launch command:" -ForegroundColor Cyan
            Write-Host "  wsl bash -c `"$wslCommandFull`""
            Write-Host ""
        } else {
            wsl bash -c $wslCommandFull
        }
    }

    "os" {
        # Run the selected CLI directly on the host OS
        $env:AC_ProjectPath = $projectRoot
        $env:AC_Worktree    = $worktree
        $env:DISABLE_AUTOUPDATER = "1"

        # Set AC_OS based on detected environment
        $env:AC_OS = switch ($currentOS) {
            "Docker" { "Linux in Docker" }
            "WSL"    { "Linux on WSL" }
            default  { $currentOS }
        }

        Write-Host "Running $cli on: $($env:AC_OS)"
        Write-Host "Working Directory: $(Get-Location) @ $env:AC_ProjectRoot"
        if ($worktree) {
            $worktreeInfo = "Worktree: $worktree"
            if ($serverConfig) { $worktreeInfo += " (port: $($serverConfig.Port))" }
            Write-Host $worktreeInfo
        }

        $envVars = @{
            "AC_ProjectRoot"    = $env:AC_ProjectRoot
            "AC_ProjectPath"    = $env:AC_ProjectPath
            "AC_OS"             = $env:AC_OS
            "AC_Worktree"       = $env:AC_Worktree
        }

        if ($currentOS -eq "Windows" -and $cli -eq "claude") {
            $env:CLAUDE_CODE_USE_POWERSHELL_TOOL = "1"
            $envVars["CLAUDE_CODE_USE_POWERSHELL_TOOL"] = "1"
        }

        # Apply the agent's sandbox-only env vars inside Docker (e.g. goose
        # GOOSE_MODE=auto, which is how goose skips per-tool approvals — it has
        # no equivalent CLI flag). Never applied on the host OS.
        if ($currentOS -eq "Docker" -and $cliSandboxedEnv) {
            foreach ($k in $cliSandboxedEnv.Keys) {
                Set-Item -Path "env:$k" -Value $cliSandboxedEnv[$k]
                $envVars[$k] = $cliSandboxedEnv[$k]
            }
        }

        if ($dryRun) {
            # BaseArgs (e.g. `goose session`) always precede; SandboxedArgs only in Docker.
            $allArgs = if ($currentOS -eq "Docker") {
                @($cliBaseArgs) + @($cliSandboxedArgs) + $cliArgs
            } else {
                @($cliBaseArgs) + $cliArgs
            }
            Show-DryRun -EnvVars $envVars -Command $cliCommand -Arguments $allArgs -ModeName $env:AC_OS
        } else {
            # Only apply CLI's "yolo" args in Docker (sandboxed environment)
            if ($currentOS -eq "Docker") {
                # Copy host SSH keys to ~/.ssh with strict perms (host bind-mount has loose
                # Windows perms that OpenSSH rejects). Skip silently if no host mount.
                if (Test-Path "/home/claude/.ssh-host") {
                    $sshDir = "/home/claude/.ssh"
                    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
                    Copy-Item -Path "/home/claude/.ssh-host/*" -Destination $sshDir -Recurse -Force -ErrorAction SilentlyContinue
                    & chmod 700 $sshDir
                    & sh -c "chmod 600 $sshDir/* 2>/dev/null; chmod 644 $sshDir/*.pub $sshDir/known_hosts $sshDir/config 2>/dev/null; true"
                }
                # Host-port proxies (set by the outer launcher on Docker Desktop hosts):
                # forward localhost:<port> -> host.docker.internal:<port> so config that
                # points at localhost (e.g. goose's LM Studio endpoint) reaches the host.
                if ($env:AC_HOST_PROXY_PORTS) {
                    foreach ($p in ($env:AC_HOST_PROXY_PORTS -split ',' | Where-Object { $_.Trim() })) {
                        $p = $p.Trim()
                        # -d0 = errors only, which silences socat's noisy per-fork
                        # "waitpid(...): no child has exited" warnings; stdout+stderr are
                        # also routed to /dev/null so the forwarder produces zero console
                        # output that would otherwise clobber the agent's TUI.
                        $socatCmd = "exec socat -d0 TCP-LISTEN:$p,fork,reuseaddr,bind=127.0.0.1 TCP:host.docker.internal:$p >/dev/null 2>&1"
                        Start-Process -NoNewWindow -FilePath "sh" -ArgumentList @("-c", $socatCmd) | Out-Null
                        Write-Host "Host proxy: localhost:$p -> host.docker.internal:$p" -ForegroundColor DarkGray
                    }
                }
                $allArgs = @($cliBaseArgs) + @($cliSandboxedArgs) + $cliArgs
                & $cliCommand @allArgs
                if ($debugMode) {
                    Write-Host ""
                    Read-Host "Press Enter to close..."
                }
            } elseif ($currentOS -eq "WSL") {
                # In WSL, use bash -i so the interactive shell sources .bashrc and picks up the npm PATH
                $cmdLine = ("$cliCommand " + ((@($cliBaseArgs) + $cliArgs) -join ' ')).Trim()
                & bash -i -c $cmdLine
            } else {
                # Windows/Linux/macOS - already in wt on Windows (handled at script start)
                $allArgs = @($cliBaseArgs) + $cliArgs
                & $cliCommand @allArgs
            }
        }
    }

    "docker" {
        # macOS: warn if Docker Desktop is too old for --network host support
        if ($currentOS -eq "macOS") {
            $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
            if ($debugMode) { Write-Host "[DEBUG] Docker version: $dockerVersion" }
            if ($dockerVersion -and $dockerVersion -match "^(\d+)\.(\d+)") {
                $major = [int]$Matches[1]
                $minor = [int]$Matches[2]
                if ($major -lt 4 -or ($major -eq 4 -and $minor -lt 34)) {
                    Write-Host "WARNING: Docker Desktop 4.34+ is required for --network host on macOS." -ForegroundColor Yellow
                    Write-Host "         Current version: $dockerVersion. Host services may not be reachable." -ForegroundColor Yellow
                }
            }
        }

        $homeDir = if ($currentOS -eq "Windows") { $env:USERPROFILE } else { $env:HOME }
        $volumeMounts = @()

        # Mount entire AC_ProjectRoot as /proj/ — all sibling projects are visible
        $volumeMounts += New-VolumeMount $env:AC_ProjectRoot "/proj"

        # Resolve the project's folder name + path inside the container.
        #   AtRoot:       cwd == AC_ProjectRoot itself — no per-project mount,
        #                 working dir is /proj (the AC_ProjectRoot mount above already
        #                 covers it; mapping it to /proj/Projects would collide).
        #   In-tree:      /proj/<folderName> — covered by the AC_ProjectRoot mount.
        #   Out-of-tree:  /proj/<sanitized-path> — needs its own mount, added below.
        $currentFolderName = if ($atRoot) {
            Split-Path -Leaf $env:AC_ProjectRoot
        } elseif ($isOutOfTree) {
            ConvertTo-SanitizedProjectName $projectRoot
        } elseif ($worktree) {
            "$projectName-$worktree"
        } else {
            $projectName
        }
        $currentHostPath = $projectRoot
        $dockerProjectPath = if ($atRoot) { "/proj" } else { "/proj/$currentFolderName" }

        if ($isOutOfTree) {
            $volumeMounts += New-VolumeMount $currentHostPath $dockerProjectPath
        }

        # Artifact/node_modules overrides per project (avoid permission conflicts
        # with the host). Skipped when:
        #   - AtRoot (no per-project mount target)
        #   - Out-of-tree (don't litter random host folders with artifacts/node_modules/)
        #   - The matching host folder doesn't already exist (don't auto-create them
        #     in projects that don't use them).
        if (-not $isOutOfTree -and -not $atRoot) {
            $artifactsParent = Join-Path $currentHostPath "artifacts"
            if (Test-Path $artifactsParent) {
                $artifactsHostPath = Join-Path $artifactsParent "claude-docker"
                $volumeMounts += New-VolumeMount $artifactsHostPath "$dockerProjectPath/artifacts" -EnsureExists
            }

            $nodeModulesMountPoint = Join-Path $currentHostPath "node_modules"
            if (Test-Path $nodeModulesMountPoint) {
                # Redirect node_modules into artifacts/claude-docker/node_modules so it
                # persists across container rebuilds with consistent permissions.
                $nodeModulesHostPath = Join-Path $currentHostPath "artifacts" "claude-docker" "node_modules"
                $volumeMounts += New-VolumeMount $nodeModulesHostPath "$dockerProjectPath/node_modules" -EnsureExists
            }
        }

        # Claude config mounts. The host's ~/.claude/{commands,skills}/team links
        # (created by `ai install`) come through this parent mount. On Windows the
        # links are NTFS junctions, which Docker Desktop resolves transparently —
        # so AgentCli's shared commands/skills are visible without an extra mount.
        # On Linux/macOS/WSL the links are POSIX symlinks whose target is a host
        # path that doesn't exist inside the container, so they would dangle;
        # we re-mount AgentCli's source folders explicitly to fill them in.
        $volumeMounts += New-VolumeMount "$homeDir/.claude" "/home/claude/.claude"
        if ($currentOS -ne "Windows") {
            foreach ($folder in @("commands", "skills")) {
                $hostPath = Join-Path $scriptDir ".claude" $folder
                if (Test-Path $hostPath) {
                    $volumeMounts += New-VolumeMount $hostPath "/home/claude/.claude/$folder/team" -ReadOnly
                }
            }
        }

        # Handle .claude.json mounting
        $claudeJsonPath = "$homeDir/.claude.json"
        if ($env:AC_CLAUDE_ISOLATE -iin "true", "1") {
            # Isolated mode: copy .claude.json to a unique file per instance
            $instanceId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
            $isolateDir = Join-Path $projectRoot "artifacts" "claude-docker"
            if (-not (Test-Path $isolateDir)) {
                New-Item -ItemType Directory -Path $isolateDir -Force | Out-Null
            }
            if (Test-Path $claudeJsonPath) {
                $isolatedClaudeJson = Join-Path $isolateDir ".claude-$instanceId.json"
                Copy-Item $claudeJsonPath $isolatedClaudeJson
                $volumeMounts += New-VolumeMount $isolatedClaudeJson "/home/claude/.claude.json"
            }
            Write-Host "Claude isolation: enabled (instance: $instanceId)" -ForegroundColor Cyan
        } else {
            # Normal mode: mount .claude.json directly from host
            if (Test-Path $claudeJsonPath) {
                $volumeMounts += New-VolumeMount $claudeJsonPath "/home/claude/.claude.json"
            }
        }

        # Git config mount
        $gitConfigPath = "$homeDir/.gitconfig"
        if (Test-Path $gitConfigPath) {
            $volumeMounts += New-VolumeMount $gitConfigPath "/home/claude/.gitconfig" -ReadOnly
        }

        # SSH keys mount (read-only; copied to ~/.ssh with strict perms inside container)
        # Mounted to .ssh-host (not .ssh) because Windows bind-mounts expose loose perms
        # that OpenSSH refuses. The "os" branch copies + chmods on container start.
        $sshPath = "$homeDir/.ssh"
        if (Test-Path $sshPath) {
            $volumeMounts += New-VolumeMount $sshPath "/home/claude/.ssh-host" -ReadOnly
        }

        # Gcloud config mount
        $gcloudConfigPath = if ($currentOS -eq "Windows") { "$env:APPDATA/gcloud" } else { "$homeDir/.config/gcloud" }
        if (Test-Path $gcloudConfigPath) {
            $volumeMounts += New-VolumeMount $gcloudConfigPath "/home/claude/.config/gcloud" -ReadOnly
        }

        # GCP key folder mount (for GOOGLE_APPLICATION_CREDENTIALS)
        $gcpKeyPath = "$homeDir/.gcp"
        if (Test-Path $gcpKeyPath) {
            $volumeMounts += New-VolumeMount $gcpKeyPath "/home/claude/.gcp" -ReadOnly
        }

        # .actual folder mount (project-agnostic; contains prompts and other config)
        $actualPath = "$homeDir/.actual"
        if (Test-Path $actualPath) {
            $volumeMounts += New-VolumeMount $actualPath "/home/claude/.actual" -ReadOnly
        }

        # Goose config mount (only when the goose agent is selected). Goose in the
        # container reads ~/.config/goose/config.yaml; the host folder that DIRECTLY
        # holds config.yaml is OS-specific (%APPDATA%\Block\goose\config on Windows,
        # ~/.config/goose elsewhere), so it maps 1:1 onto the container path.
        # Read-only — the container's LM Studio / provider setup carries over. The
        # config's localhost:1234 endpoint is made reachable by the host-port proxy
        # below (Docker Desktop's --network host attaches to the Linux VM, not the
        # Windows/macOS host, so localhost:1234 would otherwise hit nothing).
        if ($cli -eq "goose") {
            $gooseConfigDir = Get-GooseConfigDir
            if ($gooseConfigDir) {
                $volumeMounts += New-VolumeMount $gooseConfigDir "/home/claude/.config/goose" -ReadOnly
            }
        }

        # OpenCode config mount (only when the opencode agent is selected). OpenCode
        # reads ~/.config/opencode/opencode.json(c); the host dir maps 1:1 onto the
        # container path. Read-only — a localhost:1234 LM Studio endpoint in the
        # config is made reachable by the host-port proxy below.
        if ($cli -eq "opencode") {
            $openCodeConfigDir = Get-OpenCodeConfigDir
            if ($openCodeConfigDir) {
                $volumeMounts += New-VolumeMount $openCodeConfigDir "/home/claude/.config/opencode" -ReadOnly
            }
        }

        # Calculate Docker working directory
        $dockerWorkDir     = "$dockerProjectPath$relativePath"
        # All projects now share the AgentCli Docker image — no per-project Dockerfile.
        $imageName         = "claude-$($agentCliFolderName.ToLower())"
        # Container reuse / cleanup is still per-project (or per-worktree); for out-of-tree
        # projects the sanitized folder name doubles as the container base name; for the
        # AtRoot case the AC_ProjectRoot leaf is the natural identifier.
        $containerBaseName = if ($atRoot -or $isOutOfTree) {
            $currentFolderName.ToLower()
        } elseif ($worktree) {
            "$($projectName.ToLower())-$($worktree.ToLower())"
        } else {
            $projectName.ToLower()
        }
        $containerName     = "$containerBaseName-$(Get-Date -Format 'MMdd-HHmmss')"
        # Always re-invoke AgentCli's ai.ps1 (consumer projects no longer carry a copy).
        $dockerScriptPath = "/proj/$agentCliFolderName/ai.ps1"

        if ($dryRun) {
            Write-Host "Container: $containerName"
            Write-Host "Working Directory: $dockerWorkDir @ /proj"
        }

        # Build args for the script running in Docker. The agent selector is prepended
        # so the inner pwsh ai.ps1 parses it back into $cli and runs the right binary.
        $dockerScriptArgs = @($cli, "os", "from-docker")
        if ($dryRun) { $dockerScriptArgs += "--dry-run" }
        if ($debugMode) { $dockerScriptArgs += "--debug" }
        $dockerScriptArgs += $cliArgs

        # Container reuse logic (default unless --new is specified)
        if (-not $newContainer) {
            $existingContainers = @(docker ps --filter "label=worktree=$containerBaseName" --format "{{.ID}}`t{{.Names}}`t{{.Status}}" 2>$null | Where-Object { $_ })
            $selectedContainer = $null
            if ($existingContainers.Count -eq 1) {
                $selectedContainer = $existingContainers[0]
            } elseif ($existingContainers.Count -gt 1) {
                $displayItems = $existingContainers | ForEach-Object { $p = $_ -split "`t"; "$($p[1]) ($($p[2]))" }
                $idx = Read-UserSelection `
                    -Title "Multiple containers found for '$containerBaseName'" `
                    -Items $displayItems `
                    -Prompt "Select container"
                $selectedContainer = $existingContainers[$idx]
            }
            if ($selectedContainer) {
                $parts = $selectedContainer -split "`t"
                $containerId          = $parts[0]
                $containerDisplayName = $parts[1]
                if ($dryRun) {
                    Write-Host ""
                    Write-Host "=== DRY RUN (Docker - reuse) ===" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "Would reuse container: $containerDisplayName" -ForegroundColor Cyan
                    Write-Host "Command:" -ForegroundColor Cyan
                    Write-Host "  docker exec -it -w $dockerWorkDir $containerId pwsh $dockerScriptPath $($dockerScriptArgs -join ' ')"
                    Write-Host ""
                } else {
                    Write-Host "Reusing container: $containerDisplayName" -ForegroundColor Cyan
                    $execArgs = @("exec", "-it", "-w", $dockerWorkDir, $containerId, "pwsh", $dockerScriptPath) + $dockerScriptArgs
                    & docker @execArgs
                }
                exit $LASTEXITCODE
            }
            # No container selected - fall through to create new
        }

        # Build project path env vars for Docker. $dockerProjectPath was set up top
        # ("/proj" for AtRoot, "/proj/<folder>" otherwise) and reused for $dockerWorkDir.
        $projectEnvVars = @(
            "-e", "AC_ProjectPath=$dockerProjectPath",
            "-e", "AC_Worktree=$worktree"
        )

        # Collect environment variables to propagate:
        # - Variables with __ in their names (e.g., ChatSettings__OpenAIApiKey)
        # - AC_GITHUB_TOKEN, GH_TOKEN, NPM_READ_TOKEN, GOOGLE_CLOUD_PROJECT
        # - ActualChat_*, ActualLab_*, Claude_* variables
        $propagatedEnvVars = @()
        Get-ChildItem env: | ForEach-Object {
            $name  = $_.Name
            $value = $_.Value
            if ($name -match '__' -or
                $name -eq 'AC_GITHUB_TOKEN' -or
                $name -eq 'GH_TOKEN' -or
                $name -eq 'NPM_READ_TOKEN' -or
                $name -eq 'GOOGLE_CLOUD_PROJECT' -or
                $name -like 'ActualChat_*' -or
                $name -like 'ActualLab_*' -or
                $name -like 'Claude_*') {
                $propagatedEnvVars += "-e"
                $propagatedEnvVars += "$name=$value"
            }
        }

        # Set GOOGLE_APPLICATION_CREDENTIALS to container path (host path won't work)
        if ($env:GOOGLE_APPLICATION_CREDENTIALS) {
            $propagatedEnvVars += "-e"
            $propagatedEnvVars += "GOOGLE_APPLICATION_CREDENTIALS=/home/claude/.gcp/key.json"
        }

        # Build docker run command - run this script with "os" argument inside container
        # Uses --network host so localhost inside container = host's localhost
        $dockerArgs = @(
            "run", "-it", "--rm"
            "--network", "host"
            "--name", $containerName
            "--label", "worktree=$containerBaseName"
        )

        # Chrome DevTools MCP: pass debug port so the MCP wrapper script can resolve the host IP
        # Docker Desktop on Windows uses a VM, so localhost/127.0.0.1 won't reach the host.
        # Chrome rejects non-IP Host headers, so the wrapper resolves host.docker.internal to an IPv4 IP.

        # PulseAudio for voice mode: auto-start if installed but stopped
        [PulseAudioSetup]::new().EnsureRunning()
        $pulseServer = if ($currentOS -in "macOS", "Windows") { "tcp:host.docker.internal:4713" } else { "tcp:localhost:4713" }
        $audioEnvVars = @(
            "-e", "PULSE_SERVER=$pulseServer"
        )

        # Host-port proxies (macOS only). On Docker Desktop --network host attaches
        # the container to the Linux VM's netns, not the host, so host-only services
        # (e.g. LM Studio) aren't at localhost. The in-container startup runs a socat
        # forwarder per listed port so localhost:<port> reaches host.docker.internal:<port>.
        # (LM Studio must serve on 0.0.0.0, since host.docker.internal is a non-loopback IP.)
        #
        # NOT used on Windows: there we rely on WSL mirrored networking
        # (.wslconfig -> networkingMode=mirrored), which makes Docker Desktop's WSL2
        # backend share the Windows loopback — so --network host reaches the host's
        # localhost:1234 directly (LM Studio can stay bound to 127.0.0.1). Running the
        # proxy there is worse than useless: socat would bind :1234 on the shared
        # loopback and its host.docker.internal:1234 upstream loops back onto itself.
        # Native-Linux docker also needs nothing — localhost already IS the host.
        $hostProxyEnvVars = @()
        if ($cli -in "goose", "opencode" -and $currentOS -eq "macOS") {
            $lmStudioPort = if ($env:AC_LMSTUDIO_PORT) { $env:AC_LMSTUDIO_PORT } else { "1234" }
            $hostProxyEnvVars = @("-e", "AC_HOST_PROXY_PORTS=$lmStudioPort")
        }

        $dockerArgs += $volumeMounts + $propagatedEnvVars + $audioEnvVars + $hostProxyEnvVars + @(
            "-e", "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY"
            "-e", "DISABLE_AUTOUPDATER=1"
            "-e", "DOTNET_SYSTEM_NET_DISABLEIPV6=1"
            "-e", "AC_ProjectRoot=/proj"
            "-e", "AC_CHROME_DEBUG_PORT=$ChromeDebugPort"
        ) + $projectEnvVars

        $dockerArgs += @(
            "-w", $dockerWorkDir
            $imageName
            "pwsh", $dockerScriptPath
        ) + $dockerScriptArgs

        if ($dryRun) {
            # Build env vars hashtable for display
            $dockerEnvVars = @{
                "AC_ProjectRoot"    = "/proj"
                "AC_ProjectPath"    = $dockerProjectPath
                "AC_OS"             = "Linux in Docker"
                "AC_Worktree"       = $worktree
            }

            Write-Host ""
            Write-Host "=== DRY RUN (Docker) ===" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Environment variables:" -ForegroundColor Cyan
            foreach ($key in $dockerEnvVars.Keys | Sort-Object) {
                Write-Host "  $key=$($dockerEnvVars[$key])"
            }
            Write-Host ""
            Write-Host "Command:" -ForegroundColor Cyan
            $dryCmd = ("$cliCommand " + ((@($cliBaseArgs) + @($cliSandboxedArgs) + $cliArgs) -join ' ')).Trim()
            Write-Host "  $dryCmd"
            Write-Host ""
            Write-Host "Docker launch command:" -ForegroundColor Cyan
            Write-Host "  docker $($dockerArgs -join ' ')"
            Write-Host ""
        } else {
            # On Windows, we're already in wt (handled at script start)
            & docker @dockerArgs
        }
    }

    "audio" {
        [PulseAudioSetup]::new().Setup()
    }

    "chrome" {
        if ($currentOS -eq "Windows") {
            $exePaths = @(
                "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
            )
            $defaultProfileDir = "$env:LOCALAPPDATA\Google\Chrome\Playwright"
            $anonProfileBase   = "$env:LOCALAPPDATA\Google\Chrome\Playwright-anon"
        } elseif ($currentOS -eq "macOS") {
            $exePaths = @("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
            $defaultProfileDir = "$env:HOME/Library/Application Support/Google/Chrome Playwright"
            $anonProfileBase   = "$env:HOME/Library/Application Support/Google/Chrome Playwright-anon"
        } else {
            $exePaths = @(
                "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable",
                "/usr/bin/chromium-browser", "/usr/bin/chromium"
            )
            $defaultProfileDir = "$env:HOME/.config/google-chrome-playwright"
            $anonProfileBase   = "$env:HOME/.config/google-chrome-playwright-anon"
        }
        $exePath = $exePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $exePath) {
            Write-Error "Chrome not found. Please install Google Chrome."
            exit 1
        }
        Start-DebugBrowsers `
            -BrowserName "Chrome" `
            -ExePath $exePath `
            -DefaultProfileDir $defaultProfileDir `
            -AnonProfileBase $anonProfileBase `
            -StartPort $ChromeDebugStartPort `
            -Count $ChromeInstanceCount `
            -UseAnonymous $ChromeUseAnonymousProfile `
            -ExtraArgs $ChromeExtraArgs
    }

    "edge" {
        if ($currentOS -eq "Windows") {
            $exePaths = @(
                "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
            )
            $defaultProfileDir = "$env:LOCALAPPDATA\Microsoft\Edge\Playwright"
            $anonProfileBase   = "$env:LOCALAPPDATA\Microsoft\Edge\Playwright-anon"
        } elseif ($currentOS -eq "macOS") {
            $exePaths = @("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
            $defaultProfileDir = "$env:HOME/Library/Application Support/Microsoft Edge Playwright"
            $anonProfileBase   = "$env:HOME/Library/Application Support/Microsoft Edge Playwright-anon"
        } else {
            $exePaths = @(
                "/usr/bin/microsoft-edge", "/usr/bin/microsoft-edge-stable",
                "/usr/bin/microsoft-edge-beta", "/usr/bin/microsoft-edge-dev"
            )
            $defaultProfileDir = "$env:HOME/.config/microsoft-edge-playwright"
            $anonProfileBase   = "$env:HOME/.config/microsoft-edge-playwright-anon"
        }
        $exePath = $exePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $exePath) {
            Write-Error "Microsoft Edge not found. Please install Microsoft Edge."
            exit 1
        }
        Start-DebugBrowsers `
            -BrowserName "Edge" `
            -ExePath $exePath `
            -DefaultProfileDir $defaultProfileDir `
            -AnonProfileBase $anonProfileBase `
            -StartPort $EdgeDebugStartPort `
            -Count $EdgeInstanceCount `
            -UseAnonymous $EdgeUseAnonymousProfile `
            -ExtraArgs $EdgeExtraArgs
    }
}
