# Usage: python3 compare.py <baseline-results-dir> <branch-results-dir>  (2026-10-26 dogfood cycle)
# "Changed suites" = skills/eval suites changed between main 2730201 and the measured branch skills 3177cde (needs git).
import json,sys,glob,collections
def solving(d):
    r=collections.defaultdict(list)
    for f in sorted(glob.glob(f"{d}/solving-*-20261026-*.json")):
        j=json.load(open(f))
        for c in j["cases"]:
            ok=all(a["value"] for a in c.get("assertions",{}).values())
            reason=" | ".join(str(a.get("reason",""))[:90] for a in c.get("assertions",{}).values() if not a["value"])
            r[c["name"]].append((ok,reason))
    for k,v in sorted(r.items()):
        print(f"  {k:40s} {sum(o for o,_ in v)}/{len(v)}  " + "; ".join(x for o,x in v if not o)[:200])
    tot=sum(len(v) for v in r.values()); p=sum(o for v in r.values() for o,_ in v); print(f"  TOTAL {p}/{tot}")
def trigger(d):
    f=sorted(glob.glob(f"{d}/trigger-20261026-*.json"))[-1]; j=json.load(open(f))
    cs=j["cases"]; ok=[c for c in cs if c["output"]==c["expected_output"]]
    print(f"  trigger {len(ok)}/{len(cs)} = {len(ok)/len(cs):.1%}  ({f.split('/')[-1]})")
    return {c["name"]:(c["output"],c["expected_output"]) for c in cs}
for arm,d in [("BASE (main 2730201 skills)",sys.argv[1]),("BRANCH",sys.argv[2])]:
    print(arm); solving(d); globals()[arm[:4]]=trigger(d)
b,n=globals()["BASE"],globals()["BRAN"]
print("trigger cases that changed outcome:")
for k in sorted(set(b)|set(n)):
    if k in b and k in n and (b[k][0]==b[k][1])!=(n[k][0]==n[k][1]):
        print(f"  {'FIXED ' if n[k][0]==n[k][1] else 'BROKE '} {k[:75]}  base={b[k][0]} branch={n[k][0]} want={n[k][1]}")
import os,subprocess
_root=os.path.join(os.path.dirname(os.path.abspath(__file__)),"..","..","..")
_changed=subprocess.run(["git","-C",_root,"diff","--name-only","2730201..3177cde","--","skills","evals"],capture_output=True,text=True).stdout.split()
TOUCHED={f.split("/")[1] for f in _changed if f.count("/")>=2 and f.split("/")[1] not in ("runner","tests","results")}
print("branch trigger failures in suites this branch changed:")
for k,(o,e) in sorted(n.items()):
    if o!=e and k.split("::")[0] in TOUCHED:
        print(f"  {k[:80]} got={o} want={e}")
