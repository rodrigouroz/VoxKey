#!/usr/bin/env python3
"""Summarize content-free local VoxKey performance records; never uploads data."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
from statistics import median


def summarize(directory):
    groups = defaultdict(list)
    outcomes = Counter()
    skipped = 0
    for path in sorted(directory.glob("*.json")):
        try:
            row = json.loads(path.read_text())
            if row["schemaVersion"] != 1:
                skipped += 1
                continue
            outcomes[row["outcome"]] += 1
            seconds = row["totals"].get("captureAudioSeconds", 0)
            length = "short (<15s)" if seconds < 15 else "medium (15–60s)" if seconds < 60 else "long (60s+)"
            key = (row["build"], row["model"], row["language"], row["improvementEnabled"], length)
            groups[key].append(row)
        except (ValueError, KeyError, TypeError):
            skipped += 1
    lines = ["# VoxKey performance measurements", "", f"Outcomes: {dict(outcomes)}. Unreadable/unsupported records: {skipped}.", "",
             "Timings below are medians / maxima in milliseconds. Small groups are observations, not reliable percentiles.",
             "Inference timings are wall time, not GPU utilization or energy. Process CPU includes other VoxKey work; memory is sampled RSS, not a true peak.", ""]
    for key, rows in sorted(groups.items()):
        build, model, language, improvement, length = key
        lines += [f"## {length} · improvement {'on' if improvement else 'off'} · {language}", "",
                  f"Build `{build}` · model `{model}` · {len(rows)} sessions", ""]
        for field in ("destination", "delivery"):
            diagnostics = [r[field] for r in rows if isinstance(r.get(field), dict)]
            if diagnostics:
                statuses = Counter(d.get("status", "unknown") for d in diagnostics)
                searches = Counter(attempts[-1].get("searchResult") for d in diagnostics
                                   if (attempts := d.get("focusAttempts")) and attempts[-1].get("searchResult"))
                lines += [f"{field.capitalize()} results: {dict(statuses)}."]
                if searches:
                    lines += [f"Last focus search results: {dict(searches)}."]
                if field == "destination":
                    lines += [f"Application categories: {dict(Counter(d.get('applicationCategory', 'unavailable') for d in diagnostics))}."]
                else:
                    lines += [f"Delivery routes: {dict(Counter(d.get('deliveryRoute', 'not attempted') for d in diagnostics))}."]
                lines += [""]
        completed = [r for r in rows if r["outcome"] in ("delivered", "unconfirmed", "noDestination")]
        lines += [f"Latency observations: {len(completed)} completed transcriptions; failures and cancellations excluded.", "",
                  "| Measurement | Median | Maximum | Samples |", "|---|---:|---:|---:|"]
        def emit(label, values):
            if values:
                lines.append(f"| {label} | {median(values):.1f} | {max(values):.1f} | {len(values)} |")
        def interval(start, end):
            return [max(0, r["milestonesMS"][end] - r["milestonesMS"][start]) for r in completed
                    if start in r["milestonesMS"] and end in r["milestonesMS"]]
        emit("Stop request → session finished (ms)", interval("releaseRequested", "finished"))
        emit("Stop request → recognition ready (ms)", interval("releaseRequested", "recognitionReady"))
        emit("Capture start → first preview (ms)", [max(0, r["totals"]["firstPreviewMS"] - r["milestonesMS"]["captureStarted"])
             for r in completed if "firstPreviewMS" in r["totals"] and "captureStarted" in r["milestonesMS"]])
        for label, metric in [("Improvement (ms)", "improvementMS"), ("S1 (ms)", "s1MS"), ("GECToR (ms)", "gectorMS"),
                              ("Delivery + confirmation (ms)", "deliveryMS"), ("Preview inference, whole session (ms)", "previewDecodeMS"),
                              ("Authoritative inference, whole session (ms)", "authoritativeDecodeMS"),
                              ("Waiting for preview cancellation (ms)", "previewCancellationWaitMS"),
                              ("Audio drain work (ms)", "drainMS"), ("Resampling work (ms)", "resampleMS"),
                              ("Audio remaining at stop (seconds)", "finalTailAudioSeconds"),
                              ("Preview decodes", "previewDecodes"), ("Completed decodes before stop", "authoritativeDecodesBeforeRelease")]:
            emit(label, [r["totals"][metric] for r in completed if metric in r["totals"]])
        emit("Process CPU time, whole session (ms)", [r["processCPUTimeMS"] for r in rows])
        emit("Process CPU time after stop (ms)", [max(0, r["processCPUTimeMS"] - r["captureProcessCPUTimeMS"])
             for r in completed if r.get("captureProcessCPUTimeMS") is not None])
        emit("Sampled process resident memory (MiB)", [r["sampledPeakResidentBytes"] / 2**20 for r in rows])
        emit("Preview audio processed / captured audio", [r["totals"].get("previewAudioSeconds", 0) / r["totals"]["captureAudioSeconds"]
             for r in completed if r["totals"].get("captureAudioSeconds", 0) > 0])
        lines += ["", f"Thermal states at finish (0 nominal, 1 fair, 2 serious, 3 critical): {dict(Counter(r['thermalStateAtEnd'] for r in rows))}", ""]
    if not groups:
        lines += ["No performance records yet. Use the local performance build for a few dictations.", ""]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path,
                        default=Path.home() / "Library/Application Support/com.rodrigouroz.VoxKey/Diagnostics/Performance")
    args = parser.parse_args()
    print(summarize(args.directory))
