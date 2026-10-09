let v=require("components.core_versions");
let env={variant:"extended",architecture:"aarch64",package_type:"apk"};
let releases=[
 {version:"1.14.2",variant:"extended",architecture:"aarch64",package_type:"apk",stable:true,asset_url:"https://example.invalid/a.apk",release_url:"https://example.invalid/v1.14.2"},
 {version:"1.14.2",variant:"extended",architecture:"x86_64",package_type:"apk",stable:true},
 {version:"1.15.0-beta.1",variant:"extended",architecture:"aarch64",package_type:"apk",stable:false},
 {version:"1.14.1",variant:"extended",architecture:"aarch64",package_type:"ipk",stable:true},
 {version:"1.14.1",variant:"extended",architecture:"aarch64",package_type:"apk",stable:true,asset_url:"https://example.invalid/old.apk"}
];
let result=v.catalog(releases,env);
assert(length(result.entries)==4,"prerelease excluded");
assert(result.entries[0].available,"matching artifact available");
assert(result.entries[1].reason=="wrong_architecture" && !result.entries[1].available,"architecture mismatch");
assert(result.entries[2].reason=="wrong_package_type","package mismatch");
assert(index(sprintf("%J",result),"asset_url")<0,"only server resolves installation URL");
assert(v.resolve(result.entries[0].id,releases,env).asset_url==releases[0].asset_url,"trusted resolution");
assert(v.resolve(result.entries[0].id,[],env)==null,"removed release rejected");
assert(v.resolve(result.entries[1].id,releases,env)==null,"incompatible candidate rejected");
assert(v.resolve("https://attacker.invalid/file.apk",releases,env)==null,"URL cannot be candidate id");
let pin={version:"1.14.1",variant:"extended"};
assert(v.select(releases,env,pin).candidate.version=="1.14.1","pin wins over newer stable");
assert(v.select([releases[0]],env,pin).error=="pinned_version_unavailable","missing pin cannot fall back to latest");
assert(v.select(releases,env,{version:"1.14.1",variant:"stable"}).error=="pinned_variant_mismatch","pin never changes variant");
assert(v.select(releases,env,null).candidate.version=="1.14.2","unpin restores latest");
let oversized=[];for(let n=0;n<101;n++)push(oversized,releases[0]);
assert(v.catalog(oversized,env).unavailable_reason=="catalog_too_large","candidate bound");
assert(v.catalog([{...releases[0],extra:sprintf("%02100000d",1)}],env).unavailable_reason=="catalog_too_large","response size bound");
print("core version catalog checks passed\n");
