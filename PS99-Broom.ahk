#Requires AutoHotkey v2.0
#SingleInstance Force
DllCall("User32\SetProcessDPIAware")
CoordMode "Mouse", "Screen"
SetKeyDelay -1, 25
Thread "Interrupt", 0

global running := false, phase := "off", helperPid := 0, hwnd := 0, runGeneration := 0
global gamesPlayed := 0, updateCheckPid := 0, clickGuardRetryAt := 0, clickGuardCounter := 0
global waitingLoadingAt := 0, transferPending := false, transferLobbyAt := 0
global entryLobbyAt := 0, entrySideRetries := 0, entryLoadingAt := 0
global gameStartCandidateAt := 0, gameVerified := false
global phaseAt := 0, lastSeq := "", freshAt := 0, lastCue := "", lastCueAt := 0
global hudHits := 0, hudMissingAt := 0, lobbyHits := 0, returnHits := 0
global returnLeftAt := 0, lobbyStableAt := 0, controllerLog := ""
global lastLobbyClick := 0, lobbyClickAttempts := 0, lobbyClickSent := false, lobbyCandidateAt := 0
global entryHits := 0, entryAttempts := 0
global focusPaused := false, focusPauseAt := 0, focusRetryAt := 0, focusAttempts := 0, focusActiveAt := 0
global helperDir := A_ScriptDir "\masquerade", publishedPhase := ""
global magnetPid := 0, magnetBusy := false, magnetLastClick := 0, magnetSeq := "", magnetUsed := false
global broomPid := 0, broomBusy := false, broomUsed := false, broomSeq := "", mouseAutomationBusy := false
global roundCandidate := 0, roundHits := 0, eventRound := 0, eventRoundAt := 0
global game2StartedAt := 0, game2Direction := "", game2MoveAt := 0, game2JumpAt := 0, game2LobbyAt := 0
OnExit Cleanup

global panel := Gui("+AlwaysOnTop", "PS99 Broom Sweep " InstalledVersion())
panel.SetFont("s10", "Segoe UI")
panel.AddText("w350", "Broom Sweep: wait for entry, then react to cues")
global status := panel.AddText("xm w350", "Status: Off")
global gameCounter := panel.AddText("xm w350", "Games played: 0")
panel.AddText("xm w350", "Start from the same lobby and camera position.")
magnetSaved := 0
try magnetSaved := IniRead(A_ScriptDir "\settings.ini", "Options", "TreatMagnet", 0)
global magnetCheck := panel.AddCheckbox("xm w350 Checked" (magnetSaved = 1 ? 1 : 0), "Use Treat Magnet when ready")
magnetCheck.OnEvent("Click", MagnetOptionChanged)
broomSaved := 0, broomAfterSaved := 0, surviveSaved := 0
try broomSaved := IniRead(A_ScriptDir "\settings.ini", "Options", "UseBroomstick", 0)
try broomAfterSaved := Integer(IniRead(A_ScriptDir "\settings.ini", "Options", "BroomAfter", 0))
try surviveSaved := IniRead(A_ScriptDir "\settings.ini", "Options", "SurviveGame2", 0)
broomAfterSaved := Max(0, Min(2, broomAfterSaved))
global broomCheck := panel.AddCheckbox("xm w350 Checked" (broomSaved = 1 ? 1 : 0), "Use Broomstick")
broomCheck.OnEvent("Click", BroomOptionsChanged)
panel.AddText("xm y+6", "Use after game:")
global broomAfter := panel.AddDropDownList("x+8 w205 Choose" (broomAfterSaved+1), ["0 - Save from game 1", "1 - Save from game 2", "2 - Save from game 3"])
broomAfter.OnEvent("Change", BroomOptionsChanged)
panel.AddText("xm w350", "Only if you survive to that point.")
global surviveCheck := panel.AddCheckbox("xm w350 Checked" (surviveSaved = 1 ? 1 : 0), "Attempt to survive game 2")
surviveCheck.OnEvent("Click", BroomOptionsChanged)
panel.AddButton("xm w170 h34", "Start / stop (F6)").OnEvent("Click", Toggle)
global updateButton := panel.AddButton("x+10 w170 h34", "Update / reload")
updateButton.OnEvent("Click", UpdateAndReload)
panel.AddText("xm w350", "Auto-refocus enabled. F8 exits.")
panel.OnEvent("Close", (*) => ExitApp())
panel.Show()
; Check shortly after launch and then every ten minutes without interrupting play.
SetTimer InitialUpdateCheck, -5000, -1
SetTimer BackgroundUpdateCheck, 600000, -1
SetTimer RefreshUpdateNotice, 2000, -1
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

InitialUpdateCheck() {
    BackgroundUpdateCheck()
}

