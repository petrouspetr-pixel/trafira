let fs=require("fs"),profiles=require("config.profiles");
let document={schema:1,name:"Read test",config:[{".name":"settings",".type":"settings",dns_server:["1.1.1.1"]}]};
let created=profiles.create(document);
assert(created.success,"create fixture profile");
let path=profiles.DIRECTORY+"/"+created.id+".json",original=fs.readfile(path);
let lock_path=profiles.DIRECTORY+"/.lock",inode=fs.stat(lock_path).ino;
let other=fs.open(lock_path,"ae",384);
assert(other && other.lock("sn"),"hold another reader on the registry inode");

// Separate open file descriptions use real kernel flock semantics, even in one process.
let listed=profiles.list();
assert(listed.success && length(listed.entries)==1,"profile list must coexist with another reader");
let exported=profiles.export_profile(created.id);
assert(exported.success && exported.document.name==document.name,"export must coexist with another reader");
let preview=profiles.preview(created.id,document.config);
assert(preview.success && length(preview.changes)==0,"preview must coexist with another reader");
for(let result in [profiles.create(document),profiles.rename(created.id,"Blocked"),profiles.remove(created.id)])
    assert(!result.success && result.error=="busy","writers must not overlap readers");
assert(fs.readfile(path)==original && length(fs.glob(profiles.DIRECTORY+"/*.json"))==1,"blocked writes leave profiles unchanged");
other.close();
assert(profiles.rename(created.id,"After readers").success,"read handles close before a writer enters");

other=fs.open(lock_path,"ae",384);
assert(other && other.lock("xn"),"hold an exclusive writer on the same inode");
for(let result in [profiles.list(),profiles.export_profile(created.id),profiles.preview(created.id,[])])
    assert(!result.success && result.error=="busy","readers must not overlap a writer");
for(let result in [profiles.create(document),profiles.rename(created.id,"Blocked"),profiles.remove(created.id)])
    assert(!result.success && result.error=="busy","writers remain exclusive");
other.close();
assert(profiles.list().entries[0].name=="After readers","list recovers after the writer finishes");
assert(fs.stat(lock_path).ino==inode,"the shared registry lock inode remains stable");
assert(profiles.remove(created.id).success,"remove after locks are released");
print("profile concurrent read and write exclusion checks passed\n");
