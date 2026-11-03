#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; Automatically pins only high-confidence browser Picture-in-Picture top-level windows.
; VirtualDesktopAccessor API: IsPinnedWindow(HWND) -> i32, PinWindow(HWND) -> i32.

global AppName := "PiP Window Pinner"
global IniPath := A_ScriptDir "\config.ini"
global LogPath := A_ScriptDir "\PiPWindowPinner.log"
global DllPath := A_ScriptDir "\lib\VirtualDesktopAccessor.dll"
global Processed := Map() ; HWND -> immutable identity, prevents stale HWND reuse
global ApiReady := false
global PollInterval := 750
global Verbose := false
global TitlePatterns := []
global MinWidth := 120, MinHeight := 80, MaxWidth := 1600, MaxHeight := 1200

Initialize()

Initialize() {
    global
    LoadConfig()
    if !CheckPlatform() || !LoadVirtualDesktopAccessor() {
        ExitApp 2
    }
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Open log", (*) => Run(LogPath))
    A_TrayMenu.Add("Reload", (*) => Reload())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_IconTip := AppName
    SetTimer(ScanForPiP, PollInterval)
    SetTimer(PruneProcessed, 15000)
    Log("Started. Poll interval=" PollInterval "ms")
    ScanForPiP()
}

LoadConfig() {
    global
    PollInterval := Clamp(IniRead(IniPath, "General", "PollIntervalMs", "750") + 0, 250, 5000)
    Verbose := IniRead(IniPath, "General", "VerboseLogging", "0") = "1"
    rawPatterns := IniRead(IniPath, "Detection", "TitlePatterns", "Picture-in-Picture|Picture in Picture|PiP")
    TitlePatterns := StrSplit(StrLower(rawPatterns), "|")
    MinWidth := IniRead(IniPath, "Detection", "MinWidth", "120") + 0
    MinHeight := IniRead(IniPath, "Detection", "MinHeight", "80") + 0
    MaxWidth := IniRead(IniPath, "Detection", "MaxWidth", "1600") + 0
    MaxHeight := IniRead(IniPath, "Detection", "MaxHeight", "1200") + 0
}

CheckPlatform() {
    global
    if A_PtrSize != 8 {
        Log("Unsupported: 32-bit AutoHotkey. 64-bit required.")
        return false
    }
    build := RegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuild", "0") + 0
    allow := IniRead(IniPath, "General", "AllowUnverifiedOsBuild", "0") = "1"
    ; Upstream VDA 2024-12-16 release states >=26100.2605, tested through 26200.8117.
    if (build < 26100 || (build > 26200 && !allow)) {
        Log("Unsupported/unverified Windows build " build ". Refusing DLL load. Set AllowUnverifiedOsBuild=1 only after manual validation.")
        return false
    }
    return true
}

LoadVirtualDesktopAccessor() {
    global ApiReady, DllPath
    if !FileExist(DllPath) {
        Log("DLL missing: " DllPath)
        return false
    }
    module := DllCall("Kernel32\LoadLibraryW", "wstr", DllPath, "ptr")
    if !module {
        Log("DLL load failed. Win32=" A_LastError)
        return false
    }
    for name in ["IsPinnedWindow", "PinWindow"] {
        if !DllCall("Kernel32\GetProcAddress", "ptr", module, "astr", name, "ptr") {
            Log("DLL missing export: " name)
            return false
        }
    }
    ApiReady := true
    Log("VirtualDesktopAccessor loaded: " DllPath)
    return true
}

ScanForPiP(*) {
    global ApiReady
    if !ApiReady
        return
    try windows := WinGetList()
    catch as err {
        Log("Window enumeration failed: " err.Message)
        return
    }
    for hwnd in windows {
        try {
            if IsPiPWindow(hwnd)
                PinIfNeeded(hwnd)
        } catch as err {
            Log("Inspect failed hwnd=" hwnd ": " err.Message)
        }
    }
}

