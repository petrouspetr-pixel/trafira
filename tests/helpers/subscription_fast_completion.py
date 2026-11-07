"""Force real subscription workers to finish before the launcher returns."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "trafira/files/usr/lib"


class FastSubscriptionJobs(unittest.TestCase):
    def test_worker_does_not_update_when_pid_cannot_be_published(self):
        with tempfile.TemporaryDirectory(prefix="trafira-sub-pid-") as tmp:
            work = Path(tmp)
            state = work / "state.json"
            state.mkdir()
            called = work / "called"
            service = work / "trafira-fixture"
            service.write_text(f'#!/bin/sh\nprintf called > "{called}"\n')
            service.chmod(0o755)
            env = dict(os.environ, TRAFIRA_BIN=str(service), TRAFIRA_LIB=str(LIB))
            result = subprocess.run(["ucode", "-L", str(LIB), str(LIB / "components/updates.uc"),
                                     "subscription-update-worker", str(state), str(work / "output"), "proxy", "2"],
                                    env=env, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(called.exists(), "unregistered worker executed an update")
            self.assertTrue(state.is_dir(), "failed registration changed its target")

    def test_completed_success_and_failure_keep_their_job_id(self):
        for code in [0, 7]:
            with self.subTest(exit_code=code), tempfile.TemporaryDirectory(prefix="trafira-fast-sub-") as tmp:
                work = Path(tmp)
                binaries = work / "bin"
                binaries.mkdir()
                # Interpose only the launcher's shell. The worker is the real
                # ucode command, and the parent resumes after its terminal state.
                shell = binaries / "sh"
                shell.write_text("#!" + sys.executable + "\n" + r'''
import os, sys
args = sys.argv[1:]
if len(args) >= 2 and args[0] == '-c' and 'subscription-update-worker' in args[1] and args[1].endswith('& echo $!'):
    args[1] = args[1][:-len('& echo $!')] + '& child=$!; wait "$child"; printf "%s\n" "$child"'
os.execv('/bin/sh', ['sh', *args])
''')
                shell.chmod(0o755)
                service = binaries / "trafira-fixture"
                service.write_text(f'#!/bin/sh\nprintf "fixture finished {code}\\n"\nexit {code}\n')
                service.chmod(0o755)
                env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                           TRAFIRA_LIB=str(LIB), TRAFIRA_BIN=str(service),
                           TMP_SING_BOX_FOLDER=str(work / "sing-box"),
                           TRAFIRA_RUNTIME_STATE_DIR=str(work / "run"),
                           TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR=str(work / "persistent"),
                           TRAFIRA_SUBSCRIPTION_UPDATE_JOB_DIR=str(work / "jobs"))
                result = subprocess.run(["ucode", "-L", str(LIB), str(LIB / "components/updates.uc"),
                                         "subscription-update-async", "proxy", "2"],
                                        env=env, capture_output=True, text=True, timeout=8)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                response = json.loads(result.stdout)
                self.assertTrue(response["success"], response)
                self.assertTrue(response["job_id"], response)
                path = work / "jobs" / (response["job_id"] + ".json")
                terminal = path.read_bytes()
                status = json.loads(terminal)
                self.assertFalse(status["running"], status)
                self.assertEqual(status["success"], code == 0)
                self.assertEqual(status["exit_code"], code)
                self.assertEqual(status["message"], f"fixture finished {code}")
                self.assertEqual(status["section"], "proxy")
                self.assertEqual(status["source_index"], "2")
                polled = subprocess.run(["ucode", "-L", str(LIB), str(LIB / "components/updates.uc"),
                                         "subscription-update-status", response["job_id"]],
                                        env=env, capture_output=True, text=True, timeout=5)
                self.assertEqual(polled.returncode, 0, polled.stderr)
                self.assertEqual(json.loads(polled.stdout)["success"], code == 0)
                self.assertEqual(path.read_bytes(), terminal, "status/parent must not rewrite a finished job")


if __name__ == "__main__":
    unittest.main(verbosity=2)