BackgroundUpdateCheck() {
    global updateCheckPid
    if updateCheckPid && ProcessExist(updateCheckPid)
        return
    python := A_ScriptDir "\runtime\python\pythonw.exe"
    if !FileExist(python)
        python := EnvGet("USERPROFILE") "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
    updater := A_ScriptDir "\updater.py"
    if !FileExist(python) || !FileExist(updater)
        return
    try Run '"' python '" "' updater '" --check-only', A_ScriptDir, "Hide", &updateCheckPid
}

RefreshUpdateNotice() {
    result := ""
    try result := Trim(FileRead(A_ScriptDir "\update-available.txt", "UTF-8"))
    if RegExMatch(result, "^(\d+\.\d+\.\d+)\|(\d+\.\d+\.\d+)$", &match) && "v" match[1] = InstalledVersion()
        updateButton.Text := "Update available!"
    else
        updateButton.Text := "Update / reload"
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
    global lastCue, lastCueAt, hudHits, hudMissingAt, lobbyHits, returnHits, returnLeftAt, lobbyStableAt, lastLobbyClick, lobbyClickAttempts, lobbyClickSent, lobbyCandidateAt
    global focusPaused, focusPauseAt, focusRetryAt, focusAttempts, focusActiveAt, publishedPhase, magnetUsed
    global waitingLoadingAt, transferPending, transferLobbyAt, entryLobbyAt, entrySideRetries, entryLoadingAt
    global gameStartCandidateAt, gameVerified, broomUsed, eventRound, eventRoundAt, roundCandidate, roundHits, game2LobbyAt
    magnetUsed := false, waitingLoadingAt := 0, transferPending := false, transferLobbyAt := 0
    entryLobbyAt := 0, entrySideRetries := 0, entryLoadingAt := 0
    gameStartCandidateAt := 0, gameVerified := false
    broomUsed := false, eventRound := 0, eventRoundAt := 0, roundCandidate := 0, roundHits := 0, game2LobbyAt := 0
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
        lastLobbyClick := 0, lobbyClickAttempts := 0, lobbyClickSent := false, lobbyCandidateAt := 0
        entryHits := 0, entryAttempts := 0
        focusPaused := false, focusPauseAt := 0, focusRetryAt := 0, focusAttempts := 0, focusActiveAt := 0
        controllerLog := helperDir "\controller-" FormatTime(, "yyyyMMdd-HHmmss") "-" DllCall("GetCurrentProcessId") ".log"
        LogEvent("start", "hwnd=" hwnd " helper=" helperPid)
        freshAt := A_TickCount, lastSeq := ""
        SendEvent "{d down}"
        status.Text := "Status: Entering (D for 7.5 seconds)"
        SetTimer Tick, 30, 10
        if broomCheck.Value || surviveCheck.Value
            StartBroomWorker()
    } catch Error as e {
        Stop("Start failed: " e.Message)
    }
}



BroomOptionsChanged(*) {
    global phase, phaseAt, lobbyHits
    try IniWrite broomCheck.Value, A_ScriptDir "\settings.ini", "Options", "UseBroomstick"
    try IniWrite broomAfter.Value-1, A_ScriptDir "\settings.ini", "Options", "BroomAfter"
    try IniWrite surviveCheck.Value, A_ScriptDir "\settings.ini", "Options", "SurviveGame2"
    if !running
        return
    if broomCheck.Value || surviveCheck.Value
        StartBroomWorker()
    else {
        StopBroomWorker()
        StopGame2Movement()
        if phase = "broom_wait" || phase = "game2" {
            phase := "return", phaseAt := A_TickCount, lobbyHits := 0
        }
    }
    if !surviveCheck.Value
        StopGame2Movement()
    else if phase = "game2"
        SetTimer Game2Tick, 150, -1
}

StartBroomWorker() {
    global broomPid, broomSeq
    if broomPid && ProcessExist(broomPid)
        return
    try FileDelete helperDir "\broom-observation.txt"
    python := A_ScriptDir "\runtime\python\pythonw.exe"
    if !FileExist(python)
        python := EnvGet("USERPROFILE") "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
    try {
        Run '"' python '" "' helperDir '\live_detector.py" --broom ' hwnd, helperDir, "Hide", &broomPid
        broomSeq := ""
        LogEvent("broom_worker_started", "pid=" broomPid)
        SetTimer BroomTick, 120, -1
    } catch Error as e {
        broomPid := 0
        LogEvent("broom_worker_failed", e.Message)
        status.Text := "Status: Broom detector could not start"
    }
}

StopBroomWorker() {
    global broomPid, broomBusy, broomSeq
    SetTimer BroomTick, 0
    if broomPid && ProcessExist(broomPid)
        try ProcessClose broomPid
    broomPid := 0, broomBusy := false, broomSeq := ""
}

