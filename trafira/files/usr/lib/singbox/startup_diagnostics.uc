let fs = require("fs");

function reason(log, marker) {
    let current = false;
    let result = "";
    for (let line in split(log || "", "\n")) {
        if (index(line, marker) >= 0) { current = true; continue; }
        if (!current || !match(line, /sing-box\[[0-9]+\]:/)) continue;
        line = replace(line, /\x1b\[[0-9;]*m/g, "");
        if (!match(line, /FATAL|initialize rule-set|initial rule-set/)) continue;
        line = replace(line, /^.*sing-box\[[0-9]+\]:[ \t]*/, "");
        // Download URLs can contain credentials or private paths.
        line = replace(line, /https?:\/\/[^ \t"<>]+/g, "[redacted URL]");
        result = substr(line, 0, 700);
    }
    return result;
}
function begin() {
    let stamp = clock();
    let marker = "trafira-sing-box-start-" + stamp[0] + "-" + stamp[1];
    system("logger -t trafira " + marker);
    return marker;
}
function read(marker) {
    let pipe = fs.popen("logread -l 250 2>/dev/null", "r");
    if (!pipe) return "";
    let log = pipe.read("all");
    pipe.close();
    return reason(log, marker);
}
return { begin, read, reason };
