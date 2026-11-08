#Requires AutoHotkey v2.0
#SingleInstance Force
DllCall("User32\SetProcessDPIAware")
CoordMode "Mouse", "Screen"
SetKeyDelay -1, 25
Thread "Interrupt", 0

global running := false, phase := "off", helperPid := 0, hwnd := 0
global phaseAt := 0, lastSeq := "", freshAt := 0, lastCue := "", lastCueAt := 0
global hudHits := 0, hudMissingAt := 0, lobbyHits := 0, returnHits := 0
global returnLeftAt := 0, lobbyStableAt := 0, controllerLog := ""
global lastLobbyClick := 0, lobbyClickAttempts := 0
global entryHits := 0, entryAttempts := 0
global helperDir := A_ScriptDir "\masquerade"
OnExit Cleanup

global panel := Gui("+AlwaysOnTop", "PS99 Broom Sweep")
panel.SetFont("s10", "Segoe UI")
panel.AddText("w350", "Broom Sweep: wait for entry, then react to cues")
global status := panel.AddText("xm w350", "Status: Off")
panel.AddText("xm w350", "Start from the same lobby and camera position.")
panel.AddButton("xm w170 h34", "Start / stop (F6)").OnEvent("Click", Toggle)
panel.AddButton("x+10 w170 h34", "Update / reload").OnEvent("Click", UpdateAndReload)
panel.AddText("xm w350", "Keep Roblox focused. F8 exits.")
panel.OnEvent("Close", (*) => ExitApp())
panel.Show()
F6::Toggle()
F8::ExitApp()

UpdateAndReload(*) {
    python := A_ScriptDir "\runtime\python\pythonw.exe"
    if !FileExist(python)
        python := EnvGet("USERPROFILE") "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
    updater := A_ScriptDir "\updater.py"
    config := A_ScriptDir "\version.json"
    if !FileExist(python) || !FileExist(updater) || !FileExist(config) {
        MsgBox "The update checker is missing. Keep updater.py and version.json beside the macro."
        return
    }
    try {
        pid := DllCall("GetCurrentProcessId")
        Run '"' python '" "' updater '" --reload ' pid ' "' A_AhkPath '" "' A_ScriptFullPath '"', A_ScriptDir, "Hide"
        ; Exit releases keys and stops the detector before files are replaced.
        ExitApp()
    } catch Error as e {
        MsgBox "Could not start the update checker: " e.Message
    }
}

Toggle(*) {
    if running
        Stop("Stopped")
    else
        Start()
}

Start() {
    global running, phase, helperPid, hwnd, phaseAt, lastSeq, freshAt, controllerLog, entryHits, entryAttempts
    hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
    python := A_ScriptDir "\runtime\python\pythonw.exe"
    if !FileExist(python)
        python := EnvGet("USERPROFILE") "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
    helper := helperDir "\live_detector.py"
    if !hwnd || !FileExist(python) || !FileExist(helper) {
        MsgBox "Open Roblox and keep the masquerade detector folder beside this macro."
        return
    }
    for name in ["stop.request", "observation.txt", "observation.tmp"] {
        try FileDelete helperDir "\" name
    }
    try {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd, , 2)
            throw Error("Could not focus Roblox")
        Run '"' python '" "' helper '" ' hwnd, helperDir, "Hide", &helperPid
        running := true, phase := "entry", phaseAt := A_TickCount
        entryHits := 0, entryAttempts := 0
        controllerLog := helperDir "\controller-" FormatTime(, "yyyyMMdd-HHmmss") "-" DllCall("GetCurrentProcessId") ".log"
        LogEvent("start", "hwnd=" hwnd " helper=" helperPid)
        freshAt := A_TickCount, lastSeq := ""
        SendEvent "{d down}"
        status.Text := "Status: Entering (D for 7.5 seconds)"
        SetTimer Tick, 30
    } catch Error as e {
        Stop("Start failed: " e.Message)
    }
}

LogEvent(event, detail := "") {
    if !controllerLog
        return
    try FileAppend Format("{} tick={} phase={} {} {}`n", FormatTime(, "yyyy-MM-dd HH:mm:ss"), A_TickCount, phase, event, detail), controllerLog, "UTF-8"
}

