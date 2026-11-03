[CmdletBinding()]
param(
    [switch]$AllowUnverifiedOsBuild,
    [switch]$SkipDllDownload,
    [switch]$InstallAutoHotkey
)

$ErrorActionPreference = 'Stop'
$appName = 'PiPWindowPinner'
$source = $PSScriptRoot
$installRoot = Join-Path $env:LOCALAPPDATA $appName
$dllDirectory = Join-Path $installRoot 'lib'
$taskName = $appName
$releaseTag = '2024-12-16-windows11'
$dllUrl = "https://github.com/Ciantic/VirtualDesktopAccessor/releases/download/$releaseTag/VirtualDesktopAccessor.dll"
$dllSha256 = '8740C572A1C000E3B87FFEB1E4C397EAE9AF3BD4A2ABDC3BCFFACAB4493F8FF5'
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild

function Find-AutoHotkeyV2 {
    $found64 = Get-Command AutoHotkey64.exe -ErrorAction SilentlyContinue
    $found = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue
    $candidates = @()
    if ($found64) { $candidates += $found64.Source }
    if ($found) { $candidates += $found.Source }
    $candidates += "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
    $candidates += "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe"
    $candidates += "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
    $candidates += "$env:LOCALAPPDATA\AutoHotkey\v2\AutoHotkey64.exe"
    $candidates = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($candidate in $candidates) {
        $version = (Get-Item -LiteralPath $candidate).VersionInfo.ProductVersion
        if ($version -match '2\.\d+') { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'AutoHotkey v2 x64 not found. Install it from https://www.autohotkey.com/ first.'
}

function Install-AutoHotkeyV2 {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'winget is unavailable. Install AutoHotkey v2 x64 from https://www.autohotkey.com/, then rerun.' }
    Write-Host 'Installing AutoHotkey v2 x64 through winget (package: AutoHotkey.AutoHotkey)...'
    & $winget.Source install --id AutoHotkey.AutoHotkey --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget AutoHotkey installation failed with exit code $LASTEXITCODE." }
}

function Stop-RunningPiPWindowPinner {
    # VDA stays loaded by AutoHotkey, so stop only this app before replacing its DLL.
    Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe' OR Name='AutoHotkey.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$appName*" } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
            Wait-Process -Id $_.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
        }
}

if ($build -lt 26100 -or ($build -gt 26200 -and -not $AllowUnverifiedOsBuild)) {
    throw "Windows build $build is outside VirtualDesktopAccessor 2024-12-16 documented/tested range (26100.2605 through 26200.8117). No supported Windows public API pins an individual window across virtual desktops. Refusing install. After manual DLL validation, rerun with -AllowUnverifiedOsBuild."
}

try {
    $ahk = Find-AutoHotkeyV2
} catch {
    if (-not $InstallAutoHotkey) { throw }
    Install-AutoHotkeyV2
    $ahk = Find-AutoHotkeyV2
}
Stop-RunningPiPWindowPinner
New-Item -ItemType Directory -Force -Path $installRoot, $dllDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'PiPWindowPinner.ahk') -Destination $installRoot -Force
$installedConfig = Join-Path $installRoot 'config.ini'
if (-not (Test-Path -LiteralPath $installedConfig)) {
    Copy-Item -LiteralPath (Join-Path $source 'config.ini') -Destination $installRoot -Force
}
if ($AllowUnverifiedOsBuild) {
    # User explicitly accepted current-build risk for this install; persist that choice for background launches.
    Set-Content -LiteralPath $installedConfig -Value ((Get-Content -LiteralPath $installedConfig) -replace '^AllowUnverifiedOsBuild=0$', 'AllowUnverifiedOsBuild=1') -Encoding utf8
}

if (-not $SkipDllDownload) {
    # Origin: official Ciantic GitHub release. SHA-256 pinned from its release asset.
    $destination = Join-Path $dllDirectory 'VirtualDesktopAccessor.dll'
    Invoke-WebRequest -Uri $dllUrl -OutFile $destination
    $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($actual -ne $dllSha256) {
        Remove-Item -LiteralPath $destination -Force
        throw "VirtualDesktopAccessor SHA-256 mismatch. Expected $dllSha256; got $actual."
    }
    Write-Host "Verified official VirtualDesktopAccessor.dll SHA-256: $actual"
}

$installedDll = Join-Path $dllDirectory 'VirtualDesktopAccessor.dll'
if (-not (Test-Path -LiteralPath $installedDll)) { throw "DLL missing: $installedDll" }
$action = New-ScheduledTaskAction -Execute $ahk -Argument ('"' + (Join-Path $installRoot 'PiPWindowPinner.ahk') + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Delay = 'PT10S'
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Description 'Pins verified browser Picture-in-Picture windows on all virtual desktops.' -Force | Out-Null
Start-Process -FilePath $ahk -ArgumentList ('"' + (Join-Path $installRoot 'PiPWindowPinner.ahk') + '"')
Write-Host "Installed $appName in $installRoot and registered per-user logon task '$taskName'."
