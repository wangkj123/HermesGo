param(
    [string]$WorkspaceDir = (Join-Path $PSScriptRoot 'workspaces\HermesGo-sandbox')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-DirectHttpRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [int]$TimeoutSec = 5
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

    try {
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = $content
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Stop-PortListeners {
    param([int[]]$Ports)

    foreach ($port in $Ports) {
        $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($listeners) {
            $listeners |
                Select-Object -ExpandProperty OwningProcess -Unique |
                ForEach-Object {
                    if ($_ -and $_ -ne $PID) {
                        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
                    }
                }
        }
    }

    Start-Sleep -Seconds 1
}

function Wait-HttpReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [int]$TimeoutSec = 90,

        [string]$Needle = ''
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-DirectHttpRequest -Uri $Uri -TimeoutSec 5
            if ($response.StatusCode -eq 200) {
                if ([string]::IsNullOrWhiteSpace($Needle) -or $response.Content -match [regex]::Escape($Needle)) {
                    return $response
                }
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 500
    }

    throw ('Timed out waiting for: {0}' -f $Uri)
}

function Assert-LauncherSurface {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExePath
    )

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class HermesGoNative
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@
    $process = Start-Process -FilePath $ExePath -PassThru
    try {
        $window = $null
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and -not $window) {
            Start-Sleep -Milliseconds 500
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $condition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                'HermesGo 启动器')
            $window = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
        }

        if (-not $window) {
            throw 'launcher window not found'
        }

        $all = $window.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)

        $beginnerComboBox = $null
        $uiSuiteListBox = $null
        $startButton = $null
        $comboBoxCount = 0
        $listBoxCount = 0
        $checkBoxCount = 0
        $startButtonCount = 0
        for ($i = 0; $i -lt $all.Count; $i++) {
            $element = $all.Item($i)
            $className = $element.Current.ClassName
            $name = $element.Current.Name
            $controlType = $element.Current.ControlType

            if ($className -like 'WindowsForms10.COMBOBOX*') {
                $comboBoxCount++
            }
            if (-not $beginnerComboBox -and $className -like 'WindowsForms10.COMBOBOX*' -and $name -eq 'Beginner: Local Start') {
                $beginnerComboBox = $element
            }
            elseif (-not $uiSuiteListBox -and $className -like 'WindowsForms10.LISTBOX*') {
                $uiSuiteListBox = $element
                $listBoxCount++
            }
            elseif ($className -like 'WindowsForms10.BUTTON*' -and (
                $name -eq '启动后自动打开浏览器' -or
                $name -eq '启动后打开 Hermes CLI 聊天窗口（仅 00）')) {
                $checkBoxCount++
            }
            elseif ($className -like 'WindowsForms10.BUTTON*' -and $name -eq '启动' -and $element.Current.BoundingRectangle.Top -lt 500) {
                $startButtonCount++
                if (-not $startButton) {
                    $startButton = $element
                }
            }
        }

        if (-not $beginnerComboBox) {
            throw 'launcher beginner combo box not found'
        }
        if (-not $startButton) {
            throw 'launcher start button not found'
        }
        if ($startButtonCount -ne 1) {
            throw ('launcher should expose exactly one startup button, found: {0}' -f $startButtonCount)
        }
        if (-not $uiSuiteListBox) {
            throw 'launcher UI suite list box not found'
        }
        $listBoxHandle = $uiSuiteListBox.Current.NativeWindowHandle
        if ($listBoxHandle -eq 0) {
            throw 'launcher UI suite list box does not expose a native window handle'
        }
        $uiSuiteItemCount = [int]([HermesGoNative]::SendMessage(
            [IntPtr]$listBoxHandle,
            0x018B,
            [IntPtr]::Zero,
            [IntPtr]::Zero).ToInt64())
        if ($uiSuiteItemCount -ne 8) {
            throw ('launcher UI suite list should expose 8 items, found: {0}' -f $uiSuiteItemCount)
        }
        if ($checkBoxCount -lt 2) {
            throw ('launcher should expose the browser/chat checkboxes, found: {0}' -f $checkBoxCount)
        }
        $titleLabel = $window.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                '请选择一个启动方式')))
        if (-not $titleLabel) {
            throw 'launcher main title not found'
        }

        $mainActionTitle = $window.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                'HermesGo 主启动与维护'))
        )
        if (-not $mainActionTitle) {
            throw 'launcher main action section not found'
        }

        $uiSuiteTitle = $window.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                'UI 套件共 8 项（00 原版 + 01-07）'))
        )
        if (-not $uiSuiteTitle) {
            throw 'launcher UI suite section not found'
        }

        if ($comboBoxCount -lt 1) {
            throw ('launcher should expose the main launcher combo box, found: {0}' -f $comboBoxCount)
        }
    }
    finally {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

$resolvedWorkspace = [System.IO.Path]::GetFullPath($WorkspaceDir)
if (-not (Test-Path -LiteralPath $resolvedWorkspace)) {
    throw ('workspace not found: {0}' -f $resolvedWorkspace)
}

$appRoot = Join-Path $resolvedWorkspace 'app'
$scriptsRoot = Join-Path $appRoot 'scripts'
$toolsRoot = Join-Path $appRoot 'tools'
$runtimeBinDir = Join-Path $appRoot 'runtime\bin'
$exePath = Join-Path $resolvedWorkspace 'HermesGo.exe'

$rootFiles = @(Get-ChildItem -LiteralPath $resolvedWorkspace -File | Select-Object -ExpandProperty Name)
$expectedRootFiles = @('HermesGo.exe', 'README.md')
if ($rootFiles.Count -ne $expectedRootFiles.Count -or (Compare-Object -ReferenceObject $expectedRootFiles -DifferenceObject $rootFiles)) {
    throw ('workspace root should only contain HermesGo.exe and README.md as files, found: {0}' -f (($rootFiles | Sort-Object) -join ', '))
}

$requiredPaths = @(
    'HermesGo.exe',
    'README.md',
    'app',
    'app\docs\README.md',
    'app\ui-suite',
    'app\ui-suite\docs\README.md',
    'app\ui-suite\apps\02-mission-control',
    'app\assets\icons\HermesGo.ico',
    'app\home',
    'app\data\ollama',
    'app\runtime\hermes-agent',
    'app\tools\codex.cmd',
    'app\scripts\HermesGo.bat',
    'app\scripts\Start-HermesGo.ps1',
    'app\scripts\Verify-HermesGo.ps1'
)

$missing = @()
foreach ($relativePath in $requiredPaths) {
    $candidate = Join-Path $resolvedWorkspace $relativePath
    if (-not (Test-Path -LiteralPath $candidate)) {
        $missing += $relativePath
    }
}

if ($missing.Count -gt 0) {
    throw ('workspace is missing required paths: {0}' -f ($missing -join ', '))
}

$env:PATH = [string]::Join(';', @($toolsRoot, $runtimeBinDir, $env:PATH))
$env:HERMESGO_SKIP_UPDATE = '1'

$codexResolved = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codexResolved) {
    throw 'workspace codex compatibility launcher not found in PATH'
}

