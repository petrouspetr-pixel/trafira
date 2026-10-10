#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'JS'
const fs=require('fs'),root=process.argv[2];
const acl=JSON.parse(fs.readFileSync(root+'/luci-app-trafira/root/usr/share/rpcd/acl.d/luci-app-trafira.json'))['luci-app-trafira'];
if (acl.read.file['/usr/bin/trafira-config']) throw Error('read-only sessions must not access unrestricted profile actions');
if (!acl.read.file['/usr/bin/trafira-read']?.includes('exec')) throw Error('restricted profile read entrypoint missing');
if (!acl.write.file['/usr/bin/trafira-config']?.includes('exec')) throw Error('administrative profile entrypoint missing');
for (const access of [acl.read,acl.write]) for (const key of Object.keys(access.file)) if (key.includes('/profiles') || key.includes('/transactions')) throw Error('broad profile filesystem ACL');
const cli=fs.readFileSync(root+'/trafira/files/usr/bin/trafira','utf8');
if (/profile_action\s*:/.test(cli)) throw Error('profile action must use the separate configuration dispatcher');
JS
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_PROFILES_DIR="$WORK_DIR/profiles"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
ucode "$ROOT_DIR/trafira/files/usr/bin/trafira-config" profile_action '{"action":"list"}' >"$WORK_DIR/list.json"
node - "$WORK_DIR/list.json" <<'JS'
if (!JSON.parse(require('fs').readFileSync(process.argv[2])).success) throw Error('administrative profile command failed');
JS
grep -Fq 'files/usr/bin/trafira-config' "$ROOT_DIR/trafira/Makefile"
grep -Fq 'files/usr/bin/trafira-config' "$ROOT_DIR/build.sh"
printf 'profile permissions and entrypoint checks passed\n'
