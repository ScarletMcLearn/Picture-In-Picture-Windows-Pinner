[CmdletBinding()]
param([switch]$KeepLogs)

$ErrorActionPreference = 'Stop'
$appName = 'PiPWindowPinner'
$installRoot = Join-Path $env:LOCALAPPDATA $appName

Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe' OR Name='AutoHotkey.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*PiPWindowPinner.ahk*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Unregister-ScheduledTask -TaskName $appName -Confirm:$false -ErrorAction SilentlyContinue
if ($KeepLogs -and (Test-Path -LiteralPath (Join-Path $installRoot 'PiPWindowPinner.log'))) {
    Copy-Item -LiteralPath (Join-Path $installRoot 'PiPWindowPinner.log') -Destination (Join-Path $PSScriptRoot 'PiPWindowPinner.log') -Force
}
if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
Write-Host "Removed per-user task and $installRoot."
