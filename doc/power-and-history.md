# Power, activity, and history

[← Back to the README](../README.md)

YooTrack samples macOS process and hardware counters, groups related processes, and displays current activity in the menu bar and details window. It normally samples every five seconds while a view is open and every 15 seconds in the background. Some readings need two samples before a rate can be calculated; a dash means a value is unavailable, not necessarily zero.

## Live readings

| Reading | How to interpret it |
| --- | --- |
| Processor power (W) | An estimate from the change in a process’s macOS energy counter over time. It is not the total power drawn by all hardware associated with an app. |
| CPU (%) | CPU time across cores; 100% is approximately one fully occupied core, so a process can exceed 100%. |
| Memory | Reported physical memory footprint, summed for grouped processes when available. |
| GPU (%) | Driver-reported execution activity over time, not per-app GPU watts. Concurrent activity can exceed 100%, and app percentages do not necessarily add up to device utilization. |
| Network ↓ / ↑ | Bytes received and sent per second. These readings require the optional collector. |
| Battery discharge (W) | Estimated rate of energy leaving the battery, based on voltage and current. A battery can discharge while plugged in. |
| Energy Impact | Apple’s relative activity score from the collector; it is not watts. |

Apps may contain multiple processes. YooTrack groups processes by app bundle and eligible parent relationships. Work performed by shared system services may remain separate rather than being attributed to an app.

## The optional collector

Basic processor and native GPU monitoring work without administrator access. The optional collector runs with administrator privileges and uses `powermetrics` to provide additional readings, including Energy Impact, network rates, and CPU, GPU, and Neural Engine hardware power where available.

**The collector installer has an unresolved security finding.** It is not installed automatically; read the [security audit](../SECURITY_AUDIT.md) before choosing to install it. The [installation guide](install-and-development.md#optional-collector) explains setup and removal.

## History and battery estimates

History is stored in `~/Library/Application Support/YooTrack/history.sqlite`. YooTrack keeps up to seven days of data, subject to its storage limit, and compacts older samples into coarser time buckets. The available ranges are one minute, five minutes, 30 minutes, the last hour, today, seven days, and custom. Bucket boundaries and gaps make range totals approximate. Use **Settings → Clear History** to delete recorded history.

**Processor energy (Wh)** is the accumulated observed process energy for the selected range, including intervals when the Mac was plugged in. A processor-energy share compares a row’s processor energy to the recorded processor energy in the list.

**Battery loss** is measured in percentage points: a decrease from 80% to 79% is one point. YooTrack accumulates observed decreases across eligible samples, so the total need not equal the net change from the start of a range to the end, especially if charging occurred in between.

**Estimated share of drain** and **estimated battery contribution** use intervals that pass YooTrack’s battery-only attribution checks. The app compares measured processor energy with estimated battery discharge for those intervals and allocates a portion of the observed percentage-point decrease. Charging, adapter-supplemented intervals, missing readings, inconsistent counters, and sampling gaps can prevent attribution. The displayed **coverage** is the share of monitored time that passed those checks; low coverage means the estimate describes only a limited portion of the period. Graphics, the display, and other hardware remain unattributed.

These readings are estimates for investigating patterns, not a complete account of what caused battery use. See the [disclaimer](../DISCLAIMER.md#measurements-and-battery-estimates).

## Process details and summaries

Expand an app and select a process to inspect available details such as its executable, owner, parent chain, working directory, and filtered launch arguments. macOS can restrict inspection, and a current parent does not necessarily identify the original launcher. Paths and arguments may contain private information; filtering is heuristic and is not a guarantee that secrets are removed.

On supported systems, the **Summarize** action uses Apple’s on-device Foundation Models when available. It runs when requested and has no cloud-model fallback; when unavailable or unsuccessful, YooTrack can show a built-in explanation instead. AI explanations are interpretations, not verified facts.
