#!/usr/bin/env python3

import json
import math
import pathlib
import statistics
import sys
import re


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def command_output(path):
    value = read_json(path)
    data = value.get("data", value)
    if isinstance(data, dict):
        output = data.get("output", "")
        return output if isinstance(output, str) else ""
    return data if isinstance(data, str) else ""


def resource_value(text, memory=False):
    match = re.fullmatch(r"(-?[0-9]+(?:\.[0-9]+)?)([KMGTP]?)", text)
    if not match:
        return None
    value = float(match.group(1))
    suffix = match.group(2)
    if memory:
        multipliers = {"": 1.0 / 1024.0, "K": 1.0, "M": 1024.0, "G": 1024.0 * 1024.0, "T": 1024.0 * 1024.0 * 1024.0}
    else:
        multipliers = {"": 1.0, "K": 0.001, "M": 1.0, "G": 1000.0, "T": 1000000.0}
    return value * multipliers[suffix]


def process_sample(path):
    cpu_values = []
    rss_values = []
    phys_mem_values = []
    footprint_values = []
    cpu_time_values = []
    for line in command_output(path).splitlines():
        fields = line.split()
        if len(fields) < 3 or not fields[0].isdigit():
            continue
        if len(fields) >= 3:
            try:
                cpu = float(fields[1])
                rss = float(fields[2])
            except ValueError:
                cpu = None
                rss = None
            if cpu is not None and rss is not None and math.isfinite(cpu) and math.isfinite(rss):
                cpu_values.append(cpu)
                rss_values.append(rss)
        if len(fields) >= 6:
            resource = fields[2]
            value = fields[5]
            if resource == "phys_mem":
                parsed = resource_value(value, memory=True)
                if parsed is not None and math.isfinite(parsed):
                    phys_mem_values.append(parsed)
            elif resource == "phys_footprint":
                parsed = resource_value(value, memory=True)
                if parsed is not None and math.isfinite(parsed):
                    footprint_values.append(parsed)
            elif resource == "cpu_time":
                parsed = resource_value(value)
                if parsed is not None and math.isfinite(parsed):
                    cpu_time_values.append(parsed)
    return cpu_values, rss_values, phys_mem_values, footprint_values, cpu_time_values


def metrics(run_dir):
    cpu = []
    rss = []
    memory = []
    cpu_time = []
    paths = []
    for name in ["metrics-before.json"]:
        path = run_dir / name
        if path.exists():
            paths.append(path)
    paths.extend(sorted(run_dir.glob("metrics-sample-*.json")))
    for name in ["metrics-after.json"]:
        path = run_dir / name
        if path.exists():
            paths.append(path)
    for path in paths:
        sample_cpu, sample_rss, sample_phys_mem, sample_footprint, sample_cpu_time = process_sample(path)
        cpu.extend(sample_cpu)
        rss.extend(sample_rss)
        memory.extend(sample_footprint or sample_phys_mem)
        cpu_time.extend(sample_cpu_time)
    return cpu, rss, memory, cpu_time


def periodic_metric_sample_count(run_dir):
    return len(list(run_dir.glob("metrics-sample-*.json")))


def run_values(run_dir):
    values = {}
    try:
        lines = (run_dir / "run.txt").read_text().splitlines()
    except OSError:
        return values
    for line in lines:
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def touch_metrics(run_dir):
    path = run_dir / "touch-latency.tsv"
    delays = []
    stalls = 0
    hangs = 0
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return delays, stalls, hangs
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) < 10:
            continue
        try:
            delays.append(float(fields[6]))
            stalls += int(fields[7])
            hangs += int(fields[8])
        except ValueError:
            continue
    return delays, stalls, hangs


def frame_metrics(run_dir):
    path = run_dir / "frame-responsiveness.tsv"
    durations = []
    failures = 0
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return durations, failures
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) < 6:
            failures += 1
            continue
        try:
            durations.append(float(fields[3]))
        except ValueError:
            failures += 1
            continue
        try:
            if int(fields[4]) != 0 or int(fields[5]) != 0:
                failures += 1
        except ValueError:
            failures += 1
    return durations, failures


def crash_lines(run_dir, suffix):
    return [line for line in command_output(run_dir / f"crashes-{suffix}.json").splitlines() if line.strip()]


def required_artifacts(run_dir):
    names = [
        "run.txt",
        "metrics-before.json",
        "metrics-after.json",
        "touch-latency.tsv",
        "frame-responsiveness.tsv",
        "crashes-before.json",
        "crashes-after.json",
    ]
    return [name for name in names if not (run_dir / name).is_file()]


