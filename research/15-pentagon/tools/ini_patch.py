import sys, difflib
raw = open("/tmp/ini_now.bin","rb").read()[:2487]
txt = raw.decode("ascii")
lines = txt.split("\r\n")
keys = [l for l in lines if "=" in l]
bad  = [l for l in lines if l and "=" not in l and not l.startswith(("#",";","["))]
print("строк:", len(lines), "ключей:", len(keys), "подозрительных:", bad)
out = []; done = False
for l in lines:
    if l.startswith("pent1024.romset="):
        out.append("pent1024.romset=PENTGLUK.ROM"); done = True
    else:
        out.append(l)
if not done:
    idx = max(i for i, l in enumerate(out) if l.startswith("pent1024."))
    out.insert(idx+1, "pent1024.romset=PENTGLUK.ROM")
nb = "\r\n".join(out).encode("ascii")
print("было", len(raw), "-> стало", len(nb), "; ключей стало", len([l for l in out if "=" in l]))
assert len(nb) - len(raw) == len(b"pent1024.romset=PENTGLUK.ROM\r\n"), (len(nb), len(raw))
open("/tmp/ini_new.bin","wb").write(nb)
for d in difflib.unified_diff(lines, out, lineterm="", n=1):
    if d.startswith(("+","-")) and not d.startswith(("+++","---")): print("   ", d)
