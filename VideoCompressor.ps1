#Requires -Version 5.1
<#
  Video Compressor GUI v1.2.2
  Compress a video to a target file size (MB) using ffmpeg.
   - Output format: MP4, MKV, MOV (H.264 + AAC) or WebM (VP9 + Opus).
   - Auto-detects a GPU H.264 encoder (NVIDIA NVENC / Intel QSV / AMD AMF), falls back to CPU (x264).
   - CPU = 2-pass encode (accurate size). GPU = 1-pass capped VBR (fast, lands slightly under target).
  Needs ffmpeg.exe + ffprobe.exe in the same folder as this script (or in PATH).
  NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
#>

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================
# 1. CONFIG
# =====================================================================
$script:AppName = 'Video Compressor'
$script:AppVer  = '1.2.2'
$script:Cfg = @{
    MaxMB          = 10000  # largest accepted target size
    MarginCpu      = 0.95   # 2-pass x264 is accurate -> 5% safety margin
    MarginGpu      = 0.92   # 1-pass GPU VBR is looser -> 8% safety margin
    MinVideoKbps   = 50     # below this the target is refused
    LowQualityKbps = 300    # below this the user is warned
    TimerMs        = 500    # progress polling interval
}
$script:AppData = Join-Path $env:LOCALAPPDATA 'VideoCompressor'
$script:ErrLog  = Join-Path $script:AppData 'error.log'

# Encoder table. Opts are the same options used for the real encode AND for the detection test.
$script:Encoders = @(
    @{ Id = 'h264_nvenc'; Name = 'NVIDIA NVENC (GPU)';     Gpu = $true; Opts = '-preset p5 -tune hq -rc vbr' },
    @{ Id = 'h264_qsv';   Name = 'Intel Quick Sync (GPU)'; Gpu = $true; Opts = '-preset slow' },
    @{ Id = 'h264_amf';   Name = 'AMD AMF (GPU)';          Gpu = $true; Opts = '-quality quality -rc vbr_peak' }
)
$script:CpuEncoder = @{ Id = 'libx264';    Name = 'CPU (x264)'; Gpu = $false; Opts = '-preset medium' }
$script:Vp9Encoder = @{ Id = 'libvpx-vp9'; Name = 'CPU (VP9)';  Gpu = $false; Opts = '-deadline good -cpu-used 4 -row-mt 1' }

# Output formats. Kind picks the codec path: h264 = x264/GPU + AAC, vp9 = VP9 + Opus (WebM cannot hold H.264).
$script:Formats = @(
    @{ Name = 'MP4  - H.264 + AAC (most compatible)'; Ext = '.mp4';  Muxer = 'mp4';      Kind = 'h264'; Flags = '-movflags +faststart' },
    @{ Name = 'MKV  - H.264 + AAC';                   Ext = '.mkv';  Muxer = 'matroska'; Kind = 'h264'; Flags = '' },
    @{ Name = 'MOV  - H.264 + AAC (Apple / editors)'; Ext = '.mov';  Muxer = 'mov';      Kind = 'h264'; Flags = '-movflags +faststart' },
    @{ Name = 'WebM - VP9 + Opus (CPU only, slower)'; Ext = '.webm'; Muxer = 'webm';     Kind = 'vp9';  Flags = '' }
)

# =====================================================================
# 2. ERROR HANDLING + TOOL LOOKUP
# =====================================================================
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

function Show-Msg([string]$text, [string]$title = 'Video Compressor', [string]$buttons = 'OK', [string]$icon = 'Information') {
    return [System.Windows.Forms.MessageBox]::Show($text, $title, $buttons, $icon)
}

function Write-ErrorLog([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $script:AppData)) { New-Item -ItemType Directory -Path $script:AppData -Force | Out-Null }
        Add-Content -LiteralPath $script:ErrLog -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $msg)
    } catch {}
}

# The console is hidden when launched from the shortcut, so errors must be shown in a dialog.
function Show-Fatal([string]$msg) {
    Write-ErrorLog $msg
    [void](Show-Msg ($msg + "`n`nDetails: " + $script:ErrLog) 'Video Compressor - Error' 'OK' 'Error')
}

