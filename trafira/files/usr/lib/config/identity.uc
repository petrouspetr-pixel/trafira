// Compare UCI data without treating its writer's whitespace/quoting as an edit.
// This never executes UCI text. Unknown or malformed syntax keeps exact identity.
function normalized(text) {
    text = text || "";
    let rows = [], row = [], token = "", started = false, quote = "", escaped = false, comment = false;
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
        if (ch == "\\" && quote != "'") { escaped = true; started = true; continue; }
        if (quote != "") {
            if (ch == quote) quote = "";
            else token += ch;
            continue;
        }
        if (ch == "'" || ch == '"') { quote = ch; started = true; continue; }
        if (ch == "#") { comment = true; continue; }
        if (match(ch, /[ \t\r\n;]/)) {
            if (started) { push(row, token); token = ""; started = false; }
            if (ch == "\n" || ch == ";") { if (length(row)) push(rows, row); row = []; }
        }
        else { token += ch; started = true; }
    }
    if (quote != "" || escaped) return "raw:" + text;
    if (started) push(row, token);
    if (length(row)) push(rows, row);

    let sections = [], current = null;
    for (let words in rows) {
        if (words[0] == "config" && length(words) >= 2 && length(words) <= 3) {
            current = { type: words[1], name: words[2], options: {} };
            push(sections, current);
        }
        else if (current && length(words) == 3 && (words[0] == "option" || words[0] == "list")) {
            let key = words[1];
            if (current.type == "settings" && current.name == "settings" && key == "shutdown_correctly")
                continue;
            if (words[0] == "option") current.options[key] = words[2];
            else {
                let values = current.options[key];
                if (type(values) != "array") values = values == null ? [] : [ values ];
                push(values, words[2]);
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
