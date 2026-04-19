param(
    [Parameter(Mandatory = $true)]
    [string]$LogFile,

    [string]$Title = 'HermesGo'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.Size = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'HermesGo status'
$titleLabel.AutoSize = $true
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(16, 16)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Waiting for log output...'
$statusLabel.AutoSize = $true
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$statusLabel.Location = New-Object System.Drawing.Point(18, 52)

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ReadOnly = $true
$box.ScrollBars = 'Vertical'
$box.Font = New-Object System.Drawing.Font('Consolas', 10)
$box.Location = New-Object System.Drawing.Point(18, 80)
$box.Size = New-Object System.Drawing.Size(846, 430)
$box.Anchor = 'Top,Bottom,Left,Right'

$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Text = 'Copy Log'
$copyButton.Location = New-Object System.Drawing.Point(18, 525)
$copyButton.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($box.Text)
    $statusLabel.Text = 'Log copied to clipboard.'
})

$openButton = New-Object System.Windows.Forms.Button
$openButton.Text = 'Open Log File'
$openButton.Location = New-Object System.Drawing.Point(110, 525)
$openButton.Add_Click({
    if (Test-Path -LiteralPath $LogFile) {
        Start-Process notepad.exe $LogFile
    }
})

$form.Controls.AddRange(@($titleLabel, $statusLabel, $box, $copyButton, $openButton))

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300

function Update-LogView {
    if (-not (Test-Path -LiteralPath $LogFile)) {
        $statusLabel.Text = "Waiting for $LogFile ..."
        return
    }

    try {
        $text = Get-Content -LiteralPath $LogFile -Raw -Encoding utf8
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $box.Text = $text
            $box.SelectionStart = $box.Text.Length
            $box.ScrollToCaret()
            $lines = $text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $tail = if ($lines.Count -gt 0) { $lines[-1] } else { '' }

            if ($tail -match '(?i)exit code 1|failed|error|exception|fatal|not found') {
                $statusLabel.Text = "Error: $tail"
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
                $form.BackColor = [System.Drawing.Color]::MistyRose
                return
            }

            if ($tail -match '(?i)exit code 0|hello probe succeeded|hermes container launched') {
                $statusLabel.Text = "Ready: $tail"
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
                $form.BackColor = [System.Drawing.Color]::Honeydew
                return
            }

            $statusLabel.Text = 'Live log view.'
            $statusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
            $form.BackColor = [System.Drawing.SystemColors]::Control
        }
    }
    catch {
        $statusLabel.Text = "Log busy, retrying..."
    }
}

$timer.Add_Tick({ Update-LogView })

$form.Add_Shown({
    Update-LogView
    $timer.Start()
})

$form.Add_FormClosed({
    $timer.Stop()
    $timer.Dispose()
})

[void]$form.ShowDialog()
