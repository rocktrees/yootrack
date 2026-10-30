#!/usr/bin/env python3
"""CPU per installed component, measured separately from the microbenchmarks."""
import json, time, subprocess, pathlib
root=pathlib.Path(__file__).resolve().parents[1]
def cpu_seconds(value):
    days=0
    if '-' in value:
        day,value=value.split('-',1);days=int(day)
    total=0
    for part in value.split(':'):total=total*60+float(part)
    return days*86400+total

def observe():
    output=subprocess.check_output(['/bin/ps','-ax','-ww','-o','pid=,ppid=,time=,comm='],text=True)
    records=[]
    for line in output.splitlines():
        fields=line.strip().split(None,3)
        if len(fields)==4: records.append({'pid':int(fields[0]),'parent':int(fields[1]),'cpu_seconds':cpu_seconds(fields[2]),'name':pathlib.Path(fields[3]).name})
    helpers={r['pid'] for r in records if r['name']=='ai.powerwatch.collector'}
    return {r['pid']:dict(r,role='app' if r['name']=='PowerWatch' else 'helper' if r['pid'] in helpers else 'powermetrics') for r in records if r['name']=='PowerWatch' or r['pid'] in helpers or (r['name']=='powermetrics' and r['parent'] in helpers)}
first=observe();assert any(r['role']=='app' for r in first.values()),'App not running'
previous=first;cpu={'app':0.,'helper':0.,'powermetrics':0.};restart={r:0 for r in cpu}
start=time.monotonic()
for _ in range(6):
    time.sleep(10)
    current=observe()
    for pid,r in current.items():
        old=previous.get(pid)
        if old: cpu[r['role']]+=max(0,r['cpu_seconds']-old['cpu_seconds'])
        else: restart[r['role']]+=1 # New-process lifetime CPU is omitted: conservative when startup precedes observation.
    previous=current
elapsed=time.monotonic()-start
result={'duration_seconds':elapsed,'cpu_seconds_by_role':cpu,'percent_of_one_core_by_role':{r:c/elapsed*100 for r,c in cpu.items()},'new_processes_by_role':restart,'note':'60-second background sample. Restarted-process first observation is omitted, so CPU may be underestimated if any restarts occur. Existing workloads continue; not a ten-minute acceptance test.'}
(root/'build/component-overhead-rust-evaluation.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