Tick() {
    global phase, phaseAt, lastSeq, freshAt, lastCue, lastCueAt
    global hudHits, hudMissingAt, lobbyHits, returnHits, returnLeftAt, lobbyStableAt, lastLobbyClick, lobbyClickAttempts
    global entryHits, entryAttempts
    if !running
        return
    if !WinActive("ahk_id " hwnd) || !ProcessExist(helperPid) {
        Stop("Focus or detector lost")
        return
    }
    now := A_TickCount
    if phase = "entry" && now-phaseAt >= 7500 {
        SendEvent "{d up}"
        phase := "entry_check", phaseAt := now
        LogEvent("entry_limit", "held_d_ms=7500 waiting_for_confirmation")
        status.Text := "Status: Checking green line; waiting up to 10 seconds"
    } else if phase = "entry_check" && now-phaseAt >= 10000 {
        entryAttempts += 1
        phase := "entry_search_w", phaseAt := now
        SendEvent "{w down}"
        LogEvent("entry_search", "attempt=" entryAttempts " direction=w max_ms=1500")
        status.Text := "Status: Searching for entry (W)"
    } else if phase = "entry_search_w" && now-phaseAt >= 1500 {
        SendEvent "{w up}"
        phase := "entry_search_s", phaseAt := now
        SendEvent "{s down}"
        LogEvent("entry_search", "direction=s max_ms=3000")
        status.Text := "Status: Searching for entry (S)"
    } else if phase = "entry_search_s" && now-phaseAt >= 3000 {
        SendEvent "{s up}"
        phase := "entry_search_center", phaseAt := now
        SendEvent "{w down}"
        LogEvent("entry_search", "attempt=" entryAttempts " direction=w_return max_ms=1500")
        status.Text := "Status: Returning across entry area"
    } else if phase = "entry_search_center" && now-phaseAt >= 1500 {
        SendEvent "{w up}"
        phase := "entry_check", phaseAt := now
        LogEvent("entry_waiting", "attempt=" entryAttempts " retry_in_ms=10000")
        status.Text := "Status: Waiting 10 seconds before searching again"
    }
    data := ""
    try data := Trim(FileRead(helperDir "\observation.txt", "UTF-8"))
    if RegExMatch(data, "^(\d+)\|(none|jump|dive|unfocused|error)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)$", &m) && m[1] != lastSeq {
        lastSeq := m[1]
        if m[2] = "error" {
            ; Let a transient capture error recover. The stale-data watchdog
            ; below stops the macro if no good observations arrive for 2.5s.
            if now-freshAt > 2500
                Stop("Detector could not read Roblox for 2.5 seconds")
            else
                status.Text := "Status: Retrying detector"
            return
        }
        if m[2] = "unfocused" {
            Stop("Roblox lost focus")
            return
        }
        freshAt := now
        if phase = "entry_check" || phase = "entry_search_w" || phase = "entry_search_s" || phase = "entry_search_center" {
            entryHits := Integer(m[11]) >= 650 ? entryHits+1 : 0
            if entryHits >= 2 {
                SendEvent "{d up}{a up}{w up}{s up}"
                LogEvent("entry_line_detected", "score=" m[11] " corrections=" entryAttempts)
                phase := "waiting", phaseAt := now, hudHits := 0
                status.Text := "Status: Green line detected; waiting for Broom Sweep"
            }
        }
        ; Require a timer together with a HUD label or the green Dive button.
        ; A recognized JUMP/DIVE prompt is an independent fallback.
        timer := Integer(m[7]) >= 120 && Integer(m[7]) <= 1000
        hudLabel := Integer(m[3]) >= 18 && Integer(m[3]) <= 180
        diveButton := Integer(m[6]) >= 600
        hud := (timer && (hudLabel || diveButton)) || m[2] = "jump" || m[2] = "dive"
        if phase = "waiting" {
            hudHits := hud ? hudHits+1 : 0
            if hudHits >= 2 || m[2] = "jump" || m[2] = "dive" {
                phase := "game", phaseAt := now, hudMissingAt := 0, lastCue := "", lastCueAt := 0
                LogEvent("game_started", "hud=" m[3] " dive_green=" m[6] " timer=" m[7] " cue=" m[2])
                status.Text := "Status: Watching JUMP and DIVE cues"
                ; Do not miss the first prompt if it was the start signal.
                if m[2] = "jump" || m[2] = "dive" {
                    if m[2] = "jump"
                        SendEvent "{Space}"
                    else
                        SendEvent "t"
                    lastCue := m[2], lastCueAt := now
                }
            } else if Integer(m[10]) > 22000 {
                status.Text := "Status: Loading game"
            } else if Integer(m[9]) >= 1200 && Integer(m[9]) <= 10000 {
                status.Text := "Status: Player countdown or queue detected"
            } else if Integer(m[8]) >= 1000 && Integer(m[5]) >= 5000 {
                status.Text := "Status: Entry confirmation / lobby queue"
            } else if diveButton {
                status.Text := "Status: Dive button visible; checking timer"
            } else {
                status.Text := "Status: Waiting for Broom Sweep"
            }
        } else if phase = "game" {
            ; The observed Broom Sweep timer starts at about 50 seconds. The
            ; HUD color check does not distinguish "GAME 2" from "GAME 1".
            ; Stop reacting after this bound even if the next HUD looks similar.
            if now-phaseAt >= 52000 {
                phase := "return", phaseAt := now, lobbyHits := 0
                LogEvent("waiting_for_lobby", "reason=round_time_elapsed")
                status.Text := "Status: Round time elapsed; looking for Lobby button"
            }
            if hud
                hudMissingAt := 0
            else if !hudMissingAt
                hudMissingAt := now
            else if now-hudMissingAt > 2200 {
                phase := "return", phaseAt := now, lobbyHits := 0
                LogEvent("waiting_for_lobby", "reason=round_hud_missing")
                status.Text := "Status: Round ended; looking for Lobby button"
            }
            if phase = "game" {
                cue := m[2]
                if cue != "none" && (cue != lastCue || now-lastCueAt > 1300) {
                    if cue = "jump"
                        SendEvent "{Space}"
                    else
                        SendEvent "t"
                    lastCue := cue, lastCueAt := now
                    LogEvent("cue_action", "cue=" cue)
                    status.Text := "Status: " (cue = "jump" ? "Jump" : "Dive")
                } else if cue = "none" && now-lastCueAt > 250
                    lastCue := ""
            }
        } else if phase = "return" {
            lobbyHits := Integer(m[4]) > 4500 ? lobbyHits+1 : 0
            if lobbyHits >= 3 {
                if !ClickLobbyButton(m[4])
                    return
                phase := "returning", phaseAt := A_TickCount, returnHits := 0
                returnLeftAt := 0, lobbyStableAt := 0
                lastLobbyClick := phaseAt, lobbyClickAttempts := 1
                status.Text := "Status: Returning to lobby"
            }
        } else if phase = "returning" {
            ; First ensure the red Lobby button has actually disappeared.
            if Integer(m[4]) < 1000 {
                if !returnLeftAt {
                    returnLeftAt := now
                    LogEvent("lobby_button_disappeared", "red=" m[4])
                }
            } else {
                returnLeftAt := 0, lobbyStableAt := 0
                status.Text := "Status: Waiting for Lobby click to take effect"
                if now-lastLobbyClick >= 8000 && lobbyClickAttempts < 3 {
                    LogEvent("lobby_click_retry", "attempt=" (lobbyClickAttempts+1) " red=" m[4])
                    if !ClickLobbyButton(m[4])
                        return
                    lobbyClickAttempts += 1
                    lastLobbyClick := A_TickCount, phaseAt := lastLobbyClick
                } else if lobbyClickAttempts >= 3
                    status.Text := "Status: Lobby still visible; click it manually or press F6"
            }
            ; Purple alone also appears in other scenes: require a settled
            ; lobby-like view with no round timer, Dive button or countdown.
            looksLikeLobby := Integer(m[5]) > 8000 && Integer(m[4]) < 1000
                && Integer(m[6]) < 600 && Integer(m[7]) < 120
                && Integer(m[9]) < 1200 && Integer(m[10]) < 12000
            if returnLeftAt && now-returnLeftAt >= 1500 && now-phaseAt >= 12000 && looksLikeLobby {
                if !lobbyStableAt {
                    lobbyStableAt := now
                    LogEvent("lobby_candidate", "purple=" m[5] " timer=" m[7])
                }
            } else
                lobbyStableAt := 0
            if lobbyStableAt && now-lobbyStableAt >= 3000 {
                phase := "entry", phaseAt := now
                entryHits := 0, entryAttempts := 0
                LogEvent("lobby_confirmed", "wait_ms=" (now-returnLeftAt) " stable_ms=" (now-lobbyStableAt))
                SendEvent "{d down}"
                status.Text := "Status: Entering again (D for 7.5 seconds)"
            } else if returnLeftAt {
                if Integer(m[10]) > 22000
                    status.Text := "Status: Roblox loading screen visible"
                else if now-phaseAt < 12000
                    status.Text := "Status: Waiting 12 seconds after Lobby click"
                else
                    status.Text := "Status: Waiting to recognize loaded lobby"
            }
        }
    }
    if now-freshAt > 2500 {
        Stop("Detector stopped responding")
        return
    }
    ; Lobby-button appearance and loading times can vary widely. Remain in
    ; these phases until the corresponding visual signal appears or F6 stops.
}

