---
name: Bug report
about: Limiar doesn't limit charging, or something else is wrong
labels: bug
---

**What happened**
<!-- e.g. "It charged past 80% overnight" -->

**Your Mac**
- Model (Apple menu › About This Mac):
- macOS version:
- Firmware (`system_profiler SPHardwareDataType | grep -i firmware`):
- Charger (MagSafe / USB-C, wattage):

**Diagnostics**
```
paste the output of:
/Applications/Limiar.app/Contents/MacOS/limiard status
/Applications/Limiar.app/Contents/MacOS/limiard diag
```
