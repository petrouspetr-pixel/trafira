#!/usr/bin/env ucode
// Deliberately reads only combined runtime metadata. Never import cache.uc here:
// that command module also provides network and cache mutation operations.
let fs = require("fs");
let selection = require("singbox.selection");
let urltest = require("singbox.urltest");
let common = require("core.common");
let obj = common.object_or_empty;
let arr = common.array_or_empty;
const CACHE_DIR = getenv("TRAFIRA_SECTION_CACHE_DIR") ||
    (getenv("TRAFIRA_RUNTIME_STATE_DIR") || "/var/run/trafira") + "/section-cache";

function failure(status, reason) {
    return { status, reason, counts: { total: 0, included: 0, excluded: 0 }, nodes: [], warnings: [] };
}

function valid_side(side) {
    if (side == null)
        return true;
    if (type(side) != "object")
        return false;
    for (let key, value in side) {
        if (key == "proxy_parameters") {
            if (type(value) != "boolean")
                return false;
            continue;
        }
        if (!selection.array_contains([ "outbounds", "regex", "countries", "protocols", "transports", "securities" ], key) ||
            type(value) != "array" || length(value) > 128)
            return false;
        for (let item in value)
            if (type(item) != "string" || length(item) > 256)
                return false;
    }
    return true;
}

function selected(mode, tags, metadata, countries, include, exclude) {
    return selection.filter_candidate_outbounds(mode, tags, obj(metadata.names), countries, metadata,
        include.outbounds, include.regex, include.countries,
        include.proxy_parameters, include.protocols, include.transports, include.securities,
        exclude.outbounds, exclude.regex, exclude.countries,
        exclude.proxy_parameters, exclude.protocols, exclude.transports, exclude.securities);
}

function preview(raw) {
    if (type(raw) != "string" || length(raw) > 32768)
        return failure("invalid", "request_too_large");
    let request;
    try { request = json(raw); }
    catch (e) { return failure("invalid", "invalid_json"); }
    if (type(request) != "object" || type(request.section) != "string" ||
        length(request.section) > 128 || !match(request.section, /^[A-Za-z0-9_]+$/))
        return failure("invalid", "invalid_section");
    for (let key in request)
        if (!selection.array_contains([ "section", "filter_mode", "detect_server_country", "include", "exclude" ], key))
            return failure("invalid", "unknown_option");
    let mode = request.filter_mode == null ? "disabled" : request.filter_mode;
    if (!selection.array_contains([ "disabled", "include", "exclude", "mixed" ], mode) ||
        !valid_side(request.include) || !valid_side(request.exclude) ||
        (request.detect_server_country != null &&
         !selection.array_contains([ "flag_emoji", "country_is" ], request.detect_server_country)))
        return failure("invalid", "invalid_filter");
    let path = CACHE_DIR + "/" + request.section + ".json";
    let info = fs.stat(path);
    if (info == null)
        return failure("unavailable", "cache_missing");
    if (info.size > 4194304)
        return failure("unavailable", "cache_too_large");
    let cache;
    try { cache = json(fs.readfile(path)); }
    catch (e) { return failure("unavailable", "cache_invalid"); }
    if (type(cache) != "object")
        return failure("unavailable", "cache_invalid");
    let candidates = cache.filterPreviewCandidates;
    if (type(candidates) != "object")
        return failure("unavailable", "preview_cache_missing");
    if (type(candidates.tags) != "array" || type(candidates.metadata) != "object" ||
        length(candidates.tags) > 5000)
        return failure("unavailable", "cache_invalid");
    for (let tag in candidates.tags)
        if (type(tag) != "string" || length(tag) > 512)
            return failure("unavailable", "cache_invalid");
    let tags = selection.unique_string_array(candidates.tags);
    let metadata = candidates.metadata;
    for (let field in [ "names", "countries", "protocols", "transports", "securities" ]) {
        if (type(metadata[field]) != "object")
            return failure("unavailable", "cache_invalid");
        for (let tag in tags)
            if (metadata[field][tag] != null && type(metadata[field][tag]) != "string")
                return failure("unavailable", "cache_invalid");
    }
    let countries = request.detect_server_country == "flag_emoji"
        ? urltest.countries_from_flag_names(obj(metadata.names)) : obj(metadata.countries);
    let include = obj(request.include), exclude = obj(request.exclude);
    let needs_countries = ((mode == "include" || mode == "mixed") && length(arr(include.countries)) > 0) ||
        ((mode == "exclude" || mode == "mixed") && length(arr(exclude.countries)) > 0);
    if (request.detect_server_country == "country_is" && needs_countries)
        for (let tag in tags)
            if (type(countries[tag]) != "string" || length(countries[tag]) != 2)
                return failure("unavailable", "cached_country_data_incomplete");
    let included = selected(mode, tags, metadata, countries, include, exclude);
    let include_matches = selected("include", tags, metadata, countries, include, {});
    let exclude_survivors = selected("exclude", tags, metadata, countries, {}, exclude);
    let warnings = [ "cached_candidates_only" ];
    for (let side in [ include, exclude ])
        for (let pattern in arr(side.regex)) {
            try { regexp(pattern); }
            catch (e) {
                if (!selection.array_contains(warnings, "invalid_regex_ignored"))
                    push(warnings, "invalid_regex_ignored");
            }
        }
    let nodes = [];
    for (let tag in tags) {
        let keep = selection.array_contains(included, tag);
        let reason = "included";
        if (mode == "disabled") reason = "filters_disabled";
        else if (!keep && (mode == "include" || mode == "mixed") &&
                 !selection.array_contains(include_matches, tag)) reason = "include_not_matched";
        else if (!keep && !selection.array_contains(exclude_survivors, tag)) reason = "exclude_matched";
        push(nodes, { name: substr(common.as_string(obj(metadata.names)[tag] || tag), 0, 512),
            status: keep ? "included" : "excluded", reason });
    }
    return { status: "ok", counts: { total: length(tags), included: length(included),
        excluded: length(tags) - length(included) }, nodes, warnings };
}

print(sprintf("%J", ARGV[0] == "preview" ? preview(ARGV[1]) : failure("invalid", "invalid_command")), "\n");