# Safety net: an unexpected UI error gets a friendly dialog + log entry instead of the raw .NET crash box.
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-ErrorLog $e.Exception.ToString()
    [void](Show-Msg ("Unexpected error:`n" + $e.Exception.Message + "`n`nDetails: " + $script:ErrLog) 'Error' 'OK' 'Error')
})

function Find-Tool([string]$name) {
    if ($PSScriptRoot) {
        $local = Join-Path $PSScriptRoot "$name.exe"
        if (Test-Path -LiteralPath $local) { return $local }
    }
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:ffmpeg  = Find-Tool 'ffmpeg'
$script:ffprobe = Find-Tool 'ffprobe'
if (-not $script:ffmpeg -or -not $script:ffprobe) {
    Show-Fatal "ffmpeg.exe / ffprobe.exe not found.`n`nReinstall Video Compressor, or place both files in the same folder as VideoCompressor.ps1."
    return
}

# =====================================================================
# 3. ENCODER DETECTION
# =====================================================================
# "Listed in ffmpeg" does not mean the hardware exists, so each candidate gets a tiny real test encode.
function Test-Encoder($e) {
    $listed = & $script:ffmpeg -hide_banner -encoders 2>$null | Select-String -SimpleMatch $e.Id
    if (-not $listed) { return $false }
    $testArgs = @('-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=256x256:d=0.2', '-c:v', $e.Id) +
                ($e.Opts -split ' ') +
                @('-b:v', '1000k', '-pix_fmt', 'yuv420p', '-f', 'null', '-')
    & $script:ffmpeg @testArgs 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-BestEncoder {
    foreach ($e in $script:Encoders) { if (Test-Encoder $e) { return $e } }
    return $script:CpuEncoder
}

# =====================================================================
# 4. STATE
# =====================================================================
$script:detected    = $script:CpuEncoder   # replaced after the window opens
$script:enc         = $script:CpuEncoder
$script:fmt         = $script:Formats[0]
$script:busy        = $false
$script:proc        = $null
$script:pass        = 0
$script:totalPasses = 2
$script:margin      = $script:Cfg.MarginCpu
$script:duration    = 0.0
$script:vkbps       = 0
$script:akbps       = 128
$script:inFile      = ''
$script:outFile     = ''
$script:durPath     = ''
$script:durVal      = 0.0
$script:InfoDefault = 'Duration: -   |   Est. video bitrate: -'
$script:outTmp      = ''      # encode goes to <output>.part, renamed only on success
$script:target      = 0
$script:scale       = $false
$script:workDir     = Join-Path $env:TEMP ('vc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:logBase     = Join-Path $script:workDir 'pass'
$script:progFile    = Join-Path $script:workDir 'progress.txt'
$script:errFile     = Join-Path $script:workDir 'ffmpeg_err.txt'

# =====================================================================
# 5. UI (controls only, behaviour is wired up in section 10)
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "$($script:AppName) $($script:AppVer)"
$form.Size            = New-Object System.Drawing.Size(620, 480)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $l.UseMnemonic = $false   # show '&' literally
    $form.Controls.Add($l)
    return $l
}

[void](New-Label 'Input video (drag & drop supported):' 15 15)
$txtIn = New-Object System.Windows.Forms.TextBox
$txtIn.Location = '15,35'; $txtIn.Size = '480,23'; $txtIn.AllowDrop = $true
$form.Controls.Add($txtIn)
$btnIn = New-Object System.Windows.Forms.Button
$btnIn.Text = 'Browse...'; $btnIn.Location = '505,33'; $btnIn.Size = '85,27'
$form.Controls.Add($btnIn)

[void](New-Label 'Output file:' 15 70)
$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = '15,90'; $txtOut.Size = '480,23'
$form.Controls.Add($txtOut)
$btnOut = New-Object System.Windows.Forms.Button
$btnOut.Text = 'Save as...'; $btnOut.Location = '505,88'; $btnOut.Size = '85,27'
$form.Controls.Add($btnOut)

[void](New-Label 'Target size (MB):' 15 130)
$txtMB = New-Object System.Windows.Forms.TextBox
$txtMB.Location = '125,127'; $txtMB.Size = '60,23'; $txtMB.MaxLength = 5   # starts empty on purpose
$form.Controls.Add($txtMB)
$btnMinus = New-Object System.Windows.Forms.Button
$btnMinus.Text = '-'; $btnMinus.Location = '190,126'; $btnMinus.Size = '24,25'
$form.Controls.Add($btnMinus)
$btnPlus = New-Object System.Windows.Forms.Button
$btnPlus.Text = '+'; $btnPlus.Location = '216,126'; $btnPlus.Size = '24,25'
$form.Controls.Add($btnPlus)

[void](New-Label 'Format:' 255 130)
$cmbFmt = New-Object System.Windows.Forms.ComboBox
$cmbFmt.DropDownStyle = 'DropDownList'
$cmbFmt.Location = '308,127'; $cmbFmt.Size = '282,23'
foreach ($f in $script:Formats) { [void]$cmbFmt.Items.Add($f.Name) }
$cmbFmt.SelectedIndex = 0
$form.Controls.Add($cmbFmt)

$chkScale = New-Object System.Windows.Forms.CheckBox
$chkScale.Text = 'Downscale to 720p (better quality at small sizes)'
$chkScale.Location = '15,160'; $chkScale.AutoSize = $true
$form.Controls.Add($chkScale)

$lblEnc = New-Label 'Encoder: detecting...' 15 192
$chkCpu = New-Object System.Windows.Forms.CheckBox
$chkCpu.Text = 'Force CPU'
$chkCpu.Location = '235,189'; $chkCpu.AutoSize = $true; $chkCpu.Enabled = $false
$form.Controls.Add($chkCpu)

$lblInfo = New-Label $script:InfoDefault 15 220

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = 'Compress'; $btnGo.Location = '15,245'; $btnGo.Size = '120,32'; $btnGo.Enabled = $false
$form.Controls.Add($btnGo)
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'; $btnCancel.Location = '145,245'; $btnCancel.Size = '90,32'; $btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = '15,290'; $bar.Size = '575,22'; $bar.Minimum = 0; $bar.Maximum = 100
$form.Controls.Add($bar)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = '15,322'; $log.Size = '575,105'
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$form.Controls.Add($log)

# =====================================================================
# 6. GENERAL HELPERS
# =====================================================================
function Write-Log([string]$msg) {
    $log.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $msg))
}

