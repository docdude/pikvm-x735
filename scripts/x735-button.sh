#!/bin/bash
# X735 power-button handler: classifies GPIO5 pulses from libgpiod 2.x edge
# events. Does not touch the GPIO12 handshake.
set -Eeuo pipefail

CHIP=${X735_CHIP:-gpiochip0}
BUTTON=${X735_BUTTON:-5}
ACTION=${X735_ACTION:-log}
DEBOUNCE=${X735_DEBOUNCE:-10ms}
REBOOT_MIN_MS=200
SHUTDOWN_MS=600

log() {
    echo "X735: $*"
}

# gpiomon %S prints seconds with a nanosecond fraction.
to_ns() {
    local s=${1%.*} f=${1#*.}000000000
    echo $(( 10#$s * 1000000000 + 10#${f:0:9} ))
}

act() {
    log "$1"
    if [[ $ACTION == live ]]; then
        systemctl "$2"
        exit 0
    fi
    log "Monitor mode: $2 not executed"
}

exec 3< <(exec gpiomon -c "$CHIP" -C x735-button -e both -p "$DEBOUNCE" -F '%e %S' "$BUTTON")
mon_pid=$!
trap 'kill "$mon_pid" 2>/dev/null || true' EXIT

log "Started: $CHIP line $BUTTON edge events, debounce $DEBOUNCE, action mode: $ACTION"

rise=0
held=0
deadline_us=0
while :; do
    rc=0
    if (( rise && !held )); then
        left=$(( deadline_us - ${EPOCHREALTIME/./} ))
        (( left > 0 )) || left=1
        printf -v tmo '%d.%06d' $(( left / 1000000 )) $(( left % 1000000 ))
        read -r -t "$tmo" edge ts <&3 || rc=$?
    else
        read -r edge ts <&3 || rc=$?
    fi

    if (( rc > 128 )); then
        # Still high after SHUTDOWN_MS: act without waiting for the falling edge.
        held=1
        act "pulse held >${SHUTDOWN_MS}ms: poweroff" poweroff
        continue
    elif (( rc )); then
        log "ERROR: gpiomon exited"
        exit 1
    fi

    case $edge in
        1)
            rise=$(to_ns "$ts")
            deadline_us=$(( ${EPOCHREALTIME/./} + SHUTDOWN_MS * 1000 ))
            held=0
            ;;
        2)
            # A falling edge without a seen rise (line high at start) is ignored.
            (( rise )) || continue
            ms=$(( ($(to_ns "$ts") - rise) / 1000000 ))
            rise=0
            if (( held )); then
                log "pulse ended after ${ms}ms"
            elif (( ms > SHUTDOWN_MS )); then
                act "pulse ${ms}ms: poweroff" poweroff
            elif (( ms > REBOOT_MIN_MS )); then
                act "pulse ${ms}ms: reboot" reboot
            else
                log "pulse ${ms}ms: ignored"
            fi
            held=0
            ;;
    esac
done
