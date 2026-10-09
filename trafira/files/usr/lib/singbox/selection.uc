#!/usr/bin/env ucode
// Shared by runtime generation and the read-only cached preview.
let common = require("core.common");
let runtime_urltest = require("singbox.urltest");
let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
function supported_urltest_filter_mode(mode) {
    return mode == "include" || mode == "exclude" || mode == "mixed";
}
function array_contains(values, needle) {
    for (let value in array_or_empty(values)) {
        if (value == needle)
            return true;
    }
    return false;
}

function unique_string_array(values) {
    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = as_string(value);
        if (value == "" || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function object_keys_set(values) {
    let result = {};
    for (let value in array_or_empty(values))
        result[value] = true;
    return result;
}

function tag_display_name(tag, names) {
    let name = as_string(object_or_empty(names)[tag] || "");
    return name != "" ? name : tag;
}

function regex_match_set(tags, names, regexes) {
    return object_keys_set(runtime_urltest.regex_matching_tag_array(tags, names, regexes));
}

function tag_name_filter_matches(tag, names, name_filter, regex_set) {
    let name = tag_display_name(tag, names);
    return array_contains(name_filter, name) || regex_set[tag];
}

function tag_country_filter_matches(tag, countries, country_filter) {
    let country = uc(as_string(object_or_empty(countries)[tag] || ""));
    return country != "" && array_contains(country_filter, country);
}

function tag_attribute_filter_matches(tag, metadata, selected_values) {
    selected_values = array_or_empty(selected_values);
    if (length(selected_values) == 0)
        return true;

    let value = lc(as_string(object_or_empty(metadata)[tag] || ""));
    if (value == "")
        return false;
    for (let selected in selected_values)
        if (lc(as_string(selected)) == value)
            return true;
    return false;
}

function proxy_parameter_filter_matches_all(tag, metadata, protocols, transports, securities) {
    metadata = object_or_empty(metadata);
    return tag_attribute_filter_matches(tag, metadata.protocols, protocols) &&
        tag_attribute_filter_matches(tag, metadata.transports, transports) &&
        tag_attribute_filter_matches(tag, metadata.securities, securities);
}

function proxy_parameter_filter_matches_any(tag, metadata, protocols, transports, securities) {
    metadata = object_or_empty(metadata);
    return (length(array_or_empty(protocols)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.protocols, protocols)) ||
        (length(array_or_empty(transports)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.transports, transports)) ||
        (length(array_or_empty(securities)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.securities, securities));
}

function name_or_country_filter_configured(name_filter, regexes, country_filter) {
    return length(array_or_empty(name_filter)) > 0 ||
        length(array_or_empty(regexes)) > 0 ||
        length(array_or_empty(country_filter)) > 0;
}

function urltest_all_candidate_outbounds(urltest_candidate_tags) {
    return unique_string_array(urltest_candidate_tags);
}

function urltest_matching_candidate_outbounds(urltest_candidate_tags, names, countries, name_filter, regexes, country_filter,
    metadata, proxy_parameters_enabled, proxy_parameters_operator, protocols, transports, securities, additional_matches) {
    names = object_or_empty(names);
    countries = object_or_empty(countries);
    country_filter = runtime_urltest.normalized_country_list(country_filter);

    let regex_set = regex_match_set(urltest_candidate_tags, names, regexes);
    let base_filter_configured = name_or_country_filter_configured(name_filter, regexes, country_filter);
    let additional_set = object_keys_set(additional_matches);
    let result = [];

    for (let tag in array_or_empty(urltest_candidate_tags)) {
        let base_matches = tag_name_filter_matches(tag, names, name_filter, regex_set) ||
            tag_country_filter_matches(tag, countries, country_filter);
        let matches = additional_set[tag] || base_matches;
        if (proxy_parameters_enabled && proxy_parameters_operator == "or") {
            matches = additional_set[tag] || base_matches || proxy_parameter_filter_matches_any(
                tag, metadata, protocols, transports, securities
            );
        }
        else if (proxy_parameters_enabled) {
            if (!base_filter_configured)
                base_matches = true;
            matches = additional_set[tag] ||
                (base_matches && proxy_parameter_filter_matches_all(
                    tag, metadata, protocols, transports, securities
                ));
        }

        if (matches)
            push(result, tag);
    }

    return unique_string_array(result);
}

function urltest_exclude_outbounds(all_outbounds, excluded_outbounds) {
    let excluded = object_keys_set(excluded_outbounds);
    let result = [];
    for (let tag in array_or_empty(all_outbounds)) {
        if (!excluded[tag])
            push(result, tag);
    }
    return result;
}

function filter_candidate_outbounds(filter_mode, urltest_candidate_tags, names, countries, metadata,
    include_names, include_regex, include_countries,
    include_proxy_parameters, include_protocols, include_transports, include_securities,
    exclude_names, exclude_regex, exclude_countries,
    exclude_proxy_parameters, exclude_protocols, exclude_transports, exclude_securities,
    include_additional_matches, exclude_additional_matches) {
    let all_outbounds = urltest_all_candidate_outbounds(urltest_candidate_tags);
    if (filter_mode == "" || filter_mode == "disabled")
        return all_outbounds;
    if (!supported_urltest_filter_mode(filter_mode))
        return all_outbounds;

    let include_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        include_names,
        include_regex,
        include_countries,
        metadata,
        include_proxy_parameters,
        "and",
        include_protocols,
        include_transports,
        include_securities,
        include_additional_matches
    );
    let exclude_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        exclude_names,
        exclude_regex,
        exclude_countries,
        metadata,
        exclude_proxy_parameters,
        "or",
        exclude_protocols,
        exclude_transports,
        exclude_securities,
        exclude_additional_matches
    );

    if (filter_mode == "include")
        return include_outbounds;
    if (filter_mode == "exclude")
        return urltest_exclude_outbounds(all_outbounds, exclude_outbounds);
    if (filter_mode == "mixed")
        return urltest_exclude_outbounds(include_outbounds, exclude_outbounds);
    return all_outbounds;
}

return { filter_candidate_outbounds, unique_string_array, array_contains };
