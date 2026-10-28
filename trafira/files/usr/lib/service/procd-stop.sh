#!/bin/sh
# rc.common loads procd after sourcing init scripts. Install this wrapper from
# stop_service, when procd's functions already exist, without changing OpenWrt.
TRAFIRA_PROCD_STOP_STATUS=0

procd_kill() {
    local result message previous_namespace
    json_set_namespace procd previous_namespace
    json_init
    [ -z "$1" ] || json_add_string name "$1"
    [ -z "$2" ] || json_add_string instance "$2"
    message="$(ubus call service delete "$(json_dump)" 2>&1)"
    result=$?
    json_cleanup
    json_set_namespace "$previous_namespace"

    # UBUS_STATUS_NOT_FOUND is benign only while the service API is reachable.
    # Do not hide a missing/disconnected procd daemon or permission errors.
    if [ "$result" = 4 ] && ubus call service list '{}' >/dev/null 2>&1; then
        result=0
        message=
    fi
    [ -z "$message" ] || printf '%s\n' "$message" >&2
    TRAFIRA_PROCD_STOP_STATUS="$result"
    return "$result"
}

trafira_procd_stop_status() {
    [ "${1:-0}" = 0 ] || return "$1"
    return "${TRAFIRA_PROCD_STOP_STATUS:-0}"
}
