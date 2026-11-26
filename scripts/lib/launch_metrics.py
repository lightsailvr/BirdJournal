#!/usr/bin/env python3
"""The arithmetic behind scripts/measure-launch.sh (issue #208): one launch's times from the app's `launch` signposts, and
the table over many launches.

    launch_metrics.py start-time <pid>              when the process started, in seconds since 1970 (microseconds kept)
    launch_metrics.py run <stream.ndjson> <pid> <start-time> [key=value ...]
                                                    one JSON line for that launch; exits 3 while it isn't interactive yet
    launch_metrics.py summary [--max-load <n>] <label.jsonl> ...
                                                    a Markdown table, one column per file: the median (lowest to highest),
                                                    over the launches taken at a 1-minute load average of n or less
"""
import ctypes
import datetime
import json
import os
import statistics
import sys

# The app's signposts (subsystem com.matthewcelia.mybirdjournal, category `launch`), in the order a launch emits them.
INTERVALS = [
    ("App init", "app_init_ms"),
    ("Stores ready", "stores_ready_ms"),
    ("Open packs", "open_packs_ms"),
    ("Open bundled pack", "open_bundled_pack_ms"),
    ("Open downloaded packs", "open_downloaded_packs_ms"),
    ("Read cached index and sets", "read_index_and_sets_ms"),
    ("Build collection", "build_collection_ms"),
    ("Decode cover", "decode_cover_ms"),
    ("Warm patch shader", "warm_shader_ms"),
]
ROWS = [
    ("process_to_interactive_ms", "Process start to \"Journal interactive\""),
    ("process_to_surface_ms", "Process start to the launch surface"),
    ("process_to_app_init_ms", "Process start to the app's init"),
    ("app_init_to_interactive_ms", "App init to \"Journal interactive\""),
] + [(key, f"`{name}`") for name, key in INTERVALS]


def start_time(pid):
    """The process's start from `proc_pidinfo` (PROC_PIDTBSDINFO): `ps` only gives it to the second."""
    buffer = ctypes.create_string_buffer(136)  # struct proc_bsdinfo
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    if libproc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), buffer, 136) != 136:
        raise OSError(ctypes.get_errno(), f"no such process: {pid}")
    seconds = int.from_bytes(buffer.raw[120:128], "little")
    microseconds = int.from_bytes(buffer.raw[128:136], "little")
    return seconds + microseconds / 1_000_000


def seconds(timestamp):
    """`log stream`'s "2026-11-26 13:06:10.016123-0800" as seconds since 1970."""
    return datetime.datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def run(stream, pid, started, extra):
    begins, result, marks = {}, {}, {}
    with open(stream, encoding="utf-8", errors="replace") as lines:
        for line in lines:
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:  # the line still being written
                continue
            if event.get("processID") != pid or event.get("eventType") != "signpostEvent":
                continue
            name, kind, at = event["signpostName"], event["signpostType"], seconds(event["timestamp"])
            if kind == "begin":
                begins.setdefault(name, at)
            elif kind == "end" and name in begins:
                marks.setdefault(name, (begins[name], at))
            elif kind == "event":
                marks.setdefault(name, (at, at))
                if name == "Launch context":
                    result["context"] = event.get("eventMessage", "")
    if "Journal interactive" not in marks:
        return None
    interactive = marks["Journal interactive"][0]
    result["process_to_interactive_ms"] = (interactive - started) * 1000
    if "Launch surface appeared" in marks:
        result["process_to_surface_ms"] = (marks["Launch surface appeared"][0] - started) * 1000
    if "App init" in begins:
        result["process_to_app_init_ms"] = (begins["App init"] - started) * 1000
        result["app_init_to_interactive_ms"] = (interactive - begins["App init"]) * 1000
    for name, key in INTERVALS:
        if name in marks:
            result[key] = (marks[name][1] - marks[name][0]) * 1000
    result["load_average"] = os.getloadavg()[0]
    result.update(extra)
    return {key: round(value, 2) if isinstance(value, float) else value for key, value in result.items()}


def summary(files, max_load=None):
    columns, busy = [], []
    for file in files:
        label = os.path.splitext(os.path.basename(file))[0]
        with open(file, encoding="utf-8") as lines:
            runs = [json.loads(line) for line in lines if line.strip()]
        if max_load is not None:
            calm = [run for run in runs if run["load_average"] <= max_load]
            busy.append(f"- {label}: {len(runs) - len(calm)} of {len(runs)} launches left out, taken at a load average over {max_load:g}")
            runs = calm
        columns.append((label, runs))
    print("| ms, median (lowest to highest) | " + " | ".join(f"{label}, {len(runs)} launches" for label, runs in columns) + " |")
    print("|---|" + "---:|" * len(columns))
    for key, title in ROWS:
        cells = []
        for _, runs in columns:
            values = [run[key] for run in runs if key in run]
            cells.append(f"{statistics.median(values):.1f} ({min(values):.1f} to {max(values):.1f})" if values else "")
        if any(cells):
            print(f"| {title} | " + " | ".join(cells) + " |")
    for title, key in [("Load average (1 min) over the launches", "load_average")]:
        cells = [f"{min(r[key] for r in runs):.1f} to {max(r[key] for r in runs):.1f}" if runs else "" for _, runs in columns]
        print(f"| {title} | " + " | ".join(cells) + " |")
    for line in busy:
        print(line)
    for label, runs in columns:
        for field in ("configuration", "commit", "context", "index_cached"):
            print(f"- {label}, {field}: " + "; ".join(sorted({str(run.get(field, '?')) for run in runs})))


def main(arguments):
    if len(arguments) == 2 and arguments[0] == "start-time":
        print(f"{start_time(int(arguments[1])):.6f}")
    elif len(arguments) >= 4 and arguments[0] == "run":
        extra = dict(pair.split("=", 1) for pair in arguments[4:])
        result = run(arguments[1], int(arguments[2]), float(arguments[3]), extra)
        if result is None:
            return 3
        print(json.dumps(result))
    elif len(arguments) >= 4 and arguments[:2] == ["summary", "--max-load"]:
        summary(arguments[3:], max_load=float(arguments[2]))
    elif len(arguments) >= 2 and arguments[0] == "summary":
        summary(arguments[1:])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
