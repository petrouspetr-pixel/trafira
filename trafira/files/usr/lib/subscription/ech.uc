#!/usr/bin/env ucode

// Keep this helper usable by the standalone subscription parser without -L.
let ip = loadfile(replace(sourcepath(), /\/[^\/]+$/, "/../core/ip.uc"))();

function text(value) {
    return value == null ? "" : "" + value;
}

function domain(value) {
    value = lc(text(value));
    if (substr(value, length(value) - 1) == ".")
        value = substr(value, 0, length(value) - 1);
    if (value == "" || length(value) > 253)
        return "";
    for (let label in split(value, "."))
        if (length(label) > 63 || !match(label, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/))
            return "";
    return value;
}

function decode(value) {
    // URI '+' is significant in both base64 and domain+DoH ECH values.
    // Decode percent escapes once, preserving literal plus signs.
    if (match(replace(value, /%[0-9A-Fa-f]{2}/g, ""), /%/))
        return null;
    return replace(value, /%([0-9A-Fa-f]{2})/g, function(all, digits) {
        return chr(hex(digits));
    });
}

function query(link) {
    link = text(link);
    let question = index(link, "?"), fragment = index(link, "#");
    if (question < 0 || (fragment >= 0 && fragment < question))
        return { present: false, link };
    let end = fragment >= 0 ? fragment : length(link);
    let retained = [], result = { present: false, link };
    for (let pair in split(substr(link, question + 1, end - question - 1), "&")) {
        let equals = index(pair, "=");
        let key = decode(equals >= 0 ? substr(pair, 0, equals) : pair);
        if (key != "ech") {
            push(retained, pair);
            continue;
        }
        if (result.present)
            result.error = "ECH parameter must occur only once";
        result.present = true;
        result.value = decode(equals >= 0 ? substr(pair, equals + 1) : "");
        if (result.value == null)
            result.error = "ECH parameter contains invalid percent escapes";
    }
    result.link = substr(link, 0, question) +
        (length(retained) > 0 ? "?" + join("&", retained) : "") + substr(link, end);
    return result;
}

