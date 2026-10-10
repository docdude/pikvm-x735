#!/bin/bash
# Hold the X735 BOOT handshake (GPIO12) high; exec keeps gpioset as the
# service's main process.
set -Eeuo pipefail
chip=$(/usr/local/bin/x735-chip gpio)
exec gpioset -c "$chip" -C x735-boot 12=1
