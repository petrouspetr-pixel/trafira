#!/usr/bin/env python3
"""Collect licenses from the actual, checksum-verified Go dependency sources."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

go, source, destination = sys.argv[1:]
out=Path(destination);out.mkdir(parents=True,exist_ok=True)
env={**os.environ,"GOOS":"linux","GOARCH":"arm64","CGO_ENABLED":"0","GOTOOLCHAIN":"local"}
text=subprocess.check_output([go,"list","-deps","-f","{{if .Module}}{{.Module.Path}}|{{.Module.Version}}|{{.Module.Dir}}{{end}}","."],cwd=source,env=env,text=True)
index=[]
for line in sorted(set(text.splitlines())):
    if not line:continue
    name,version,directory=line.split("|",2)
    module=Path(directory)
    files=[p for p in module.iterdir() if p.is_file() and p.name.upper().split(".")[0] in ("LICENSE","COPYING","NOTICE","LICENCE","COPYRIGHT")]
    if not files:raise SystemExit("Missing license in linked module "+name)
    target=out/name.replace("/","_");target.mkdir(parents=True,exist_ok=True)
    for file in files:shutil.copyfile(file,target/file.name)
    index.append(name+" "+version)
(out/"MODULES.txt").write_text("\n".join(index)+"\n",encoding="utf-8")
