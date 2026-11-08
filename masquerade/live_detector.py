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
    for y in range(12,500):
        row=green[y]
        starts=np.flatnonzero(row & ~np.r_[False,row[:-1]])
        ends=np.flatnonzero(row & ~np.r_[row[1:],False])
        for x0,x1 in zip(starts,ends):
            if x1-x0+1 < 12:
                continue
            # Limit the sample to one short section, as long lines may cross
            # over characters or different background colors.
            x1=min(x1,x0+35)
            above=purple[max(0,y-12):max(0,y-3),x0:x1+1]
            below=purple[min(515,y+5):min(515,y+15),x0:x1+1]
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
    seq=0; began=time.monotonic()
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
                    cue,scores=detect(frame, source_aspect=aspect)
                    entry_score=entry_confirmation(frame)
                    game,red,purple,green,timer,entry,countdown,loading=scene_info(frame)
                    status=f'{seq}|{cue or "none"}|{game}|{red}|{purple}|{green}|{timer}|{entry}|{countdown}|{loading}|{round(entry_score*1000)}'
                    f.write(json.dumps({'time':round(start-began,3),'cue':cue,'scores':scores,'hud_yellow':game,'lobby_red':red,'lobby_purple':purple,'dive_green':green,'timer_white':timer,'entry_white':entry,'entry_score':round(entry_score,3),'countdown_white':countdown,'loading_white':loading,'window':[rect.left,rect.top,rect.right,rect.bottom],'processing_ms':round((time.monotonic()-start)*1000,1)})+'\n')
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
            time.sleep(max(.005,.05-(time.monotonic()-start)))


if __name__=='__main__':main()
