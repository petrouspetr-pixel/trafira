// Generic lists: bound the stream independently of curl's version and headers.
let fs = require("fs");

function quote(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }

function download(args, path, limit) {
    let stamp = clock(), temporary = sprintf("%s.download.%d.%d", path, stamp[0], stamp[1]);
    let output = fs.open(temporary, "wex", 384);
    if (!output) return { code: 23, http_status: null };
    let pipe = null, tail = "", bytes = 0, ok = true, oversized = false;
    try {
        pipe = fs.popen("exec " + join(" ", map(args, quote)) + " 2>/dev/null", "r");
        ok = pipe != null;
        while (ok) {
            fs.error();
            // Three trailing bytes belong to curl's HTTP write-out, not the body.
            let chunk = pipe.read(min(65536, limit - bytes + 4));
            if (fs.error()) { ok = false; break; }
            if (chunk == null || chunk == "") break;
            let data = tail + chunk, count = max(0, length(data) - 3);
            if (bytes + count > limit) { oversized = true; ok = false; break; }
            if (count > 0 && output.write(substr(data, 0, count)) != count) { ok = false; break; }
            bytes += count;
            tail = substr(data, count);
        }
    }
    catch (e) { ok = false; }
    let closed = output.close();
    // Closing the read end also terminates a writer still sending oversized data.
    let code = pipe ? pipe.close() : 23;
    code = code == null || code < 0 ? 23 : code > 255 ? int(code / 256) : code;
    let http_status = match(tail, /^[1-5][0-9][0-9]$/) ? int(tail) : null;
    if (oversized) code = 63;
    else if (code == 0) {
        let info = fs.lstat(temporary);
        if (!ok || !closed || http_status == null || !info || info.type != "file" || info.size != bytes ||
            !fs.rename(temporary, path)) code = 23;
    }
    fs.unlink(temporary);
    return { code, http_status };
}

return { download };
