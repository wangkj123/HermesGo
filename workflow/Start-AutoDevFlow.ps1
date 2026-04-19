param(
    [string]$Project = "HermesGo",
    [string]$Goal = "Rebuild HermesGo team-style automation flow",
    [switch]$SkipVerification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workflowRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $workflowRoot
$runsRoot = Join-Path $workflowRoot "runs"
$latestRunPath = Join-Path $workflowRoot "latest-run.txt"
$latestSummaryPath = Join-Path $workflowRoot "latest-summary.txt"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $runsRoot ("{0}-{1}" -f $runId, $Project)
$activityLog = Join-Path $runDir "activity.log"
$statusPath = Join-Path $runDir "status.json"
$rootProgressLog = Join-Path $repoRoot "logs\agent-progress.md"
$verificationOutputPath = Join-Path $runDir "verification-output.log"
$newline = [Environment]::NewLine

$roles = @(
    "ArchitectureLead",
    "DeliveryManager",
    "Implementer",
    "Supervisor",
    "Tester",
    "Reviewer",
    "Archivist"
)

function New-Utf8File {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($Lines -join $newline), $utf8)
}

function Add-Activity {
    param(
        [string]$Action,
        [string]$Tool,
        [string]$Result,
        [string]$Next
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $activityLines = @(
        "[$timestamp]",
        "Action: $Action",
        "Tool: $Tool",
        "Result: $Result",
        "Next: $Next",
        ""
    )
    Add-Content -LiteralPath $activityLog -Value ($activityLines -join $newline) -Encoding utf8

    $progressLines = @(
        "",
        "### $(Get-Date -Format 'HH:mm')",
        "- Action: $Action",
        "- Tool: $Tool",
        "- Result: $Result",
        "- Next: $Next"
    )
    Add-Content -LiteralPath $rootProgressLog -Value ($progressLines -join $newline) -Encoding utf8
}

function Invoke-CheckScript {
    param([string]$ScriptPath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -KeepTemp"
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd().Trim()
    $stderr = $process.StandardError.ReadToEnd().Trim()
    $process.WaitForExit()

    return [pscustomobject]@{
        Script = $ScriptPath
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

if (-not (Test-Path -LiteralPath $runsRoot)) {
    New-Item -ItemType Directory -Path $runsRoot -Force | Out-Null
}

New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$briefPath = Join-Path $runDir "01-intake.md"
$planPath = Join-Path $runDir "02-plan.md"
$contractsPath = Join-Path $runDir "03-contracts.md"
$implementationPath = Join-Path $runDir "04-implementation.md"
$verificationPath = Join-Path $runDir "05-verification.md"
$reviewPath = Join-Path $runDir "06-review.md"
$summaryPath = Join-Path $runDir "07-summary.md"

New-Utf8File -Path $briefPath -Lines @(
    "# Intake",
    "",
    "- Project: $Project",
    "- Goal: $Goal",
    "- RunId: $runId",
    "- Roles: $($roles -join ', ')",
    "",
    "## Scope",
    "",
    "- Replace single-script execution with a team-style flow",
    "- Separate goal, contract, implementation, supervision, testing, review, and archive",
    "- Start with HermesGo as the first project"
)

Add-Activity -Action "Initialize automated development run" -Tool "Start-AutoDevFlow.ps1" -Result "Created run directory $runDir" -Next "Write plan, contracts, implementation checklist, and verification plan."

New-Utf8File -Path $planPath -Lines @(
    "# Plan",
    "",
    "## Owners",
    "",
    "- ArchitectureLead: define boundaries and success criteria",
    "- DeliveryManager: sequence stages and dependencies",
    "- Implementer: land code changes",
    "- Supervisor: monitor runtime and retries",
    "- Tester: run scripts and collect evidence",
    "- Reviewer: make gate decisions",
    "- Archivist: keep records and summary",
    "",
    "## Phases",
    "",
    "1. Intake",
    "2. Plan",
    "3. Contracts",
    "4. Implementation",
    "5. Supervision",
    "6. Verification",
    "7. Review",
    "8. Archive"
)

New-Utf8File -Path $contractsPath -Lines @(
    "# Contracts",
    "",
    "## Current Project Contract",
    "",
    "- Launcher: HermesGo.bat",
    "  - Non-headless mode only starts the supervisor",
    "  - Headless mode performs Docker startup and hello probe",
    "",
    "- Supervisor: HermesGoSupervisor.ps1",
    "  - Monitors logs, success/failure, timeouts, and retries",
    "",
    "- Status Viewer: HermesGoStatus.ps1",
    "  - Legacy log viewer, not the default entrypoint",
    "",
    "- Verifier",
    "  - Verify-HermesGo.ps1: validates the headless success path",
    "  - Verify-HermesGoSupervisor.ps1: validates supervisor success, failure, and retry behavior"
)

New-Utf8File -Path $implementationPath -Lines @(
    "# Implementation",
    "",
    "## Current Work Items",
    "",
    "- Create project-level workflow structure and role definitions",
    "- Create run directories and process artifact templates",
    "- Add supervisor-specific verification script",
    "- Start one automated development run and store the outputs"
)

$verificationSummary = @()
$reviewDecision = "approve"
$reviewReason = "All configured checks passed."

if (-not $SkipVerification) {
    $scriptsToRun = @(
        (Join-Path $repoRoot "HermesGo\Verify-HermesGo.ps1"),
        (Join-Path $repoRoot "HermesGo\Verify-HermesGoSupervisor.ps1")
    )

    $checkResults = foreach ($script in $scriptsToRun) {
        Invoke-CheckScript -ScriptPath $script
    }

    $outputLines = @()
    foreach ($item in $checkResults) {
        $outputLines += "=== $($item.Script) ==="
        $outputLines += "ExitCode: $($item.ExitCode)"
        $outputLines += "STDOUT:"
        $outputLines += $item.StdOut
        $outputLines += ""
        $outputLines += "STDERR:"
        $outputLines += $item.StdErr
        $outputLines += ""
    }
    New-Utf8File -Path $verificationOutputPath -Lines $outputLines

    foreach ($item in $checkResults) {
        $status = if ($item.ExitCode -eq 0) { "pass" } else { "fail" }
        $verificationSummary += "- $([System.IO.Path]::GetFileName($item.Script)): $status"
    }

    $failedChecks = @($checkResults | Where-Object { $_.ExitCode -ne 0 })
    if ($failedChecks.Count -gt 0) {
        $reviewDecision = "changes_required"
        $reviewReason = "At least one verification script failed."
    }

    Add-Activity -Action "Run verification scripts" -Tool "powershell.exe" -Result ($verificationSummary -join "; ") -Next "Write verification and review artifacts."
}
else {
    New-Utf8File -Path $verificationOutputPath -Lines @("Verification skipped.")
    $verificationSummary += "- verification skipped"
    $reviewDecision = "blocked"
    $reviewReason = "Verification was skipped."
    Add-Activity -Action "Skip verification" -Tool "Start-AutoDevFlow.ps1" -Result "Verification phase skipped by parameter." -Next "Write blocked review result."
}

$verificationLines = @(
    "# Verification",
    "",
    "## Checks",
    ""
) + $verificationSummary + @(
    "",
    "## Evidence",
    "",
    "- verification-output.log"
)
New-Utf8File -Path $verificationPath -Lines $verificationLines

New-Utf8File -Path $reviewPath -Lines @(
    "# Review",
    "",
    "- Decision: $reviewDecision",
    "- Reason: $reviewReason",
    "",
    "## Gate Notes",
    "",
    "- Evidence must include process log, verification output, and summary.",
    "- Supervisor behavior must be independently verified."
)

New-Utf8File -Path $summaryPath -Lines @(
    "# Summary",
    "",
    "- Project: $Project",
    "- Goal: $Goal",
    "- RunId: $runId",
    "- ReviewDecision: $reviewDecision",
    "",
    "## Outputs",
    "",
    "- 01-intake.md",
    "- 02-plan.md",
    "- 03-contracts.md",
    "- 04-implementation.md",
    "- 05-verification.md",
    "- 06-review.md",
    "- 07-summary.md",
    "- verification-output.log",
    "- activity.log"
)

$statusObject = [ordered]@{
    project = $Project
    goal = $Goal
    runId = $runId
    reviewDecision = $reviewDecision
    generatedAt = (Get-Date -Format "s")
    verification = $verificationSummary
}
New-Utf8File -Path $statusPath -Lines @(($statusObject | ConvertTo-Json -Depth 4))

New-Utf8File -Path $latestRunPath -Lines @($runDir)
New-Utf8File -Path $latestSummaryPath -Lines @(
    "AutoDevFlow Latest Result",
    "",
    "Project: $Project",
    "Goal: $Goal",
    "RunId: $runId",
    "RunDir: $runDir",
    "ReviewDecision: $reviewDecision",
    "",
    "Open these files:",
    "- $summaryPath",
    "- $reviewPath",
    "- $verificationPath",
    "- $verificationOutputPath",
    "",
    "Open this folder:",
    "- $runDir"
)

Add-Activity -Action "Finalize automated development run" -Tool "Start-AutoDevFlow.ps1" -Result "Review decision: $reviewDecision" -Next "Archive stable conclusions into docs when needed."

Write-Host "AutoDev run created at: $runDir"
Write-Host "Review decision: $reviewDecision"
