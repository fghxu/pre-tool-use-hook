# Notify-Ask.ps1 — Windows toast + sound notification on "ask" decisions
#
# Fire-and-forget: the notification is launched in a detached background
# process so the hook's stdout/exit path is never blocked. Any failure is
# caught and written to stderr as a warning — the decision is never changed.
#
# Mock mode (for testing): when PRETOOLHOOK_ASKNOTIFY_MOCK is set to a
# directory path, the notifier writes "<dir>\ask-notified.txt" (containing
# the decision reason) instead of popping a real toast/sound. Tests assert
# on the marker file's presence/absence.

function Send-AskNotification {
    <#
    .SYNOPSIS
        Fires a Windows toast notification + sound when the hook decision is "ask".
    .DESCRIPTION
        Non-blocking: spawns a detached PowerShell process that shows the toast
        and plays the sound. Returns immediately. Any error is caught and
        logged to stderr — the hook decision is never affected.

        Trigger: ClassifyResult.Decision -eq 'ask' AND config ask_notification.enabled.
        Config block (compiled under $config._compiled.askNotification):
            Enabled   : bool (default $true) — master switch
            Popup     : bool (default $true) — show toast
            Sound     : bool (default $true) — play sound
            SoundFile : string (default '') — path to .wav; empty = [console]::beep
    .PARAMETER ClassifyResult
        The classification result object (must have .Decision and .Reason).
    .PARAMETER Config
        The loaded config object (uses ._compiled.askNotification).
    #>
    param(
        [PSCustomObject]$ClassifyResult,
        [PSCustomObject]$Config
    )

    # Gate 1: decision must be "ask"
    if ($ClassifyResult.Decision -ne 'ask') { return }

    # Gate 2: config must exist and be enabled
    $an = $null
    if ($Config -and $Config._compiled -and $Config._compiled.askNotification) {
        $an = $Config._compiled.askNotification
    }
    if (-not $an -or -not $an.Enabled) { return }

    # Mock mode: write a marker file instead of a real toast (for testing)
    $mockDir = $env:PRETOOLHOOK_ASKNOTIFY_MOCK
    if ($mockDir) {
        try {
            if (-not (Test-Path $mockDir)) { New-Item -ItemType Directory -Path $mockDir -Force | Out-Null }
            $markerPath = Join-Path $mockDir "ask-notified.txt"
            $body = "decision=ask`nreason=$($ClassifyResult.Reason)`ncommand=$($ClassifyResult.Command)`ntime=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            [System.IO.File]::WriteAllText($markerPath, $body)
        }
        catch {
            [Console]::Error.WriteLine("Hook: Warning: Ask-notification mock write failed: $($_.Exception.Message)")
        }
        return
    }

    # Real notification: build the command string, launch detached.
    $reason = "$($ClassifyResult.Reason)"
    $command = "$($ClassifyResult.Command)"
    # Sanitize for embedding in a single-quoted PowerShell string
    $reason = $reason -replace "'", "''"
    $command = $command -replace "'", "''"
    if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) + '…' }
    if ($command.Length -gt 100) { $command = $command.Substring(0, 100) + '…' }

    $title = "PreToolUse Hook — Approval Needed"
    $body = "$reason`n$command"

    # Build the notification script
    $notifyScript = @"
try {
    # Sound
    if ('$($an.Sound)' -eq 'True') {
        `$soundFile = '$($an.SoundFile -replace "'", "''")'
        if (`$soundFile -and (Test-Path `$soundFile)) {
            (New-Object System.Media.SoundPlayer `$soundFile).PlaySync()
        } else {
            [console]::beep(800, 300)
        }
    }

    # Toast popup
    if ('$($an.Popup)' -eq 'True') {
        try {
            # Windows 10+ toast via Windows Runtime
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

            `$template = @'
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>$title</text>
            <text>$body</text>
        </binding>
    </visual>
</toast>
'@

            `$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            `$xml.LoadXml(`$template)
            `$toast = [Windows.UI.Notifications.ToastNotification]::new(`$xml)

            # Use a reliable AppID — piggyback on PowerShell's registered AppUserModelID
            `$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$appId).Show(`$toast)
        }
        catch {
            # Fallback: NotifyIcon balloon tip (reliable in RDP/VDI sessions)
            try {
                Add-Type -AssemblyName System.Windows.Forms
                Add-Type -AssemblyName System.Drawing
                `$notify = New-Object System.Windows.Forms.NotifyIcon
                `$notify.Icon = [System.Drawing.SystemIcons]::Warning
                `$notify.Visible = `$true
                `$notify.ShowBalloonTip(5000, '$title', '$body', [System.Windows.Forms.ToolTipIcon]::Warning)
                Start-Sleep -Seconds 6
                `$notify.Dispose()
            }
            catch {
                [Console]::Error.WriteLine("AskNotify: balloon fallback failed: `$(`$_.Exception.Message)")
            }
        }
    }
}
catch {
    [Console]::Error.WriteLine("AskNotify: notification failed: `$(`$_.Exception.Message)")
}
"@

    # Launch detached — fire-and-forget, never blocks the hook
    try {
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($notifyScript))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $null = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        [Console]::Error.WriteLine("Hook: Warning: Ask-notification launch failed: $($_.Exception.Message)")
    }
}
