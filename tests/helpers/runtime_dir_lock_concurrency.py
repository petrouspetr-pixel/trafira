"""Deterministic publication races against real production ucode and libc mkdir."""
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "trafira/files/usr/lib"


class DirectoryLocks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="trafira-dir-lock-")
        cls.base = Path(cls.workspace.name)
        source = cls.base / "mkdir.c"
        cls.library = cls.base / "mkdir.so"
        source.write_text(r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int mkdir(const char *path, mode_t mode) {
  int (*real_mkdir)(const char*,mode_t)=dlsym(RTLD_NEXT,"mkdir");
  int code=real_mkdir(path,mode);
  const char *target=getenv("LOCK_BARRIER_TARGET");
  if(!code && target && !strcmp(path,target)) {
    const char *ready=getenv("LOCK_BARRIER_READY"), *resume=getenv("LOCK_BARRIER_RESUME");
    int fd=open(ready,O_WRONLY|O_CREAT|O_TRUNC,0600);
    if(fd>=0){write(fd,"ready",5);close(fd);}
    while(access(resume,F_OK))usleep(10000);
  }
  return code;
}
''')
        subprocess.run(["cc", "-shared", "-fPIC", str(source), "-ldl", "-o", str(cls.library)],
                       check=True, capture_output=True)
        cls.scripts = []
        for name in ["state", "initd"]:
            original = (LIB / "service" / (name + ".uc")).read_text()
            functions = []
            # Keep production declarations in source order; only provide the
            # original command/write primitives without starting any service.
            for function in ["first_line_value", "pid_alive", "lock_dir_write_owner",
                             "release_runtime_dir_lock", "acquire_runtime_dir_lock"]:
                start = original.find("function " + function + "(")
                if start < 0:
                    continue
                end = original.find("\nfunction ", start + 1)
                functions.append((start, original[start:end]))
            prelude = '''let fs=require("fs"),runtime_dir_lock=null;
try { runtime_dir_lock=require("service.runtime_dir_lock"); } catch(e) {}
function as_string(v){return v==null?"":""+v;}
function command_success_from_args(args){
 let parts=[];
 for(let arg in args) push(parts,"'"+replace(""+arg,/'/g,"'\\\\''")+"'");
 return system(join(" ",parts)+" >/dev/null 2>&1")==0;
}
function write_text_file(path,value){return fs.writefile(path,value)!=null;}
'''
            script = cls.base / (name + ".uc")
            script.write_text(prelude + "\n".join(code for _, code in sorted(functions)) +
                              '\nif(ARGV[0]=="release"){release_runtime_dir_lock(ARGV[1]);exit(0);}'
                              '\nexit(acquire_runtime_dir_lock(ARGV[1],ARGV[2])?0:1);')
            cls.scripts.append(script)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def command(self, script, lock, mode="acquire"):
        return ["ucode", "-L", str(LIB), str(script), mode, str(lock), str(os.getpid())]

    def paused_owner(self, script, work):
        lock, ready, resume = (work / name for name in ["runtime.lock", "ready", "resume"])
        env = dict(os.environ, LD_PRELOAD=str(self.library), LOCK_BARRIER_TARGET=str(lock),
                   LOCK_BARRIER_READY=str(ready), LOCK_BARRIER_RESUME=str(resume))
        process = subprocess.Popen(self.command(script, lock), env=env, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 4
        while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        if not ready.exists():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            out, err = process.communicate(timeout=2)
            self.fail("mkdir checkpoint not reached: " + out + err)
        return process, lock, resume

    def test_second_owner_cannot_steal_unpublished_directory(self):
        for script in self.scripts:
            with self.subTest(module=script.stem), tempfile.TemporaryDirectory(dir=self.base) as tmp:
                owner, lock, resume = self.paused_owner(script, Path(tmp))
                try:
                    other = subprocess.run(self.command(script, lock), capture_output=True, text=True, timeout=3)
                finally:
                    resume.touch()
                    out, err = owner.communicate(timeout=3)
                self.assertEqual(owner.returncode, 0, out + err)
                self.assertNotEqual(other.returncode, 0, "two owners acquired the same runtime lock")
                self.assertEqual((lock / "pid").read_text().strip(), str(os.getpid()))

    def test_killed_publisher_releases_guard_and_empty_directory_is_recoverable(self):
        for script in self.scripts:
            with self.subTest(module=script.stem), tempfile.TemporaryDirectory(dir=self.base) as tmp:
                owner, lock, _ = self.paused_owner(script, Path(tmp))
                os.killpg(owner.pid, signal.SIGKILL)
                owner.communicate(timeout=3)
                result = subprocess.run(self.command(script, lock), capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_live_owner_stale_owner_and_release(self):
        for script in self.scripts:
            with self.subTest(module=script.stem), tempfile.TemporaryDirectory(dir=self.base) as tmp:
                lock = Path(tmp) / "runtime.lock"
                for mode, expected in [("acquire", 0), ("acquire", 1), ("release", 0), ("acquire", 0)]:
                    result = subprocess.run(self.command(script, lock, mode), capture_output=True, timeout=3)
                    self.assertEqual(result.returncode, expected, result.stderr)
                (lock / "pid").write_text("999999999\n")
                result = subprocess.run(self.command(script, lock), capture_output=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_short_pid_write_cannot_publish_a_lock(self):
        def limit():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))
        for script in self.scripts:
            with self.subTest(module=script.stem), tempfile.TemporaryDirectory(dir=self.base) as tmp:
                lock = Path(tmp) / "runtime.lock"
                result = subprocess.run(self.command(script, lock), capture_output=True, text=True,
                                        timeout=3, preexec_fn=limit)
                self.assertNotEqual(result.returncode, 0, "partial PID was accepted as a lock owner")
                self.assertFalse(lock.exists(), "failed PID publication left a runtime lock")


if __name__ == "__main__":
    unittest.main(verbosity=2)
