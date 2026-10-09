#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cp -R "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/lib"
export TRAFIRA_LIB="$WORK_DIR/lib"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_CORE_CATALOG_DIR="$WORK_DIR/catalog"
export CORE_CLI_TEST="$WORK_DIR"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
printf 'trafira.settings=settings\ntrafira.settings.sing_box_pinned_version=1.14.1\ntrafira.settings.sing_box_pinned_variant=stable\n' >"$TRAFIRA_UCI_STATE_FILE"
cat >"$TRAFIRA_LIB/components/core_sources.uc" <<'UC'
return {
 environment:()=>({variant:"stable",architecture:"aarch64",package_type:"apk"}),
 current_version:()=>"1.14.2",
 fetch:()=>[{version:"1.14.1",variant:"stable",architecture:"aarch64",package_type:"apk",stable:true,repository_package:"sing-box"}]
};
UC
cat >"$TRAFIRA_LIB/components/updates.uc" <<'UC'
let fs=require("fs");
if(ARGV[0]=="component-version-async") {
  fs.writefile(getenv("CORE_CLI_TEST")+"/launched",ARGV[1]);
  print("{\"success\":true,\"job_id\":\"100-200\"}\n");
} else if(ARGV[0]=="component-action-status")print("{\"success\":false,\"running\":false,\"restored\":true,\"job_id\":\"100-200\"}\n");
else exit(1);
UC
call() { ucode -L "$TRAFIRA_LIB" "$ROOT_DIR/trafira/files/usr/bin/trafira-config" core_action "$1"; }
call '{"action":"catalog"}' >"$WORK_DIR/catalog.json"
call '{"action":"unpin","expected_current_version":"old"}' >"$WORK_DIR/conflict.json"
call '{"action":"unpin","expected_current_version":"1.14.2"}' >"$WORK_DIR/unpin.json"
call '{"action":"install","candidate_id":"stable~aarch64~apk~1.14.1","expected_current_version":"1.14.2","pin":true}' >"$WORK_DIR/start.json"
call '{"action":"status"}' >"$WORK_DIR/status.json"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),root=process.argv[2],read=name=>JSON.parse(fs.readFileSync(`${root}/${name}.json`));
if (read('catalog').entries[0].version!=='1.14.1' || read('catalog').pin.version!=='1.14.1') throw Error('catalog and pin');
if (read('conflict').error!=='conflict' || !read('unpin').success) throw Error('unpin guards');
if (!read('start').running || read('start').job_id!=='100-200') throw Error('background install launch');
if (!read('status').restored || read('status').running) throw Error('background status after remount');
if (JSON.parse(fs.readFileSync(`${root}/launched`)).candidate_id!=='stable~aarch64~apk~1.14.1') throw Error('structured worker request');
JS
printf 'core version CLI checks passed\n'
