#!/usr/bin/env ucode

let fs = require("fs");
let uci = require("core.uci");

const CONFIG_NAME = getenv("TRAFIRA_CONFIG_NAME") || "trafira";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42";
const DNSMASQ_INIT = getenv("DNSMASQ_INIT") || "/etc/init.d/dnsmasq";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function run(command) {
    return system(command) == 0;
}

function uci_available() {
    return uci.available();
}

function uci_get(path) {
    return uci.get(path);
}

function uci_exists(path) {
    return uci.exists(path);
}

function uci_delete(path) {
    if (uci_exists(path) && !uci.delete(path))
        die("DNS UCI delete failed\n");
}

function uci_set(path, value) {
    if (!uci.set(path, value))
        die("DNS UCI set failed\n");
}

function uci_add_list(path, value) {
    if (!uci.add_list(path, value))
        die("DNS UCI add_list failed\n");
}


function uci_commit(package_name) {
    if (!uci.commit(package_name))
        die("DNS UCI commit failed\n");
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function list_has(values, needle) {
    for (let value in words(values))
        if (value == needle)
            return true;
    return false;
}

function uci_del_list(path, value) {
    if (!list_has(uci_get(path), value))
        return true;
    if (!uci.del_list(path, value))
        die("DNS UCI del_list failed\n");
    return true;
}

function log(message, level) {
    level = as_string(level || "info");
    run("logger -t " + shell_quote("trafira") + " " + shell_quote("[" + level + "] " + as_string(message)));
}

function restart_dnsmasq() {
    return run("[ -x " + shell_quote(DNSMASQ_INIT) + " ] && " + shell_quote(DNSMASQ_INIT) + " restart");
}

function dnsmasq_legacy_instance_exists() {
    return uci_exists("dhcp.trafira");
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_trafira_dns() {
    return list_has(dnsmasq_default_servers(), SB_DNS_INBOUND_ADDRESS);
}

function dnsmasq_has_trafira_dns() {
    return dnsmasq_default_has_trafira_dns() || dnsmasq_legacy_instance_exists();
}

function dnsmasq_has_trafira_managed_state() {
    return uci_exists("dhcp.@dnsmasq[0].trafira_snapshot_server") ||
        uci_exists("dhcp.@dnsmasq[0].trafira_snapshot_noresolv") ||
        uci_exists("dhcp.@dnsmasq[0].trafira_snapshot_cachesize") ||
        uci_get("dhcp.@dnsmasq[0].trafira_server") != "" ||
        uci_get("dhcp.@dnsmasq[0].trafira_noresolv") != "" ||
        uci_get("dhcp.@dnsmasq[0].trafira_cachesize") != "" ||
        uci_get("dhcp.@dnsmasq[0].trafira_notinterface") != "" ||
        dnsmasq_legacy_instance_exists();
}

function dnsmasq_management_disabled() {
    return truthy(uci_get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function dnsmasq_default_config_is_complete() {
    return dnsmasq_default_has_trafira_dns() &&
        uci_get("dhcp.@dnsmasq[0].noresolv") == "1" &&
        uci_get("dhcp.@dnsmasq[0].cachesize") == "0" &&
        !dnsmasq_legacy_instance_exists();
}

function dnsmasq_legacy_interfaces() {
    let legacy_dnsmasq_section = "trafira";
    let legacy_interfaces = uci_get("dhcp." + legacy_dnsmasq_section + ".interface");
    if (legacy_interfaces == "")
        legacy_interfaces = uci_get(CONFIG_NAME + ".settings.source_network_interfaces");
    if (legacy_interfaces == "")
        legacy_interfaces = "br-lan";

    return legacy_interfaces;
}

// Snapshot presence separately: an absent option must not become a default
// value on rollback. Existing legacy backups remain authoritative.
function snapshot_dnsmasq_option(key, applied) {
    let path = "dhcp.@dnsmasq[0].";
    let marker = path + "trafira_snapshot_" + key;
    if (uci_exists(marker))
        return;
    let backup = path + "trafira_" + key;
    let present = uci_exists(backup);
    let value = uci_get(backup);
    if (!present) {
        present = uci_exists(path + key);
        value = uci_get(path + key);
        if (key == "server") {
            let servers = [];
            for (let server in words(value))
                if (server != SB_DNS_INBOUND_ADDRESS)
                    push(servers, server);
            value = join(" ", servers);
            present = value != "";
        }
        else if (dnsmasq_default_has_trafira_dns()) {
            // Old installs had no absence marker; retain their known fallback.
            value = key == "noresolv" ? "0" : "150";
            present = true;
        }
        if (present)
            uci_set(backup, value);
    }
    uci_set(path + "trafira_applied_" + key, applied);
    uci_set(marker, present ? "present" : "absent");
}

function replace_dnsmasq_servers(values) {
    uci_delete("dhcp.@dnsmasq[0].server");
    for (let value in words(values))
        uci_add_list("dhcp.@dnsmasq[0].server", value);
}

function clear_dnsmasq_snapshots() {
    for (let key in [ "server", "noresolv", "cachesize", "notinterface" ]) {
        uci_delete("dhcp.@dnsmasq[0].trafira_" + key);
        uci_delete("dhcp.@dnsmasq[0].trafira_snapshot_" + key);
        uci_delete("dhcp.@dnsmasq[0].trafira_applied_" + key);
    }
}

function dnsmasq_cleanup_legacy_instance() {
    let present = dnsmasq_legacy_instance_exists();
    if (!present)
        return;
    let path = "dhcp.@dnsmasq[0].";
    let interfaces = dnsmasq_legacy_interfaces();
    let current = uci_get(path + "notinterface");
    let backup = uci_get(path + "trafira_notinterface");
    let expected = true;
    for (let value in words(current))
        if (!list_has(interfaces, value) && !list_has(backup, value))
            expected = false;
    for (let value in words(interfaces))
        if (!list_has(current, value))
            expected = false;
    if (expected && backup != "") {
        uci_delete(path + "notinterface");
        for (let value in words(backup))
            uci_add_list(path + "notinterface", value);
    }
    else {
        for (let value in words(interfaces))
            if (!list_has(backup, value))
                uci_del_list(path + "notinterface", value);
    }
    uci_delete("dhcp.trafira");
}

function dnsmasq_configure_default_instance() {
    snapshot_dnsmasq_option("server", SB_DNS_INBOUND_ADDRESS);
    snapshot_dnsmasq_option("noresolv", "1");
    snapshot_dnsmasq_option("cachesize", "0");
    // The backup must survive an interrupted configure before forwarding changes.
    uci_commit("dhcp");
    replace_dnsmasq_servers(SB_DNS_INBOUND_ADDRESS);
    uci_set("dhcp.@dnsmasq[0].noresolv", "1");
    uci_set("dhcp.@dnsmasq[0].cachesize", "0");
}

function dnsmasq_restore_default_instance() {
    let path = "dhcp.@dnsmasq[0].";
    let servers = dnsmasq_default_servers();
    let applied = uci_get(path + "trafira_applied_server") || SB_DNS_INBOUND_ADDRESS;
    let managed = list_has(servers, applied);
    let snapshot = uci_get(path + "trafira_snapshot_server");
    let backup = uci_get(path + "trafira_server");
    if (trim(servers) == applied) {
        replace_dnsmasq_servers(snapshot == "absent" ? "" : backup);
    }
    else if (managed) {
        // External additions/replacements own the current list. Remove only
        // our address; do not reinstate a stale upstream server backup.
        uci_del_list(path + "server", applied);
    }

    for (let item in [ [ "noresolv", "1", "0" ], [ "cachesize", "0", "150" ] ]) {
        let key = item[0];
        let current = uci_get(path + key);
        let expected = uci_get(path + "trafira_applied_" + key) || item[1];
        let marker = uci_get(path + "trafira_snapshot_" + key);
        let has_backup = uci_exists(path + "trafira_" + key);
        // Missing legacy options are restored for compatibility; new snapshots
        // distinguish an external deletion from the value we applied.
        if (current != expected && !(marker == "" && current == "" && has_backup))
            continue;
        if (marker == "absent")
            uci_delete(path + key);
        else if (has_backup)
            uci_set(path + key, uci_get(path + "trafira_" + key));
        else if (managed && marker == "")
            uci_set(path + key, item[2]);
    }
}

function dnsmasq_configure(force) {
    try {
        if (!uci_available())
            return true;

        if (as_string(force) != "force" && uci_get(CONFIG_NAME + ".settings.shutdown_correctly") == "0") {
            if (dnsmasq_default_config_is_complete()) {
                log("Previous Trafira shutdown was unclean; dnsmasq already points to sing-box", "info");
                return true;
            }
            log("Previous Trafira shutdown was unclean and dnsmasq is not ready; applying Trafira DNS settings", "info");
        }

        log("Configuring dnsmasq to forward DNS to sing-box", "info");
        dnsmasq_cleanup_legacy_instance();
        dnsmasq_configure_default_instance();
        uci_commit("dhcp");

        return restart_dnsmasq();
    }
    catch (e) {
        log(as_string(e), "err");
        return false;
    }
}

function dnsmasq_restore(force, quiet) {
    try {
        if (!uci_available())
            return true;

        if (!quiet)
            log("Restoring DNS settings in dnsmasq", "info");
        if (as_string(force) != "force" && uci_get(CONFIG_NAME + ".settings.shutdown_correctly") == "1") {
            if (!dnsmasq_has_trafira_dns() && !dnsmasq_has_trafira_managed_state()) {
                log("dnsmasq already uses non-Trafira DNS settings; restore is not required", "info");
                return true;
            }
            log("Trafira DNS settings are still present after a clean shutdown; restoring DNS settings in dnsmasq", "info");
        }

        dnsmasq_cleanup_legacy_instance();
        dnsmasq_restore_default_instance();
        uci_commit("dhcp");
        if (!restart_dnsmasq())
            return false;
        // Retain rollback information when applying or restarting failed.
        clear_dnsmasq_snapshots();
        uci_commit("dhcp");
        return true;
    }
    catch (e) {
        log(as_string(e), "err");
        return false;
    }
}

function failsafe_restore() {
    if (!uci_available())
        return true;

    if (dnsmasq_management_disabled()) {
        if (!dnsmasq_has_trafira_managed_state()) {
            log("DNS rollback skipped: dont_touch_dhcp is enabled and no Trafira dnsmasq changes were found", "info");
            return true;
        }

        log("Rolling back previous Trafira dnsmasq changes because dont_touch_dhcp is enabled", "warn");
    }
    else {
        log("Rolling back Trafira DNS changes in dnsmasq", "warn");
    }

    return dnsmasq_restore("force", true);
}

let mode = ARGV[0] || "";

if (mode == "configure")
    exit(dnsmasq_configure(ARGV[1]) ? 0 : 1);
else if (mode == "restore")
    exit(dnsmasq_restore(ARGV[1]) ? 0 : 1);
else if (mode == "failsafe-restore")
    exit(failsafe_restore() ? 0 : 1);
else if (mode == "has-trafira-dns")
    exit(dnsmasq_has_trafira_dns() ? 0 : 1);
else if (mode == "has-managed-state")
    exit(dnsmasq_has_trafira_managed_state() ? 0 : 1);
else if (mode == "default-config-complete")
    exit(dnsmasq_default_config_is_complete() ? 0 : 1);

warn("Usage: dns/apply.uc <configure|restore|failsafe-restore|has-trafira-dns|has-managed-state|default-config-complete>\n");
exit(1);
