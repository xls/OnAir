#!/usr/bin/env python3
# Walks every row of the app's own mode table against the built-in test signal on the simulator and writes one JSON line per mode. Usage: verify_all.py <out.jsonl> [seconds] [index,index,...]
import json, os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(os.path.dirname(HERE))
out = sys.argv[1]; secs = int(sys.argv[2]) if len(sys.argv) > 2 else 14
SIM = "304F6404-088D-4278-9828-87B7B475812B"
only = [int(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 else None
done = set()
if os.path.exists(out):
    for line in open(out): done.add(json.loads(line)["index"])
total = 400
index = -1
while index + 1 < total:
    index += 1
    if index in done or (only is not None and index not in only): continue
    t0 = time.time()
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", SIM, "net.rizos.onair", "--mode-index", str(index), "--source", "test", "--page", "mode", "--start"], capture_output=True)
    time.sleep(secs)
    alive = subprocess.run(["xcrun", "simctl", "spawn", SIM, "launchctl", "list"], capture_output=True, text=True).stdout.count("net.rizos.onair") > 0
    log = subprocess.run(["xcrun", "simctl", "spawn", SIM, "log", "show", "--last", "6s", "--predicate", 'process == "OnAir" AND eventMessage CONTAINS "OnAirVerify running"', "--style", "compact"], capture_output=True, text=True, errors="replace").stdout
    lines = [l for l in log.splitlines() if "OnAirVerify running" in l]
    last = lines[-1] if lines else ""
    head = [l for l in subprocess.run(["xcrun", "simctl", "spawn", SIM, "log", "show", "--last", str(secs + 8) + "s", "--predicate", 'process == "OnAir" AND eventMessage CONTAINS "OnAirVerify index"', "--style", "compact"], capture_output=True, text=True, errors="replace").stdout.splitlines() if "OnAirVerify index" in l]
    h = re.search(r'index (\d+) of (\d+) is (.*) family (\d+) group (.*)$', head[-1]) if head else None
    if h: total = int(h[2])
    r = {"index": index, "mode": h[3] if h else "?", "family": int(h[4]) if h else -1, "group": h[5] if h else "", "alive": alive}
    m = re.search(r'running=(\d) std=(-?\d+) audioSec=([\d.]+) videoFrames=(\d+)', last)
    if m: r.update(running=int(m[1]), std=int(m[2]), audio=float(m[3]), video=int(m[4]))
    m = re.search(r'"summary":"((?:[^"\\]|\\.)*)"', last); r["summary"] = m[1][:120] if m else ""
    shown = subprocess.run(["xcrun", "simctl", "spawn", SIM, "log", "show", "--last", "6s", "--predicate", 'process == "OnAir" AND eventMessage CONTAINS "OnAirVerify shown"', "--style", "compact"], capture_output=True, text=True, errors="replace").stdout
    shown = [l for l in shown.splitlines() if "OnAirVerify shown" in l]
    m = re.search(r'cards=(\d+) tables=(\d+) rows=(\d+) summary=(.*)$', shown[-1]) if shown else None
    r["decoded"] = bool(m)
    r["cards"], r["tables"], r["rows"] = (int(m[1]), int(m[2]), int(m[3])) if m else (0, 0, 0)
    if m: r["summary"] = m[4][:120]
    open(out, "a").write(json.dumps(r) + "\n")
    print(index, r["mode"], r.get("running"), r.get("std"), r["alive"], r["cards"], r["rows"], r["summary"][:50], flush=True)
