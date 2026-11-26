#!/usr/bin/python3
"""Run one fprintd verification and correlate it with VFS491 journal events.

The study stores derived frame metrics and the verification outcome only. It
never stores the account name, command transcript, fingerprint pixels,
templates, or minutiae.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import getpass
import json
import math
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

EVENT_MARKER = "VFS491_EVENT "
INTEGER_FIELDS = {
    "capture", "width", "height", "bytes", "min", "p05", "p50", "p95", "max",
    "broker_status",
}
FLOAT_FIELDS = {
    "capture_ms", "mean", "stddev", "entropy", "dark_pct", "bright_pct",
    "row_sd", "col_sd", "grad_h", "grad_v",
}


def parse_event_line(line: str) -> dict[str, Any] | None:
    marker = line.find(EVENT_MARKER)
    if marker < 0:
        return None
    try:
        tokens = shlex.split(line[marker + len(EVENT_MARKER):])
    except ValueError:
        return None

    event: dict[str, Any] = {}
    for token in tokens:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        if key in INTEGER_FIELDS:
            try:
                event[key] = int(value)
            except ValueError:
                return None
        elif key in FLOAT_FIELDS:
            try:
                number = float(value)
            except ValueError:
                return None
            if not math.isfinite(number):
                return None
            event[key] = number
        elif key in {"type", "claim_id"}:
            event[key] = value

    if event.get("type") not in {"capture_start", "frame", "capture_error"}:
        return None
    if not event.get("claim_id") or "capture" not in event:
        return None
    if event["capture"] < 1 or event["capture"] > 0xFFFFFFFF:
        return None
    if event["type"] == "frame":
        if event.get("width") != 200 or event.get("height", 0) < 1:
            return None
        if event.get("bytes") != event["width"] * event["height"]:
            return None
    return event


def extract_events(
    journal_text: str,
    start_realtime_us: int | None = None,
    end_realtime_us: int | None = None,
) -> list[dict[str, Any]]:
    """Parse journalctl JSON and retain only events inside the verify interval."""
    events: list[dict[str, Any]] = []
    for line in journal_text.splitlines():
        try:
            record = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            # Plain MESSAGE lines are useful for unit tests, but without a
            # journal timestamp they must never be used for real correlation.
            event = parse_event_line(line)
            if event is not None and start_realtime_us is None and end_realtime_us is None:
                events.append(event)
            continue
        if not isinstance(record, dict):
            continue
        message = record.get("MESSAGE")
        timestamp = record.get("__REALTIME_TIMESTAMP")
        if not isinstance(message, str) or not isinstance(timestamp, (str, int)):
            continue
        try:
            realtime_us = int(timestamp)
        except (TypeError, ValueError):
            continue
        if start_realtime_us is not None and realtime_us < start_realtime_us:
            continue
        if end_realtime_us is not None and realtime_us > end_realtime_us:
            continue
        event = parse_event_line(message)
        if event is None:
            continue
        event["journal_realtime_us"] = realtime_us
        events.append(event)
    events.sort(key=lambda item: item.get("journal_realtime_us", 0))
    return events


def parse_result(output: str) -> str:
    if re.search(r"\bverify-match\b", output):
        return "match"
    if re.search(r"\bverify-no-match\b", output):
        return "no-match"
    if re.search(r"\bverify-retry-scan\b", output):
        return "retry-scan"
    if re.search(r"\bverify-error\b", output):
        return "error"
    if "Failed to match fingerprint" in output:
        return "no-match"
    return "unknown"


def _journal_time(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds")


def query_journal(
    journalctl: str, start: dt.datetime, end: dt.datetime
) -> tuple[list[dict[str, Any]], str | None]:
    # Query a small outer window for journal timestamp precision, then enforce
    # the exact process interval against __REALTIME_TIMESTAMP below.
    since = _journal_time(start - dt.timedelta(seconds=2))
    until = _journal_time(end + dt.timedelta(seconds=2))
    command = [
        journalctl, "--no-pager", "--output=json", "--unit=fprintd.service",
        f"--since={since}", f"--until={until}",
    ]
    try:
        completed = subprocess.run(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace",
            check=False, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [], str(exc)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"journalctl exited {completed.returncode}"
        return [], detail

    start_us = int(start.timestamp() * 1_000_000)
    end_us = int(end.timestamp() * 1_000_000)
    return extract_events(completed.stdout, start_us, end_us), None


@contextmanager
def study_lock() -> Iterator[None]:
    """Serialize study runs so their journal intervals cannot overlap."""
    cache = Path.home() / ".cache"
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = cache / "vfs491-verify-study.lock"
    flags = os.O_CREAT | os.O_RDWR
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(lock_path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError("study lock is not a regular file")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("another VFS491 verification study is already running") from exc
        yield
    finally:
        os.close(fd)


def append_record(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = (json.dumps(record, separators=(",", ":"), sort_keys=True, allow_nan=False) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("study output must be a regular file")
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short write while appending study record")
            offset += written
    finally:
        os.close(fd)


def run_verification(binary: str, finger: str, username: str) -> tuple[int, str]:
    command = [binary, "-f", finger, username]
    process = subprocess.Popen(
        command, stdin=None, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", bufsize=1,
    )
    assert process.stdout is not None
    lines: list[str] = []
    try:
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            lines.append(line)
        return_code = process.wait()
    except KeyboardInterrupt:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        raise
    return return_code, "".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Record one VFS491 verify result alongside matching frame metrics"
    )
    parser.add_argument("--finger", required=True, help="fprintd finger label, e.g. right-index-finger")
    parser.add_argument("--user", default=getpass.getuser(), help="local fprintd username (not saved)")
    parser.add_argument(
        "--class", dest="trial_class", choices=("genuine", "different-finger", "unknown"),
        default="unknown", help="label the physical trial; this is not inferred by the driver",
    )
    parser.add_argument(
        "--output", type=Path,
        default=Path.home() / "VFS491-verify-study.jsonl",
        help="private JSONL study file (default: ~/VFS491-verify-study.jsonl)",
    )
    parser.add_argument("--fprintd-verify", default="fprintd-verify")
    parser.add_argument("--journalctl", default="journalctl")
    args = parser.parse_args()

    binary = shutil.which(args.fprintd_verify)
    if binary is None:
        parser.error(f"cannot find verification command: {args.fprintd_verify}")
    journalctl = shutil.which(args.journalctl)
    if journalctl is None:
        parser.error(f"cannot find journal command: {args.journalctl}")

    try:
        with study_lock():
            started = dt.datetime.now(dt.timezone.utc)
            try:
                exit_code, output = run_verification(binary, args.finger, args.user)
            except KeyboardInterrupt:
                print("Verification interrupted; no result record written.", file=sys.stderr)
                return 130
            ended = dt.datetime.now(dt.timezone.utc)
            events, journal_error = query_journal(journalctl, started, ended)
            frames = [event for event in events if event["type"] == "frame"]
            record = {
                "schema_version": 2,
                "study_id": str(uuid.uuid4()),
                "started_at": started.isoformat(timespec="milliseconds"),
                "ended_at": ended.isoformat(timespec="milliseconds"),
                "finger": args.finger,
                "trial_class": args.trial_class,
                "result": parse_result(output),
                "exit_code": exit_code,
                "capture_events": events,
                "frame_count": len(frames),
                "journal_error": journal_error,
            }
            output_path = args.output.expanduser()
            append_record(output_path, record)
    except RuntimeError as exc:
        print(f"VFS491 study: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"VFS491 study: could not write study record: {exc}", file=sys.stderr)
        return 2

    print(
        f"VFS491 study: result={record['result']}, frames={len(frames)}, "
        f"events={len(events)}, record={output_path}"
    )
    if journal_error:
        print(f"Journal correlation unavailable: {journal_error}", file=sys.stderr)
        print("Grant this account read access to the system journal before interpreting the dataset.", file=sys.stderr)
    if not frames:
        print("No timestamp-matched VFS491 frame telemetry was found for this verification.", file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