$codexCmdText = Get-Content -LiteralPath (Join-Path $toolsRoot 'codex.cmd') -Raw -Encoding utf8
if ($codexCmdText -match '(?s)if /i "%~1"=="login" \(\s*"%PYTHON_EXE%" -m hermes_cli\.main auth add openai-codex --device-auth') {
    throw 'workspace codex compatibility launcher still hard-codes device-auth for plain login'
}
if ($codexCmdText -notmatch '(?s)if /i "%~1"=="login" \(\s*if /i "%~2"=="--device-auth"') {
    throw 'workspace codex compatibility launcher does not preserve optional device-auth handling'
}

$codexOutput = & cmd /c "call `"$toolsRoot\codex.cmd`"" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ('workspace codex compatibility launcher failed with exit code {0}' -f $LASTEXITCODE)
}
if (($codexOutput -join [Environment]::NewLine) -notmatch 'HermesGo codex compatibility launcher') {
    throw 'workspace codex compatibility launcher did not print the expected banner'
}

$bootstrapText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\HermesGoBootstrap.cs') -Raw -Encoding utf8
if ($bootstrapText -match 'ResolveToolPath\("codex\.cmd"\)') {
    throw 'launcher still shells out to codex.cmd for OpenAI login'
}
if ($bootstrapText -notmatch 'RunBlockingOpenAiAuthCommand\("auth", "add", "openai-codex"\)') {
    throw 'launcher no longer invokes the bundled OpenAI auth command directly'
}
if ($bootstrapText -notmatch 'PromptForCloudConfiguration\(cloudDisplayName\)') {
    throw 'launcher no longer prompts before starting cloud login when Codex auth is missing'
}
if ($bootstrapText -notmatch 'BuildUiSuitePanel\(\);') {
    throw 'launcher bootstrap does not build the visible UI suite panel'
}
if ($bootstrapText -notmatch 'MainAction = GetSelectedLauncherOption\(\)' -or
    $bootstrapText -notmatch 'TryApplyUiSuitePreset\(selection\.MainAction\)' -or
    $bootstrapText -notmatch 'ShouldUseUiSuiteLaunch\(\)') {
    throw 'launcher bootstrap does not preserve the preset-plus-UI combination launch behavior.'
}
if ($bootstrapText -notmatch 'Text = "请选择一个启动方式"') {
    throw 'launcher bootstrap does not expose the classic startup title'
}
if ($bootstrapText -notmatch 'Text = "HermesGo 主启动与维护"') {
    throw 'launcher bootstrap does not expose the main action header'
}
if ($bootstrapText -notmatch 'Text = "Beginner: Local Start"') {
    throw 'launcher bootstrap does not expose the Beginner: Local Start startup entry'
}
if ($bootstrapText -notmatch 'Text = "Cloud: GPT-5\.4 Mini"') {
    throw 'launcher bootstrap does not expose the Cloud: GPT-5.4 Mini startup entry'
}
if ($bootstrapText -notmatch 'Text = "UI 套件共 8 项（00 原版 \+ 01-07）"') {
    throw 'launcher bootstrap does not expose the UI suite section title'
}

$marker = Join-Path $resolvedWorkspace 'app\docs\TEST_WORKSPACE.txt'
if (-not (Test-Path -LiteralPath $marker)) {
    throw 'workspace marker missing: app\docs\TEST_WORKSPACE.txt'
}

$launcherActionsPath = Join-Path $appRoot 'home\launcher-actions.txt'
$launcherActionsText = Get-Content -LiteralPath $launcherActionsPath -Raw -Encoding utf8
if ($launcherActionsText -notmatch '; HermesGo custom launcher actions' -or
    $launcherActionsText -notmatch '; UI 套件主入口已经集成到 HermesGo\.exe 里。' -or
    $launcherActionsText -match '(?m)^(?![;#\s]).+\|.+\|.+\|.+\|.+$') {
    throw 'launcher actions template does not match the packaged comment-only launcher-actions.txt.'
}

$configText = Get-Content -LiteralPath (Join-Path $appRoot 'home\config.yaml') -Raw -Encoding utf8
if ($configText -notmatch '(?m)^\s*provider:\s*"ollama"\s*$' -or
    $configText -notmatch '(?m)^\s*default:\s*"gemma:2b"\s*$' -or
    $configText -notmatch '(?m)^\s*base_url:\s*"http://127\.0\.0\.1:11434/v1"\s*$') {
    throw 'home\config.yaml should default to ollama / gemma:2b / 11434.'
}

$rootReadmeText = Get-Content -LiteralPath (Join-Path $resolvedWorkspace 'README.md') -Raw -Encoding utf8
if ($rootReadmeText -notmatch [regex]::Escape('Double-click `HermesGo.exe`. It opens the classic launcher with a selectable action box for beginner start, OpenAI GPT-5.4 mini, Dashboard / Config, and utility actions for model switching, self-check, logs, config folders, and custom launcher actions from `home\launcher-actions.txt`. The launcher keeps local start as the default; cloud is still available as an explicit choice.') -or
    $rootReadmeText -notmatch [regex]::Escape('`HermesGo.exe` exposes a visible `UI 套件共 8 项（00 原版 + 01-07）` section instead of hiding the suite behind a utility entry')) {
    throw 'root README does not mention the classic launcher and visible UI suite section.'
}

$bundleMatches = Select-String -Path (Join-Path $appRoot 'runtime\hermes-agent\hermes_cli\web_dist\assets\*.js') -Pattern '"/selfext"' -SimpleMatch -ErrorAction SilentlyContinue
if ($bundleMatches) {
    throw 'SelfExt route string is still present in the packaged dashboard bundle.'
}

try {
    Stop-PortListeners -Ports @(9119, 11434, 18900)
    Assert-LauncherSurface -ExePath $exePath

    $launcherLog = Join-Path $appRoot 'logs\update\HermesGo-bootstrap.log'
    if (-not (Test-Path -LiteralPath $launcherLog)) {
        throw ('Launcher debug log not found: {0}' -f $launcherLog)
    }

    Stop-PortListeners -Ports @(9119, 11434)

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot 'Verify-HermesGo.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw ('Verify-HermesGo.ps1 failed with exit code {0}' -f $LASTEXITCODE)
    }
}
finally {
    Stop-PortListeners -Ports @(9119, 11434, 18900)
}

Write-Host "[HermesGo test] workspace verified: $resolvedWorkspace"