def summarize(run_dir):
    cpu, rss, memory, cpu_time = metrics(run_dir)
    delays, stalls, hangs = touch_metrics(run_dir)
    frames, frame_failures = frame_metrics(run_dir)
    values = run_values(run_dir)
    before_crashes = crash_lines(run_dir, "before")
    after_crashes = crash_lines(run_dir, "after")
    values_duration_ms = float(values.get("duration_ms", "0") or 0)
    ps_cpu_available = any(value > 0 for value in cpu)
    cpu_time_delta = None
    cpu_time_rate = None
    if len(cpu_time) >= 2:
        cpu_time_delta = cpu_time[-1] - cpu_time[0]
        if values_duration_ms > 0:
            cpu_time_rate = cpu_time_delta / values_duration_ms * 100.0
    cpu_median = statistics.median(cpu) if ps_cpu_available else cpu_time_rate
    rss_median = statistics.median(rss) if rss else None
    memory_median = statistics.median(memory) if memory else None
    memory_growth = None
    if len(memory) >= 2 and memory[0] > 0:
        memory_growth = (memory[-1] - memory[0]) / memory[0]
    return {
        "run": str(run_dir),
        "mode": values.get("mode"),
        "profile": values.get("profile"),
        "cpu_samples": len(cpu),
        "cpu_measurement_source": "ps" if ps_cpu_available else ("ltop_cpu_time" if cpu_time_rate is not None else None),
        "periodic_metric_samples": periodic_metric_sample_count(run_dir),
        "cpu_median_percent": cpu_median,
        "cpu_time_samples": len(cpu_time),
        "cpu_time_delta_units": cpu_time_delta,
        "cpu_time_rate_percent": cpu_time_rate,
        "rss_samples": len(rss),
        "rss_median_kb": rss_median,
        "memory_samples": len(memory),
        "memory_median_kb": memory_median,
        "memory_growth_ratio": memory_growth,
        "touch_samples": len(delays),
        "touch_median_delay_ms": statistics.median(delays) if delays else None,
        "touch_max_delay_ms": max(delays) if delays else None,
        "stalls_over_50ms": stalls,
        "hangs": hangs,
        "frame_samples": len(frames),
        "frame_failures": frame_failures,
        "frame_max_command_ms": max(frames) if frames else None,
        "crashes_before": len(before_crashes),
        "crashes_after": len(after_crashes),
        "new_crash_lines": len(set(after_crashes) - set(before_crashes)),
        "missing_artifacts": required_artifacts(run_dir),
    }


def load_run_dirs(suite_dir):
    paths = []
    try:
        lines = (suite_dir / "runs.tsv").read_text().splitlines()
    except OSError:
        return paths
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 3:
            continue
        path = pathlib.Path(fields[2])
        if path.is_dir():
            paths.append((fields[0], fields[1], path))
    return paths


def suite_values(suite_dir):
    values = {}
    try:
        lines = (suite_dir / "suite.txt").read_text().splitlines()
    except OSError:
        return values
    for line in lines:
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def main():
    if len(sys.argv) != 2:
        print("usage: analyze-gonerino-performance.py SUITE_DIRECTORY", file=sys.stderr)
        return 2
    suite_dir = pathlib.Path(sys.argv[1])
    run_dirs = load_run_dirs(suite_dir)
    if not run_dirs:
        print("performance suite has no completed runs", file=sys.stderr)
        return 1

    summaries = []
    failures = []
    grouped = {}
    expected_profiles = set(suite_values(suite_dir).get("profiles", "home subscriptions search long-form shorts").split())
    for profile, mode, run_dir in run_dirs:
        summary = summarize(run_dir)
        summary["profile"] = profile
        summary["mode"] = mode
        summaries.append(summary)
        grouped.setdefault(profile, {})[mode] = summary
        if summary["missing_artifacts"]:
            failures.append(f"{mode}/{profile}: missing artifacts {summary['missing_artifacts']}")
        if summary["cpu_median_percent"] is None or summary["memory_samples"] == 0:
            failures.append(f"{mode}/{profile}: missing process CPU or memory samples")
        if summary["periodic_metric_samples"] < 2:
            failures.append(f"{mode}/{profile}: fewer than two periodic process samples")
        if summary["touch_samples"] == 0:
            failures.append(f"{mode}/{profile}: missing touch-latency samples")
        if summary["frame_samples"] < 2:
            failures.append(f"{mode}/{profile}: missing frame-responsiveness samples")
        if summary["frame_failures"]:
            failures.append(f"{mode}/{profile}: frame capture or accessibility snapshot failed")
        if summary["stalls_over_50ms"] or summary["hangs"] or summary["new_crash_lines"]:
            failures.append(f"{mode}/{profile}: touch stall, hang, or new crash")
        if summary["frame_max_command_ms"] is not None and summary["frame_max_command_ms"] > 5000:
            failures.append(f"{mode}/{profile}: frame capture command exceeded 5000 ms")
        if summary["memory_growth_ratio"] is not None and summary["memory_growth_ratio"] > 0.20:
            failures.append(f"{mode}/{profile}: process memory grew more than 20 percent")

    for profile in sorted(expected_profiles):
        modes = grouped.get(profile, {})
        enabled = modes.get("enabled")
        disabled = modes.get("disabled")
        if not enabled or not disabled:
            failures.append(f"{profile}: missing matched enabled/disabled run")
            continue
        if enabled["cpu_median_percent"] is None or disabled["cpu_median_percent"] is None:
            failures.append(f"{profile}: missing CPU samples")
            continue
        delta = enabled["cpu_median_percent"] - disabled["cpu_median_percent"]
        enabled["matched_cpu_delta_percent"] = delta
        if abs(delta) > 2.0:
            failures.append(f"{profile}: matched median CPU delta exceeded 2 percentage points")
        if enabled["touch_median_delay_ms"] is None or disabled["touch_median_delay_ms"] is None:
            failures.append(f"{profile}: missing matched touch samples")
        else:
            touch_delta = enabled["touch_median_delay_ms"] - disabled["touch_median_delay_ms"]
            enabled["matched_touch_delta_ms"] = touch_delta
            if abs(touch_delta) > 50.0:
                failures.append(f"{profile}: matched touch latency delta exceeded 50 ms")

    report = {"suite": str(suite_dir), "runs": summaries, "failures": failures, "passed": not failures}
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