ClickLobbyButton(redCount) {
    WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
    MouseGetPos &oldX, &oldY
    clickX := wx+Round(ww*.5), clickY := wy+Round(wh*.925)
    LogEvent("lobby_click_prepare", "x=" clickX " y=" clickY " red=" redCount)
    status.Text := "Status: Moving mouse to Lobby"
    ; Relative SendInput movements generate mouse-input events, rather than
    ; relying on the visible Windows pointer changing position alone.
    if !MoveByRelativeInput(clickX, clickY) {
        LogEvent("lobby_click_cancelled", "reason=relative_move_failed")
        if running
            Stop("Could not move mouse to Lobby")
        return false
    }
    Sleep 250
    if !running || !WinActive("ahk_id " hwnd) {
        LogEvent("lobby_click_cancelled", "reason=focus_or_stop")
        if running
            Stop("Focus lost before Lobby click")
        return false
    }
    MouseGetPos &actualX, &actualY
    LogEvent("lobby_mouse_position", "x=" actualX " y=" actualY)
    if Abs(actualX-clickX) > 3 || Abs(actualY-clickY) > 3 {
        Stop("Mouse could not reach Lobby button")
        return false
    }
    SendInput "{LButton down}"
    try Sleep 60
    finally SendInput "{LButton up}"
    LogEvent("lobby_click_sent", "x=" actualX " y=" actualY)
    ; Give Roblox time to consume the release before restoring the cursor.
    Sleep 700
    MouseMove oldX, oldY, 0
    return true
}

