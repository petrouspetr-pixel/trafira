#!/usr/bin/env python3
"""Fetch a pinned CI artifact in bounded ranges; publish only after full SHA-256."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit


def download(url, destination, size, sha256, chunk_size=16777216, workers=4, timeout=240, curl=None):
    if (urlsplit(url).scheme != "https" or not urlsplit(url).hostname or
            type(size) is not int or size <= 0 or
            not re.fullmatch(r"[a-fA-F0-9]{64}", sha256) or
            type(chunk_size) is not int or not 1 <= chunk_size <= 16777216 or
            type(workers) is not int or not 1 <= workers <= 8 or
            not math.isfinite(timeout) or timeout <= 0):
        raise ValueError("A pinned HTTPS artifact, positive size and bounded download settings are required")
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    deadline, cancelled = time.monotonic() + timeout, threading.Event()
    transport = list(curl) if curl is not None else ["curl"]
    with tempfile.TemporaryDirectory(prefix=".artifact-ranges-", dir=destination.parent) as temporary:
        root = Path(temporary)

        def fetch(index):
            start, end = index * chunk_size, min(size, (index + 1) * chunk_size) - 1
            body, headers = root / f"{index}.part", root / f"{index}.headers"
            remaining = deadline - time.monotonic()
            if cancelled.is_set() or remaining <= 0:
                raise RuntimeError("Artifact download deadline exceeded")
            args = transport + ["--proto", "=https", "--proto-redir", "=https", "--fail",
                "--location", "--silent", "--show-error", "--max-redirs", "5",
                "--connect-timeout", "15", "--max-time", str(min(60, remaining)),
                "--max-filesize", str(end - start + 1), "--range", f"{start}-{end}",
                "--dump-header", str(headers), "--output", str(body), "--write-out", "%{http_code}", url]
            try:
                result = subprocess.run(args, capture_output=True, text=True, timeout=remaining)
            except (subprocess.TimeoutExpired, OSError):
                raise RuntimeError("Artifact range transport failed or exceeded its deadline") from None
            if result.returncode or result.stdout.strip() != "206":
                code = result.stdout.strip()
                code = code if re.fullmatch(r"[0-9]{3}", code) else "unknown"
                received = body.stat().st_size if body.is_file() else 0
                raise RuntimeError(f"Artifact range {index}: curl exit={result.returncode}, HTTP={code}, received={received}/{end-start+1}")
            if not body.is_file() or body.stat().st_size != end - start + 1:
                raise RuntimeError("Artifact range has an unexpected size")
            if not headers.is_file() or headers.stat().st_size > 131072:
                raise RuntimeError("Artifact range headers are missing or oversized")
            blocks = [block for block in re.split(r"\r?\n\r?\n", headers.read_text(encoding="latin-1"))
                      if re.match(r"^HTTP/\S+\s+\d{3}", block)]
            # An earlier redirect's Content-Range cannot validate the final body.
            ranges = re.findall(r"(?im)^Content-Range:\s*([^\r\n]+)", blocks[-1]) if blocks else []
            if (not blocks or not re.match(r"^HTTP/\S+\s+206(?:\s|$)", blocks[-1]) or
                    ranges != [f"bytes {start}-{end}/{size}"]):
                raise RuntimeError("Artifact server returned an incorrect Content-Range")
            return index

        count = (size + chunk_size - 1) // chunk_size
        with ThreadPoolExecutor(max_workers=workers) as pool:
            pending = [pool.submit(fetch, index) for index in range(count)]
            try:
                for completed in as_completed(pending):
                    completed.result()
            except Exception:
                cancelled.set()
                for future in pending:
                    future.cancel()
                raise
        complete, digest = root / "verified", hashlib.sha256()
        with complete.open("xb") as output:
            for index in range(count):
                with (root / f"{index}.part").open("rb") as part:
                    while chunk := part.read(65536):
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Artifact verification deadline exceeded")
                        output.write(chunk)
                        digest.update(chunk)
        if complete.stat().st_size != size or digest.hexdigest() != sha256.lower():
            raise RuntimeError("Artifact SHA-256 verification failed")
        os.replace(complete, destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("destination")
    parser.add_argument("--size", type=int, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--timeout", type=float, default=240)
    arguments = parser.parse_args()
    download(arguments.url, arguments.destination, arguments.size, arguments.sha256, timeout=arguments.timeout)
    print("Artifact downloaded and SHA-256 verified")