StopGame2Movement() {
    global game2Direction, game2MoveAt, game2JumpAt
    SetTimer Game2Tick, 0
    if game2Direction != ""
        SendEvent "{a up}{d up}{Space up}"
    game2Direction := "", game2MoveAt := 0, game2JumpAt := 0
}

Game2Tick() {
    global game2Direction, game2MoveAt, game2JumpAt
    if !running || phase != "game2" || !surviveCheck.Value || focusPaused || !WinActive("ahk_id " hwnd)
        return
    now := A_TickCount
    if now-game2StartedAt >= 90000 {
        StopGame2Movement()
        status.Text := "Status: Game 2 time limit; waiting for next game"
        return
    }
    if !game2MoveAt || now-game2MoveAt >= 3000 {
        if game2Direction = "a" {
            SendEvent "{a up}{d down}"
            game2Direction := "d"
        } else {
            SendEvent "{d up}{a down}"
            game2Direction := "a"
        }
        game2MoveAt := now
    }
    if !game2JumpAt || now-game2JumpAt >= 350 {
        SendEvent "{Space}"
        game2JumpAt := now
    }
}

BroomTick() {
    global broomSeq, broomBusy, broomUsed, roundCandidate, roundHits, eventRound, eventRoundAt, mouseAutomationBusy
    global phase, phaseAt, game2StartedAt, lobbyHits, game2LobbyAt
    if !running || focusPaused || !WinActive("ahk_id " hwnd) || broomBusy
        return
    if phase != "waiting" && phase != "game" && phase != "game2" && phase != "broom_wait"
        return
    data := ""
    try data := Trim(FileRead(helperDir "\broom-observation.txt", "UTF-8"))
    if !RegExMatch(data, "^(\d+)\|([0-3])\|(-?\d+)\|(-?\d+)\|(\d+)$", &m) || m[1] = broomSeq
        return
    broomSeq := m[1]
    now := A_TickCount, age := now-Integer(m[5]), seenRound := Integer(m[2])
    if age < 0 || age > 2000
        return
    if seenRound > 0 {
        if seenRound = roundCandidate
            roundHits += 1
        else
            roundCandidate := seenRound, roundHits := 1
        if roundHits >= 2 && seenRound >= eventRound {
            if seenRound != eventRound
                LogEvent("event_round_detected", "round=" seenRound)
            eventRound := seenRound, eventRoundAt := now
        }
    } else
        roundHits := 0
    if !eventRound || now-eventRoundAt > 3000
        return
    after := broomAfter.Value-1
    keepGame2 := surviveCheck.Value || (broomCheck.Value && after = 2 && !broomUsed)
    if eventRound = 2 && keepGame2 && (phase = "game" || phase = "broom_wait") {
        phase := "game2", phaseAt := now, game2StartedAt := now, game2LobbyAt := 0
        StopMagnet()
        LogEvent("game2_started", "survival=" surviveCheck.Value)
        status.Text := surviveCheck.Value ? "Status: Game 2: moving and jumping" : "Status: Waiting through game 2"
        if surviveCheck.Value
            SetTimer Game2Tick, 150, -1
    }
    if eventRound >= 3 && phase = "game2" {
        StopGame2Movement()
        phase := "broom_wait", phaseAt := now
        LogEvent("game2_finished", "round=" eventRound)
        status.Text := "Status: Game 2 ended"
    }
    if eventRound >= 3 && phase = "broom_wait" && (!broomCheck.Value || broomUsed) {
        phase := "return", phaseAt := now, lobbyHits := 0
        status.Text := "Status: Looking for Lobby button"
        return
    }
    if !broomCheck.Value || broomUsed || mouseAutomationBusy || eventRound != after+1 || A_TickCount < clickGuardRetryAt
        return
    if after = 0 && phase != "waiting" && phase != "game"
        return
    if after > 0 && phase != "game" && phase != "game2" && phase != "broom_wait"
        return
    x := Integer(m[3]), y := Integer(m[4])
    if !x && !y
        return
    generation := runGeneration
    broomBusy := true, mouseAutomationBusy := true
    try {
        MouseGetPos &oldX, &oldY
        if !MoveByRelativeInput(x,y,generation) || !running || generation != runGeneration || !broomCheck.Value || broomUsed || !WinActive("ahk_id " hwnd)
            return
        if !ClickGuard(generation)
            return
        latest := ""
        try latest := Trim(FileRead(helperDir "\broom-observation.txt", "UTF-8"))
        if !RegExMatch(latest, "^(\d+)\|([0-3])\|(-?\d+)\|(-?\d+)\|(\d+)$", &check)
            return
        latestAge := A_TickCount-Integer(check[5])
        if latestAge < 0 || latestAge > 2000 || Integer(check[2]) != after+1 || Abs(Integer(check[3])-x)>10 || Abs(Integer(check[4])-y)>10
            return
        Critical "On"
        validPhase := after = 0 ? (phase = "waiting" || phase = "game") : (phase = "game" || phase = "game2" || phase = "broom_wait")
        if !running || generation != runGeneration || !broomCheck.Value || broomUsed || !WinActive("ahk_id " hwnd) || !validPhase {
            Critical "Off"
            return
        }
        SendInput "{LButton down}"
        broomUsed := true
        Critical "Off"
        try Sleep 60
        finally SendInput "{LButton up}"
        LogEvent("broom_clicked", "after=" after " round=" eventRound " x=" x " y=" y)
        if running && generation = runGeneration && WinActive("ahk_id " hwnd)
            MouseMove oldX,oldY,0
        if after > 0 && !(after = 1 && surviveCheck.Value) {
            StopGame2Movement()
            phase := "return", phaseAt := A_TickCount, lobbyHits := 0
            status.Text := "Status: Broomstick used; looking for Lobby"
        }
    } finally {
        broomBusy := false, mouseAutomationBusy := false
    }
}

