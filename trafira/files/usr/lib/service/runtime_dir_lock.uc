// PID ownership outlives the short CLI helper. Serialize its publication and
// recovery separately so an empty, newly created directory is never stolen.
let fs = require("fs");

function guard(directory, wait) {
    let path = directory + ".guard", info = fs.lstat(path);
    if (info && info.type != "file")
        return null;
    let file = fs.open(path, "ae", 384);
    if (!file)
        return null;
    if (file.lock(wait ? "x" : "xn"))
        return file;
    file.close();
    return null;
}

function first_line(path) {
    let input = fs.open(path, "re");
    if (!input)
        return "";
    let value = input.read(64) || "";
    input.close();
    return split(value, "\n")[0];
}

function alive(pid) {
    return match(pid || "", /^[1-9][0-9]*$/) && fs.access("/proc/" + pid);
}

function remove(directory) {
    fs.unlink(directory + "/pid");
    return fs.rmdir(directory);
}

function acquire_locked(directory, pid) {
    if (!fs.mkdir(directory, 448)) {
        if (alive(first_line(directory + "/pid")) || !remove(directory) ||
            !fs.mkdir(directory, 448))
            return false;
    }
    let text = pid + "\n", output = fs.open(directory + "/pid", "we", 384);
    let written = output ? output.write(text) : null;
    if (output)
        output.close();
    // Old ucode may ignore a buffered fclose failure. Read after close.
    if (written == length(text) && fs.readfile(directory + "/pid") == text)
        return true;
    remove(directory);
    return false;
}

function acquire(directory, pid) {
    if (type(directory) != "string" || directory == "" ||
        !match("" + (pid || ""), /^[1-9][0-9]{0,19}$/))
        return false;
    let held = guard(directory, false);
    if (!held)
        return false;
    let result = false;
    try { result = acquire_locked(directory, "" + pid); } catch (e) {}
    held.close();
    return result;
}

function release(directory) {
    if (type(directory) != "string" || directory == "")
        return;
    let held = guard(directory, true);
    if (!held)
        return;
    try { remove(directory); } catch (e) {}
    held.close();
    // Never unlink the stable guard inode: another helper may already hold it.
}

return { acquire, release };
