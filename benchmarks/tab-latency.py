#!/usr/bin/env python3
"""Summarize native UI-test timing records, excluding test-driver round trips."""
import json
import math
from pathlib import Path
import statistics
import sys


def summarize(path):
    batches = []
    for line in Path(path).read_text().splitlines():
        if "TAB_RENDER_TIMINGS_MS " in line:
            batches.extend(json.loads(line.split("TAB_RENDER_TIMINGS_MS ", 1)[1]))
        elif line.startswith("{"):
            try:
                row = json.loads(line)
                if row.get("kind") == "tab":
                    batches.append(row)
            except (ValueError, AttributeError):
                pass
    if not batches:
        raise SystemExit(f"No tab timing records in {path}; check whether the UI test completed.")
    result = {}
    for tab in ["all", "live", "history"]:
        rows = [r["handler_to_view_ms"] for r in batches if tab == "all" or r["tab"] == tab]
        ordered = sorted(rows)
        result[tab] = {"count": len(rows), "first_ms": rows[0], "median_ms": statistics.median(rows),
                       "p95_ms": ordered[math.ceil(len(ordered) * .95) - 1], "max_ms": max(rows)}
        for component in ["handler_to_update_ms", "update_to_callback_ms"]:
            values = [r[component] for r in batches if component in r and (tab == "all" or r["tab"] == tab)]
            if values:
                result[tab][component] = {"median": statistics.median(values), "max": max(values)}
    return result


print(json.dumps({"scope": "handler to SwiftUI view update / next main-loop callback; excludes driver and final display presentation",
                  "runs": {path: summarize(path) for path in sys.argv[1:]}}, indent=2))
