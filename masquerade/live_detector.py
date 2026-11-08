"""Watch the Roblox window and publish broom-cue observations locally."""
import ctypes
from ctypes import wintypes
from datetime import datetime
import json
import os
from pathlib import Path
import sys
import time

import numpy as np
from PIL import ImageGrab
from prompt_detector import detect

ROOT=Path(__file__).resolve().parent
def entry_confirmation(image):
    """Find a pale-green horizontal line surrounded by purple ground.

    The colors come from the user's entry-line sample. This is a visual
    candidate, not proof that Roblox registered the player as joined.
    """
    a=np.asarray(image if image.mode == 'RGB' and image.size == (960,515) else image.convert('RGB').resize((960,515)),dtype=np.int16)
    r,g,b=a[:,:,0],a[:,:,1],a[:,:,2]
    green=(r>=140)&(r<=215)&(g>=220)&(b>=115)&(b<=205)&(g-r>=25)&(g-b>=25)
    purple=(r>=75)&(r<=175)&(g<=105)&(b>=110)&(b>=r+10)
    # Ignore the permanent Dive button near the bottom center. Search the
    # rest of the view because the line's full-screen position is unknown.
    green[440:,400:560]=False
    green[:, :10]=False
    green[:, 950:]=False
    # Find candidate horizontal runs in one array operation; inspect only
    # those runs instead of looping through every pixel row in Python.
    padded=np.pad(green[12:500],((0,0),(1,1)),constant_values=False)
    starts_y,starts_x=np.nonzero(padded[:,1:] & ~padded[:,:-1])
    ends_y,ends_x=np.nonzero(padded[:,:-1] & ~padded[:,1:])
    for row,x0,endrow,xend in zip(starts_y,starts_x,ends_y,ends_x):
        if row != endrow or xend-x0 < 12:
            continue
        y=int(row)+12
        x1=min(int(xend),int(x0)+36)
        above=purple[y-12:y-3,x0:x1]
        below=purple[y+5:min(515,y+15),x0:x1]
        if above.size and below.size and above.mean()>=.25 and below.mean()>=.25:
            return 1.0
    return 0.0


def scene_info(image):
    """Conservative scene signals; absence is not proof of a completed round."""
    a=np.asarray(image if image.mode == 'RGB' and image.size == (960,515) else image.convert('RGB').resize((960,515)),dtype=np.int16)
    # HUD: warm yellow letters in the 'GAME 1 OF 6' strip.
    r,g,b=(a[54:73,440:521,i] for i in range(3))
    game_count=int(((r>170)&(g>140)&(b<120)).sum())
    # The elimination screen offers a large pink-red Lobby button near bottom.
    r,g,b=(a[450:495,300:660,i] for i in range(3))
    red_count=int(((r>175)&(g<85)&(b>25)&(b<155)).sum())
    r,g,b=(a[40:150,:,i] for i in range(3))
    purple_count=int(((r>145)&(b>125)&(g<90)&(r>g*1.6)&(b>g*1.4)).sum())
    r,g,b=(a[455:506,420:540,i] for i in range(3))
    dive_green=int(((g>170)&(r<155)&(b<110)&(g>r+35)).sum())
    r,g,b=(a[18:54,450:510,i] for i in range(3))
    timer_white=int(((r>190)&(g>190)&(b>190)).sum())
    r,g,b=(a[45:100,80:270,i] for i in range(3))
    entry_white=int(((r>190)&(g>190)&(b>190)).sum())
    r,g,b=(a[55:115,245:715,i] for i in range(3))
    countdown_white=int(((r>190)&(g>190)&(b>190)).sum())
    r,g,b=(a[170:340,390:570,i] for i in range(3))
    loading_white=int(((r>190)&(g>190)&(b>190)).sum())
    return game_count,red_count,purple_count,dive_green,timer_white,entry_white,countdown_white,loading_white


def main():
    hwnd=int(sys.argv[1]); user=ctypes.windll.user32
    user.SetProcessDPIAware()
    user.GetForegroundWindow.restype=wintypes.HWND
    user.GetWindowRect.argtypes=[wintypes.HWND,ctypes.POINTER(wintypes.RECT)]
    output=ROOT/'observation.txt'; temporary=ROOT/'observation.tmp'
    stop=ROOT/'stop.request'; log=ROOT/('broom-'+datetime.now().strftime('%Y%m%d-%H%M%S')+'.jsonl')
    seq=0; began=time.monotonic(); last_log=0.0; last_cue=None; last_phase=None
    phase_file=ROOT/'phase.txt'
    def publish(status):
        # Windows may temporarily deny replacement while AHK has the old
        # observation open. Treat that as a dropped frame, not a capture error.
        temporary.write_text(status,encoding='ascii')
        for attempt in range(4):
            try:
                os.replace(temporary,output)
                return True
            except PermissionError:
                if attempt < 3:
                    time.sleep(.003)
        return False
    with log.open('a',encoding='utf8',buffering=1) as f:
        while not stop.exists():
            start=time.monotonic(); rect=wintypes.RECT(); seq+=1
            try:
                focused=bool(user.GetForegroundWindow()==hwnd and user.GetWindowRect(hwnd,ctypes.byref(rect)))
                if focused:
                    im=ImageGrab.grab(bbox=(rect.left,rect.top,rect.right,rect.bottom),include_layered_windows=False,all_screens=True)
                    aspect=im.width/max(1,im.height)
                    frame=im.convert('RGB').resize((960,515))
                    try:
                        phase=phase_file.read_text(encoding='ascii').strip()
                    except (OSError, UnicodeError):
                        phase='unknown'
                    if phase not in ('entry','entry_check','entry_search_w','entry_search_s','entry_search_center','waiting','game','return','returning'):
                        phase='unknown'
                    # Match only signals that can affect the current phase.
                    # Unknown is conservative, so a missing file does not
                    # silently disable any detector.
                    cue,scores=detect(frame, source_aspect=aspect) if phase in ('waiting','game','unknown') else (None,{})
                    entry_score=entry_confirmation(frame) if phase in ('entry_check','entry_search_w','entry_search_s','entry_search_center','unknown') else 0.0
                    game,red,purple,green,timer,entry,countdown,loading=scene_info(frame)
                    status=f'{seq}|{cue or "none"}|{game}|{red}|{purple}|{green}|{timer}|{entry}|{countdown}|{loading}|{round(entry_score*1000)}'
                    if start-last_log >= 1.0 or cue != last_cue or phase != last_phase or entry_score:
                        f.write(json.dumps({'time':round(start-began,3),'phase':phase,'cue':cue,'scores':scores,'hud_yellow':game,'lobby_red':red,'lobby_purple':purple,'dive_green':green,'timer_white':timer,'entry_white':entry,'entry_score':round(entry_score,3),'countdown_white':countdown,'loading_white':loading,'window':[rect.left,rect.top,rect.right,rect.bottom],'processing_ms':round((time.monotonic()-start)*1000,1)})+'\n')
                        last_log=start; last_cue=cue; last_phase=phase
                else:
                    status=f'{seq}|unfocused|0|0|0|0|0|0|0|0|0'
                if not publish(status):
                    f.write(json.dumps({'event':'observation_busy','time':round(start-began,3)})+'\n')
            except Exception as e:
                f.write(json.dumps({'event':'error','error':repr(e)})+'\n')
                try:
                    publish(f'{seq}|error|0|0|0|0|0|0|0|0|0')
                except OSError as publish_error:
                    f.write(json.dumps({'event':'publish_error','error':repr(publish_error)})+'\n')
            time.sleep(max(.001,.025-(time.monotonic()-start)))


if __name__=='__main__':main()
