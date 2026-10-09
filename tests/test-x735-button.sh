#!/bin/bash
# Exercise scripts/x735-button.sh against a gpio-mockup chip with exact pulse
# widths. Never touches real GPIO lines and always runs in log mode.
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")/.."
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }

if lsmod | grep -q '^gpio_mockup'; then
    echo 'gpio-mockup already loaded; refusing to reuse it' >&2
    exit 1
fi
modprobe gpio-mockup gpio_mockup_ranges=-1,1
chip=$(gpiodetect | awk '/\[gpio-mockup-A\]/ {print $1; exit}')
[[ -n $chip && $chip != gpiochip0 ]] || { echo "bad mock chip: '$chip'" >&2; rmmod gpio-mockup; exit 1; }
line=/sys/kernel/debug/gpio-mockup/$chip/0
log=$(mktemp)
pid=

cleanup() {
    set +e
    [[ -n $pid ]] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    rmmod gpio-mockup
    rm -f "$log"
}
trap cleanup EXIT

set_line() { echo "$1" > "$line"; }
pulse() { set_line 1; sleep "$1"; set_line 0; sleep 0.8; }
cpu_ticks() {
    local p sum=0
    for p in "$pid" $(pgrep -P "$pid" gpiomon); do
        sum=$(( sum + $(awk '{print $14 + $15}' "/proc/$p/stat") ))
    done
    echo "$sum"
}

# Line high before the handler starts: its first falling edge must be ignored.
set_line 1
X735_CHIP=$chip X735_BUTTON=0 X735_ACTION=log ./scripts/x735-button.sh > "$log" 2>&1 &
pid=$!
for _ in $(seq 50); do grep -q Started "$log" && break; sleep 0.1; done
grep -q Started "$log" || { cat "$log"; echo 'handler did not start' >&2; exit 1; }
start_cpu=$(cpu_ticks)
set_line 0; sleep 0.8

pulse 0.10    # ignored
pulse 0.30    # reboot
pulse 0.50    # reboot
pulse 0.75    # poweroff, triggered at 600 ms while still held
pulse 1.50    # poweroff, triggered at 600 ms while still held
# Bounce: a 1-3 ms dip inside a 400 ms press must stay one reboot pulse.
set_line 1; sleep 0.15; set_line 0; sleep 0.002; set_line 1; sleep 0.25; set_line 0; sleep 0.8
sleep 5       # idle, for the CPU sample
end_cpu=$(cpu_ticks)

echo '--- handler log'
cat "$log"
echo '--- results'

mapfile -t got < <(grep -oE 'pulse [0-9]+ms: (ignored|reboot|poweroff)|pulse held >600ms: poweroff' "$log")
expect=(ignored reboot reboot held held reboot)
fails=0
for i in "${!expect[@]}"; do
    g=${got[$i]:-<missing>}
    case ${expect[$i]} in
        held) [[ $g == 'pulse held >600ms: poweroff' ]] ;;
        *)    [[ $g == *": ${expect[$i]}" ]] ;;
    esac && r=PASS || { r=FAIL; fails=$((fails + 1)); }
    printf '%-4s expected %-8s got %s\n' "$r" "${expect[$i]}" "$g"
done
(( ${#got[@]} == ${#expect[@]} )) || { echo "FAIL: ${#got[@]} classified pulses, expected ${#expect[@]}"; fails=$((fails + 1)); }
grep -q 'not executed' "$log" || { echo 'FAIL: no monitor-mode suppression logged'; fails=$((fails + 1)); }
echo "handler CPU over test (bash + gpiomon): $(( end_cpu - start_cpu )) ticks at $(getconf CLK_TCK)/s"
(( fails == 0 )) && echo 'ALL PASS' || { echo "$fails failure(s)"; exit 1; }
