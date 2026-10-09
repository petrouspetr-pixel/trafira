import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "components/warp/trafira-warp-awg/files/warp-exec.c"

@unittest.skipUnless(os.name == "posix", "requires Linux process groups")
class ProcessLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        cls.binary = str(Path(cls.work.name)/"warp-exec")
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(SOURCE), "-o", cls.binary], check=True)
    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()
    def test_result_and_timeout(self):
        cancel = str(Path(self.work.name)/"absent.json")
        result = subprocess.run([self.binary,"3",cancel,"w-test","sh","-c","printf ok; exit 7"], capture_output=True, timeout=5)
        self.assertEqual(result.stdout, b"ok")
        self.assertEqual(result.returncode, 7)
        start = time.monotonic()
        result = subprocess.run([self.binary,"1",cancel,"w-test","sleep","30"], timeout=5)
        self.assertEqual(result.returncode,124)
        self.assertLess(time.monotonic()-start,4)
    def test_cancel_and_parent_death(self):
        for interrupted in (False,True):
            cancel = Path(self.work.name)/("cancel-%s.json" % interrupted)
            pidfile = Path(self.work.name)/("child-%s" % interrupted)
            proc = subprocess.Popen([self.binary,"0",str(cancel),"w-test","sh","-c",'echo $$ > "$1"; sleep 30',"sh",str(pidfile)])
            for _ in range(100):
                if pidfile.exists():break
                time.sleep(.02)
            self.assertTrue(pidfile.exists())
            child = int(pidfile.read_text())
            if interrupted: proc.kill()
            else: cancel.write_text(json.dumps({"job_id":"w-test"}))
            proc.wait(timeout=5)
            for _ in range(100):
                path=Path("/proc/%d/stat" % child)
                if not path.exists() or path.read_text().split(")")[-1].split()[0]=="Z":break
                time.sleep(.02)
            else:self.fail("owned child survived cancellation or supervisor death")
