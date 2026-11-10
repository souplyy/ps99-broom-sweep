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


def _runs(mask, gap=2):
    indices=np.flatnonzero(mask)
    if not indices.size:
        return []
    cuts=np.flatnonzero(np.diff(indices)>gap+1)+1
    return [(int(a[0]),int(a[-1])+1) for a in np.split(indices,cuts)]


def find_ready_magnet(image):
    """Find a ready Treat Magnet using the right-side button and label colors.

    Return normalized frame coordinates, or None. A Ready label, cyan button,
    purple icon and gold detail must all be present near one another.
    """
    a=np.asarray(image.convert('RGB').resize((960,515)),dtype=np.int16)
    xbase=640
    r,g,b=(a[:,xbase:,i] for i in range(3))
    cyan=(r<165)&(g>150)&(b>150)&(g-r>30)&(b-r>25)
    green=(g>155)&(g-r>55)&(g-b>35)
    purple=(r>65)&(b>80)&(r>g*1.3)&(b>g*1.3)
    gold=(r>150)&(g>95)&(b<90)&(r>b+50)
    # The Lucky Charm is orange, while the magnet has vivid purple/magenta
    # across its icon. Generic dark purple backgrounds are not sufficient.
    magenta=(r>110)&(b>120)&(r>g*1.6)&(b>g*1.6)
    for y0,y1 in _runs(cyan.sum(axis=1)>=8):
        if not 12 <= y1-y0 <= 100:
            continue
        for x0,x1 in _runs(cyan[y0:y1].sum(axis=0)>=3,gap=5):
            w=x1-x0; h=y1-y0
            if not 12 <= w <= 100 or not .4 <= w/h <= 2.4:
                continue
            area=w*h
            if cyan[y0:y1,x0:x1].sum() < area*.13:
                continue
            ready=green[max(0,y0-max(10,round(h*.8))):y0,x0:x1].sum()
            if ready < max(5,w*.16):
                continue
            icon=purple[y0:y1,x0:x1].sum()
            highlight=gold[y0:y1,x0:x1].sum()
            if icon < max(6,area*.025) or highlight < max(2,area*.004):
                continue
            if magenta[y0:y1,x0:x1].sum() < max(4,area*.04):
                continue
            return (xbase+(x0+x1)//2,(y0+y1)//2)
    return None


def home_icon_visible(image):
    """Recognize the red-roofed, yellow-door home icon in the lower center.

    The guard is intentionally conservative: a possible match blocks a click.
    """
    frame=image if image.mode=='RGB' and image.size==(960,515) else image.convert('RGB').resize((960,515))
    a=np.asarray(frame,dtype=np.int16)[330:515,288:672]
    r,g,b=a[:,:,0],a[:,:,1],a[:,:,2]
    red=(r>145)&(g<110)&(b<85)&(r>g+60)
    yellow=(r>200)&(g>95)&(g<205)&(b<55)
    neutral=(r>140)&(g>130)&(b>120)&(abs(r-g)<35)&(abs(g-b)<35)
    dark=(r<65)&(g<65)&(b<65)
    for y0,y1 in _runs(red.sum(axis=1)>=3,gap=3):
        for x0,x1 in _runs(red[y0:y1].sum(axis=0)>=2,gap=3):
            width=x1-x0; height=y1-y0
            if not (15<=width<=100 and 8<=height<=100):
                continue
            area=width*height
            xlo=max(0,x0-width//5); xhi=min(a.shape[1],x1+width//5)
            ylo=max(0,y0-height//5); yhi=min(a.shape[0],y1+height//2)
            region=(slice(ylo,yhi),slice(xlo,xhi))
            if (red[region].sum()>=max(20,area*.05)
                and yellow[region].sum()>=max(6,area*.015)
                and neutral[region].sum()>=max(12,area*.06)
                and dark[region].sum()>=max(10,area*.03)):
                return True
    return False


def lobby_spawn_visible(image):
    """Recognize a loaded event lobby even if the upper view is obstructed."""
    frame=image if image.mode=='RGB' and image.size==(960,515) else image.convert('RGB').resize((960,515))
    a=np.asarray(frame,dtype=np.int16)[200:480]
    r,g,b=a[:,:,0],a[:,:,1],a[:,:,2]
    pink=(r>145)&(b>125)&(g<110)&(r>g*1.4)&(b>g*1.25)
    return int(pink.sum()) >= 10000 and home_icon_visible(frame)


def dark_loading_visible(image):
    """Recognize a nearly black loading frame, not normal dark scenery."""
    frame=image if image.mode=='RGB' and image.size==(960,515) else image.convert('RGB').resize((960,515))
    a=np.asarray(frame)[160:400,180:780]
    return float((a.max(axis=2)<35).mean()) >= .90


def magnet_worker():
    hwnd=int(sys.argv[2]); user=ctypes.windll.user32
    user.SetProcessDPIAware()
    user.GetForegroundWindow.restype=wintypes.HWND
    user.GetWindowRect.argtypes=[wintypes.HWND,ctypes.POINTER(wintypes.RECT)]
    ctypes.windll.kernel32.GetTickCount.restype=wintypes.DWORD
    output=ROOT/'magnet-observation.txt'; temporary=ROOT/'magnet-observation.tmp'
    stop=ROOT/'stop.request'; seq=0
    while not stop.exists():
        seq+=1
        try:
            rect=wintypes.RECT()
            if user.GetForegroundWindow()==hwnd and user.GetWindowRect(hwnd,ctypes.byref(rect)):
                im=ImageGrab.grab(bbox=(rect.left,rect.top,rect.right,rect.bottom),include_layered_windows=False,all_screens=True)
                pos=find_ready_magnet(im)
                if pos:
                    x=rect.left+round(pos[0]*(rect.right-rect.left)/960)
                    y=rect.top+round(pos[1]*(rect.bottom-rect.top)/515)
                else:
                    x=y=0
            else:
                x=y=0
            timestamp=ctypes.windll.kernel32.GetTickCount()
            temporary.write_text(f'{seq}|{x}|{y}|{timestamp}',encoding='ascii')
            try: os.replace(temporary,output)
            except PermissionError: pass
        except Exception:
            pass
        time.sleep(.4)


def main():
    hwnd=int(sys.argv[1]); user=ctypes.windll.user32
    user.SetProcessDPIAware()
    user.GetForegroundWindow.restype=wintypes.HWND
    user.GetWindowRect.argtypes=[wintypes.HWND,ctypes.POINTER(wintypes.RECT)]
    output=ROOT/'observation.txt'; temporary=ROOT/'observation.tmp'
    stop=ROOT/'stop.request'; log=ROOT/('broom-'+datetime.now().strftime('%Y%m%d-%H%M%S')+'.jsonl')
    seq=0; began=time.monotonic(); last_log=0.0; last_cue=None; last_phase=None
    phase_file=ROOT/'phase.txt'
    safety_request=ROOT/'click-safety-request.txt'
    safety_output=ROOT/'click-safety-result.txt'
    safety_temp=ROOT/'click-safety-result.tmp'
    last_safety_request=''
    waiting_scan_at=0.0; waiting_entry=0.0; waiting_lobby=0
    entry_lobby_scan_at=0.0; entry_lobby=0
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
                    if phase=='waiting':
                        if start >= waiting_scan_at:
                            waiting_entry=entry_confirmation(frame)
                            waiting_lobby=int(lobby_spawn_visible(frame))
                            waiting_scan_at=start+.3
                        entry_score=waiting_entry
                        lobby_spawn=waiting_lobby
                        dark_loading=int(dark_loading_visible(frame))
                    else:
                        waiting_scan_at=0.0
                        entry_score=entry_confirmation(frame) if phase in ('entry_check','entry_search_w','entry_search_s','entry_search_center','unknown') else 0.0
                        if phase in ('entry','entry_check','entry_search_w','entry_search_s','entry_search_center'):
                            if start >= entry_lobby_scan_at:
                                entry_lobby=int(lobby_spawn_visible(frame))
                                entry_lobby_scan_at=start+.4
                            lobby_spawn=entry_lobby
                            dark_loading=int(dark_loading_visible(frame))
                        else:
                            entry_lobby_scan_at=0.0
                            lobby_spawn=int(lobby_spawn_visible(frame)) if phase in ('return','returning','unknown') else 0
                            dark_loading=0
                    game,red,purple,green,timer,entry,countdown,loading=scene_info(frame)
                    status=f'{seq}|{cue or "none"}|{game}|{red}|{purple}|{green}|{timer}|{entry}|{countdown}|{loading}|{round(entry_score*1000)}|{lobby_spawn}|{dark_loading}'
                    if start-last_log >= 1.0 or cue != last_cue or phase != last_phase or entry_score:
                        f.write(json.dumps({'time':round(start-began,3),'phase':phase,'cue':cue,'scores':scores,'hud_yellow':game,'lobby_red':red,'lobby_purple':purple,'dive_green':green,'timer_white':timer,'entry_white':entry,'entry_score':round(entry_score,3),'lobby_spawn':lobby_spawn,'dark_loading':dark_loading,'countdown_white':countdown,'loading_white':loading,'window':[rect.left,rect.top,rect.right,rect.bottom],'processing_ms':round((time.monotonic()-start)*1000,1)})+'\n')
                        last_log=start; last_cue=cue; last_phase=phase
                else:
                    status=f'{seq}|unfocused|0|0|0|0|0|0|0|0|0|0|0'
                if not publish(status):
                    f.write(json.dumps({'event':'observation_busy','time':round(start-began,3)})+'\n')
                # Respond only after the normal cue observation has been
                # published, so a click check does not delay a jump or dive.
                try:
                    request=safety_request.read_text(encoding='ascii').strip()
                except (OSError,UnicodeError):
                    request=''
                if focused and request.isdigit() and request != last_safety_request:
                    blocked=home_icon_visible(frame)
                    timestamp=ctypes.windll.kernel32.GetTickCount() & 0xffffffff
                    safety_temp.write_text(f'{request}|{int(blocked)}|{timestamp}',encoding='ascii')
                    try:
                        os.replace(safety_temp,safety_output)
                        last_safety_request=request
                        f.write(json.dumps({'event':'click_safety','blocked':blocked,'time':round(start-began,3)})+'\n')
                    except PermissionError:
                        pass
            except Exception as e:
                f.write(json.dumps({'event':'error','error':repr(e)})+'\n')
                try:
                    publish(f'{seq}|error|0|0|0|0|0|0|0|0|0|0|0')
                except OSError as publish_error:
                    f.write(json.dumps({'event':'publish_error','error':repr(publish_error)})+'\n')
            time.sleep(max(.001,.025-(time.monotonic()-start)))


if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='--magnet':
        magnet_worker()
    else:
        main()
