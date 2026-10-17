// Compare UCI data without treating its writer's whitespace/quoting as an edit.
// This never executes UCI text. Unknown or malformed syntax keeps exact identity.
function normalized(text) {
    text = text || "";
    let rows = [], row = [], token = "", started = false, quote = "", escaped = false, comment = false, plain_command = true;
    for (let i = 0; i < length(text); i++) {
        let ch = substr(text, i, 1);
        if (comment) {
            if (ch != "\n") continue;
            comment = false;
        }
        if (escaped) {
            if (ch != "\n") token += ch;
            escaped = false;
            continue;
        }
        if (ch == "\\" && quote != "'") {
            if (!length(row)) plain_command = false;
            escaped = true; started = true; continue;
        }
        if (quote != "") {
            if (ch == quote) quote = "";
            else token += ch;
            continue;
        }
        if (ch == "'" || ch == '"') {
            if (!length(row)) plain_command = false;
            quote = ch; started = true; continue;
        }
        if (ch == "#") { comment = true; continue; }
        if (match(ch, /[ \t\r\n;]/)) {
            if (started) { push(row, token); token = ""; started = false; }
            if (ch == "\n" || ch == ";") {
                if (length(row)) push(rows, plain_command ? row : null);
                row = []; plain_command = true;
            }
        }
        else { token += ch; started = true; }
    }
    if (quote != "" || escaped) return "raw:" + text;
    if (started) push(row, token);
    if (length(row)) push(rows, plain_command ? row : null);

    let sections = [], current = null;
    for (let words in rows) {
        if (words == null) return "raw:" + text;
        let aliases = { c: "config", o: "option", l: "list" };
        words[0] = aliases[words[0]] || words[0];
        if (words[0] == "config" && length(words) >= 2 && length(words) <= 3) {
            current = { type: words[1], name: words[2] || null, options: {} };
            push(sections, current);
        }
        else if (current && length(words) >= 2 && length(words) <= 3 && (words[0] == "option" || words[0] == "list")) {
            let key = words[1], value = words[2] || "";
            if (current.type == "settings" && current.name == "settings" && key == "shutdown_correctly")
                continue;
            if (words[0] == "option") {
                if (value == "") delete current.options[key];
                else current.options[key] = value;
            }
            else {
                let values = current.options[key];
                if (type(values) != "array") values = values == null ? [] : [ values ];
                push(values, value);
                current.options[key] = values;
            }
        }
        else return "raw:" + text;
    }
    // Section and list order affect routing. Only option-key order is cosmetic.
    return sprintf("%J", map(sections, (section) => [section.type, section.name,
        map(sort(keys(section.options)), (key) => [key, section.options[key]])]));
}
return { normalized };
