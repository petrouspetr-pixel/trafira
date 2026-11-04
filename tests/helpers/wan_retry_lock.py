#!/usr/bin/env python3
"""Exercise the real initd scheduler with rc.common's inherited flock FD."""

import fcntl
import json
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
INITD = LIB / "service/initd.uc"


class WanRetryLock(unittest.TestCase):
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
                "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            service.chmod(0o755)
            env = dict(os.environ, TRAFIRA_LIB=str(LIB),
                       TRAFIRA_RUNTIME_STATE_DIR=str(work),
                       TRAFIRA_SERVICE_INIT=str(service), WAN_RETRY_CALLS=str(calls))

            def schedule(pass_fds=()):
                process = subprocess.Popen(
                    ["ucode", "-L", str(LIB), str(INITD),
                     "schedule-start-retry", str(pid_file), "5"],
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
            try:
                # Establish that a separate open description cannot take this lock.
                with lock_path.open("r+") as probe:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                try:
                    schedule(pass_fds=(1000,))
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
                                 [["retry_start_on_wan_up"]])
                self.assertFalse(pid_file.exists(), "completed retry left a stale pid file")
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
                for group in groups:
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
