#!/usr/bin/env python3
"""Observe only YooTrack and its collector. Close the app's windows/menu before running."""
import argparse
import ctypes
import json
from pathlib import Path
import subprocess
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument("--seconds", type=int, default=600)
parser.add_argument("--output", type=Path, default=Path("build/overhead.json"))
parser.add_argument("--diagnostics", type=Path, help="App diagnostic snapshot, used for root-process memory unavailable to this user")
options = parser.parse_args()
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int
def footprint_mb(pid):
    buffer = ctypes.create_string_buffer(1024)
    if libproc.proc_pid_rusage(pid, 6, ctypes.byref(buffer)) != 0: return None
    # rusage_info_v6 starts with a 16-byte UUID; ri_phys_footprint is the eighth uint64 field.
    return struct.unpack_from("=Q", buffer.raw, 72)[0] / 1048576

def cpu_seconds(value):
    days = 0
    if "-" in value:
        day, value = value.split("-", 1); days = int(day)
    fields = [float(part) for part in value.split(":")]
    result = 0
    for part in fields: result = result * 60 + part
    return days * 86400 + result

def observe():
    output = subprocess.check_output(["/bin/ps", "-ax", "-ww", "-o", "pid=,ppid=,rss=,time=,comm="], text=True)
    processes = []
    for line in output.splitlines():
        pieces = line.strip().split(None, 4)
        if len(pieces) != 5: continue
        pid, parent, rss, cpu, command = pieces
        processes.append(dict(pid=int(pid), parent=int(parent), rss_kb=int(rss), cpu_seconds=cpu_seconds(cpu), command=command))
    helpers = {p["pid"] for p in processes if Path(p["command"]).name in ("PowerWatchHelper", "ai.powerwatch.collector")}
    diagnostic_memory = {}
    if options.diagnostics:
        try:
            sample = json.loads(options.diagnostics.read_text())["sample"]
            # JSONEncoder's Date representation is seconds since 2001-01-01.
            if 0 <= time.time() - (sample["timestamp"] + 978307200) < 45:
                diagnostic_memory = {p["identity"]["pid"]: p["memoryBytes"] / 1048576
                                     for p in sample["processes"] if p.get("memoryBytes") is not None}
        except (OSError, ValueError, KeyError): pass
    selected = []
    for process in processes:
        name = Path(process["command"]).name
        if name == "PowerWatch": process["role"] = "app"
        elif process["pid"] in helpers: process["role"] = "helper"
        elif name == "powermetrics" and process["parent"] in helpers: process["role"] = "powermetrics"
        else: continue
        process["footprint_mb"] = footprint_mb(process["pid"])
        if process["footprint_mb"] is None: process["footprint_mb"] = diagnostic_memory.get(process["pid"])
        selected.append(process)
    return selected

first = observe()
if not any(p["role"] == "app" for p in first): raise SystemExit("Launch the Release app before measuring.")
initial = {p["pid"]: p["cpu_seconds"] for p in first}
last = {}; peak = dict(app=0, helper=0, powermetrics=0); footprint = dict(app=0, helper=0, powermetrics=0)
start = time.monotonic()
seen_helper = False
seen_roles = set()
measured_roles = set()
samples = 0
while True:
    records = observe(); samples += 1
    for record in records:
        seen_roles.add(record["role"])
        last[record["pid"]] = record
        peak[record["role"]] = max(peak[record["role"]], record["rss_kb"] / 1024)
        if record["footprint_mb"] is not None:
            measured_roles.add(record["role"])
            footprint[record["role"]] = max(footprint[record["role"]], record["footprint_mb"])
        if record["role"] == "powermetrics": seen_helper = True
    elapsed = time.monotonic() - start
    if elapsed >= options.seconds: break
    time.sleep(min(10, options.seconds - elapsed))

cpu = sum(max(0, p["cpu_seconds"] - initial.get(pid, 0)) for pid, p in last.items())
memory_complete = seen_roles <= measured_roles
result = dict(duration_seconds=round(elapsed, 2), samples=samples, collection_mode="full" if seen_helper else "basic", cpu_seconds=round(cpu, 3),
              average_percent_of_one_core=round(cpu / elapsed * 100, 3), peak_rss_mb=peak,
              peak_footprint_mb=footprint, memory_target_metric="ri_phys_footprint (same metric displayed in the app)",
              collection_peak_sum_mb=round(peak["helper"] + peak["powermetrics"], 2),
              collection_peak_footprint_sum_mb=round(footprint["helper"] + footprint["powermetrics"], 2),
              memory_measurement_complete=memory_complete,
              limits=dict(cpu_percent=1, app_mb=100, collection_mb=75),
              passed=memory_complete and cpu / elapsed * 100 < 1 and 0 < footprint["app"] < 100 and footprint["helper"] + footprint["powermetrics"] < 75)
result["peak_footprint_mb"] = {role: value if role not in seen_roles or role in measured_roles else None for role, value in footprint.items()}
options.output.parent.mkdir(parents=True, exist_ok=True)
options.output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2), flush=True)
