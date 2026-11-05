#!/usr/bin/env ucode
let fs = require("fs");

const SOURCE_LIMIT = 8388608;
const CACHE_LIMIT = 33554432;
const LINK_LIMIT = 262144;
const HEADER_LIMIT = 131072;
const CHUNK = 65536;

function exceeds_limit(path, limit) {
    let stat = fs.stat(path);
    return stat != null && stat.size > limit;
}

function read_file(path, limit) {
    limit = limit == null ? CACHE_LIMIT : limit;
    if (exceeds_limit(path, limit)) {
        warn("Subscription file exceeds size limit\n");
        return null;
    }
    let input = fs.open(path, "r");
    if (!input)
        return null;
    fs.error();
    let data = input.read(limit + 1), error = fs.error();
    input.close();
    if (error)
        return null;
    if (data == null)
        data = "";
    if (length(data) > limit) {
        warn("Subscription file exceeds size limit\n");
        return null;
    }
    return data;
}

function copy_stream(input, output, limit) {
    let bytes = 0;
    while (true) {
        fs.error();
        let chunk = input.read(limit == null ? CHUNK : min(CHUNK, limit - bytes + 1));
        let error = fs.error();
        if (error)
            return { ok: false, bytes };
        if (chunk == null || chunk == "")
            return { ok: true, bytes };
        bytes += length(chunk);
        if (limit != null && bytes > limit)
            return { ok: false, too_large: true, bytes };
        if (output.write(chunk) != length(chunk))
            return { ok: false, bytes };
    }
}

function copy_file(source, target) {
    let input = fs.open(source, "r");
    if (!input)
        return false;
    let stamp = clock(), tmp = sprintf("%s.%d.%d.tmp", target, stamp[0], stamp[1]);
    let output = fs.open(tmp, "w");
    if (!output) {
        input.close();
        return false;
    }
    let result = { ok: false };
    if (fs.chmod(tmp, 384))
        result = copy_stream(input, output, null);
    input.close();
    let closed = output.close();
    if (result.ok && closed && fs.rename(tmp, target))
        return true;
    fs.unlink(tmp);
    return false;
}

function files_equal(left, right) {
    let a = fs.stat(left), b = fs.stat(right);
    if (!a || !b || a.size != b.size)
        return false;
    let first = fs.open(left, "r"), second = fs.open(right, "r"), same = false;
    if (first && second) {
        while (true) {
            fs.error();
            let x = first.read(CHUNK), first_error = fs.error();
            let y = second.read(CHUNK), second_error = fs.error();
            if (first_error || second_error || x != y)
                break;
            if (x == null || x == "") {
                same = true;
                break;
            }
        }
    }
    if (first) first.close();
    if (second) second.close();
    return same;
}

return { SOURCE_LIMIT, CACHE_LIMIT, LINK_LIMIT, HEADER_LIMIT,
         exceeds_limit, read_file, copy_stream, copy_file, files_equal };
