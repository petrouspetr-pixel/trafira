#!/usr/bin/env python3
"""Real deferred workers must not outlive a failed atomic PID publication."""

import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "trafira/files/usr/lib"
CACHE = LIB / "subscription/cache.uc"


def live_group(group):
    """Include descendants (not just the PID that the launcher reports)."""
    result = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            if int(fields[2]) == group and fields[0] != "Z":
                result.append(int(entry.name))
        except (FileNotFoundError, ProcessLookupError):
            pass
    return result


def wait_until(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return bool(predicate())


class SubscriptionWorkerPid(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(shutil.which("ucode"), "real ucode is required")
        self.temp = tempfile.TemporaryDirectory(prefix="trafira-worker-pid-")
        self.work = Path(self.temp.name)
        self.groups = []
        self.addCleanup(self.cleanup)
        self.pidfile = self.work / "run/worker.pid"
        self.logs = self.work / "logs"
        binary = self.work / "bin"
        binary.mkdir()
        logger = binary / "logger"
        logger.write_text(
            "#!" + sys.executable + "\n"
            "import os, sys\n"
            "with open(os.environ['WORKER_TEST_LOGS'], 'a') as output:\n"
            "    output.write(' '.join(sys.argv[1:]) + '\\n')\n")
        logger.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                        TRAFIRA_LIB=str(LIB), WORKER_TEST_LOGS=str(self.logs),
                        TMP_SING_BOX_FOLDER=str(self.work / "sing-box"),
                        TMP_SUBSCRIPTION_FOLDER=str(self.work / "subscriptions"),
                        TRAFIRA_RUNTIME_STATE_DIR=str(self.work / "run"),
                        TRAFIRA_SECTION_CACHE_DIR=str(self.work / "sections"),
                        TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR=str(self.work / "persistent"),
                        TRAFIRA_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE=str(self.pidfile))

    def cleanup(self):
        for group in self.groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.temp.cleanup()

    def run_mode(self, mode, *args, pass_fds=()):
        process = subprocess.Popen(
            ["ucode", "-L", str(LIB), str(CACHE), mode, *args],
            env=self.env, pass_fds=pass_fds, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.groups.append(process.pid)
        stdout, stderr = process.communicate(timeout=5)
        return process, stdout + stderr

    def test_failed_atomic_pid_publication_leaves_no_worker_or_descendant(self):
        # rename(temp, target-directory) must fail even when tests run as root.
        self.pidfile.mkdir(parents=True)
        for attempt in range(2):
            process, output = self.run_mode("start-deferred-bootstrap-worker", "proxy")
            self.assertTrue(wait_until(lambda: not live_group(process.pid)),
                            f"PID-save failure left live worker/descendants: {live_group(process.pid)}")
            self.assertNotIn("Started subscription bootstrap retry worker", self.logs.read_text(), output)
            self.assertTrue(self.pidfile.is_dir(), "failed publication changed its target")
            self.assertFalse(list(self.pidfile.parent.glob("worker.pid.*.tmp")))
        self.assertIn("[error]", self.logs.read_text(), "failure must be reported")

    def test_normal_launch_duplicate_suppression_stop_and_fd1000_release(self):
        lock_path = self.work / "procd.lock"
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        os.dup2(descriptor, 1000, inheritable=True)
        if descriptor != 1000:
            os.close(descriptor)
        fcntl.flock(1000, fcntl.LOCK_EX)
        try:
            process, output = self.run_mode("start-deferred-bootstrap-worker", "proxy", pass_fds=(1000,))
            self.assertEqual(process.returncode, 0, output)
        finally:
            # LOCK_UN would release the shared child description and hide a leak.
            os.close(1000)
        self.assertTrue(self.pidfile.is_file(), output)
        worker = int(self.pidfile.read_text())
        self.assertTrue(wait_until(lambda: worker in live_group(process.pid)), "worker did not remain running")
        with lock_path.open("r+") as probe:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.fail("deferred worker inherited FD1000 and retained procd flock")
        second, output = self.run_mode("start-deferred-bootstrap-worker", "proxy")
        self.assertEqual(second.returncode, 0, output)
        self.assertEqual(int(self.pidfile.read_text()), worker, "duplicate event replaced worker PID")
        self.assertFalse(live_group(second.pid), "duplicate event launched another worker")
        stopped, output = self.run_mode("stop-deferred-bootstrap-worker")
        self.assertEqual(stopped.returncode, 0, output)
        self.assertTrue(wait_until(lambda: worker not in live_group(process.pid)), "stop left worker running")
        self.assertFalse(self.pidfile.exists(), "stop left the published PID behind")


if __name__ == "__main__":
    unittest.main()
