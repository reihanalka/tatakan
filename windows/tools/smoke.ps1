# CI smoke test: start Tatakan with demo shelves and save screenshots to windows\dist\screens.
#   .\windows\tools\smoke.ps1 -Exe <path to Tatakan.exe>
param([Parameter(Mandatory)] [string]$Exe)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
$out = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'dist\screens'
New-Item -ItemType Directory -Force $out | Out-Null

# Sample files to put on the shelves
$samples = Join-Path $env:TEMP 'tatakan-samples'
New-Item -ItemType Directory -Force $samples | Out-Null
$colors = @{ 'Poster.png' = '#F07A42'; 'Moodboard.png' = '#60B4E2'; 'Logo grid.png' = '#161616' }
foreach ($name in $colors.Keys) {
  $bmp = New-Object System.Drawing.Bitmap 640, 480
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.ColorTranslator]::FromHtml($colors[$name]))
  $g.FillEllipse([System.Drawing.Brushes]::White, 220, 140, 200, 200)
  $bmp.Save((Join-Path $samples $name), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
'Brief: KV for the launch event' | Set-Content (Join-Path $samples 'Brief.txt')
$files = Get-ChildItem $samples | ForEach-Object { '"' + $_.FullName + '"' }

function Shot([string]$name) {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save((Join-Path $out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

function Run([string]$name, [string]$extra) {
  Get-Process Tatakan -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 1
  $p = Start-Process $Exe -ArgumentList ("--demo " + ($files -join ' ') + " $extra") -PassThru
  Start-Sleep 6
  if ($p.HasExited) { throw "Tatakan exited early (code $($p.ExitCode)) for $name" }
  Shot $name
  Write-Host "screenshot: $name"
}

Run 'shelf-pile-light' '--light'
Run 'shelf-list-dark' '--dark --expand'
Run 'shelves-pair-light' '--light --pair'
Run 'settings-dark' '--dark --settings'
Get-Process Tatakan -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host "OK  screenshots in $out"
