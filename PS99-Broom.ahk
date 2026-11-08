#Requires AutoHotkey v2.0
#SingleInstance Force
DllCall("User32\SetProcessDPIAware")
CoordMode "Mouse", "Screen"
SetKeyDelay -1, 25
Thread "Interrupt", 0

global running := false, phase := "off", helperPid := 0, hwnd := 0, runGeneration := 0
global phaseAt := 0, lastSeq := "", freshAt := 0, lastCue := "", lastCueAt := 0
global hudHits := 0, hudMissingAt := 0, lobbyHits := 0, returnHits := 0
global returnLeftAt := 0, lobbyStableAt := 0, controllerLog := ""
global lastLobbyClick := 0, lobbyClickAttempts := 0
global entryHits := 0, entryAttempts := 0
global focusPaused := false, focusPauseAt := 0, focusRetryAt := 0, focusAttempts := 0, focusActiveAt := 0
global helperDir := A_ScriptDir "\masquerade", publishedPhase := ""
global magnetPid := 0, magnetBusy := false, magnetLastClick := 0, magnetSeq := ""
OnExit Cleanup

global panel := Gui("+AlwaysOnTop", "PS99 Broom Sweep " InstalledVersion())
panel.SetFont("s10", "Segoe UI")
panel.AddText("w350", "Broom Sweep: wait for entry, then react to cues")
global status := panel.AddText("xm w350", "Status: Off")
panel.AddText("xm w350", "Start from the same lobby and camera position.")
magnetSaved := 0
try magnetSaved := IniRead(A_ScriptDir "\settings.ini", "Options", "TreatMagnet", 0)
global magnetCheck := panel.AddCheckbox("xm w350 Checked" (magnetSaved = 1 ? 1 : 0), "Use Treat Magnet when ready")
magnetCheck.OnEvent("Click", MagnetOptionChanged)
panel.AddButton("xm w170 h34", "Start / stop (F6)").OnEvent("Click", Toggle)
panel.AddButton("x+10 w170 h34", "Update / reload").OnEvent("Click", UpdateAndReload)
panel.AddText("xm w350", "Auto-refocus enabled. F8 exits.")
panel.OnEvent("Close", (*) => ExitApp())
panel.Show()
F6::Toggle()
F8::ExitApp()

InstalledVersion() {
    try {
        contents := FileRead(A_ScriptDir "\version.json", "UTF-8")
        if RegExMatch(contents, '"version"\s*:\s*"(\d+\.\d+\.\d+)"', &match)
            return "v" match[1]
    }
    return "version unknown"
}

UpdateAndReload(*) {
    python := A_ScriptDir "\runtime\python\pythonw.exe"
    if !FileExist(python)
        python := EnvGet("USERPROFILE") "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
    updater := A_ScriptDir "\updater.py"
    config := A_ScriptDir "\version.json"
    missing := ""
    if !FileExist(updater)
        missing .= "`n- updater.py"
    if !FileExist(config)
        missing .= "`n- version.json"
    if !FileExist(python)
        missing .= "`n- bundled Python runtime (runtime\python\pythonw.exe)"
    if missing {
        MsgBox "The macro folder is incomplete. Missing:" missing "`n`nGitHub's Code > Download ZIP contains source files only. Download and extract BroomSweep-Portable.zip from:`nhttps://github.com/souplyy/ps99-broom-sweep/releases/latest"
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
    if running {
        ; Stop may interrupt a timer or a click routine. A full script reload
        ; discards every suspended thread, timer, and variable before restart.
        Critical "On"
        Stop("Stopped; resetting")
        Reload
        ; Reload returns only if it could not start the replacement process.
        status.Text := "Status: Reset failed; close and reopen the macro"
        Critical "Off"
    } else
        Start()
}

Start() {
    global running, phase, helperPid, hwnd, phaseAt, lastSeq, freshAt, controllerLog, entryHits, entryAttempts, runGeneration
    global lastCue, lastCueAt, hudHits, hudMissingAt, lobbyHits, returnHits, returnLeftAt, lobbyStableAt, lastLobbyClick, lobbyClickAttempts
    global focusPaused, focusPauseAt, focusRetryAt, focusAttempts, focusActiveAt, publishedPhase
    hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
    python := A_ScriptDir "\runtime\python\pythonw.exe"
    if !FileExist(python)
        python := EnvGet("USERPROFILE") "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
    helper := helperDir "\live_detector.py"
    if !hwnd {
        MsgBox "Open Roblox before starting the macro."
        return
    }
    if !FileExist(python) || !FileExist(helper) {
        MsgBox "The portable runtime or detector is missing. GitHub's Code > Download ZIP is source-only. Download and extract BroomSweep-Portable.zip from:`nhttps://github.com/souplyy/ps99-broom-sweep/releases/latest"
        return
    }
    for name in ["stop.request", "observation.txt", "observation.tmp"] {
        try FileDelete helperDir "\" name
    }
    if FileExist(helperDir "\stop.request") {
        MsgBox "Could not clear the old detector stop file. Close other copies of the macro and try again."
        return
    }
    try {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd, , 2)
            throw Error("Could not focus Roblox")
        Run '"' python '" "' helper '" ' hwnd, helperDir, "Hide", &helperPid
        runGeneration += 1
        running := true, phase := "entry", phaseAt := A_TickCount
        publishedPhase := ""
        PublishPhase()
        lastCue := "", lastCueAt := 0, hudHits := 0, hudMissingAt := 0
        lobbyHits := 0, returnHits := 0, returnLeftAt := 0, lobbyStableAt := 0
        lastLobbyClick := 0, lobbyClickAttempts := 0
        entryHits := 0, entryAttempts := 0
        focusPaused := false, focusPauseAt := 0, focusRetryAt := 0, focusAttempts := 0, focusActiveAt := 0
        controllerLog := helperDir "\controller-" FormatTime(, "yyyyMMdd-HHmmss") "-" DllCall("GetCurrentProcessId") ".log"
        LogEvent("start", "hwnd=" hwnd " helper=" helperPid)
        freshAt := A_TickCount, lastSeq := ""
        SendEvent "{d down}"
        status.Text := "Status: Entering (D for 7.5 seconds)"
        SetTimer Tick, 30, 10
        if magnetCheck.Value
            StartMagnet()
    } catch Error as e {
        Stop("Start failed: " e.Message)
    }
}


