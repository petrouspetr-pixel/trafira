// Buffer a bounded nft script. nft commits the complete input atomically at EOF.
let fs = require("fs");

function create(limit) {
    limit = limit == null ? 1048576 : int(limit);
    let lines = [], size = 0, failed = limit < 1, closed = false, callbacks = [];

    function append(text) {
        if (closed || failed || type(text) != "string")
            return false;
        if (text != "" && substr(text, -1) != "\n")
            text += "\n";
        if (size + length(text) > limit) {
            failed = true;
            return false;
        }
        size += length(text);
        push(lines, text);
        return true;
    }

    function command(args) {
        let words = [];
        for (let arg in args)
            if ((type(arg) != "string" && type(arg) != "int") || match("" + arg, /[\r\n]/)) {
                failed = true;
                return false;
            }
            else push(words, "" + arg);
        // nft's argv interface joins arguments before parsing them too.
        return append(join(" ", words));
    }

    function after_commit(callback) {
        if (closed || failed || type(callback) != "function")
            return false;
        push(callbacks, callback);
        return true;
    }

    function commit() {
        if (closed)
            return false;
        closed = true;
        if (failed)
            return false;
        if (size > 0) {
            let pipe = fs.popen("exec nft -f -", "w");
            if (!pipe)
                return false;
            let text = join("", lines);
            let written = pipe.write(text);
            let status = pipe.close();
            lines = [];
            if (written != length(text) || status != 0)
                return false;
        }
        for (let callback in callbacks)
            if (callback() === false)
                return false;
        return true;
    }

    return { append, command, after_commit, commit };
}

return { create };
