#!/bin/bash
set -Eeuo pipefail

CHIP=/dev/gpiochip0
BUTTON=5
BOOT=12
ACTION=${X735_ACTION:-log}

log() {
    echo "X735: $*"
}

read_button() {
    gpioget --numeric -c "$CHIP" "$BUTTON"
}

# Keep the boot/handshake output asserted.
gpioset -c "$CHIP" "$BOOT=1" &
gpio_pid=$!

cleanup() {
    kill "$gpio_pid" 2>/dev/null || true
    wait "$gpio_pid" 2>/dev/null || true
}
trap cleanup EXIT

sleep 0.2

if ! kill -0 "$gpio_pid" 2>/dev/null; then
    log "ERROR: Cannot claim GPIO $BOOT"
    exit 1
fi

log "Started: GPIO $BUTTON input, GPIO $BOOT output"
log "Action mode: $ACTION"

# Avoid treating a high signal at startup as a button press.
while [ "$(read_button)" = "1" ]; do
    sleep 0.1
done

while true; do
    signal=$(read_button)

    if [ "$signal" = "1" ]; then
        start=$(date +%s%3N)

        while [ "$(read_button)" = "1" ]; do
            elapsed=$(( $(date +%s%3N) - start ))

            if [ "$elapsed" -gt 600 ]; then
                log "Shutdown signal (${elapsed}ms)"

                if [ "$ACTION" = "live" ]; then
                    systemctl poweroff
                    exit 0
                fi

                # Wait until the pulse finishes.
                while [ "$(read_button)" = "1" ]; do
                    sleep 0.05
                done

                log "Monitor mode: shutdown not executed"
                break
            fi

            sleep 0.02
        done

        elapsed=$(( $(date +%s%3N) - start ))

        if [ "$elapsed" -gt 200 ] &&
           [ "$elapsed" -le 600 ]; then

            log "Reboot signal (${elapsed}ms)"

            if [ "$ACTION" = "live" ]; then
                systemctl reboot
                exit 0
            fi

            log "Monitor mode: reboot not executed"
        fi
    fi

    sleep 0.1
done
