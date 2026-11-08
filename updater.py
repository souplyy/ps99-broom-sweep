"""Startup updater for a configured public GitHub Releases repository.

Update assets are restricted to an explicit allowlist; local settings and logs
are not overwritten. Failure is non-fatal and never prevents offline startup.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.request
import zipfile
import subprocess
import sys

ROOT=Path(__file__).resolve().parent
CONFIG=ROOT/'version.json'
ALLOWED={'PS99-Broom.ahk','masquerade/live_detector.py','masquerade/prompt_detector.py',
         'masquerade/jump-reference.png','masquerade/dive-reference.png','updater.py','version.txt'}
MAX_DOWNLOAD=12*1024*1024


def macro_window_exists():
    """Find both the original and versioned macro-window titles."""
    user=ctypes.windll.user32
    found=[]
    callback_type=ctypes.WINFUNCTYPE(ctypes.c_bool,ctypes.c_void_p,ctypes.c_void_p)
    user.GetWindowTextLengthW.argtypes=[ctypes.c_void_p]
    user.GetWindowTextLengthW.restype=ctypes.c_int
    user.GetWindowTextW.argtypes=[ctypes.c_void_p,ctypes.c_wchar_p,ctypes.c_int]
    user.EnumWindows.argtypes=[callback_type,ctypes.c_void_p]
    @callback_type
    def visit(hwnd,_):
        size=user.GetWindowTextLengthW(hwnd)
        if size:
            title=ctypes.create_unicode_buffer(size+1)
            user.GetWindowTextW(hwnd,title,size+1)
            if title.value=='PS99 Broom Sweep' or title.value.startswith('PS99 Broom Sweep '):
                found.append(title.value)
                return False
        return True
    user.EnumWindows(visit,None)
    return bool(found)


def fetch(url,limit):
    request=urllib.request.Request(url,headers={'User-Agent':'BroomSweep-Updater/1','Accept':'application/vnd.github+json'})
    with urllib.request.urlopen(request,timeout=5) as response:
        data=response.read(limit+1)
    if len(data)>limit:
        raise ValueError('Update is larger than expected')
    return data


def log(message):
    try:
        with (ROOT/'update-status.log').open('a',encoding='utf8') as out:
            from datetime import datetime
            out.write(datetime.now().isoformat(timespec='seconds')+' '+message+'\n')
    except OSError:
        pass


def check_only():
    """Read release metadata only; never modify or interrupt the running macro."""
    settings=json.loads(CONFIG.read_text(encoding='utf8'))
    repository=settings.get('repository','')
    current=settings.get('version','')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repository):
        raise ValueError('Update source not configured')
    if not re.fullmatch(r'\d+\.\d+\.\d+',current):
        raise ValueError('Installed version is invalid')
    release=json.loads(fetch('https://api.github.com/repos/'+repository+'/releases/latest',1024*1024))
    latest=release.get('tag_name','').lstrip('v')
    if not re.fullmatch(r'\d+\.\d+\.\d+',latest):
        raise ValueError('Release tag must be a numeric version')
    available=latest if tuple(map(int,latest.split('.'))) > tuple(map(int,current.split('.'))) else ''
    target=ROOT/'update-available.txt'
    temp=ROOT/'update-available.tmp'
    temp.write_text(current+'|'+available,encoding='ascii')
    os.replace(temp,target)
    log('Background update check: '+('v'+available+' available' if available else 'up to date'))


def main():
    settings=json.loads(CONFIG.read_text(encoding='utf8'))
    repository=settings.get('repository','')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repository):
        log('Update source not configured; starting installed version.')
        return
    # Do not replace files in an already-running macro or its detector.
    if macro_window_exists():
        log('Macro is already running; update check skipped.')
        return
    release=json.loads(fetch('https://api.github.com/repos/'+repository+'/releases/latest',1024*1024))
    version=release.get('tag_name','').lstrip('v')
    if not re.fullmatch(r'\d+\.\d+\.\d+',version):
        raise ValueError('Release tag must be a numeric version')
    current=settings.get('version','0.0.0')
    if not re.fullmatch(r'\d+\.\d+\.\d+',current):
        raise ValueError('Installed version is invalid')
    if tuple(map(int,version.split('.'))) <= tuple(map(int,current.split('.'))):
        log('Already up to date: '+current)
        return
    assets={item['name']:item for item in release.get('assets',[]) if item.get('name') in {'broom-update.zip','broom-update.sha256'}}
    if set(assets)!={'broom-update.zip','broom-update.sha256'}:
        raise ValueError('Release is missing an update asset')
    prefix='https://github.com/'+repository+'/releases/download/'
    for asset in assets.values():
        if not asset['browser_download_url'].startswith(prefix):
            raise ValueError('Unexpected release asset source')
    checksum=fetch(assets['broom-update.sha256']['browser_download_url'],1024).decode('ascii').split()[0]
    data=fetch(assets['broom-update.zip']['browser_download_url'],MAX_DOWNLOAD)
    if not re.fullmatch(r'[0-9a-fA-F]{64}',checksum) or hashlib.sha256(data).hexdigest()!=checksum.lower():
        raise ValueError('Update checksum does not match')
    from io import BytesIO
    with zipfile.ZipFile(BytesIO(data)) as z:
        entries=z.infolist()
        if len(entries)!=len(ALLOWED) or {e.filename for e in entries}!=ALLOWED:
            raise ValueError('Unexpected or duplicate update files')
        if sum(e.file_size for e in entries)>MAX_DOWNLOAD:
            raise ValueError('Uncompressed update is too large')
        if z.read('version.txt').decode('ascii').strip()!=version:
            raise ValueError('Release and payload versions differ')
        contents={name:z.read(name) for name in ALLOWED if name!='version.txt'}
    # Stage and roll back on ordinary file errors; version is committed last.
    backups={name:(ROOT/name).read_bytes() if (ROOT/name).exists() else None for name in contents}
    applied=[]
    try:
        for name,content in contents.items():
            dest=ROOT/name; dest.parent.mkdir(parents=True,exist_ok=True)
            temp=dest.with_name(dest.name+'.update-tmp')
            temp.write_bytes(content);os.replace(temp,dest);applied.append(name)
        settings['version']=version
        temp=CONFIG.with_name('version.json.update-tmp')
        temp.write_text(json.dumps(settings,indent=2)+'\n',encoding='utf8');os.replace(temp,CONFIG)
    except Exception:
        for name in reversed(applied):
            dest=ROOT/name; old=backups[name]
            if old is None: dest.unlink(missing_ok=True)
            else: dest.write_bytes(old)
        raise
    log('Updated to '+version)


def wait_for_process(pid):
    kernel=ctypes.windll.kernel32
    kernel.OpenProcess.argtypes=[ctypes.c_uint32,ctypes.c_int,ctypes.c_uint32]
    kernel.OpenProcess.restype=ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_uint32]
    kernel.WaitForSingleObject.restype=ctypes.c_uint32
    kernel.CloseHandle.argtypes=[ctypes.c_void_p]
    handle=kernel.OpenProcess(0x00100000,False,pid)
    if not handle:
        return True
    try:
        return kernel.WaitForSingleObject(handle,15000)==0
    finally:
        kernel.CloseHandle(handle)


def run():
    reload_args=sys.argv[1:]
    if reload_args == ['--check-only']:
        try:
            check_only()
        except Exception as exc:
            log('Background update check failed: '+repr(exc))
        return
    if reload_args:
        if len(reload_args)!=4 or reload_args[0]!='--reload' or not reload_args[1].isdigit():
            raise ValueError('Invalid reload arguments')
        if not wait_for_process(int(reload_args[1])):
            log('Original macro did not exit; update cancelled.')
            ctypes.windll.user32.MessageBoxW(None, 'The macro did not close in time, so the update was cancelled. Close it and try Update / reload again.', 'Broom Sweep updater', 0x30)
            return
    try:
        main()
    except Exception as exc:
        log('Update check failed: '+repr(exc))
    finally:
        if reload_args:
            ahk,script=map(Path,reload_args[2:])
            if script.resolve() != (ROOT/'PS99-Broom.ahk').resolve():
                log('Cannot reopen: invalid script path.')
                ctypes.windll.user32.MessageBoxW(None, 'Could not reopen the macro because its script path was invalid. Open PS99-Broom.ahk manually.', 'Broom Sweep updater', 0x30)
            else:
                bundled=ROOT/'runtime'/'AutoHotkey64.exe'
                candidates=[path for i,path in enumerate((bundled,ahk)) if path.is_file() and path not in (bundled,ahk)[:i]]
                errors=[]
                for exe in candidates:
                    try:
                        process=subprocess.Popen([str(exe),str(script)],cwd=str(ROOT))
                        log('Relaunched macro: '+str(exe)+' pid='+str(process.pid))
                        break
                    except OSError as exc:
                        errors.append(repr(exc))
                else:
                    log('Cannot reopen macro: '+('; '.join(errors) or 'AutoHotkey executable missing'))
                    ctypes.windll.user32.MessageBoxW(None, 'The update check finished, but the macro could not reopen. Double-click PS99-Broom.ahk to start it. See update-status.log for details.', 'Broom Sweep updater', 0x30)


if __name__=='__main__':
    try: run()
    except Exception as exc: log('Update launcher failed: '+repr(exc))