MoveByRelativeInput(goalX, goalY) {
    ; Windows can scale relative input according to pointer settings, so use
    ; small steps and re-measure rather than assuming 1 input unit = 1 pixel.
    size := A_PtrSize = 8 ? 40 : 28
    offset := A_PtrSize = 8 ? 8 : 4
    input := Buffer(size, 0)
    NumPut("UInt", 0, input, 0) ; INPUT_MOUSE
    NumPut("UInt", 0x2001, input, offset+12) ; MOVE | MOVE_NOCOALESCE
    started := A_TickCount
    loop 600 {
        if !running || !WinActive("ahk_id " hwnd) || A_TickCount-started > 6000
            return false
        MouseGetPos &x, &y
        dx := goalX-x, dy := goalY-y
        if Abs(dx) <= 3 && Abs(dy) <= 3
            return true
        stepX := Max(-6, Min(6, dx)), stepY := Max(-6, Min(6, dy))
        NumPut("Int", stepX, input, offset)
        NumPut("Int", stepY, input, offset+4)
        if DllCall("User32\SendInput", "UInt", 1, "Ptr", input.Ptr, "Int", size, "UInt") != 1 {
            LogEvent("relative_mouse_input_failed", "error=" A_LastError)
            return false
        }
        Sleep 3
    }
    return false
}

Stop(message := "Off") {
    global running, phase, helperPid
    if running
        LogEvent("stop", "reason=" message)
    running := false, phase := "off"
    SetTimer Tick, 0
    SendEvent "{d up}{a up}{w up}{s up}{Space up}{t up}"
    if helperPid && ProcessExist(helperPid) {
        try FileAppend "stop", helperDir "\stop.request", "UTF-8"
        ; Terminate only this macro's own helper; no other processes are touched.
        try ProcessClose helperPid
    }
    helperPid := 0
    status.Text := "Status: " message
}

Cleanup(*) {
    Stop()
}
