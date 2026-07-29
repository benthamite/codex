"""Tests for capture_protocol.py failure handling."""

import contextlib
import io
import json
import os
import runpy
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock


class _Pipe:
    def write(self, _text):
        return None

    def flush(self):
        return None


class _Process:
    def __init__(self):
        started = {
            "method": "thread/started",
            "params": {"thread": {"id": "thread-1"}},
        }
        self.stdin = _Pipe()
        self.stdout = iter([json.dumps(started) + "\n"])
        self.terminated = False

    def terminate(self):
        self.terminated = True


class _Thread:
    def __init__(self, target, daemon=False):
        self.target = target
        self.daemon = daemon

    def start(self):
        self.target()


class _TimeoutEvent:
    def set(self):
        return None

    def wait(self, timeout=None):
        return False


class CaptureProtocolTest(unittest.TestCase):
    def test_timeout_is_reported_as_failure(self):
        script = os.path.join(os.path.dirname(__file__), "capture_protocol.py")
        process = _Process()
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(subprocess, "Popen", return_value=process),
            mock.patch.object(threading, "Thread", _Thread),
            mock.patch.object(threading, "Event", _TimeoutEvent),
            mock.patch.object(time, "sleep", lambda _seconds: None),
            mock.patch.object(sys, "argv", [script, "wait forever"]),
            mock.patch.dict(os.environ, {"CGT_TURN_TIMEOUT": "0.01"}, clear=False),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            with self.assertRaises(SystemExit) as raised:
                runpy.run_path(script, run_name="__main__")
        self.assertNotEqual(raised.exception.code, 0)
        self.assertTrue(process.terminated)
        self.assertIn("timed out", stderr.getvalue().lower())
        self.assertEqual(stdout.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
