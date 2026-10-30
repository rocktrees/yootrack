#!/usr/bin/env python3
"""Release microbenchmarks; does not replace the installed app or change its collector."""
import json, subprocess, statistics, pathlib, platform
root=pathlib.Path(__file__).resolve().parents[1]
trials=[]
# Alternate order to limit cache/order bias. Both run as the invoking user.
for trial in range(8):
    order=['Swift','Rust'] if trial%2==0 else ['Rust','Swift']
    for language in order:
        command=[str(root/'build'/('benchmark-'+language.lower()))]
        if language=='Swift': command+=['process','200']
        else: command+=['200']
        reading=json.loads(subprocess.check_output(command,text=True))
        reading['trial']=trial;trials.append(reading)
# Compare the production Swift native/GPU/grouping/serialization pipeline separately.
phases=[]
for mode in ['gpu','pipeline']:
    for _ in range(3):
        phases.append(json.loads(subprocess.check_output([str(root/'build/benchmark-swift'),mode,'50'],text=True)))
summary={}
for language in ['Swift','Rust']:
    rows=[r for r in trials if r['language']==language]
    summary[language]={key:statistics.median(r[key] for r in rows) for key in ['cpu_ms_per_pass','wall_ms_per_pass','footprint_mib','processes','readable_processes']}
for mode in ['gpu','pipeline']:
    rows=[r for r in phases if r['mode']==mode]
    summary['Swift '+mode]={key:statistics.median(r[key] for r in rows) for key in ['cpu_ms_per_pass','wall_ms_per_pass','footprint_mib','processes','gpu_processes']}
# Reject comparisons where readable coverage differs materially.
assert abs(summary['Swift']['processes']-summary['Rust']['processes'])/summary['Swift']['processes']<.05
assert abs(summary['Swift']['readable_processes']-summary['Rust']['readable_processes'])/summary['Swift']['readable_processes']<.05
result={'machine':platform.machine(),'trials':trials,'phases':phases,'median':summary,
        'process_cpu_reduction_percent':100*(1-summary['Rust']['cpu_ms_per_pass']/summary['Swift']['cpu_ms_per_pass']),
        'scope':'Process enumeration, CPU/energy/memory counters, executable/name caches, and PID/start identity checks. Rust prototype does NOT implement GPU, battery, grouping, history, XPC, powermetrics parsing, UI, process controls or local AI.',
        'swift_pipeline_scope':'Production native process + GPU + battery reads, MeasurementEngine grouping/deltas, AppUsage aggregation, and JSON encoding; excludes powermetrics, SQLite writes, XPC and UI.',
        'privileges':'Both microbenchmarks run as the same logged-in user; neither elevates to root.',
        'c_shim':'Rust uses macOS SDK C struct-layout wrappers for BSD/rusage; kernel calls and identity checks match Swift. Includes C marshalling overhead.'}
output=root/'build/rust-swift-comparison.json';output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'median':summary,'process_cpu_reduction_percent':result['process_cpu_reduction_percent']},indent=2))
