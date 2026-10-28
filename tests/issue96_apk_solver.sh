#!/usr/bin/env bash
# Real OpenWrt APK solver, confined to disposable roots. No router or service.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_BIN="${APK_BIN:-}"
if [[ -z "$APK_BIN" ]]; then
  printf 'SKIP issue96 real APK solver: set APK_BIN to OpenWrt SDK host apk\n'
  exit 0
fi
[[ -x "$APK_BIN" ]] || { printf 'Invalid APK_BIN\n' >&2; exit 1; }
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT
ACTION="$ROOT_DIR/trafira/files/usr/lib/components/action.uc"
HELPER="$ROOT_DIR/tests/helpers/issue96_apk_solver.cjs"
mkdir -p "$WORK_DIR/packages"
make_package() {
  local name="$1" version="$2" depends="$3" provides="${4:-}" output="${5:-$1}"
  local tree="$WORK_DIR/payload/$name"
  mkdir -p "$tree/usr/share/issue96"
  printf '%s %s\n' "$name" "$version" >"$tree/usr/share/issue96/$name"
  local metadata=(-I "name:$name" -I "version:$version" -I 'arch:noarch' -I 'description:issue96 isolated solver fixture' -I 'license:MIT')
  [[ -z "$depends" ]] || metadata+=(-I "depends:$depends")
  [[ -z "$provides" ]] || metadata+=(-I "provides:$provides")
  "$APK_BIN" mkpkg --files "$tree" --output "$WORK_DIR/packages/$output.apk" "${metadata[@]}"
}
make_package ca-bundle 20260601-r1 ''
make_package kernel 6.12.44-r1 ''
# The real Extended package provides virtual sing-box and conflicts with its concrete counterpart.
make_package sing-box-extended 1.14.3.2.7.3-r0 '!sing-box ca-bundle=20260601-r1 kernel=6.12.44-r1' sing-box old-extended
make_package sing-box 1.13.0-r0 'ca-bundle=20260601-r1 kernel=6.12.44-r1' '' old-stable
make_package sing-box-tiny 1.13.0-r0 '!sing-box ca-bundle=20260601-r1 kernel=6.12.44-r1' sing-box old-tiny
make_package sing-box-extended 2.0.0.1.0-r0 '!sing-box ca-bundle=20260601-r1 kernel=6.12.44-r1' sing-box
make_package sing-box 1.14.2-r1 'ca-bundle=20260601-r1 kernel=6.12.44-r1'
make_package sing-box-tiny 1.14.2-r1 '!sing-box ca-bundle=20260601-r1 kernel=6.12.44-r1' sing-box
make_package incompatible 1-r0 'ca-bundle>=20260901-r1'
for source in stable tiny extended; do
 for case in stable tiny extended compressed; do
  root="$WORK_DIR/$source-$case"
  mkdir -p "$root/etc/apk" "$root/lib/apk/db"
  "$APK_BIN" --root "$root" --initdb --no-network --repositories-file /dev/null --no-scripts --no-commit-hooks \
    add --allow-untrusted "$WORK_DIR/packages/ca-bundle.apk" "$WORK_DIR/packages/kernel.apk" "$WORK_DIR/packages/old-$source.apk"
  cp "$root/etc/apk/world" "$WORK_DIR/$source-$case.original-world"
  source_name=sing-box; [[ "$source" != tiny ]] || source_name=sing-box-tiny
  [[ "$source" != extended ]] || source_name=sing-box-extended
  node - "$root/etc/apk/world" "$WORK_DIR/$source-$case.json" "$source_name" <<'JS'
const fs=require('node:fs');fs.writeFileSync(process.argv[3],JSON.stringify({source_name:process.argv[4],world:fs.readFileSync(process.argv[2],'utf8'),packages:[{name:'ca-bundle',version:'20260601-r1'},{name:'kernel',version:'6.12.44-r1'}]}));
JS
 done
