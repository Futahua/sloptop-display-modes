#Requires AutoHotkey v2.0
#SingleInstance Force

; Ctrl+Win+Shift+X  ->  toggle between sloptop and ipad mode.
;
; Standalone on purpose. sloptop_engine.ahk could host this, but it only binds
; mouse buttons and Enter/Escape/Space inside modal contexts - keeping the
; display toggle separate means neither script can break the other, and this one
; can be reloaded without disturbing the engine.
;
; A Windows shortcut cannot express this combination: .lnk hotkeys support
; Ctrl+Alt+<key> and Ctrl+Shift+<key> but not the Win key, so a hotkey daemon is
; the only route.
;
; TOGGLE MODE.bat lives outside the repo. It decides direction from the live
; topology (scripts\current-mode.ps1) and keeps mode.state in sync. It is
; launched hidden because the bats it calls spawn console windows.

toggleBat := "D:\Letters\MatTroiSeConMoc\Papers\User Generated\TOGGLE MODE.bat"
logFile   := A_ScriptDir "\toggle.log"
diagFile  := A_ScriptDir "\hotkey-daemon.log"

Diag(msg) {
    global diagFile
    try FileAppend "[" FormatTime(, "yyyy-MM-dd HH:mm:ss") "] " msg "`n", diagFile
}

; --- why this file logs so much -------------------------------------------
; A press that does nothing has three indistinguishable causes: the daemon is
; dead, the daemon is alive but the hotkey never reached it, or the hotkey
; reached it and the command underneath failed silently. Without a record you
; cannot tell them apart, and the last diagnosis of this hotkey was wrong
; because it was inferred from a file timestamp. So: startup is logged, hotkey
; registration is logged, a heartbeat proves liveness, and every press is
; recorded before anything else happens.
Diag("--- daemon start, pid " ProcessExist() ", admin=" (A_IsAdmin ? "yes" : "no") " ---")

; Registration can fail (another process owning the combination, a hook that
; cannot be installed). Unwrapped, AHK shows a dialog on a screen that may not
; exist in ipad mode and then exits - looking, again, like nothing happened.
try {
    Hotkey "^#+x", DoToggle, "On"
    Hotkey "^#+r", DoReload, "On"
    Diag("hotkeys registered: ^#+x toggle, ^#+r reload")
} catch as e {
    Diag("HOTKEY REGISTRATION FAILED: " e.Message)
    TrayTip "Display toggle", "Hotkey registration failed:`n" e.Message, 3
}

; Windows silently uninstalls a low-level keyboard hook whose owner blocks for
; longer than LowLevelHooksTimeout. The process keeps running with no error and
; no dialog; its hotkeys are simply gone. That matches the observed behaviour
; exactly: the toggle worked on the 9th and then stopped while pid 26840 was
; still alive the whole time. Re-asserting on a timer rebuilds the binding, and
; the heartbeat line is the evidence that distinguishes "daemon died" from
; "daemon alive, key not arriving" the next time this happens.
beats := 0
Rearm() {
    global beats
    beats++
    try {
        Hotkey "^#+x", DoToggle, "On"
        Hotkey "^#+r", DoReload, "On"
    } catch as e {
        Diag("rearm failed: " e.Message)
    }
    ; Hourly, not every tick - this file has to stay readable.
    if (Mod(beats, 60) = 1)
        Diag("heartbeat " beats ", hotkeys re-armed")
}
SetTimer Rearm, 60000

DoToggle(*) {
    global toggleBat, logFile
    Diag("^#+x pressed")

    if !FileExist(toggleBat) {
        Diag("bat missing: " toggleBat)
        TrayTip "Display toggle", "Not found:`n" toggleBat, 3
        return
    }
    ; A switch takes ~20s. Show something immediately so a keypress that appears
    ; to do nothing is not mistaken for a dead hotkey.
    TrayTip "Display toggle", "Switching display mode...", 1

    try FileAppend "`n=== " FormatTime(, "yyyy-MM-dd HH:mm:ss") " hotkey pressed ===`n", logFile

    ; QUOTING MATTERS. cmd /c applies its own quote-stripping: the whole command
    ; line has to sit inside ONE outer pair of quotes when the paths themselves
    ; are quoted. The earlier form was cmd /c "" "<bat>" - the empty-string trick
    ; belongs to `start`, not `cmd /c` - and it silently ran nothing at all. No
    ; error, no output, no switch.
    try {
        Run 'cmd.exe /c ""' toggleBat '" >> "' logFile '" 2>&1"', , "Hide"
        Diag("launched toggle bat")
    } catch as e {
        Diag("RUN FAILED: " e.Message)
        TrayTip "Display toggle", "Launch failed:`n" e.Message, 3
    }
}

; Ctrl+Win+Shift+R reloads this script, for editing the binding without hunting
; down the process.
DoReload(*) {
    Diag("^#+r pressed - reloading")
    Reload
}