MagnetOptionChanged(*) {
    try IniWrite magnetCheck.Value, A_ScriptDir "\settings.ini", "Options", "TreatMagnet"
    if !running
        return
    if magnetCheck.Value
        StartMagnet()
    else
        StopMagnet()
}

StartMagnet() {
    global magnetPid, magnetLastClick, magnetSeq, magnetBusy
    if magnetPid && ProcessExist(magnetPid)
        return
    try FileDelete helperDir "\magnet-observation.txt"
    python := A_ScriptDir "\runtime\python\pythonw.exe"
    if !FileExist(python)
        python := EnvGet("USERPROFILE") "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
    try {
        Run '"' python '" "' helperDir '\live_detector.py" --magnet ' hwnd, helperDir, "Hide", &magnetPid
        magnetLastClick := 0, magnetSeq := "", magnetBusy := false
        LogEvent("magnet_worker_started", "pid=" magnetPid)
        SetTimer MagnetTick, 100, -1
    } catch Error as e {
        magnetPid := 0
        LogEvent("magnet_worker_failed", e.Message)
        MsgBox "Could not start the Treat Magnet detector: " e.Message
    }
}

StopMagnet() {
    global magnetPid, magnetBusy, magnetSeq
    SetTimer MagnetTick, 0
    if magnetPid && ProcessExist(magnetPid)
        try ProcessClose magnetPid
    magnetPid := 0, magnetBusy := false, magnetSeq := ""
}

MagnetTick() {
    global magnetBusy, magnetLastClick, magnetSeq
    if !running || !magnetCheck.Value || magnetBusy || focusPaused || !WinActive("ahk_id " hwnd)
        return
    ; The Lobby flow controls the mouse itself. Avoid conflicting with it.
    if phase = "return" || phase = "returning"
        return
    if A_TickCount-magnetLastClick < 8000 && magnetLastClick
        return
    data := ""
    try data := Trim(FileRead(helperDir "\magnet-observation.txt", "UTF-8"))
    if !RegExMatch(data, "^(\d+)\|(-?\d+)\|(-?\d+)\|(\d+)$", &m) || m[1] = magnetSeq
        return
    magnetSeq := m[1]
    x := Integer(m[2]), y := Integer(m[3]), seen := Integer(m[4])
    if (!x && !y) || A_TickCount-seen > 1200 || A_TickCount-seen < 0
        return
    generation := runGeneration
    magnetBusy := true
    try {
        MouseGetPos &oldX, &oldY
        if !MoveByRelativeInput(x, y, generation) || !running || generation != runGeneration || !magnetCheck.Value || !WinActive("ahk_id " hwnd) || phase = "return" || phase = "returning"
            return
        latest := ""
        try latest := Trim(FileRead(helperDir "\magnet-observation.txt", "UTF-8"))
        if !RegExMatch(latest, "^(\d+)\|(-?\d+)\|(-?\d+)\|(\d+)$", &check)
            return
        age := A_TickCount-Integer(check[4])
        if age < 0 || age > 1200 || Abs(Integer(check[2])-x) > 10 || Abs(Integer(check[3])-y) > 10
            return
        ; Tick has higher timer priority and can react to a cue while this
        ; mouse routine is moving or waiting.
        ; Keep the final focus check and mouse-down together. Cues can
        ; interrupt again immediately after the button is pressed.
        Critical "On"
        if !running || generation != runGeneration || !magnetCheck.Value || !WinActive("ahk_id " hwnd) || phase = "return" || phase = "returning" {
            Critical "Off"
            return
        }
        SendInput "{LButton down}"
        Critical "Off"
        try Sleep 60
        finally SendInput "{LButton up}"
        magnetLastClick := A_TickCount
        LogEvent("magnet_clicked", "x=" x " y=" y)
        if running && generation = runGeneration && WinActive("ahk_id " hwnd)
            MouseMove oldX, oldY, 0
    } finally {
        magnetBusy := false
    }
}