function Remove-Quiet([string]$path, [switch]$Recurse) {
    if ($path -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Force -Recurse:$Recurse -ErrorAction SilentlyContinue
    }
}

function Get-Duration([string]$file) {
    # Some containers (mkv/webm) have no format-level duration, so fall back to the video stream.
    foreach ($entry in 'format=duration', 'stream=duration') {
        $out  = & $script:ffprobe -v error -select_streams v:0 -show_entries $entry -of csv=p=0 -i $file 2>$null
        $line = $out | Select-Object -First 1
        $d = 0.0
        if ($line -and [double]::TryParse([string]$line, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) { return $d }
    }
    return 0.0
}

function Get-Bitrates([double]$duration, [int]$targetMB) {
    $totalKbps = ($targetMB * 1MB * 8 * $script:margin) / $duration / 1000
    $audio = if ($totalKbps -gt 400) { 128 } else { 64 }
    $video = [math]::Floor($totalKbps - $audio)
    return [pscustomobject]@{ Video = $video; Audio = $audio }
}

# =====================================================================
# 7. UI STATE HELPERS (read and update the controls)
# =====================================================================
# Target size typed by the user: whole number 1..MaxMB, or 0 when empty/invalid.
function Get-TargetMB {
    $n = 0
    if ([int]::TryParse($txtMB.Text.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $script:Cfg.MaxMB) { return $n }
    return 0
}

function Get-Format {
    return $script:Formats[[math]::Max(0, $cmbFmt.SelectedIndex)]
}

# CPU encoders (x264, VP9) run 2 passes with a 5% margin. GPU encoders run 1 pass with an 8% margin.
function Set-Encoder($e) {
    $script:enc         = $e
    $script:totalPasses = if ($e.Gpu) { 1 } else { 2 }
    $script:margin      = if ($e.Gpu) { $script:Cfg.MarginGpu } else { $script:Cfg.MarginCpu }
}

function Get-ChosenEncoder {
    if ((Get-Format).Kind -eq 'vp9') { return $script:Vp9Encoder }   # WebM = VP9, CPU only
    if ($chkCpu.Checked) { return $script:CpuEncoder }
    return $script:detected
}

# Refresh the encoder label and the Force CPU checkbox (not while an encode is running).
function Update-EncoderUi {
    $lblEnc.Text = 'Encoder: ' + (Get-ChosenEncoder).Name
    if (-not $script:busy) {
        $chkCpu.Enabled = ((Get-Format).Kind -ne 'vp9') -and [bool]$script:detected.Gpu
    }
}

function Set-Busy([bool]$busy) {
    $script:busy       = $busy
    $btnGo.Enabled     = -not $busy
    $btnCancel.Enabled = $busy
    foreach ($c in @($txtIn, $txtOut, $btnIn, $btnOut, $txtMB, $btnMinus, $btnPlus, $cmbFmt, $chkScale)) { $c.Enabled = -not $busy }
    if ($busy) { $chkCpu.Enabled = $false } else { Update-EncoderUi }
}

function Update-Info {
    $path = $txtIn.Text.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $lblInfo.Text = $script:InfoDefault
        return
    }
    if ($script:durPath -ne $path) { $script:durVal = Get-Duration $path; $script:durPath = $path }   # cached: runs on every keystroke
    $d = $script:durVal
    if ($d -le 0) { $lblInfo.Text = $script:InfoDefault; return }
    Set-Encoder (Get-ChosenEncoder)
    $mb = Get-TargetMB
    if ($mb -le 0) { $lblInfo.Text = ("Duration: {0:N1}s   |   Enter a target size (MB)" -f $d); return }
    $br = Get-Bitrates $d $mb
    $hint = ''
    if ($br.Video -lt $script:Cfg.MinVideoKbps)       { $hint = '  (target too small)' }
    elseif ($br.Video -lt $script:Cfg.LowQualityKbps) { $hint = '  (very low quality)' }
    $lblInfo.Text = ("Duration: {0:N1}s   |   Est. video bitrate: {1} kbps{2}" -f $d, $br.Video, $hint)
}

# =====================================================================
# 8. ENCODE ENGINE (ffmpeg arguments, process control, progress)
# =====================================================================
function New-EncodeArguments([int]$pass) {
    $v   = $script:vkbps
    $fmt = $script:fmt

    # Downscale never upscales (min 720, source height). Otherwise force even dimensions (yuv420p needs them).
    if ($script:scale) { $vf = '-vf "scale=-2:''min(720,ih)''"' }
    else               { $vf = '-vf "scale=trunc(iw/2)*2:trunc(ih/2)*2"' }

    $acodec = if ($fmt.Kind -eq 'vp9') { 'libopus' } else { 'aac' }
    $base   = "-y -hide_banner -nostats -loglevel error -progress `"$($script:progFile)`" -i `"$($script:inFile)`" $vf -pix_fmt yuv420p"
    $out    = "-c:a $acodec -b:a $($script:akbps)k $($fmt.Flags) -f $($fmt.Muxer) `"$($script:outTmp)`""
    $opts   = $script:enc.Opts

    if (-not $script:enc.Gpu) {
        # CPU: two-pass (x264 or VP9)
        $c = "-c:v $($script:enc.Id) $opts -b:v ${v}k -pass $pass -passlogfile `"$($script:logBase)`""
        if ($pass -eq 1) { return "$base $c -an -f null NUL" }
        return "$base $c $out"
    }
    $c = "-c:v $($script:enc.Id) $opts -b:v ${v}k -maxrate ${v}k -bufsize $($v * 2)k"
    return "$base $c $out"
}