done
# No rollback archives for unchanged dependencies remain anywhere in the fixture.
rm -- "$WORK_DIR/packages/ca-bundle.apk" "$WORK_DIR/packages/kernel.apk"
run_transaction() {
  local root="$1" transition="$2" target="$3" file="$4" simulate="$5" reinstall="$6"
  local args=()
  mapfile -d '' -t args < <(node "$HELPER" "$ACTION" command "$transition" "$target" "$file" "$simulate" "$reinstall")
  [[ "${args[0]}" == --no-network && "${args[2]}" == /dev/null ]] || return 1
  "$APK_BIN" --root "$root" --initdb --no-scripts --no-commit-hooks "${args[@]}"
}
validate_plan() {
  local transition="$1" target="$2" allow_unchanged="$3" required="$4"
  node "$HELPER" "$ACTION" plan "$transition" "$target" '' "$allow_unchanged" 0 "$WORK_DIR/plan" "$required"
}
assert_dependencies() {
  local root="$1"
  "$APK_BIN" --root "$root" --no-network --repositories-file /dev/null query --from installed --format json --fields name,version ca-bundle kernel >"$WORK_DIR/dependencies.json"
  node - "$WORK_DIR/dependencies.json" <<'JS'
const fs=require('node:fs'),assert=require('node:assert/strict');const pkgs=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
assert.equal(pkgs.length,2);for(const [name,version] of [['ca-bundle','20260601-r1'],['kernel','6.12.44-r1']])assert(pkgs.some(p=>p.name===name&&p.version===version));
JS
}
for source in stable tiny extended; do
 for case in stable tiny extended compressed; do
  source_name=sing-box; [[ "$source" != tiny ]] || source_name=sing-box-tiny
  [[ "$source" != extended ]] || source_name=sing-box-extended
  root="$WORK_DIR/$source-$case"; transition="$WORK_DIR/$source-$case.json"; target=''; file=''
  if [[ "$case" == stable ]]; then target=sing-box; file="$WORK_DIR/packages/sing-box.apk"; fi
  if [[ "$case" == tiny ]]; then target=sing-box-tiny; file="$WORK_DIR/packages/sing-box-tiny.apk"; fi
  if [[ "$case" == extended ]]; then target=sing-box-extended; file="$WORK_DIR/packages/sing-box-extended.apk"; fi
  if [[ "$target" == "$source_name" ]]; then required='[]'; else required="[\"$source_name\"]"; fi
  run_transaction "$root" "$transition" "$target" "$file" 1 0 >"$WORK_DIR/plan"
  validate_plan "$transition" "$target" 0 "$required"
  run_transaction "$root" "$transition" "$target" "$file" 0 0
  node "$HELPER" "$ACTION" world "$transition" "$target" >"$root/etc/apk/world"
  target_version=""; [[ -z "$target" ]] || target_version=1.14.2-r1
  [[ "$target" != sing-box-extended ]] || target_version=2.0.0.1.0-r0
  node "$HELPER" "$ACTION" lookup "$transition" "$target" "$root" "$target_version"
  assert_dependencies "$root"
  if [[ -n "$target" && "$target" != "$source_name" ]]; then required="[\"$target\"]"; else required='[]'; fi
  run_transaction "$root" "$transition" "$source_name" "$WORK_DIR/packages/old-$source.apk" 1 0 >"$WORK_DIR/plan"
  validate_plan "$transition" "$source_name" 0 "$required"
  run_transaction "$root" "$transition" "$source_name" "$WORK_DIR/packages/old-$source.apk" 0 0
  cp "$WORK_DIR/$source-$case.original-world" "$root/etc/apk/world"
  assert_dependencies "$root"
  cmp "$WORK_DIR/$source-$case.original-world" "$root/etc/apk/world"
  # Failure before package removal: same-version payload must really be restored,
  # with dependency pins in world and force-reinstall naming ONLY the old core.
  rm -- "$root/usr/share/issue96/$source_name"
  run_transaction "$root" "$transition" "$source_name" "$WORK_DIR/packages/old-$source.apk" 0 0
  run_transaction "$root" "$transition" "$source_name" "$WORK_DIR/packages/old-$source.apk" 1 1 >"$WORK_DIR/plan"
  validate_plan "$transition" "$source_name" 0 '[]'
  run_transaction "$root" "$transition" "$source_name" "$WORK_DIR/packages/old-$source.apk" 0 1
  cp "$WORK_DIR/$source-$case.original-world" "$root/etc/apk/world"
  test -s "$root/usr/share/issue96/$source_name"
  source_version=1.13.0-r0; [[ "$source_name" != sing-box-extended ]] || source_version=1.14.3.2.7.3-r0
  node "$HELPER" "$ACTION" lookup "$transition" "$source_name" "$root" "$source_version"
  assert_dependencies "$root"
  cmp "$WORK_DIR/$source-$case.original-world" "$root/etc/apk/world"
 done
done
# A candidate requiring a newer dependency cannot use a network/cache candidate.
if run_transaction "$WORK_DIR/stable-stable" "$WORK_DIR/stable-stable.json" incompatible "$WORK_DIR/packages/incompatible.apk" 1 0 >"$WORK_DIR/plan" 2>&1; then
  printf 'Unsafe incompatible dependency plan unexpectedly succeeded\n' >&2; exit 1
fi
assert_dependencies "$WORK_DIR/stable-stable"
cmp "$WORK_DIR/stable-stable.original-world" "$WORK_DIR/stable-stable/etc/apk/world"
printf 'issue96 real APK solver: Stable/Tiny/Compressed, virtual provider, exact rollback, dependency preservation passed\n'