function doh_url(value) {
    value = text(value);
    if (length(value) > 4096 || index(value, "?") >= 0 || index(value, "#") >= 0)
        return null;
    for (let i = 0; i < length(value); i++)
        if (ord(substr(value, i, 1)) <= 32 || ord(substr(value, i, 1)) == 127)
            return null;
    // sing-box's HTTPS transport applies URL.setPath, not URL.Parse: a query
    // string cannot be represented by its path field and must not be dropped.
    let parsed = match(value, /^https:\/\/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(:([0-9]+))?(\/[^?#]*)?$/);
    if (!parsed)
        return null;
    let host = parsed[1], port = parsed[3] ? int(parsed[3], 10) : 443;
    if (port < 1 || port > 65535)
        return null;
    if (substr(host, 0, 1) == "[") {
        host = substr(host, 1, length(host) - 2);
        if (!ip.valid_ipv6(host))
            return null;
    }
    else if (match(host, /^[0-9.]+$/) ? !ip.valid_ipv4(host, false, true) : domain(host) == "") {
        return null;
    }
    let path = parsed[4] || "/dns-query";
    if (decode(path) == null || index(path, "\\") >= 0)
        return null;
    return { url: value, server: host, server_port: port, path, is_ip: ip.valid_ip(host) };
}

function uint16(value, offset) {
    return ord(substr(value, offset, 1)) * 256 + ord(substr(value, offset + 1, 1));
}

function valid_config_list(raw) {
    let size = length(raw);
    if (size < 6 || size > 65537 || uint16(raw, 0) != size - 2)
        return false;
    let offset = 2;
    while (offset < size) {
        if (offset + 4 > size)
            return false;
        let version = uint16(raw, offset), bytes = uint16(raw, offset + 2);
        offset += 4;
        let end = offset + bytes;
        if (bytes == 0 || end > size)
            return false;
        if (version == 0xfe0d) {
            // RFC 9849: config_id, kem_id, public_key, cipher_suites,
            // maximum_name_length, public_name, extensions.
            if (offset + 5 > end)
                return false;
            let key_size = uint16(raw, offset + 3);
            offset += 5;
            if (key_size == 0 || offset + key_size + 2 > end)
                return false;
            offset += key_size;
            let suites = uint16(raw, offset);
            offset += 2;
            if (suites == 0 || suites % 4 != 0 || offset + suites + 2 > end)
                return false;
            offset += suites + 1;
            let name_size = ord(substr(raw, offset, 1));
            offset++;
            if (name_size == 0 || offset + name_size + 2 > end ||
                domain(substr(raw, offset, name_size)) == "")
                return false;
            offset += name_size;
            let extensions = uint16(raw, offset);
            offset += 2;
            if (offset + extensions != end)
                return false;
            while (offset < end) {
                if (offset + 4 > end)
                    return false;
                let extension_size = uint16(raw, offset + 2);
                offset += 4 + extension_size;
                if (offset > end)
                    return false;
            }
        }
        offset = end;
    }
    return offset == size;
}

function inline_config(value) {
    let payload = value;
    if (substr(value, 0, 10) == "-----BEGIN") {
        let pem = match(value, /^-----BEGIN ECH CONFIGS-----[\r\n]+([A-Za-z0-9+/=\r\n]+)-----END ECH CONFIGS-----[\r\n]*$/);
        if (!pem)
            return null;
        payload = replace(pem[1], /[\r\n]/g, "");
    }
    if (length(payload) > 87384 || !match(payload, /^[A-Za-z0-9+\/_-]+={0,2}$/))
        return null;
    payload = replace(replace(payload, /-/g, "+"), /_/g, "/");
    let unpadded = replace(payload, /=+$/, "");
    if (length(unpadded) % 4 == 1 ||
        (index(payload, "=") >= 0 && length(payload) % 4 != 0))
        return null;
    while (length(payload) % 4 != 0)
        payload += "=";
    let raw;
    try { raw = b64dec(payload); }
    catch (e) { return null; }
    if (raw == null || replace(b64enc(raw), /=+$/, "") != unpadded || !valid_config_list(raw))
        return null;
    return ["-----BEGIN ECH CONFIGS-----", b64enc(raw), "-----END ECH CONFIGS-----"];
}

function parse(value) {
    if (type(value) != "string" || value == "" || length(value) > 100000)
        return { error: "ECH value is empty, invalid or too large" };
    if (index(value, "://") >= 0) {
        let plus = index(value, "+");
        let name = plus > 0 ? domain(substr(value, 0, plus)) : "";
        let doh = plus > 0 ? doh_url(substr(value, plus + 1)) : null;
        if (name == "" || doh == null)
            return { error: "ECH requires domain+https://host[:port]/path without credentials, query or fragment" };
        return { ech: { enabled: true, query_server_name: name }, doh: doh.url };
    }
    // Try the binary format before domain names: unpadded base64 may consist
    // entirely of letters and digits.
    let config = inline_config(value);
    if (config != null)
        return { ech: { enabled: true, config } };
    let name = domain(value);
    if (name != "" && index(name, ".") >= 0)
        return { ech: { enabled: true, query_server_name: name } };
    return { error: "ECH value must contain a valid ECHConfigList, ECH CONFIGS PEM or query domain" };
}

function apply(outbound, value) {
    let parsed = parse(value);
    if (parsed.error)
        return parsed.error;
    let tls = type(outbound.tls) == "object" ? outbound.tls : {};
    if (tls.enabled !== true)
        return "ECH requires TLS to be enabled";
    if (type(tls.reality) == "object" && tls.reality.enabled !== false)
        return "ECH cannot be combined with REALITY";
    tls.ech = parsed.ech;
    if (parsed.doh)
        outbound.__trafira_ech_doh = parsed.doh;
    return "";
}

function value(outbound) {
    let tls = type(outbound.tls) == "object" ? outbound.tls : {};
    let ech = type(tls.ech) == "object" ? tls.ech : {};
    if (tls.enabled === false || ech.enabled !== true)
        return "";
    if (type(ech.config) == "array" && length(ech.config) > 0) {
        let config = inline_config(join("\n", ech.config));
        return config == null ? "" : config[1];
    }
    if (text(ech.config_path) != "")
        return "";
    let name = domain(ech.query_server_name || tls.server_name || outbound.server);
    if (name == "")
        return "";
    let doh = text(outbound.__trafira_ech_doh);
    return doh == "" ? name : (doh_url(doh) == null ? "" : name + "+" + doh);
}

return { query, parse, apply, value, domain, doh_url };
