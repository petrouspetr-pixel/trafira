#!/usr/bin/env python3
"""Exercise the real initd scheduler with rc.common's inherited flock FD."""

import fcntl
import json
import os
from pathlib import Path
import shutil
import resource
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "trafira/files/usr/lib"
INITD = LIB / "service/initd.uc"


def live_group(group):
    members = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            if int(fields[2]) == group and fields[0] != "Z":
                members.append(int(entry.name))
        except (FileNotFoundError, ProcessLookupError):
            pass
    return members


class WanRetryLock(unittest.TestCase):
    def test_failed_service_start_does_not_claim_unpublished_retry_was_scheduled(self):
        with tempfile.TemporaryDirectory(prefix="trafira-wan-log-") as tmp:
            work = Path(tmp)
            binary = work / "bin"
            binary.mkdir()
            logger = binary / "logger"
            logger.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$WAN_RETRY_LOG\"\n")
            logger.chmod(0o755)
            service = binary / "trafira-fixture"
            service.write_text("#!/bin/sh\nexit 1\n")
            service.chmod(0o755)
            pid_file = work / "retry.pid"
            pid_file.mkdir()
            uci = work / "uci"
            uci.write_text("trafira.settings=settings\ntrafira.settings.shutdown_correctly=1\n")
            logs = work / "logs"
            env = dict(os.environ, TRAFIRA_LIB=str(LIB),
                       TRAFIRA_RUNTIME_STATE_DIR=str(work), TRAFIRA_TRANSACTION_DIR=str(work / "transactions"),
                       TRAFIRA_UI_ACTION_TRACKED="1", TRAFIRA_UCI_STATE_FILE=str(uci),
                       TRAFIRA_BIN=str(service), TRAFIRA_SERVICE_INIT=str(service),
                       TRAFIRA_START_RETRY_PID_FILE=str(pid_file), WAN_RETRY_LOG=str(logs),
                       PATH=str(binary) + os.pathsep + os.environ["PATH"])
            process = subprocess.Popen(
                ["ucode", "-L", str(LIB), str(INITD), "start-service", "manual"],
                env=env, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                stdout, stderr = process.communicate(timeout=5)
                self.assertNotEqual(process.returncode, 0, stdout + stderr)
                self.assertNotIn("scheduled an automatic retry", logs.read_text())
                self.assertIn("[error]", logs.read_text(), "failed scheduling must be reported")
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_failed_pid_publication_cancels_worker_and_all_descendants(self):
        self.assertIsNotNone(shutil.which("ucode"), "real ucode is required")
        for failure in ("directory", "short-write"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix="trafira-wan-pid-") as tmp:
                work = Path(tmp)
                pid_file, calls = work / "retry.pid", work / "calls"
                service = work / "service fixture"
                service.write_text("#!/bin/sh\nprintf invoked > \"$WAN_RETRY_CALLS\"\n")
                service.chmod(0o755)
                if failure == "directory":
                    pid_file.mkdir()
                env = dict(os.environ, TRAFIRA_LIB=str(LIB),
                           TRAFIRA_RUNTIME_STATE_DIR=str(work),
                           TRAFIRA_SERVICE_INIT=str(service), WAN_RETRY_CALLS=str(calls))

                def bound_file():
                    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
                    resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))

                process = subprocess.Popen(
                    ["ucode", "-L", str(LIB), str(INITD),
                     "schedule-start-retry", str(pid_file), "1"],
                    env=env, start_new_session=True,
                    preexec_fn=bound_file if failure == "short-write" else None,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    stdout, stderr = process.communicate(timeout=3)
                    # Observe both assertions before reporting failure, so this
                    # catches a parent-only kill as well as a late invocation.
                    deadline = time.monotonic() + 0.4
                    while live_group(process.pid) and time.monotonic() < deadline:
                        time.sleep(0.01)
                    survivors = live_group(process.pid)
                    time.sleep(1.2)
                    self.assertFalse(calls.exists(), "failed PID publication still invoked SERVICE_INIT")
                    self.assertFalse(survivors, f"failed PID publication left live descendants: {survivors}")
                    self.assertNotEqual(process.returncode, 0, stdout + stderr)
                    if failure == "directory":
                        self.assertTrue(pid_file.is_dir(), "failure changed its directory target")
                    else:
                        self.assertFalse(pid_file.exists(), "failure left a partial PID file")
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_sleeping_retry_releases_procd_lock_and_runs_once(self):
        """A detached retry must release FD1000 without losing or duplicating work."""
        self.assertIsNotNone(shutil.which("ucode"), "real ucode is required")
        groups = []
        with tempfile.TemporaryDirectory(prefix="trafira-wan-lock-") as tmp:
            work = Path(tmp)
            pid_file = work / "start-retry.pid"
            calls = work / "calls.jsonl"
            # A distinct executable proves the configured SERVICE_INIT is used.
            service = work / "service init's fixture"
            service.write_text(
                "#!" + sys.executable + "\n"
                "import json, os, sys\n"
                "with open(os.environ['WAN_RETRY_CALLS'], 'a') as output:\n"
                "    output.write(json.dumps({'args': sys.argv[1:], "
                "'other_fd': os.read(1001, 100).decode()}) + '\\n')\n"
            )
            service.chmod(0o755)
            env = dict(os.environ, TRAFIRA_LIB=str(LIB),
                       TRAFIRA_RUNTIME_STATE_DIR=str(work),
                       TRAFIRA_SERVICE_INIT=str(service), WAN_RETRY_CALLS=str(calls))

            def schedule(pass_fds=(), delay="5"):
                process = subprocess.Popen(
                    ["ucode", "-L", str(LIB), str(INITD),
                     "schedule-start-retry", str(pid_file), delay],
                    env=env, pass_fds=pass_fds, start_new_session=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                groups.append(process.pid)
                stdout, stderr = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, stdout + stderr)

            lock_path = work / "procd.lock"
            descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            os.dup2(descriptor, 1000, inheritable=True)
            if descriptor != 1000:
                os.close(descriptor)
            fcntl.flock(1000, fcntl.LOCK_EX)
            other_path = work / "other-descriptor"
            other_path.write_text("unrelated descriptor preserved")
            descriptor = os.open(other_path, os.O_RDONLY)
            os.dup2(descriptor, 1001, inheritable=True)
            if descriptor != 1001:
                os.close(descriptor)
            try:
                # Establish that a separate open description cannot take this lock.
                with lock_path.open("r+") as probe:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                try:
                    schedule(pass_fds=(1000, 1001))
                finally:
                    # Do not LOCK_UN: that would unlock the child's shared open
                    # description too and hide the exact inheritance regression.
                    os.close(1000)

                worker = int(pid_file.read_text().strip())
                os.kill(worker, 0)
                self.assertFalse(calls.exists(), "retry fired before the delay elapsed")
                lock_retained = False
                with lock_path.open("r+") as probe:
                    try:
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        lock_retained = True

                # A second event during the same real sleep must reuse the worker.
                schedule()
                self.assertEqual(int(pid_file.read_text().strip()), worker)
                self.assertFalse(calls.exists(), "fixture must observe a sleeping retry")
                deadline = time.monotonic() + 10
                while not calls.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(calls.exists(), "scheduled SERVICE_INIT was never executed")
                # Allow an accidentally duplicated worker to append its call too.
                time.sleep(0.3)
                self.assertEqual([json.loads(line) for line in calls.read_text().splitlines()],
                                 [{"args": ["retry_start_on_wan_up"],
                                   "other_fd": "unrelated descriptor preserved"}])
                self.assertFalse(pid_file.exists(), "completed retry left a stale pid file")
                calls.unlink()
                # Closing the inherited procd descriptor must leave cancellation
                # effective as well as preserving the unrelated inherited FD.
                schedule(pass_fds=(1001,), delay="2")
                subprocess.run(
                    ["ucode", "-L", str(LIB), str(INITD),
                     "cancel-scheduled-start-retry", str(pid_file)],
                    env=env, check=True, timeout=3,
                )
                self.assertFalse(pid_file.exists(), "cancelled retry left a pid file")
                time.sleep(2.3)
                self.assertFalse(calls.exists(), "cancelled retry invoked SERVICE_INIT")
                # Report the lock assertion after verifying that releasing it did
                # not merely suppress the promised deferred service invocation.
                self.assertFalse(lock_retained,
                                 "sleeping WAN retry inherited FD1000 and retained procd flock "
                                 "after schedule-start-retry returned")
            finally:
                try:
                    os.close(1000)
                except OSError:
                    pass
                os.close(1001)
                for group in groups:
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
