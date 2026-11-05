#!/usr/bin/env ucode
// The normalized subscription remains ordinary JSON with outbounds. Its own
// identity and UI metadata are committed in the same inode, never in sidecars.
let fs = require("fs");
let io = loadfile(replace(sourcepath(), /\/[^\/]+$/, "/io.uc"))();
const KEY = "__trafira_cache_v1";
const PREFIX = '{"__trafira_cache_v1":';

function valid_record(value) {
    if (type(value) != "object" || value.version != 1)
        return false;
    for (let field in ["url", "user_agent", "hwid", "device_headers"])
        if (type(value[field]) != "string")
            return false;
    return value.metadata == null || type(value.metadata) == "object";
}

function header(text) {
    if (substr(text || "", 0, length(PREFIX)) != PREFIX)
        return { present: false };
    let end = index(text, "\n"), value;
    if (end < 0 || end > io.HEADER_LIMIT || substr(text, end - 1, 1) != ",")
        return { present: true, valid: false };
    try { value = json(substr(text, length(PREFIX), end - length(PREFIX) - 1)); }
    catch (e) { return { present: true, valid: false }; }
    return { present: true, valid: valid_record(value), value, offset: end + 1 };
}

function snapshot(path) {
    let text = io.read_file(path, io.CACHE_LIMIT), document;
    try { document = json(text); } catch (e) { return { valid: false }; }
    if (type(document) != "object")
        return { valid: false };
    let own = KEY in document, prologue = header(text);
    if (own || prologue.present) {
        if (!own || !prologue.valid || !valid_record(document[KEY]) ||
            sprintf("%J", prologue.value) != sprintf("%J", document[KEY]))
            return { valid: false, present: true };
        return { valid: true, present: true, document, record: document[KEY] };
    }
    return { valid: true, present: false, document };
}

function identity_matches(a, b) {
    if (!a || !b)
        return false;
    for (let field in ["url", "user_agent", "hwid", "device_headers"])
        if (a[field] != b[field])
            return false;
    return true;
}

function inspect(path) {
    let input = fs.open(path, "re");
    if (!input)
        return { present: false };
    let text = input.read(io.HEADER_LIMIT + 1) || "";
    input.close();
    let parsed = header(text);
    if (parsed.present)
        return parsed;
    // A reserved record outside the canonical prologue is corruption, not a
    // legacy source. Only old files need the full bounded format check.
    let snap = snapshot(path);
    return snap.valid && !snap.present ? { present: false } : { present: true, valid: false };
}

function input_header(input) {
    input.seek(0);
    let text = input.read(io.HEADER_LIMIT + 1) || "", parsed = header(text);
    if (parsed.present)
        return parsed;
    let offset = 0;
    while (index([" ", "\r", "\n", "\t"], substr(text, offset, 1)) >= 0 && offset < length(text))
        offset++;
    return { present: false, valid: substr(text, offset, 1) == "{", offset: offset + 1 };
}

function equal_bodies(a, first, b, second) {
    a.seek(first); b.seek(second);
    while (true) {
        fs.error(); let x = a.read(65536), error = fs.error();
        let y = b.read(65536), other_error = fs.error();
        if (error || other_error || x != y)
            return false;
        if (x == null || x == "")
            return true;
    }
}

function stage(source, target, tmp, record, validate) {
    let input = fs.open(source, "re");
    if (!input)
        return false;
    // A pinned descriptor prevents validating one generation and copying a
    // different inode after a concurrent atomic source replacement.
    let valid = false;
    try { valid = validate("/proc/self/fd/" + input.fileno()); } catch (e) {}
    let old = input_header(input);
    if (!valid || !old.valid || (old.present && sprintf("%J", old.value) != sprintf("%J", record))) {
        input.close(); return false;
    }
    let current = fs.open(target, "re");
    if (current) {
        let previous = input_header(current);
        let same = previous.valid && previous.present &&
            sprintf("%J", previous.value) == sprintf("%J", record) &&
            equal_bodies(input, old.offset, current, previous.offset);
        current.close();
        if (same) { input.close(); return true; }
    }
    let prefix = PREFIX + sprintf("%J", record) + ",\n";
    if (length(prefix) > io.HEADER_LIMIT) { input.close(); return false; }
    input.seek(old.offset);
    let output = fs.open(tmp, "wex", 384), result = { ok: false };
    if (output && output.write(prefix) == length(prefix))
        result = io.copy_stream(input, output, io.CACHE_LIMIT - length(prefix));
    input.close();
    let closed = output ? output.close() : false;
    return result.ok && closed && io.complete_file(tmp, length(prefix) + result.bytes) && fs.rename(tmp, target);
}

function writer_lock(dir) {
    let file = fs.open(dir + "/.bundle.lock", "ae", 384);
    if (!file)
        return null;
    let deadline = clock(true)[0] + 2;
    while (!file.lock("xn")) {
        if (clock(true)[0] >= deadline) { file.close(); return null; }
        sleep(20);
    }
    return file;
}

function cleanup(dir) {
    if (!fs.lstat(dir + "/.bundle.tmp"))
        return;
    let lock = writer_lock(dir);
    if (!lock)
        return;
    fs.unlink(dir + "/.bundle.tmp");
    lock.close();
}

function publish(source, target, record, validate, after_commit) {
    if (!valid_record(record))
        return false;
    let slash = rindex(target, "/"), dir = slash >= 0 ? substr(target, 0, slash) : ".";
    let lock = writer_lock(dir);
    if (!lock)
        return false;
    // One staging name per locked directory bounds crash leftovers to one file.
    let tmp = dir + "/.bundle.tmp", result = false;
    fs.unlink(tmp);
    try {
        result = stage(source, target, tmp, record, validate);
        // Compatibility views are not the commit record. Reuse the same
        // locked staging path so a crash cannot accumulate small temp files.
        if (result && type(after_commit) == "function")
            after_commit(tmp);
    } catch (e) {}
    fs.unlink(tmp);
    lock.close();
    return result;
}

return { KEY, valid_record, snapshot, inspect, identity_matches, publish, cleanup };
