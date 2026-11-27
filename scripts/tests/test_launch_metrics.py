"""Launch metrics tests, on a signpost stream written here:
python3 -m unittest discover -s scripts/tests -p test_launch_metrics.py."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
import launch_metrics  # noqa: E402

# 13:06:10.000000 Pacific, as `log stream` writes it; the process "started" half a second before.
STARTED = launch_metrics.seconds("2026-11-26 13:06:09.500000-0800")


def signpost(pid, kind, name, at, message=""):
    return json.dumps({
        "eventType": "signpostEvent", "processID": pid, "signpostType": kind, "signpostName": name,
        "timestamp": f"2026-11-26 13:06:10.{at:06d}-0800", "eventMessage": message,
    })


def stream(folder, lines):
    path = Path(folder) / "stream.ndjson"
    path.write_text("\n".join(lines) + "\n")
    return path


LAUNCH = [
    'Filtering the log data using "subsystem == ..."',
    signpost(7, "begin", "App init", 0),
    signpost(7, "end", "App init", 80_000),
    signpost(7, "event", "Launch surface appeared", 100_000),
    signpost(7, "begin", "Stores ready", 100_100),
    signpost(7, "begin", "Open packs", 101_000),
    signpost(7, "begin", "Open bundled pack", 101_000),
    signpost(7, "end", "Open bundled pack", 110_500),
    signpost(7, "end", "Open packs", 115_000),
    signpost(7, "end", "Stores ready", 150_000),
    signpost(7, "event", "Launch context", 240_000, "sightings: 0; packs: us-ca-la:12"),
    signpost(7, "event", "Journal interactive", 250_000),
]


class RunTests(unittest.TestCase):
    def test_a_launch_is_timed_from_the_process_start_to_the_interactive_signpost(self):
        with tempfile.TemporaryDirectory() as folder:
            result = launch_metrics.run(stream(folder, LAUNCH), 7, STARTED, {"configuration": "Debug"})
        self.assertEqual(result["process_to_interactive_ms"], 750.0)
        self.assertEqual(result["process_to_surface_ms"], 600.0)
        self.assertEqual(result["process_to_app_init_ms"], 500.0)
        self.assertEqual(result["app_init_to_interactive_ms"], 250.0)
        self.assertEqual(result["app_init_ms"], 80.0)
        self.assertEqual(result["open_bundled_pack_ms"], 9.5)
        self.assertEqual(result["open_packs_ms"], 14.0)
        self.assertEqual(result["stores_ready_ms"], 49.9)
        self.assertEqual(result["context"], "sightings: 0; packs: us-ca-la:12")
        self.assertEqual(result["configuration"], "Debug")
        self.assertNotIn("build_collection_ms", result, "an interval the launch never logged is left out")

    def test_a_launch_that_is_not_interactive_yet_has_no_result(self):
        with tempfile.TemporaryDirectory() as folder:
            path = stream(folder, LAUNCH[:-1] + [LAUNCH[-1][:40]])  # the last line still being written
            self.assertIsNone(launch_metrics.run(path, 7, STARTED, {}))
            self.assertEqual(launch_metrics.main(["run", str(path), "7", str(STARTED)]), 3)

    def test_another_launchs_signposts_are_not_this_ones(self):
        earlier = [signpost(6, "begin", "App init", 0), signpost(6, "event", "Journal interactive", 10_000)]
        with tempfile.TemporaryDirectory() as folder:
            result = launch_metrics.run(stream(folder, earlier + LAUNCH), 7, STARTED, {})
            self.assertEqual(result["process_to_interactive_ms"], 750.0)
            self.assertIsNone(launch_metrics.run(stream(folder, earlier), 7, STARTED, {}))


class SummaryTests(unittest.TestCase):
    def test_the_table_has_a_column_per_label_with_the_median_and_the_range(self):
        with tempfile.TemporaryDirectory() as folder:
            for label, times in [("before", [900.0, 700.0, 800.0]), ("after", [650.0, 750.0])]:
                lines = [{"process_to_interactive_ms": time, "open_bundled_pack_ms": time / 100, "load_average": 4.0 + index,
                          "configuration": "Debug", "commit": label, "context": "sightings: 0; packs: us-ca-la:12"} for index, time in enumerate(times)]
                (Path(folder) / f"{label}.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                launch_metrics.summary([os.path.join(folder, "before.jsonl"), os.path.join(folder, "after.jsonl")])
        table = printed.getvalue().splitlines()
        self.assertEqual(table[0], "| ms, median (lowest to highest) | before, 3 launches | after, 2 launches |")
        self.assertIn('| Process start to "Journal interactive" | 800.0 (700.0 to 900.0) | 700.0 (650.0 to 750.0) |', table)
        self.assertIn("| `Open bundled pack` | 8.0 (7.0 to 9.0) | 7.0 (6.5 to 7.5) |", table)
        self.assertIn("| Load average (1 min) over the launches | 4.0 to 6.0 | 4.0 to 5.0 |", table)
        self.assertFalse(any("Build collection" in line for line in table), "a row no launch has is left out")
        self.assertIn("- before, context: sightings: 0; packs: us-ca-la:12", table)

    def test_launches_taken_under_load_can_be_left_out(self):
        with tempfile.TemporaryDirectory() as folder:
            lines = [{"process_to_interactive_ms": time, "load_average": load} for time, load in [(700.0, 4.0), (720.0, 30.0), (2900.0, 310.0)]]
            (Path(folder) / "before.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                self.assertEqual(launch_metrics.main(["summary", "--max-load", "30", os.path.join(folder, "before.jsonl")]), 0)
        table = printed.getvalue().splitlines()
        self.assertEqual(table[0], "| ms, median (lowest to highest) | before, 2 launches |")
        self.assertIn('| Process start to "Journal interactive" | 710.0 (700.0 to 720.0) |', table)
        self.assertIn("- before: 1 of 3 launches left out, taken at a load average over 30", table)


class StartTimeTests(unittest.TestCase):
    def test_this_process_started_before_now_and_not_long_ago(self):
        import time
        started = launch_metrics.start_time(os.getpid())
        self.assertLess(started, time.time())
        self.assertGreater(started, time.time() - 3600)


if __name__ == "__main__":
    unittest.main()
