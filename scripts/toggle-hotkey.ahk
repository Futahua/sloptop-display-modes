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
; TOGGLE MODE.bat lives outside the repo and alternates using a mode.state file:
;   slop -> runs ipad mode      anything else -> runs sloptop mode
; It is launched hidden because the bats it calls spawn console windows.

toggleBat := "D:\Letters\MatTroiSeConMoc\Papers\User Generated\TOGGLE MODE.bat"

^#+x:: {
    global toggleBat
    if !FileExist(toggleBat) {
        TrayTip "Display toggle", "Not found:`n" toggleBat, 3
        return
    }
    ; A switch takes ~20s. Show something immediately so a keypress that appears
    ; to do nothing is not mistaken for a dead hotkey.
    TrayTip "Display toggle", "Switching display mode...", 1
    Run 'cmd.exe /c "" "' toggleBat '"', , "Hide"
}

; Ctrl+Win+Shift+R reloads this script, for editing the binding without hunting
; down the process.
^#+r:: {
    Reload
}
