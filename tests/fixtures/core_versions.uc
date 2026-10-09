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
let prefix="https://github.com/shtorm-7/sing-box-extended/releases/download/v1.14.2/";
let name="sing-box-extended_1.14.2_openwrt_aarch64.apk";
let github=[{tag_name:"v1.14.2",html_url:"https://github.com/shtorm-7/sing-box-extended/releases/tag/v1.14.2",assets:[
 {name,browser_download_url:prefix+name,size:123,digest:"sha256:"+sprintf("%064d",1)},
 {name:"sing-box-extended_1.14.2_openwrt_x86_64.apk",browser_download_url:prefix+"wrong.apk",size:123}
]}];
let normalized=v.from_github(github,env);
assert(length(normalized)==1 && normalized[0].architecture=="aarch64","only matching package asset exposed");
assert(normalized[0].sha256==sprintf("%064d",1),"published checksum preserved");
github[0].assets[0].browser_download_url="https://attacker.invalid/package.apk";
assert(length(v.from_github(github,env))==0,"off-source release asset rejected");
let packages=v.from_packages([{name:"sing-box",version:"1.14.2-r1",arch:"aarch64"},{name:"sing-box-tiny",version:"1.14.2-r1",arch:"aarch64"}],{...env,variant:"stable"});
assert(length(packages)==1 && packages[0].repository_package=="sing-box","repository package variant exact");
assert(v.catalog(packages,{...env,variant:"stable"}).entries[0].available,"real repository version selectable");
let compressed_name="sing-box-1.14.2-extended-2.7.2-linux-arm64-compressed.tar.gz";
let compressed=v.from_github([{tag_name:"v1.14.2-extended-2.7.2",assets:[{name:compressed_name,size:200,browser_download_url:"https://github.com/shtorm-7/sing-box-extended/releases/download/v1.14.2-extended-2.7.2/"+compressed_name}]}],{...env,variant:"extended-compressed",package_type:"tar.gz",binary_architecture:"arm64"});
assert(length(compressed)==1,"compressed releases use sing-box-version asset prefix");
print("core version source adapter checks passed\n");