function Start-Pass([int]$pass) {
    $script:pass = $pass
    Set-Content -LiteralPath $script:progFile -Value '' -Encoding ascii
    Write-Log "Encoding with $($script:enc.Name) - pass $pass/$($script:totalPasses)"
    $script:proc = Start-Process -FilePath $script:ffmpeg -ArgumentList (New-EncodeArguments $pass) `
        -NoNewWindow -PassThru -RedirectStandardError $script:errFile
    $null = $script:proc.Handle   # cache the handle so ExitCode is reliable
}

function Stop-Encode {
    if ($script:proc -and -not $script:proc.HasExited) {
        try { $script:proc.Kill() } catch {}
        [void]$script:proc.WaitForExit(5000)   # let ffmpeg release its files before cleanup
    }
}

function Get-FfmpegError {
    try {
        if (Test-Path -LiteralPath $script:errFile) {
            return ((Get-Content -LiteralPath $script:errFile -Tail 3) -join ' | ')
        }
    } catch {}
    return ''
}

# Reads only the tail of the progress file (it grows for the whole encode).
function Get-ProgressSeconds {
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($script:progFile, 'Open', 'Read', 'ReadWrite')
        $take = [int][math]::Min($fs.Length, 4096)
        if ($take -le 0) { return 0.0 }
        [void]$fs.Seek(-$take, 'End')
        $buf  = New-Object byte[] $take
        $read = $fs.Read($buf, 0, $take)
        $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
        $m = [regex]::Matches($text, 'out_time_us=(\d+)')
        if ($m.Count -gt 0) { return [double]$m[$m.Count - 1].Groups[1].Value / 1e6 }
    } catch {
    } finally {
        if ($fs) { $fs.Close() }
    }
    return 0.0
}

# =====================================================================
# 9. RUN CONTROL (cleanup + the timer that drives the passes)
# =====================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:Cfg.TimerMs

# Cleanup + log only. Callers show any dialogs afterwards.
function Finish([bool]$ok, [string]$msg) {
    $timer.Stop()
    Stop-Encode
    Remove-Quiet $script:outTmp
    Remove-Quiet $script:workDir -Recurse
    Set-Busy $false
    Write-Log $msg
    $bar.Value = if ($ok) { 100 } else { 0 }
}

$timer.Add_Tick({
    try {
        if (-not $script:proc) { return }

        $secs = Get-ProgressSeconds
        $pct  = if ($script:duration -gt 0) { [math]::Min(1.0, $secs / $script:duration) } else { 0 }
        $bar.Value = [int]((($script:pass - 1) + $pct) / $script:totalPasses * 100)

        if (-not $script:proc.HasExited) { return }
        $script:proc.WaitForExit()
        $code = $script:proc.ExitCode

        if ($code -ne 0) {
            if ($script:enc.Gpu) {
                # GPU encode failed (driver / unsupported input) -> automatic CPU fallback
                Write-Log "$($script:enc.Name) failed (exit $code): $(Get-FfmpegError)"
                Write-Log 'Falling back to CPU (x264).'
                Set-Encoder $script:CpuEncoder
                $br = Get-Bitrates $script:duration $script:target
                $script:vkbps = $br.Video; $script:akbps = $br.Audio
                $lblEnc.Text = 'Encoder: CPU (x264) [fallback]'
                Start-Pass 1
                return
            }
            $detail = Get-FfmpegError
            Finish $false "ffmpeg failed on pass $($script:pass) (exit code $code). $detail"
            [void](Show-Msg "Compression failed.`n`n$detail" 'Error' 'OK' 'Error')
            return
        }

        if ($script:pass -lt $script:totalPasses) { Start-Pass ($script:pass + 1); return }

        # Success: promote the .part file to the final name
        $sizeMB = [math]::Round((Get-Item -LiteralPath $script:outTmp).Length / 1MB, 2)
        Move-Item -LiteralPath $script:outTmp -Destination $script:outFile -Force
        $msg = "Done: $($script:outFile)`n$sizeMB MB (target $($script:target) MB)"
        if ($sizeMB -gt $script:target) { $msg += "`n`nWarning: the file is larger than the target. Try a smaller target size." }
        Finish $true ($msg -replace "`n", ' ')
        $r = Show-Msg ($msg + "`n`nOpen the output folder?") 'Done' 'YesNo' 'Information'
        if ($r -eq 'Yes') { Start-Process explorer.exe -ArgumentList "/select,`"$($script:outFile)`"" }
    } catch {
        Write-ErrorLog $_.Exception.ToString()
        Finish $false "Unexpected error: $($_.Exception.Message)"
        [void](Show-Msg "Unexpected error:`n$($_.Exception.Message)`n`nDetails: $($script:ErrLog)" 'Error' 'OK' 'Error')
    }
})