MagnetOptionChanged(*) {
    try IniWrite magnetCheck.Value, A_ScriptDir "\settings.ini", "Options", "TreatMagnet"
    if !running
        return
    if magnetCheck.Value && phase = "game" && !magnetUsed && A_TickCount-phaseAt <= 15000
        StartMagnet()
    else if !magnetCheck.Value
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
    global magnetBusy, magnetLastClick, magnetSeq, magnetUsed, mouseAutomationBusy
    if !running || !magnetCheck.Value || magnetUsed || magnetBusy || mouseAutomationBusy || focusPaused || !WinActive("ahk_id " hwnd) || A_TickCount < clickGuardRetryAt
        return
    ; Use it only near the beginning of the first minigame, once per run.
    if phase != "game" || A_TickCount-phaseAt > 15000 {
        StopMagnet()
        return
    }
    data := ""
    try data := Trim(FileRead(helperDir "\magnet-observation.txt", "UTF-8"))
    if !RegExMatch(data, "^(\d+)\|(-?\d+)\|(-?\d+)\|(\d+)$", &m) || m[1] = magnetSeq
        return
    magnetSeq := m[1]
    x := Integer(m[2]), y := Integer(m[3]), seen := Integer(m[4])
    if (!x && !y) || A_TickCount-seen > 1200 || A_TickCount-seen < 0
        return
    generation := runGeneration
    magnetBusy := true, mouseAutomationBusy := true
    try {
        MouseGetPos &oldX, &oldY
        if !MoveByRelativeInput(x, y, generation) || !running || generation != runGeneration || !magnetCheck.Value || !WinActive("ahk_id " hwnd) || phase != "game" || A_TickCount-phaseAt > 15000 || magnetUsed
            return
        latest := ""
        try latest := Trim(FileRead(helperDir "\magnet-observation.txt", "UTF-8"))
        if !RegExMatch(latest, "^(\d+)\|(-?\d+)\|(-?\d+)\|(\d+)$", &check)
            return
        age := A_TickCount-Integer(check[4])
        if age < 0 || age > 1200 || Abs(Integer(check[2])-x) > 10 || Abs(Integer(check[3])-y) > 10
            return
        if !ClickGuard(generation)
            return
        ; Re-check that the magnet is still detected after the guard wait.
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
        if !running || generation != runGeneration || !magnetCheck.Value || !WinActive("ahk_id " hwnd) || phase != "game" || A_TickCount-phaseAt > 15000 || magnetUsed {
            Critical "Off"
            return
        }
        SendInput "{LButton down}"
        magnetUsed := true
        Critical "Off"
        try Sleep 60
        finally SendInput "{LButton up}"
        magnetLastClick := A_TickCount
        LogEvent("magnet_clicked", "x=" x " y=" y " once_per_game=1")
        StopMagnet()
        if running && generation = runGeneration && WinActive("ahk_id " hwnd)
            MouseMove oldX, oldY, 0
    } finally {
        magnetBusy := false, mouseAutomationBusy := false
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
    global hudHits, hudMissingAt, lobbyHits, returnHits, returnLeftAt, lobbyStableAt, lastLobbyClick, lobbyClickAttempts, lobbyClickSent, lobbyCandidateAt
    global entryHits, entryAttempts, focusPaused, focusPauseAt, focusRetryAt, focusAttempts, focusActiveAt, magnetUsed, gamesPlayed
    global waitingLoadingAt, transferPending, transferLobbyAt, entryLobbyAt, entrySideRetries, entryLoadingAt
    global gameStartCandidateAt, gameVerified
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
            waitingLoadingAt := 0, transferLobbyAt := 0, entryLoadingAt := 0, gameStartCandidateAt := 0
            SendEvent "{d up}{a up}{w up}{s up}{Space up}{t up}"
            LogEvent("focus_paused", "movement released")
        }
        if !WinExist("ahk_id " hwnd) {
            replacement := WinExist("ahk_exe RobloxPlayerBeta.exe")
            if replacement && replacement != hwnd {
                if !ReconnectRoblox(replacement)
                    return
                focusAttempts := 0, focusRetryAt := now+1000
            }
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
        if !RegExMatch(data, "^(\d+)\|(none|jump|dive)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)$", &resume) || resume[1] = lastSeq {
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
        ; After multiple failed searches, retry the initial sideways route
        ; only if recent frames still look like a settled, unqueued lobby.
        if entryAttempts >= 3 && entryLobbyAt && now-entryLobbyAt >= 3000 {
            entrySideRetries += 1, entryAttempts := 0, entryLobbyAt := 0
            phase := "entry", phaseAt := now
            SendEvent "{d down}"
            LogEvent("entry_side_retry", "retry=" entrySideRetries " reason=search_exhausted_lobby_visible")
            status.Text := "Status: Retrying entry (D for 7.5 seconds)"
        } else {
            entryAttempts += 1
            phase := "entry_search_w", phaseAt := now
            SendEvent "{w down}"
            LogEvent("entry_search", "attempt=" entryAttempts " direction=w max_ms=1500")
            status.Text := "Status: Searching for entry (W)"
        }
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
    if RegExMatch(data, "^(\d+)\|(none|jump|dive|unfocused|error)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)\|(\d+)$", &m) && m[1] != lastSeq {
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
        entering := phase = "entry" || phase = "entry_check" || phase = "entry_search_w" || phase = "entry_search_s" || phase = "entry_search_center"
        if entering {
            ; Transfers can occur while searching too. Stop moving as soon as
            ; a loading view appears and re-enter only after the new lobby.
            loading := Integer(m[13]) = 1 || Integer(m[10]) > 22000
            if loading {
                if !entryLoadingAt
                    entryLoadingAt := now
                else if now-entryLoadingAt >= 300 {
                    SendEvent "{d up}{a up}{w up}{s up}"
                    LogEvent("entry_loading_detected", "previous_phase=" phase " loading=" m[10] " dark=" m[13] " stable_ms=" (now-entryLoadingAt))
                    phase := "waiting", phaseAt := now, hudHits := 0
                    waitingLoadingAt := entryLoadingAt, transferPending := true, transferLobbyAt := 0, entryLobbyAt := 0
                    entryLoadingAt := 0, gameStartCandidateAt := 0
                    status.Text := "Status: Loading while entering; waiting for new lobby"
                    return
                }
            } else
                entryLoadingAt := 0
            settledLobby := Integer(m[12]) = 1 && Integer(m[11]) < 650 && Integer(m[4]) < 1000
                && Integer(m[6]) < 600 && Integer(m[7]) < 120 && Integer(m[9]) < 1200 && Integer(m[10]) < 12000
            if settledLobby {
                if !entryLobbyAt
                    entryLobbyAt := now
            } else
                entryLobbyAt := 0
        }
        if phase = "entry_check" || phase = "entry_search_w" || phase = "entry_search_s" || phase = "entry_search_center" {
            entryHits := Integer(m[11]) >= 650 ? entryHits+1 : 0
            if entryHits >= 2 {
                SendEvent "{d up}{a up}{w up}{s up}"
                LogEvent("entry_line_detected", "score=" m[11] " corrections=" entryAttempts)
                phase := "waiting", phaseAt := now, hudHits := 0
                waitingLoadingAt := 0, transferPending := false, transferLobbyAt := 0
                status.Text := "Status: Green line detected; waiting for Broom Sweep"
            }
        }
        ; Require a timer together with a HUD label or the green Dive button.
        ; A recognized JUMP/DIVE prompt is an independent fallback.
        timer := Integer(m[7]) >= 120 && Integer(m[7]) <= 1000
        hudLabel := Integer(m[3]) >= 18 && Integer(m[3]) <= 180
        diveButton := Integer(m[6]) >= 600
        cuePresent := m[2] = "jump" || m[2] = "dive"
        hud := (timer && (hudLabel || diveButton)) || cuePresent
        if phase = "waiting" {
            ; Loading and menus can coincidentally contain white and green.
            ; Require a clean HUD for 400 ms, or a recognized prompt itself.
            clearScene := Integer(m[10]) < 8000 && Integer(m[9]) < 4000 && Integer(m[13]) = 0
            startHud := timer && (hudLabel || diveButton) && clearScene
            if startHud {
                if !gameStartCandidateAt
                    gameStartCandidateAt := now
            } else
                gameStartCandidateAt := 0
            if cuePresent || gameStartCandidateAt && now-gameStartCandidateAt >= 400 {
                phase := "game", phaseAt := now, hudMissingAt := 0, lobbyHits := 0, lastCue := "", lastCueAt := 0
                gameVerified := cuePresent || hudLabel
                lobbyClickSent := false, lobbyCandidateAt := 0
                gameStartCandidateAt := 0
                waitingLoadingAt := 0, transferPending := false, transferLobbyAt := 0
                gamesPlayed += 1
                gameCounter.Text := "Games played: " gamesPlayed
                LogEvent("game_started", "count=" gamesPlayed " hud=" m[3] " dive_green=" m[6] " timer=" m[7] " cue=" m[2])
                status.Text := "Status: Watching JUMP and DIVE cues"
                ; Do not miss the first prompt if it was the start signal.
                if m[2] = "jump" || m[2] = "dive" {
                    if m[2] = "jump"
                        SendEvent "{Space}"
                    else
                        SendEvent "t"
                    lastCue := m[2], lastCueAt := now
                }
                if magnetCheck.Value && !magnetUsed
                    StartMagnet()
            } else if MaybeRecoverServerTransfer(m, now, hud) {
                return
            } else if Integer(m[10]) > 22000 || Integer(m[13]) = 1 {
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
            if hudLabel || cuePresent
                gameVerified := true
            if !gameVerified && now-phaseAt >= 8000 {
                LogEvent("game_start_rejected", "reason=no_hud_label_or_cue elapsed_ms=" (now-phaseAt))
                gamesPlayed := Max(0, gamesPlayed-1)
                gameCounter.Text := "Games played: " gamesPlayed
                StopMagnet()
                phase := "waiting", phaseAt := now, hudHits := 0
                transferPending := true, waitingLoadingAt := 0, transferLobbyAt := 0, gameStartCandidateAt := 0
                status.Text := "Status: Checking for game or returned lobby"
                return
            }
            ; The HUD can disappear or look different on another display.
            ; Keep reacting to cues until the Lobby button is confirmed, or
            ; a generous safety limit expires to avoid playing later games.
            lobbyHits := Integer(m[4]) > 4500 ? lobbyHits+1 : 0
            if lobbyHits >= 3 {
                if surviveCheck.Value || (broomCheck.Value && broomAfter.Value > 1 && !broomUsed) {
                    LogEvent("waiting_next_game", "reason=round_end red=" m[4])
                    phase := "broom_wait", phaseAt := now, lobbyHits := 0
                    status.Text := "Status: Waiting for the next game"
                } else {
                    LogEvent("waiting_for_lobby", "reason=lobby_button_confirmed red=" m[4])
                    phase := "return", phaseAt := now, lobbyHits := 0
                    status.Text := "Status: Round ended; looking for Lobby button"
                }
            } else if now-phaseAt >= 75000 {
                if surviveCheck.Value || (broomCheck.Value && broomAfter.Value > 1 && !broomUsed) {
                    LogEvent("waiting_next_game", "reason=round_time_elapsed")
                    phase := "broom_wait", phaseAt := now
                    status.Text := "Status: Waiting for the next game"
                } else {
                    LogEvent("waiting_for_lobby", "reason=round_safety_timeout elapsed_ms=" (now-phaseAt))
                    phase := "return", phaseAt := now, lobbyHits := 0
                    status.Text := "Status: Round time limit; looking for Lobby button"
                }
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
        } else if phase = "game2" || phase = "broom_wait" {
            if DetectGame2Elimination(m, now)
                return
            ; Without a confirmed next-round label, do not guess when to use
            ; the broom. Release movement and return after a generous limit.
            if now-phaseAt >= 120000 {
                StopGame2Movement()
                LogEvent("waiting_next_game_timeout", "phase=" phase)
                phase := "return", phaseAt := now, lobbyHits := 0
                status.Text := "Status: Next game not confirmed; looking for Lobby"
            }
        } else if phase = "return" {
            if MaybeResumeFromLobby(m, now)
                return
            ; Never send another Lobby click for a game after one has been
            ; sent, even if the view changes or the click routine is interrupted.
            if lobbyClickSent {
                lobbyCandidateAt := 0
                status.Text := "Status: Lobby click sent; waiting for lobby"
                return
            }
            likelyButton := Integer(m[4]) > 4500 && Integer(m[12]) != 1
                && Integer(m[10]) < 12000 && m[2] = "none"
            if likelyButton {
                if !lobbyCandidateAt
                    lobbyCandidateAt := now
            } else
                lobbyCandidateAt := 0
            if lobbyCandidateAt && now-lobbyCandidateAt >= 1500 {
                if mouseAutomationBusy
                    return
                if !ClickLobbyButton(m[4]) || !running || tickGeneration != runGeneration
                    return
                phase := "returning", phaseAt := A_TickCount, returnHits := 0
                returnLeftAt := 0, lobbyStableAt := 0
                lastLobbyClick := phaseAt, lobbyClickAttempts := 1, lobbyCandidateAt := 0
                status.Text := "Status: Returning to lobby"
            }
        } else if phase = "returning" {
            ; Do not retry a click based on fluctuating red scenery: the home
            ; button can occupy the same coordinates as the Lobby button.
            if Integer(m[4]) < 1000 && !returnLeftAt {
                returnLeftAt := now
                LogEvent("lobby_button_disappeared", "red=" m[4])
            }
            if !returnLeftAt && now-lastLobbyClick >= 8000
                status.Text := "Status: Lobby click unconfirmed; check Roblox"
            if MaybeResumeFromLobby(m, now)
                return
            if returnLeftAt {
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





DetectGame2Elimination(observation, now) {
    global game2LobbyAt, phase, phaseAt, lobbyHits
    ; Require a sustained Lobby-button signal. A transient red animation
    ; should not stop movement or cause an accidental click.
    lobbyVisible := Integer(observation[4]) > 4500 && Integer(observation[12]) != 1
    if !lobbyVisible {
        game2LobbyAt := 0
        return false
    }
    if !game2LobbyAt {
        game2LobbyAt := now
        return false
    }
    if now-game2LobbyAt < 800
        return false
    StopGame2Movement()
    LogEvent("game2_lobby_detected", "red=" observation[4] " stable_ms=" (now-game2LobbyAt) " phase=" phase)
    phase := "return", phaseAt := now, lobbyHits := 0, game2LobbyAt := 0
    status.Text := "Status: Eliminated; returning to lobby"
    return true
}

ReconnectRoblox(replacement) {
    global hwnd, helperPid, lastSeq, freshAt, transferPending, waitingLoadingAt, transferLobbyAt
    oldHwnd := hwnd
    if helperPid && ProcessExist(helperPid) {
        try ProcessClose helperPid
        try ProcessWaitClose helperPid, 2
    }
    helperPid := 0
    try FileDelete helperDir "\observation.txt"
    python := A_ScriptDir "\runtime\python\pythonw.exe"
    if !FileExist(python)
        python := EnvGet("USERPROFILE") "\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
    try {
        hwnd := replacement
        Run '"' python '" "' helperDir '\live_detector.py" ' hwnd, helperDir, "Hide", &helperPid
        if broomCheck.Value || surviveCheck.Value {
            StopBroomWorker()
            StartBroomWorker()
        }
        lastSeq := "", freshAt := A_TickCount
        if phase = "waiting"
            transferPending := true, waitingLoadingAt := 0, transferLobbyAt := 0
        LogEvent("roblox_window_replaced", "old=" oldHwnd " new=" hwnd " helper=" helperPid)
        return true
    } catch Error as e {
        Stop("Could not reconnect detector: " e.Message)
        return false
    }
}

MaybeRecoverServerTransfer(observation, now, hud) {
    global waitingLoadingAt, transferPending, transferLobbyAt
    global phase, phaseAt, entryHits, entryAttempts, hudHits, entryLobbyAt, entrySideRetries
    loading := Integer(observation[13]) = 1 || Integer(observation[10]) > 22000
    if loading {
        transferLobbyAt := 0
        if !waitingLoadingAt
            waitingLoadingAt := now
        else if !transferPending && now-waitingLoadingAt >= 800 {
            transferPending := true
            LogEvent("waiting_transfer_candidate", "reason=loading_screen")
        }
        return false
    }
    waitingLoadingAt := 0
    quiet := !hud && Integer(observation[4]) < 1000 && Integer(observation[6]) < 600
        && Integer(observation[7]) < 120 && Integer(observation[9]) < 1200
        && Integer(observation[10]) < 12000 && Integer(observation[11]) < 650
    if !transferPending || Integer(observation[12]) != 1 || !quiet {
        transferLobbyAt := 0
        return false
    }
    if !transferLobbyAt {
        transferLobbyAt := now
        LogEvent("waiting_transfer_lobby_candidate", "green=" observation[11])
        return false
    }
    if now-transferLobbyAt < 4000
        return false
    LogEvent("waiting_transfer_reenter", "stable_ms=" (now-transferLobbyAt))
    phase := "entry", phaseAt := now, entryHits := 0, entryAttempts := 0, hudHits := 0
    transferPending := false, waitingLoadingAt := 0, transferLobbyAt := 0, entryLobbyAt := 0, entrySideRetries := 0
    SendEvent "{d down}"
    status.Text := "Status: New server detected; entering again"
    return true
}

MaybeResumeFromLobby(observation, now) {
    global phase, phaseAt, returnLeftAt, lobbyStableAt, entryHits, entryAttempts, magnetUsed, entryLobbyAt, entrySideRetries
    global broomUsed, eventRound, eventRoundAt, roundCandidate, roundHits
    red := Integer(observation[4])
    topPurple := Integer(observation[5])
    spawnEvidence := Integer(observation[12]) = 1
    quiet := Integer(observation[6]) < 600 && Integer(observation[7]) < 120
        && Integer(observation[9]) < 1200 && Integer(observation[10]) < 12000
    ; The lower-screen evidence can also recover if the Lobby click succeeded
    ; but the controller missed the transition to the "returning" phase.
    oldEvidence := red < 1000 && phase = "returning" && returnLeftAt && now-returnLeftAt >= 1500 && topPurple > 8000
    candidate := quiet && now-phaseAt >= 12000 && (spawnEvidence || oldEvidence)
    if !candidate {
        lobbyStableAt := 0
        return false
    }
    if !lobbyStableAt {
        lobbyStableAt := now
        LogEvent("lobby_candidate", "purple=" topPurple " spawn=" spawnEvidence " timer=" observation[7])
        return false
    }
    if now-lobbyStableAt < 3000
        return false
    LogEvent("lobby_confirmed", "spawn=" spawnEvidence " stable_ms=" (now-lobbyStableAt))
    phase := "entry", phaseAt := now
    magnetUsed := false, entryHits := 0, entryAttempts := 0, lobbyStableAt := 0
    broomUsed := false, eventRound := 0, eventRoundAt := 0, roundCandidate := 0, roundHits := 0
    entryLobbyAt := 0, entrySideRetries := 0
    SendEvent "{d down}"
    status.Text := "Status: Entering again (D for 7.5 seconds)"
    return true
}

ClickGuard(generation) {
    global clickGuardCounter, clickGuardRetryAt
    if A_TickCount < clickGuardRetryAt
        return false
    if !running || generation != runGeneration || !WinActive("ahk_id " hwnd)
        return false
    clickGuardCounter += 1
    request := A_TickCount "" clickGuardCounter
    try {
        out := FileOpen(helperDir "\click-safety-request.txt", "w", "UTF-8-RAW")
        out.Write(request)
        out.Close()
    } catch {
        clickGuardRetryAt := A_TickCount+2000
        LogEvent("click_guard_blocked", "reason=request_write_failed")
        status.Text := "Status: Click paused; safety check unavailable"
        return false
    }
    started := A_TickCount
    while A_TickCount-started < 2000 {
        if !running || generation != runGeneration || !WinActive("ahk_id " hwnd)
            return false
        result := ""
        try result := Trim(FileRead(helperDir "\click-safety-result.txt", "UTF-8"))
        if RegExMatch(result, "^(\d+)\|([01])\|(\d+)$", &reply) && reply[1] = request {
            age := A_TickCount-Integer(reply[3])
            if age >= 0 && age <= 750 {
                if reply[2] = "0"
                    return true
                clickGuardRetryAt := A_TickCount+2000
                LogEvent("click_guard_blocked", "reason=home_icon")
                status.Text := "Status: Home icon detected; clicks paused"
                return false
            }
            break
        }
        Sleep 25
    }
    clickGuardRetryAt := A_TickCount+2000
    LogEvent("click_guard_blocked", "reason=check_timeout_or_stale")
    status.Text := "Status: Click paused; safety check unavailable"
    return false
}

ClickLobbyButton(redCount) {
    global lobbyClickSent
    if lobbyClickSent || A_TickCount < clickGuardRetryAt
        return false
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
    if !ClickGuard(clickGeneration) || !running || clickGeneration != runGeneration || !WinActive("ahk_id " hwnd) || phase != "return" && phase != "returning"
        return false
    ; Verify the Lobby button is still present after moving and checking.
    fresh := ""
    try fresh := Trim(FileRead(helperDir "\observation.txt", "UTF-8"))
    if !RegExMatch(fresh, "^\d+\|(?:none|jump|dive)\|\d+\|(\d+)\|", &check) || Integer(check[1]) <= 4500
        return false
    ; Latch before yielding so an interrupted click can never be repeated.
    Critical "On"
    if lobbyClickSent || !running || clickGeneration != runGeneration || !WinActive("ahk_id " hwnd) {
        Critical "Off"
        return false
    }
    SendInput "{LButton down}"
    lobbyClickSent := true
    Critical "Off"
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
    StopGame2Movement()
    StopBroomWorker()
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
