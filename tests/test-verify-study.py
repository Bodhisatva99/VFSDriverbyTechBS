#!/usr/bin/python3
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "vfs491-verify-study.py"
SPEC = importlib.util.spec_from_file_location("vfs491_verify_study", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class VerifyStudyTests(unittest.TestCase):
    CLAIM = "01234567-89ab-cdef-0123-456789abcdef"

    def test_parse_frame_event(self):
        line = (
            f"fprintd[123]: VFS491_EVENT type=frame claim_id={self.CLAIM} "
            "capture=4 width=200 height=239 bytes=47800 capture_ms=3636.0 "
            "min=0 p05=0 p50=96 p95=240 max=240 mean=115.53 stddev=89.7 "
            "entropy=3.738 dark_pct=13.15 bright_pct=19.33 row_sd=23.07 "
            "col_sd=36.38 grad_h=27.76 grad_v=31.58"
        )
        event = MODULE.parse_event_line(line)
        self.assertIsNotNone(event)
        self.assertEqual(event["type"], "frame")
        self.assertEqual(event["capture"], 4)
        self.assertEqual(event["height"], 239)
        self.assertAlmostEqual(event["mean"], 115.53)

    def test_parse_error_and_start_events(self):
        lines = "\n".join([
            f"VFS491_EVENT type=capture_start claim_id={self.CLAIM} capture=1",
            f"VFS491_EVENT type=capture_error claim_id={self.CLAIM} capture=1 broker_status=11 capture_ms=500.0",
        ])
        events = MODULE.extract_events(lines)
        self.assertEqual([event["type"] for event in events], ["capture_start", "capture_error"])
        self.assertEqual(events[1]["broker_status"], 11)

    def test_rejects_malformed_events(self):
        self.assertIsNone(MODULE.parse_event_line(f"VFS491_EVENT type=frame claim_id={self.CLAIM} capture=bad"))
        self.assertIsNone(MODULE.parse_event_line("VFS491_EVENT type=frame capture=1"))
        self.assertIsNone(MODULE.parse_event_line(
            f"VFS491_EVENT type=frame claim_id={self.CLAIM} capture=1 width=200 height=2 bytes=399"
        ))
        self.assertEqual(MODULE.extract_events("unrelated log line"), [])

    def test_journal_event_filter_uses_exact_process_interval(self):
        start = 1_800_000_000_000_000
        end = start + 4_000_000
        records = []
        for timestamp, sequence in ((start - 1, 1), (start + 1, 2), (end, 3), (end + 1, 4)):
            records.append(json.dumps({
                "MESSAGE": f"VFS491_EVENT type=capture_start claim_id={self.CLAIM} capture={sequence}",
                "__REALTIME_TIMESTAMP": str(timestamp),
            }))
        events = MODULE.extract_events("\n".join(records), start, end)
        self.assertEqual([event["capture"] for event in events], [2, 3])
        self.assertEqual(events[0]["journal_realtime_us"], start + 1)

    def test_parse_verify_results(self):
        self.assertEqual(MODULE.parse_result("Verify result: verify-match (done)"), "match")
        self.assertEqual(MODULE.parse_result("Verify result: verify-no-match (done)"), "no-match")
        self.assertEqual(MODULE.parse_result("Verify result: verify-retry-scan"), "retry-scan")
        self.assertEqual(MODULE.parse_result("Failed to match fingerprint"), "no-match")
        self.assertEqual(MODULE.parse_result("nothing useful"), "unknown")

    def test_cli_correlates_only_in_interval_journal_events(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            verify = root / "fake-fprintd-verify"
            journal = root / "fake-journalctl"
            timestamp_file = root / "verify-event.timestamp"
            output = root / "study.jsonl"
            verify.write_text(
                "#!/usr/bin/env python3\n"
                "import pathlib,time\n"
                f"pathlib.Path({str(timestamp_file)!r}).write_text(str(time.time_ns() // 1000))\n"
                "print('Verify result: verify-match (done)')\n"
            )
            journal.write_text(
                "#!/usr/bin/env python3\n"
                "import json,pathlib\n"
                f"now=int(pathlib.Path({str(timestamp_file)!r}).read_text())\n"
                f"claim={self.CLAIM!r}\n"
                "events=[\n"
                " {'MESSAGE':f'VFS491_EVENT type=capture_start claim_id={claim} capture=1','__REALTIME_TIMESTAMP':str(now)},\n"
                " {'MESSAGE':f'VFS491_EVENT type=frame claim_id={claim} capture=1 width=200 height=220 bytes=44000 capture_ms=2500.0 mean=120.0 entropy=3.5','__REALTIME_TIMESTAMP':str(now)},\n"
                " {'MESSAGE':f'VFS491_EVENT type=capture_start claim_id={claim} capture=99','__REALTIME_TIMESTAMP':str(now-5000000)},\n"
                " {'MESSAGE':f'VFS491_EVENT type=capture_start claim_id={claim} capture=100','__REALTIME_TIMESTAMP':str(now+5000000)},\n"
                "]\n"
                "for event in events: print(json.dumps(event))\n"
            )
            verify.chmod(0o755)
            journal.chmod(0o755)
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--finger", "right-index-finger",
                 "--class", "genuine", "--user", "study-user", "--fprintd-verify", str(verify),
                 "--journalctl", str(journal), "--output", str(output)],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            record = json.loads(output.read_text().strip())
            self.assertEqual(record["schema_version"], 2)
            self.assertEqual(record["result"], "match")
            self.assertEqual(record["trial_class"], "genuine")
            self.assertEqual(record["frame_count"], 1)
            self.assertEqual([e["capture"] for e in record["capture_events"]], [1, 1])
            self.assertIn("journal_realtime_us", record["capture_events"][0])
            self.assertNotIn("study-user", output.read_text())
            self.assertNotIn("Verify result", output.read_text())

    def test_append_record_is_private_jsonl_and_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "study.jsonl"
            MODULE.append_record(path, {"result": "match", "frame_count": 1})
            MODULE.append_record(path, {"result": "no-match", "frame_count": 1})
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            records = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual([item["result"] for item in records], ["match", "no-match"])
            target = root / "target"
            target.write_text("untouched")
            link = root / "link.jsonl"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                MODULE.append_record(link, {"result": "match"})
            self.assertEqual(target.read_text(), "untouched")

    def test_study_runs_are_serialized(self):
        with tempfile.TemporaryDirectory() as directory:
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = directory
            try:
                with MODULE.study_lock():
                    with self.assertRaises(RuntimeError):
                        with MODULE.study_lock():
                            pass
            finally:
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home


if __name__ == "__main__":
    unittest.main(verbosity=2)
