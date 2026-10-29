"""Exercise production parsing on banIP-sized rulesets; bound tokenization work."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[2]
source = (root / "trafira/files/usr/lib/providers/nfqueue/check.uc").read_text()
# Count calls in the real parser, rather than relying on a machine-specific deadline.
source, changed = re.subn(r"function nft_line_fields\(line\)\s*\{",
                         "function nft_line_fields(line) { tokenized++;", source)
assert changed == 1, "Production tokenizer not found"
source = source[:source.index("function rewrite_legacy_runtime_path")]
source = "let tokenized = 0;\n" + source.removeprefix("#!/usr/bin/env ucode\n")
node = "--node-fallback" in sys.argv
if node:
    source = source[source.index("function cleaned_queue_token"):]
    source = re.sub(r"for \(let (\w+) in ([^\n]+)\) \{", r"for (let \1 of \2) {", source)
    source = """const fs = require('node:fs'); let tokenized = 0;
const as_string = v => v == null ? '' : String(v), int = Number;
const length = v => v.length, push = (v, x) => v.push(x);
const read_stdin = () => fs.readFileSync(0, 'utf8');
const split = (v, s) => v.split(s), match = (v, p) => v.match(p);
const replace = (v, a, b) => v.replace(a, b), trim = v => v.trim();
const substr = (v, s, n) => n == null ? v.slice(s) : v.slice(s, s+n);
const index = (v, s) => v.indexOf(s);
""" + source
    source += "console.log(JSON.stringify({overlap:nft_queue_overlap('TrafiraTable',4300,4555),tokenized}));"
else:
    source += """let overlap = nft_queue_overlap("TrafiraTable", 4300, 4555);
printf('{"overlap":%s,"tokenized":%d}\\n', overlap ? "true" : "false", tokenized);
"""

# More than 190 KiB of irrelevant set data, plus queues inside Trafira's own table.
large = "table inet banIP {\n set blocked {\n" + "".join(
    f"  192.0.2.{i % 256} timeout 1d expires 23h comment \"banIP entry {i}\",\n"
    for i in range(4877)) + " }\n}\n"
large += "table inet TrafiraTable {\n chain c {\n" + " queue num 4300\n" * 400 + " }\n}\n"
cases = [
    ("no queue outside own table", "table inet fw4 {\n counter accept\n}\n", False),
    ("foreign queue after own table", "table inet fw4 {\n queue num 4310\n}\n", True),
    ("explicit ownership", 'table inet fw4 {\n queue num 4300 comment "trafira-ignore"\n}\n', False),
    ("range crossing ownership boundary", 'table inet fw4 {\n queue num 4200-4310 comment "trafira-ignore"\n}\n', True),
    ("comment only", 'table inet fw4 {\n counter comment "queue num 4300"\n}\n', False),
    ("table family transition and CRLF", ' \ttable ip TrafiraTable {\r\n queue num 4400\r\n}\r\n', True),
]
with tempfile.TemporaryDirectory(prefix="trafira-nfqueue-scaling-") as tmp:
    runner = Path(tmp) / ("check.cjs" if node else "check.uc")
    runner.write_text(source)
    for description, tail, expected in cases:
        fixture = large + tail
        start = time.monotonic()
        result = subprocess.run(["node" if node else "ucode", str(runner)],
                                input=fixture, text=True, capture_output=True, timeout=30)
        assert result.returncode == 0, (description, result.stderr)
        actual = json.loads(result.stdout)
        assert actual["overlap"] == expected, (description, actual)
        assert actual["tokenized"] <= 4, (description, actual,
            "Unrelated nftables lines must not undergo character-by-character parsing")
        print(f"PASS: {description}: {len(fixture)} bytes, "
              f"{actual['tokenized']} tokenized lines, {time.monotonic()-start:.3f}s")
print("NFQUEUE large-ruleset checks passed" + (" (Node fallback; not a ucode syntax check)" if node else " (real ucode)"))
