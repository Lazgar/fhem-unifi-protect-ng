#!/usr/bin/env python3
"""Creates controls_UnifiProtectNG.txt (FHEM update list). Run after every change of FHEM/*.pm and commit the result."""
import os, time
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lines = []
for f in sorted(os.listdir(os.path.join(here, "FHEM"))):
    if f.endswith(".pm"):
        p = os.path.join(here, "FHEM", f)
        t = time.strftime("%Y-%m-%d_%H:%M:%S", time.gmtime(os.path.getmtime(p)))
        lines.append("UPD %s %d FHEM/%s" % (t, os.path.getsize(p), f))
open(os.path.join(here, "controls_UnifiProtectNG.txt"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
