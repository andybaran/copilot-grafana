<#
.SYNOPSIS
  Windows operations wrapper for the Copilot CLI Token Observability stack.

.DESCRIPTION
  PowerShell parity with the macOS/Linux Makefile. Drives `podman compose`
  (override with -ComposeExe / -ComposeArgs, e.g. for Docker Desktop).

.EXAMPLE
  .\make.ps1 up
  .\make.ps1 backfill
  .\make.ps1 traces
  .\make.ps1 install        # auto-start at logon via Scheduled Task
  .\make.ps1 -ComposeExe docker -ComposeArgs compose up
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'up', 'traces', 'down', 'restart', 'logs', 'ps',
        'backfill', 'migrate', 'psql', 'urls', 'install', 'uninstall')]
    [string]$Target = 'help',

    [string]$ComposeExe = 'podman',
    [string[]]$ComposeArgs = @('compose')
)

$ErrorActionPreference = 'Stop'
$RepoDir   = $PSScriptRoot
$TaskName  = 'CopilotObservability'

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
    Push-Location -LiteralPath $RepoDir
    try { & $ComposeExe @ComposeArgs @Rest }
    finally { Pop-Location }
}

# COPILOT_HOME, forward-slash normalized so the drive-letter colon survives the
# compose volume mount on Windows.
function Get-CopilotHome {
    $home = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
    return ($home -replace '\\', '/')
}

switch ($Target) {
    'help' {
        @'
Copilot CLI Token Observability - Windows operations (make.ps1)

  up          Start the core stack (postgres, collector, prometheus, grafana)
  traces      Start the stack WITH Tempo trace storage
  down        Stop the stack (keep data volumes)
  restart     Restart the core stack
  logs        Tail logs from all services
  ps          Show container status
  backfill    Parse ~/.copilot/session-state/*/events.jsonl into Postgres (idempotent)
  migrate     Apply postgres/migrations/*.sql to the running database (idempotent)
  psql        Open a psql shell to the usage database
  urls        Print service URLs
  install     Auto-start the stack at logon (Scheduled Task)
  uninstall   Remove the logon Scheduled Task

Compose engine: {0} {1}
'@ -f $ComposeExe, ($ComposeArgs -join ' ')
    }

    'up' {
        Invoke-Compose up -d
        Write-Host 'Grafana: http://localhost:3000  (anonymous admin)'
    }

    'traces'  { Invoke-Compose --profile traces up -d }
    'down'    { Invoke-Compose --profile traces --profile tools down }
    'restart' { Invoke-Compose restart }
    'logs'    { Invoke-Compose logs -f --tail=100 }
    'ps'      { Invoke-Compose ps }

    'backfill' {
        $env:COPILOT_HOME = Get-CopilotHome
        Invoke-Compose --profile tools run --rm backfill
    }

    'migrate' {
        Get-ChildItem -LiteralPath (Join-Path $RepoDir 'postgres\migrations') -Filter '*.sql' |
            Sort-Object Name | ForEach-Object {
                Write-Host "applying $($_.Name)"
                Get-Content -LiteralPath $_.FullName -Raw |
                    & $ComposeExe @ComposeArgs exec -T postgres `
                        psql -v ON_ERROR_STOP=1 -U copilot -d copilot_usage
                if ($LASTEXITCODE -ne 0) { throw "migration failed: $($_.Name)" }
            }
    }

    'psql' { Invoke-Compose exec postgres psql -U copilot -d copilot_usage }

    'urls' {
        @'
Grafana    http://localhost:3000
Prometheus http://localhost:9090
Collector  http://localhost:4318 (OTLP/HTTP), :4317 (gRPC), :8889 (/metrics)
Tempo      http://localhost:3200 (only with 'make.ps1 traces')
'@
    }

    'install' {
        $startup  = Join-Path $RepoDir 'scripts\startup.ps1'
        $template = Get-Content -LiteralPath (Join-Path $RepoDir 'scripts\startup.ps1.template') -Raw
        $argsList = ($ComposeArgs | ForEach-Object { "'$_'" }) -join ', '
        $template = $template.
            Replace('__REPO_DIR__', $RepoDir).
            Replace('__COMPOSE_EXE__', $ComposeExe).
            Replace('__COMPOSE_ARGS__', $argsList)
        Set-Content -LiteralPath $startup -Value $template -Encoding UTF8

        $pwsh = (Get-Process -Id $PID).Path  # the running PowerShell host (pwsh.exe or powershell.exe)
        $action  = New-ScheduledTaskAction -Execute $pwsh `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startup`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        try {
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Settings $settings -Description 'Start Copilot observability stack at logon' `
                -ErrorAction Stop | Out-Null
            Write-Host "Installed Scheduled Task '$TaskName'. Stack will start at logon."
        } catch {
            Write-Warning "Could not register the Scheduled Task: $($_.Exception.Message)"
            Write-Host "Registering a logon task can require an elevated shell or may be blocked" `
                "by policy. Re-run '.\\make.ps1 install' from an Administrator PowerShell, or" `
                "start the stack manually with '.\\make.ps1 up'."
        }
    }

    'uninstall' {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Removed Scheduled Task '$TaskName'."
        } else {
            Write-Host "Scheduled Task '$TaskName' not found."
        }
    }
}
