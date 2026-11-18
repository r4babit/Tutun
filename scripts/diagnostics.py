#!/usr/bin/env python3
"""A strict allowlist report: no logs, URLs, IPs, IDs, keys, process arguments or profile contents."""
import json,platform,plistlib,subprocess,sys
from pathlib import Path

def report():
    out={"format":1,"platform":platform.system(),"machine":platform.machine(),"os_version":platform.mac_ver()[0]}
    app=Path('/Applications/Tutun.app/Contents/Info.plist')
    if app.exists():
        p=plistlib.loads(app.read_bytes())
        out['mac']={k:p.get(k) for k in ['CFBundleShortVersionString','CFBundleVersion','LSMinimumSystemVersion']}
    adb=Path.home()/'Library/Android/sdk/platform-tools/adb'
    if adb.exists():
        # Query only package metadata; never invoke logcat or decrypt app state.
        p=subprocess.run([str(adb),'shell','dumpsys','package','app.tutun'],capture_output=True,text=True,timeout=15)
        import re
        out['android']={key:(m.group(1) if (m:=re.search(r'\b'+key+r'=([0-9.]+)',p.stdout)) else None) for key in ['versionCode','versionName','minSdk','targetSdk']}
    return out
if __name__=='__main__':
    print(json.dumps(report(),ensure_ascii=False,indent=2))
