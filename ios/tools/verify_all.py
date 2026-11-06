#!/usr/bin/env python3
# Runs every mode of OnAir's mode table against the built-in test signal on the simulator and writes one JSON line per mode. Usage: verify_all.py <out.jsonl> [seconds]
import json, os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(os.path.dirname(HERE))
out = sys.argv[1]; secs = int(sys.argv[2]) if len(sys.argv) > 2 else 14
SIM = "304F6404-088D-4278-9828-87B7B475812B"
table = open(os.path.join(ROOT, "app/ui/mode_table.cpp")).read()
rows = re.findall(r'^\s*\{(\d+|k\w+),\s*"([^"]+)",\s*(\d+),\s*IM_COL32\([^)]*\),\s*"[^"]*",\s*"[^"]*",\s*(?:"([^"]*)"|nullptr)', table, re.M)
modes = []
for family, name, group, sub in rows:
    label = sub or name
    if label not in [m[0] for m in modes]: modes.append((label, family, group))
done = set()
if os.path.exists(out):
    for line in open(out): done.add(json.loads(line)["mode"])
for label, family, group in modes:
    if label in done or label == "Plugins": continue
    t0 = time.time()
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", SIM, "net.rizos.onair", "--mode", label, "--source", "test", "--page", "mode", "--start"], capture_output=True)
    time.sleep(secs)
    alive = subprocess.run(["xcrun", "simctl", "spawn", SIM, "launchctl", "list"], capture_output=True, text=True).stdout.count("net.rizos.onair") > 0
    log = subprocess.run(["xcrun", "simctl", "spawn", SIM, "log", "show", "--last", "6s", "--predicate", 'process == "OnAir" AND eventMessage CONTAINS "OnAirVerify running"', "--style", "compact"], capture_output=True, text=True, errors="replace").stdout
    lines = [l for l in log.splitlines() if "OnAirVerify running" in l]
    last = lines[-1] if lines else ""
    r = {"mode": label, "family": family, "group": group, "alive": alive}
    m = re.search(r'running=(\d) std=(-?\d+) audioSec=([\d.]+) videoFrames=(\d+)', last)
    if m: r.update(running=int(m[1]), std=int(m[2]), audio=float(m[3]), video=int(m[4]))
    m = re.search(r'"summary":"((?:[^"\\]|\\.)*)"', last); r["summary"] = m[1][:120] if m else ""
    r["cards"] = last.count('",["') + ('"cards":[[' in last)
    r["rows"] = 0
    if '"rows":[[' in last: r["rows"] = 1
    open(out, "a").write(json.dumps(r) + "\n")
    print(label, r.get("running"), r.get("std"), r["alive"], r["summary"][:60], flush=True)
