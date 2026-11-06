#!/usr/bin/env python3
"""Real deferred workers must not outlive a failed atomic PID publication."""

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
        for pid in self.owned_workers():
            try:
                self.groups.append(os.getpgid(pid))
            except ProcessLookupError:
                pass
        for group in self.groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.temp.cleanup()

    def owned_workers(self):
        result = []
        marker = ("TRAFIRA_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE=" + str(self.pidfile)).encode()
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if (b"deferred-bootstrap-worker" in (entry / "cmdline").read_bytes().split(b"\0") and
                        marker in (entry / "environ").read_bytes().split(b"\0")):
                    result.append(int(entry.name))
            except (FileNotFoundError, ProcessLookupError):
                pass
        return result

    def run_mode(self, mode, *args, pass_fds=()):
        process = subprocess.Popen(
            ["ucode", "-L", str(LIB), str(CACHE), mode, *args],
            env=self.env, pass_fds=pass_fds, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.groups.append(process.pid)
        stdout, stderr = process.communicate(timeout=5)
        for pid in self.owned_workers():
            try:
                self.groups.append(os.getpgid(pid))
            except ProcessLookupError:
                pass
        return process, stdout + stderr

    def test_failed_atomic_pid_publication_leaves_no_worker_or_descendant(self):
        # rename(temp, target-directory) must fail even when tests run as root.
        self.pidfile.mkdir(parents=True)
        for attempt in range(2):
            process, output = self.run_mode("start-deferred-bootstrap-worker", "proxy")
            self.assertTrue(wait_until(lambda: not live_group(process.pid)),
                            f"PID-save failure left live worker/descendants: {live_group(process.pid)}")
            self.assertNotEqual(process.returncode, 0, "failed PID publication reported CLI success")
            self.assertTrue(wait_until(lambda: not self.owned_workers()), "failed publication left detached worker")
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
        worker_group = os.getpgid(worker)
        self.groups.append(worker_group)
        self.assertTrue(wait_until(lambda: worker in live_group(worker_group)), "worker did not remain running")
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
        self.assertTrue(wait_until(lambda: not live_group(worker_group)), "stop left worker or descendants running")
        self.assertFalse(self.pidfile.exists(), "stop left the published PID behind")

    def test_stale_pid_cannot_kill_or_suppress_foreign_process(self):
        foreign = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.groups.append(foreign.pid)
        self.addCleanup(lambda: (foreign.kill() if foreign.poll() is None else None, foreign.wait()))
        self.pidfile.parent.mkdir(parents=True)
        fields = Path(f"/proc/{foreign.pid}/stat").read_text().rsplit(")", 1)[1].split()
        for record in [None, {"version": 1, "role": "subscription", "pid": str(foreign.pid),
                              "ticks": fields[19], "group": str(foreign.pid), "session": str(foreign.pid)}]:
            with self.subTest(record=record):
                self.pidfile.write_text(str(foreign.pid) + "\n")
                owner = Path(str(self.pidfile) + ".owner.json")
                if record:
                    owner.write_text(json.dumps(record))
                result, output = self.run_mode("stop-deferred-bootstrap-worker")
                self.assertEqual(result.returncode, 0, output)
                time.sleep(0.05)
                self.assertIsNone(foreign.poll(), "stale PID killed an unrelated process")
                self.assertFalse(self.pidfile.exists())
                self.assertFalse(owner.exists())
        self.pidfile.write_text(str(foreign.pid) + "\n")
        result, output = self.run_mode("start-deferred-bootstrap-worker", "proxy")
        self.assertEqual(result.returncode, 0, output)
        self.assertNotEqual(int(self.pidfile.read_text()), foreign.pid, "foreign PID suppressed recovery")
        self.run_mode("stop-deferred-bootstrap-worker")
        self.assertIsNone(foreign.poll())

    def test_long_deferred_section_list_does_not_break_worker_registration(self):
        sections = " ".join("section_%04d" % index for index in range(1000))
        result, output = self.run_mode("start-deferred-bootstrap-worker", sections)
        self.assertEqual(result.returncode, 0, output)
        result, output = self.run_mode("stop-deferred-bootstrap-worker")
        self.assertEqual(result.returncode, 0, output)
        self.assertFalse(self.pidfile.exists())

    def install_download_fixture(self, blocking):
        binary = self.work / "bin"
        real = shutil.which("ucode")
        wrapper = binary / "ucode"
        wrapper.write_text("#!" + sys.executable + "\n" +
                           "import os,sys\n"
                           "if sys.argv[-1]=='sing-box-service-running': sys.exit(0)\n" +
                           f"os.execv({real!r},[{real!r},*sys.argv[1:]])\n")
        wrapper.chmod(0o755)
        curl = binary / "curl"
        curl.write_text("#!" + sys.executable + "\n" + '''import json,os,signal,subprocess,sys,time
from pathlib import Path
args=sys.argv[1:]
if '-D' in args: Path(args[args.index('-D')+1]).write_text('HTTP/1.1 200 OK\\r\\n\\r\\n')
''' + ('''signal.signal(signal.SIGTERM,signal.SIG_IGN)
child=subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(300)'])
Path(os.environ['WORKER_DOWNLOAD_STARTED']).write_text(json.dumps({'pid':os.getpid(),'group':os.getpgrp(),'child':child.pid}))
while True: time.sleep(1)
''' if blocking else '''print('{"outbounds":[{"type":"socks","tag":"node","server":"127.0.0.1","server_port":1080}]}')
'''))
        curl.chmod(0o755)
        uci = self.work / "uci"
        uci.write_text("trafira.settings=settings\ntrafira.proxy=section\n"
                       "trafira.proxy.connection_type=proxy\ntrafira.proxy.action=connection\n"
                       "trafira.source=subscription_url\ntrafira.source.section=proxy\n"
                       "trafira.source.url=https://fixture.invalid/sub\ntrafira.source.auto_user_agent=0\n"
                       "trafira.source.user_agent=Harness\n")
        self.env.update(TRAFIRA_UCI_STATE_FILE=str(uci), WORKER_DOWNLOAD_STARTED=str(self.work / "download-started"))

    def active_cancel(self, crash):
        self.install_download_fixture(True)
        cache = self.work / "subscriptions/proxy-subscription-1.json"
        cache.parent.mkdir()
        original = b'{"outbounds":[{"type":"socks","tag":"old","server":"127.0.0.1","server_port":1080}]}'
        cache.write_bytes(original)
        for suffix, value in {"url": "https://fixture.invalid/sub", "user_agent": "Harness", "hwid": "", "device_headers": ""}.items():
            (cache.parent / ("proxy-subscription-1." + suffix)).write_text(value)
        result, output = self.run_mode("start-deferred-bootstrap-worker", "proxy")
        self.assertEqual(result.returncode, 0, output)
        started = self.work / "download-started"
        self.assertTrue(wait_until(started.exists, 42), self.logs.read_text())
        download = json.loads(started.read_text())
        self.groups.append(download["group"])
        if crash:
            os.kill(int(self.pidfile.read_text()), signal.SIGKILL)
            time.sleep(0.05)
        result, output = self.run_mode("stop-deferred-bootstrap-worker")
        self.assertEqual(result.returncode, 0, output)
        self.assertTrue(wait_until(lambda: not live_group(download["group"])),
                        "stop left an active curl/parser descendant")
        self.assertEqual(cache.read_bytes(), original)
        self.assertFalse(self.pidfile.exists())
        self.assertFalse(list(cache.parent.glob(".worker-*")), "worker scratch directory survived cancellation")

    def test_stop_active_download_terminates_descendants_and_preserves_cache(self):
        self.active_cancel(False)

    def test_orphaned_download_is_cancelled_after_its_worker_dies(self):
        self.active_cancel(True)

    def test_recovery_reload_survives_worker_cancellation(self):
        self.install_download_fixture(False)
        service = self.work / "reload-fixture"
        complete = self.work / "reload-completed"
        real = shutil.which("ucode")
        service.write_text("#!" + sys.executable + "\nimport os,subprocess\n" +
                           f"subprocess.run([{real!r},'-L',{str(LIB)!r},{str(CACHE)!r},'stop-deferred-bootstrap-worker'],check=True)\n" +
                           f"open({str(complete)!r},'w').write('reload survived')\n")
        service.chmod(0o755)
        self.env["TRAFIRA_SERVICE_INIT"] = str(service)
        result, output = self.run_mode("start-deferred-bootstrap-worker", "proxy")
        self.assertEqual(result.returncode, 0, output)
        self.assertTrue(wait_until(complete.exists, 45), self.logs.read_text())
        self.assertEqual(complete.read_text(), "reload survived")
        self.assertFalse(self.pidfile.exists())


if __name__ == "__main__":
    unittest.main()
