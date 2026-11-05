"""Whole-source publication and restart/crash consistency with real production ucode."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from subscription_resources import SubscriptionResources, LIB, NODE, VALID

KEY = "__trafira_cache_v1"


def record(url="https://source-a.example/sub", agent="AgentA", hwid="hwid-a", title="A"):
    return {"version": 1, "url": url, "user_agent": agent, "hwid": hwid, "device_headers": "",
            "metadata": {"version": 1, "title": title} if title is not None else None}


def encoded(state, node=NODE):
    return ('{"' + KEY + '":' + json.dumps(state, separators=(",", ":")) + ',\n"outbounds":' +
            json.dumps([node], separators=(",", ":")) + '}\n').encode()


class BundleTransactions(SubscriptionResources):
    def persist(self, state, node=NODE, **kwargs):
        source, metadata = self.work / "source.json", self.work / "fresh-metadata.json"
        source.write_text(json.dumps({"outbounds": [node]}))
        metadata.write_text(json.dumps(state["metadata"] or {}))
        return self.uc(str(LIB / "subscription/cache.uc"), "persist-source-cache", "proxy-subscription-1",
                       str(source), state["url"], state["user_agent"], state["hwid"], str(metadata),
                       state["device_headers"], **kwargs)

    def test_failed_persistent_commit_preserves_body_and_all_identity_files(self):
        folder = self.work / "persistent"
        folder.mkdir()
        original = {"json": VALID, "url": b"https://source-a.example/sub", "user_agent": b"AgentA",
                    "hwid": b"hwid-a", "device_headers": b"", "metadata.json": b'{"version":1,"title":"A"}'}
        for suffix, data in original.items():
            (folder / ("proxy-subscription-1." + suffix)).write_bytes(data)
        state = record(agent="x" * 512)
        result = self.persist(state, {**NODE, "server": "127.0.0.2"}, file_size=256)
        self.assertNotEqual(result.returncode, 0)
        for suffix, data in original.items():
            self.assertEqual((folder / ("proxy-subscription-1." + suffix)).read_bytes(), data,
                             f"failed source transaction changed {suffix}")

    def test_authoritative_record_restores_offline_despite_stale_sidecars(self):
        state = record()
        result = self.persist(state)
        self.assertEqual(result.returncode, 0, result.stderr)
        folder = self.work / "persistent"
        document = json.loads((folder / "proxy-subscription-1.json").read_text())
        self.assertEqual(document[KEY], state)
        for suffix in ["url", "user_agent", "hwid", "device_headers"]:
            (folder / ("proxy-subscription-1." + suffix)).write_text("stale")
        runtime = self.work / "subscriptions"
        runtime.mkdir(exist_ok=True)
        result = self.uc(str(LIB / "subscription/cache.uc"), "restore-persistent-source", "proxy-subscription-1",
                         str(runtime), str(folder), state["url"], state["user_agent"], state["hwid"], "default", "")
        self.assertEqual(result.returncode, 0, result.stderr)
        restored = json.loads((runtime / "proxy-subscription-1.json").read_text())
        self.assertEqual(restored[KEY], state)
        self.assertEqual(restored["outbounds"], document["outbounds"])

    def test_source_snapshot_keeps_identity_body_and_metadata_from_one_version(self):
        folder = self.work / "subscriptions"
        folder.mkdir()
        path = folder / "proxy-subscription-1.json"
        a, b = record(), record("https://source-b.example/sub", "AgentB", "hwid-b", "B")
        path.write_bytes(encoded(a))
        replacement = self.work / "replacement.json"
        replacement.write_bytes(encoded(b, {**NODE, "server": "127.0.0.2"}))
        script = self.work / "snapshot.uc"
        script.write_text('let fs=require("fs"),s=require("singbox.subscription");'
                          'let snap=s.read_source_snapshot("proxy-subscription-1");'
                          'fs.rename(ARGV[0],ARGV[1]);'
                          'let current=s.source_cache_is_current("proxy-subscription-1",'
                          '"https://source-a.example/sub","AgentA","hwid-a","",snap);'
                          'let out=s.read_source_outbounds("proxy-subscription-1",snap),state={subscriptionMetadata:[]};'
                          's.merge_source_metadata(state,"proxy","proxy-subscription-1",1,"https://source-a.example/sub",snap);'
                          'print(sprintf("%J",{current,out,metadata:state.subscriptionMetadata}));')
        result = self.uc(str(script), str(replacement), str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertTrue(data["current"])
        self.assertEqual(data["out"][0]["server"], "127.0.0.1")
        self.assertEqual(data["metadata"][0]["title"], "A")

    def test_absent_bundle_metadata_never_resurrects_old_section_metadata(self):
        folder = self.work / "subscriptions"
        folder.mkdir()
        (folder / "proxy-subscription-1.json").write_bytes(encoded(record(title=None)))
        sections = self.work / "sections"
        sections.mkdir()
        (sections / "proxy.json").write_text(json.dumps({"subscriptionMetadata": [{"version": 1, "title": "stale"}]}))
        script = self.work / "metadata.uc"
        script.write_text('let s=require("singbox.subscription"),snap=s.read_source_snapshot("proxy-subscription-1");'
                          'let state={subscriptionMetadata:[]};'
                          's.merge_source_metadata(state,"proxy","proxy-subscription-1",1,"https://source-a.example/sub",snap);'
                          'print(sprintf("%J",state.subscriptionMetadata));')
        result = self.uc(str(script))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_malformed_reserved_record_is_not_treated_as_legacy(self):
        folder = self.work / "subscriptions"
        folder.mkdir()
        (folder / "proxy-subscription-1.json").write_text(json.dumps({KEY: "broken", "outbounds": [NODE]}))
        for suffix, text in {"url": "https://source-a.example/sub", "user_agent": "AgentA", "hwid": "hwid-a", "device_headers": ""}.items():
            (folder / ("proxy-subscription-1." + suffix)).write_text(text)
        script = self.work / "malformed.uc"
        script.write_text('let s=require("singbox.subscription");'
                          'exit(s.source_cache_is_current("proxy-subscription-1","https://source-a.example/sub","AgentA","hwid-a","")?1:0);')
        result = self.uc(str(script))
        self.assertEqual(result.returncode, 0, "broken authoritative identity fell back to sidecars: " + result.stderr)

    def test_sigkill_before_and_after_commit_keeps_one_complete_source(self):
        source_c, library = self.work / "rename.c", self.work / "rename.so"
        source_c.write_text(r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void checkpoint(void) {
  const char *marker=getenv("BUNDLE_READY");
  int fd=open(marker,O_WRONLY|O_CREAT|O_TRUNC,0600); if(fd>=0){write(fd,"ready",5);close(fd);}
  for(;;)usleep(10000);
}
int rename(const char *old,const char *dest) {
  int (*real_rename)(const char*,const char*)=dlsym(RTLD_NEXT,"rename");
  const char *target=getenv("BUNDLE_DEST"),*phase=getenv("BUNDLE_PHASE");
  if(target && phase && !strcmp(dest,target)) {
    if(!strcmp(phase,"before"))checkpoint();
    int code=real_rename(old,dest); if(!code && !strcmp(phase,"after"))checkpoint(); return code;
  }
  return real_rename(old,dest);
}
''')
        subprocess.run(["cc", "-shared", "-fPIC", str(source_c), "-ldl", "-o", str(library)], check=True, capture_output=True)
        a, b = record(), record("https://source-b.example/sub", "AgentB", "hwid-b", "B")
        self.assertEqual(self.persist(a).returncode, 0)
        folder = self.work / "persistent"
        target = folder / "proxy-subscription-1.json"
        source, metadata = self.work / "source.json", self.work / "fresh-metadata.json"
        source.write_text(json.dumps({"outbounds": [{**NODE, "server": "127.0.0.2"}]}))
        metadata.write_text(json.dumps(b["metadata"]))
        for phase in ["before", "before", "after"]:
            marker = self.work / "ready"
            marker.unlink(missing_ok=True)
            env = {**self.env, "LD_PRELOAD": str(library), "BUNDLE_READY": str(marker), "BUNDLE_DEST": str(target), "BUNDLE_PHASE": phase}
            process = subprocess.Popen(["ucode", "-L", str(LIB), str(LIB / "subscription/cache.uc"), "persist-source-cache",
                                        "proxy-subscription-1", str(source), b["url"], b["user_agent"], b["hwid"], str(metadata), ""],
                                       env=env, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists(), "source commit checkpoint was not reached")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=3)
            document = json.loads(target.read_text())
            expected = a if phase == "before" else b
            self.assertEqual(document[KEY], expected)
            self.assertEqual(document["outbounds"][0]["server"], "127.0.0.1" if phase == "before" else "127.0.0.2")
            self.assertLessEqual(len(list(folder.glob("*.bundle.tmp"))) + len(list(folder.glob(".bundle.tmp"))), 1)
        self.assertEqual(self.persist(b, {**NODE, "server": "127.0.0.2"}).returncode, 0)
        self.assertFalse(list(folder.glob("*.bundle.tmp")) + list(folder.glob(".bundle.tmp")))


def load_tests(loader, tests, pattern):
    # Reuse only the HTTP/ucode fixture, not the parent's separately run suite.
    return unittest.TestSuite(BundleTransactions(name) for name in BundleTransactions.__dict__ if name.startswith("test_"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
