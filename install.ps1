$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Config = Join-Path $CodexHome 'config.toml'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'agents') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'skills/cost-aware-development') | Out-Null

if (Test-Path $Config) {
    Copy-Item $Config "$Config.codex-flow.$Stamp.bak"
} else {
    New-Item -ItemType File -Force -Path $Config | Out-Null
}

$text = Get-Content $Config -Raw
$managed = [ordered]@{
    enabled = 'true'
    max_concurrent_threads_per_session = '4'
    default_subagent_model = '"gpt-5.6-luna"'
    default_subagent_reasoning_effort = '"max"'
}

$pattern = '(?ms)^\[agents\]\s*\r?\n(.*?)(?=^\[[^\r\n]+\]\s*$|\z)'
$match = [regex]::Match($text, $pattern)

if ($match.Success) {
    $body = $match.Groups[1].Value
    foreach ($entry in $managed.GetEnumerator()) {
        $keyPattern = '(?m)^\s*' + [regex]::Escape($entry.Key) + '\s*=.*$'
        $line = "$($entry.Key) = $($entry.Value)"
        if ([regex]::IsMatch($body, $keyPattern)) {
            $body = [regex]::Replace($body, $keyPattern, $line)
        } else {
            if ($body.Length -gt 0 -and -not $body.EndsWith("`n")) { $body += "`n" }
            $body += "$line`n"
        }
    }
    $text = $text.Substring(0, $match.Groups[1].Index) + $body + $text.Substring($match.Groups[1].Index + $match.Groups[1].Length)
} else {
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n`n")) { $text += "`n" }
    $text += "[agents]`n"
    foreach ($entry in $managed.GetEnumerator()) {
        $text += "$($entry.Key) = $($entry.Value)`n"
    }
}

Set-Content -Path $Config -Value $text -NoNewline
Copy-Item (Join-Path $RootDir 'templates/agents/luna-explorer.toml') (Join-Path $CodexHome 'agents/luna-explorer.toml') -Force
Copy-Item (Join-Path $RootDir 'templates/agents/luna-implementer.toml') (Join-Path $CodexHome 'agents/luna-implementer.toml') -Force
Copy-Item (Join-Path $RootDir 'templates/skills/cost-aware-development/SKILL.md') (Join-Path $CodexHome 'skills/cost-aware-development/SKILL.md') -Force

Write-Host 'codex-flow installed.'
Write-Host "  config: $Config"
Write-Host "  agents: $(Join-Path $CodexHome 'agents')"
Write-Host "  skill:  $(Join-Path $CodexHome 'skills/cost-aware-development')"
Write-Host ''
Write-Host 'Restart Codex, then use it normally.'
Write-Host 'For the intended parent role, select gpt-5.6-sol with xhigh reasoning.'