LogEvent(event, detail := "") {
    if !controllerLog
        return
    try FileAppend Format("{} tick={} phase={} {} {}`n", FormatTime(, "yyyy-MM-dd HH:mm:ss"), A_TickCount, phase, event, detail), controllerLog, "UTF-8"
}

PublishPhase() {
    global publishedPhase
    if phase = publishedPhase
        return
    try {
        out := FileOpen(helperDir "\phase.txt", "w", "UTF-8-RAW")
        out.Write(phase)
        out.Close()
        publishedPhase := phase
    }
}

Tick() {
    global phase, phaseAt, lastSeq, freshAt, lastCue, lastCueAt
    global hudHits, hudMissingAt, lobbyHits, returnHits, returnLeftAt, lobbyStableAt, lastLobbyClick, lobbyClickAttempts
    global entryHits, entryAttempts, focusPaused, focusPauseAt, focusRetryAt, focusAttempts, focusActiveAt
    if !running
        return
    PublishPhase()
    tickGeneration := runGeneration
    if !ProcessExist(helperPid) {
        Stop("Detector process stopped")
        return
    }
    now := A_TickCount
    if !WinActive("ahk_id " hwnd) {
        focusActiveAt := 0
        if !focusPaused {
            focusPaused := true, focusPauseAt := now, focusRetryAt := now+1000, focusAttempts := 0
            SendEvent "{d up}{a up}{w up}{s up}{Space up}{t up}"
            LogEvent("focus_paused", "movement released")
        }
        if focusAttempts < 3 && now >= focusRetryAt {
            focusAttempts += 1, focusRetryAt := now+2000
            try WinActivate "ahk_id " hwnd
            LogEvent("focus_retry", "attempt=" focusAttempts)
        }
        status.Text := focusAttempts < 3 ? "Status: Paused; trying to refocus Roblox" : "Status: Paused; focus Roblox to resume"
        return
    }
    ; A stale unfocused observation must not restart movement or trip the watchdog.
    if focusPaused {
        if !focusActiveAt
            focusActiveAt := now
        data := ""
        try data := Trim(FileRead(helperDir "\observation.txt", "UTF-8"))
        if !RegExMatch(data, "^(\d+)\|(none|jump|dive)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)$", &resume) || resume[1] = lastSeq {
            if now-focusActiveAt > 10000 {
                focusPaused := false
                Stop("Detector did not recover after focus returned")
            }
            return
        }
        pausedMs := now-focusPauseAt
        ; Movement timers count only time when their keys were actually held.
        if phase = "entry" || phase = "entry_search_w" || phase = "entry_search_s" || phase = "entry_search_center"
            phaseAt += pausedMs
        if hudMissingAt
            hudMissingAt += pausedMs
        if returnLeftAt
            returnLeftAt += pausedMs
        if lobbyStableAt
            lobbyStableAt += pausedMs
        if lastLobbyClick
            lastLobbyClick += pausedMs
        freshAt := now, lastSeq := "", focusPaused := false
        LogEvent("focus_resumed", "paused_ms=" pausedMs " attempts=" focusAttempts)
        ; If the scene changed during a long absence, wait for the game instead
        ; of sending movement in an unknown location.
        movement := phase = "entry" || phase = "entry_search_w" || phase = "entry_search_s" || phase = "entry_search_center"
        lobbyView := Integer(resume[5]) > 8000 && Integer(resume[6]) < 600 && Integer(resume[7]) < 120 && Integer(resume[10]) < 12000
        if movement && pausedMs > 3000 && !lobbyView {
            phase := "waiting", phaseAt := now, hudHits := 0
            LogEvent("focus_scene_changed", "movement cancelled; watching game")
        } else if phase = "entry"
            SendEvent "{d down}"
        else if phase = "entry_search_s"
            SendEvent "{s down}"
        else if phase = "entry_search_w" || phase = "entry_search_center"
            SendEvent "{w down}"
        status.Text := "Status: Focus recovered; resuming"
    }
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
            ; below stops the macro if no good observations arrive for 8 seconds.
            if now-freshAt > 8000
                Stop("Detector could not read Roblox for 8 seconds")
            else
                status.Text := "Status: Retrying detector"
            return
        }
        if m[2] = "unfocused" {
            ; The detector can report the previous frame after focus returns.
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
                phase := "game", phaseAt := now, hudMissingAt := 0, lobbyHits := 0, lastCue := "", lastCueAt := 0
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
            ; The HUD can disappear or look different on another display.
            ; Keep reacting to cues until the Lobby button is confirmed, or
            ; a generous safety limit expires to avoid playing later games.
            lobbyHits := Integer(m[4]) > 4500 ? lobbyHits+1 : 0
            if lobbyHits >= 3 {
                LogEvent("waiting_for_lobby", "reason=lobby_button_confirmed red=" m[4])
                phase := "return", phaseAt := now, lobbyHits := 0
                status.Text := "Status: Round ended; looking for Lobby button"
            } else if now-phaseAt >= 75000 {
                LogEvent("waiting_for_lobby", "reason=round_safety_timeout elapsed_ms=" (now-phaseAt))
                phase := "return", phaseAt := now, lobbyHits := 0
                status.Text := "Status: Round time limit; looking for Lobby button"
            }
            if hud
                hudMissingAt := 0
            else if !hudMissingAt {
                hudMissingAt := now
                LogEvent("hud_missing", "continuing_to_watch_cues")
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
                if !ClickLobbyButton(m[4]) || !running || tickGeneration != runGeneration
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
                    if !ClickLobbyButton(m[4]) || !running || tickGeneration != runGeneration
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
    if now-freshAt > 8000 {
        Stop("Detector stopped responding")
        return
    }
    ; Lobby-button appearance and loading times can vary widely. Remain in
    ; these phases until the corresponding visual signal appears or F6 stops.
}

ClickLobbyButton(redCount) {
    clickGeneration := runGeneration
    WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
    MouseGetPos &oldX, &oldY
    clickX := wx+Round(ww*.5), clickY := wy+Round(wh*.925)
    LogEvent("lobby_click_prepare", "x=" clickX " y=" clickY " red=" redCount)
    status.Text := "Status: Moving mouse to Lobby"
    ; Relative SendInput movements generate mouse-input events, rather than
    ; relying on the visible Windows pointer changing position alone.
    if !MoveByRelativeInput(clickX, clickY, clickGeneration) {
        LogEvent("lobby_click_cancelled", "reason=relative_move_failed")
        if running && clickGeneration = runGeneration && WinActive("ahk_id " hwnd)
            Stop("Could not move mouse to Lobby")
        return false
    }
    Sleep 250
    if !running || clickGeneration != runGeneration || !WinActive("ahk_id " hwnd) {
        LogEvent("lobby_click_cancelled", "reason=focus_or_stop")
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
    if !running || clickGeneration != runGeneration || !WinActive("ahk_id " hwnd)
        return false
    MouseMove oldX, oldY, 0
    return true
}

MoveByRelativeInput(goalX, goalY, generation) {
    ; Windows can scale relative input according to pointer settings, so use
    ; small steps and re-measure rather than assuming 1 input unit = 1 pixel.
    size := A_PtrSize = 8 ? 40 : 28
    offset := A_PtrSize = 8 ? 8 : 4
    input := Buffer(size, 0)
    NumPut("UInt", 0, input, 0) ; INPUT_MOUSE
    NumPut("UInt", 0x2001, input, offset+12) ; MOVE | MOVE_NOCOALESCE
    started := A_TickCount
    loop 600 {
        if !running || generation != runGeneration || !WinActive("ahk_id " hwnd) || A_TickCount-started > 6000
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
    global running, phase, helperPid, runGeneration
    runGeneration += 1
    if running
        LogEvent("stop", "reason=" message)
    running := false, phase := "off"
    SetTimer Tick, 0
    StopMagnet()
    SendEvent "{d up}{a up}{w up}{s up}{Space up}{t up}"
    if helperPid && ProcessExist(helperPid) {
        try FileAppend "stop", helperDir "\stop.request", "UTF-8"
        ; Terminate only this macro's own helper; no other processes are touched.
        try ProcessClose helperPid
        try ProcessWaitClose helperPid, 2
    }
    helperPid := 0
    status.Text := "Status: " message
}

Cleanup(*) {
    Stop()
}