# =====================================================================
# 10. EVENTS
# =====================================================================
# ---- input / output files ----
$btnIn.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Video files|*.mp4;*.mkv;*.mov;*.avi;*.wmv;*.webm;*.flv;*.m4v|All files|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { $txtIn.Text = $dlg.FileName }
})
$btnOut.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter      = 'MP4 video|*.mp4|MKV video|*.mkv|MOV video|*.mov|WebM video|*.webm'
    $dlg.FilterIndex = $cmbFmt.SelectedIndex + 1
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtOut.Text = $dlg.FileName
        $cmbFmt.SelectedIndex = $dlg.FilterIndex - 1   # triggers the extension sync below
    }
})
$txtIn.Add_DragEnter({ if ($_.Data.GetDataPresent('FileDrop')) { $_.Effect = 'Copy' } })
$txtIn.Add_DragDrop({ $txtIn.Text = ($_.Data.GetData('FileDrop'))[0] })

$txtIn.Add_TextChanged({
    $path = $txtIn.Text.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $dir  = Split-Path $path -Parent
        $name = [IO.Path]::GetFileNameWithoutExtension($path)
        $txtOut.Text = Join-Path $dir ($name + '_compressed' + (Get-Format).Ext)
        Update-Info
    }
})

# ---- target size, format and encoder options ----
$txtMB.Add_KeyPress({
    if (-not [char]::IsControl($_.KeyChar) -and -not [char]::IsDigit($_.KeyChar)) { $_.Handled = $true }
})
$txtMB.Add_TextChanged({
    $clean = $txtMB.Text -replace '\D', ''          # also strips pasted non-digits
    if ($clean -ne $txtMB.Text) { $txtMB.Text = $clean; $txtMB.SelectionStart = $txtMB.Text.Length }
    Update-Info
})
$btnMinus.Add_Click({ $n = Get-TargetMB; if ($n -gt 1) { $txtMB.Text = [string]($n - 1) } })
$btnPlus.Add_Click({  $n = Get-TargetMB; if ($n -lt $script:Cfg.MaxMB) { $txtMB.Text = [string]($n + 1) } })
$chkCpu.Add_CheckedChanged({ Update-EncoderUi; Update-Info })
$cmbFmt.Add_SelectedIndexChanged({
    # keep the output file extension in sync with the chosen format
    $o = $txtOut.Text.Trim().Trim('"')
    if ($o) { $txtOut.Text = [IO.Path]::ChangeExtension($o, (Get-Format).Ext) }
    Update-EncoderUi
    Update-Info
})