IsPiPWindow(hwnd) {
    global TitlePatterns, MinWidth, MinHeight, MaxWidth, MaxHeight, Verbose
    if !DllCall("User32\IsWindowVisible", "ptr", hwnd, "int") || IsCloaked(hwnd)
        return false
    exe := StrLower(WinGetProcessName("ahk_id " hwnd))
    if !IsBrowser(exe)
        return false
    title := StrLower(WinGetTitle("ahk_id " hwnd))
    titleHit := HasPiPTitle(title)
    if !titleHit
        return false ; title alone never accepts; it is one required signal.
    class := WinGetClass("ahk_id " hwnd)
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    if w < MinWidth || h < MinHeight || w > MaxWidth || h > MaxHeight
        return false
    style := WinGetStyle("ahk_id " hwnd), exStyle := WinGetExStyle("ahk_id " hwnd)
    owner := DllCall("User32\GetWindow", "ptr", hwnd, "uint", 4, "ptr") ; diagnostic only; modern Chromium PiP has no owner/tool/popup flag.
    toolWindow := (exStyle & 0x80) != 0
    popup := (style & 0x80000000) != 0
    firefoxPiP := exe = "firefox.exe" && class = "MozillaDialogClass"
    chromiumPiP := (exe = "chrome.exe" || exe = "msedge.exe" || exe = "brave.exe") && class = "Chrome_WidgetWin_1"
    ; Browser process + browser PiP class + configured PiP title + PiP dimensions are all required.
    ; Chromium Edge PiP observed on Win11 uses a normal owned-less, non-popup style, so style cannot be required.
    accepted := firefoxPiP || chromiumPiP
    if accepted && Verbose
        Log("PiP candidate hwnd=" hwnd " exe=" exe " class=" class " owner=" owner " tool=" toolWindow " popup=" popup)
    return accepted
}

PinIfNeeded(hwnd) {
    global Processed, DllPath
    identity := WindowIdentity(hwnd)
    if !identity
        return
    if Processed.Has(hwnd) && Processed[hwnd] = identity
        return
    pinned := DllCall(DllPath "\IsPinnedWindow", "ptr", hwnd, "int")
    if pinned = -1 {
        Log("IsPinnedWindow failed hwnd=" hwnd)
        return
    }
    if !pinned {
        result := DllCall(DllPath "\PinWindow", "ptr", hwnd, "int")
        if result = -1 {
            Log("PinWindow failed hwnd=" hwnd)
            return
        }
        pinned := DllCall(DllPath "\IsPinnedWindow", "ptr", hwnd, "int")
    }
    if pinned = 1 {
        Processed[hwnd] := identity
        Log("Pinned PiP hwnd=" hwnd " exe=" WinGetProcessName("ahk_id " hwnd))
    } else {
        Log("Pin verification failed hwnd=" hwnd " result=" pinned)
    }
}

PruneProcessed(*) {
    global Processed
    stale := []
    for hwnd, identity in Processed {
        if !DllCall("User32\IsWindow", "ptr", hwnd, "int") || WindowIdentity(hwnd) != identity
            stale.Push(hwnd)
    }
    for hwnd in stale
        Processed.Delete(hwnd)
}

WindowIdentity(hwnd) {
    try {
        pid := WinGetPID("ahk_id " hwnd)
        return pid ":" ProcessStartedAt(pid) ":" WinGetProcessPath("ahk_id " hwnd) ":" WinGetClass("ahk_id " hwnd)
    }
    catch
        return ""
}

ProcessStartedAt(pid) {
    ; PID plus process creation FILETIME prevents an old cached HWND/PID tuple matching a new process.
    process := DllCall("Kernel32\OpenProcess", "uint", 0x1000, "int", false, "uint", pid, "ptr") ; PROCESS_QUERY_LIMITED_INFORMATION
    if !process
        return "unknown"
    creation := Buffer(8), exit := Buffer(8), kernel := Buffer(8), user := Buffer(8)
    ok := DllCall("Kernel32\GetProcessTimes", "ptr", process, "ptr", creation.Ptr, "ptr", exit.Ptr, "ptr", kernel.Ptr, "ptr", user.Ptr, "int")
    DllCall("Kernel32\CloseHandle", "ptr", process)
    return ok ? NumGet(creation, 0, "int64") : "unknown"
}

IsBrowser(exe) => exe = "chrome.exe" || exe = "msedge.exe" || exe = "brave.exe" || exe = "firefox.exe"

HasPiPTitle(title) {
    global TitlePatterns
    for pattern in TitlePatterns
        if pattern != "" && InStr(title, Trim(pattern))
            return true
    return false
}

IsCloaked(hwnd) {
    cloaked := 0
    return DllCall("Dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "int*", &cloaked, "uint", 4, "int") = 0 && cloaked != 0
}

Clamp(value, low, high) => value < low ? low : (value > high ? high : value)

Log(message) {
    global LogPath, Verbose
    line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message "`n"
    try {
        if FileExist(LogPath) && FileGetSize(LogPath) > 262144
            FileMove(LogPath, LogPath ".1", 1)
        FileAppend(line, LogPath, "UTF-8")
    }
}