# ---- run / cancel ----
$btnCancel.Add_Click({ Finish $false 'Cancelled.' })

$btnGo.Add_Click({
    try {
        # ---- validate input ----
        $in = $txtIn.Text.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($in) -or -not (Test-Path -LiteralPath $in -PathType Leaf)) { [void](Show-Msg 'Select a valid input video.' 'Error' 'OK' 'Warning'); return }
        $inFull = [IO.Path]::GetFullPath($in)

        # ---- validate target size (box starts empty) ----
        $mb = Get-TargetMB
        if ($mb -le 0) { [void](Show-Msg "Enter a target size in MB (1 to $($script:Cfg.MaxMB))." 'Target size needed' 'OK' 'Warning'); $txtMB.Focus(); return }

        # ---- validate output ----
        $out = $txtOut.Text.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($out)) { [void](Show-Msg 'Choose an output file.' 'Error' 'OK' 'Warning'); return }
        $fmt = Get-Format
        if ([IO.Path]::GetExtension($out) -ine $fmt.Ext) { $out = [IO.Path]::ChangeExtension($out, $fmt.Ext) }
        $txtOut.Text = $out
        $outFull = [IO.Path]::GetFullPath($out)
        if ($outFull -ieq $inFull) { [void](Show-Msg 'Output must be a different file than the input.' 'Error' 'OK' 'Warning'); return }
        if (-not (Test-Path -LiteralPath (Split-Path $outFull -Parent) -PathType Container)) {
            [void](Show-Msg 'The output folder does not exist.' 'Error' 'OK' 'Warning'); return }
        if (Test-Path -LiteralPath $outFull) {
            if ((Show-Msg "$outFull already exists.`n`nOverwrite it?" 'Confirm' 'YesNo' 'Question') -ne 'Yes') { return }
        }

        # ---- analyse ----
        $script:fmt      = $fmt
        $script:inFile   = $inFull
        $script:outFile  = $outFull
        $script:outTmp   = $outFull + '.part'
        $script:target   = $mb
        $script:scale    = $chkScale.Checked
        $script:duration = Get-Duration $inFull
        if ($script:duration -le 0) { [void](Show-Msg 'Could not read the video duration. Is the file a valid video?' 'Error' 'OK' 'Warning'); return }

        $origMB = (Get-Item -LiteralPath $inFull).Length / 1MB
        if ($script:target -ge $origMB) {
            $msg = "Target ({0} MB) is not smaller than the source ({1:N1} MB). Continue anyway?" -f $script:target, $origMB
            if ((Show-Msg $msg 'Confirm' 'YesNo' 'Question') -ne 'Yes') { return }
        }

        Set-Encoder (Get-ChosenEncoder)
        $br = Get-Bitrates $script:duration $script:target
        if ($br.Video -lt $script:Cfg.MinVideoKbps) {
            [void](Show-Msg "Target is too small for a $([int]$script:duration)s video. Increase the size." 'Error' 'OK' 'Warning'); return }
        if ($br.Video -lt $script:Cfg.LowQualityKbps) {
            $msg = "At $($script:target) MB the video quality will be very low ($($br.Video) kbps). Continue?"
            if ((Show-Msg $msg 'Low quality warning' 'YesNo' 'Warning') -ne 'Yes') { return }
        }
        $script:vkbps = $br.Video; $script:akbps = $br.Audio

        # ---- go ----
        New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null
        $log.Clear(); $bar.Value = 0
        Write-Log ("Format {0} | target {1} MB | video {2} kbps | audio {3} kbps" -f $fmt.Ext, $script:target, $script:vkbps, $script:akbps)
        Set-Busy $true
        Start-Pass 1
        $timer.Start()
    } catch {
        Write-ErrorLog $_.Exception.ToString()
        Finish $false "Could not start: $($_.Exception.Message)"
        [void](Show-Msg "Could not start encoding:`n$($_.Exception.Message)`n`nDetails: $($script:ErrLog)" 'Error' 'OK' 'Error')
    }
})

# ---- window lifecycle ----
$form.Add_FormClosing({
    $timer.Stop()
    Stop-Encode
    Remove-Quiet $script:outTmp
    Remove-Quiet $script:workDir -Recurse
})

# GPU detection runs after the window is visible (it takes a few seconds on some PCs).
$form.Add_Shown({
    $lblEnc.Text = 'Encoder: detecting GPU...'
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    try { $script:detected = Get-BestEncoder } catch { $script:detected = $script:CpuEncoder }
    Set-Encoder (Get-ChosenEncoder)
    Update-EncoderUi
    $btnGo.Enabled  = $true
    Write-Log "Detected encoder: $($script:detected.Name)"
})

# =====================================================================
# 11. START
# =====================================================================
try {
    [void]$form.ShowDialog()
} catch {
    Show-Fatal "Fatal error: $($_.Exception.Message)"
}