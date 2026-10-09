#!/usr/bin/env bash
# Deploy tested X735 scripts and required boot configuration on PiKVM OS.
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }

for src in scripts/x735-fan.sh scripts/x735-pwr.sh scripts/x735off systemd/x735-fan.service systemd/x735-pwr.service pikvm/x735.yaml; do
    [[ -s "$src" ]] || { echo "Missing/empty: $src (capture the working Pi first)" >&2; exit 1; }
done
command -v gpioset >/dev/null || { echo 'Missing libgpiod tools' >&2; exit 1; }
bash -n scripts/x735-fan.sh scripts/x735-pwr.sh scripts/x735off
[[ -f /boot/config.txt ]] || { echo 'Missing /boot/config.txt' >&2; exit 1; }

# Refuse potentially conflicting PWM overlays rather than guessing a repair.
if grep -Eq '^[[:space:]]*dtoverlay=pwm(-2chan)?(,|$)' /boot/config.txt &&
   ! grep -Eq '^[[:space:]]*dtoverlay=pwm,pin=13,func=4[[:space:]]*$' /boot/config.txt; then
    echo 'A different PWM overlay exists. Review /boot/config.txt manually.' >&2
    exit 1
fi

root_was_ro=0
boot_was_ro=0
boot_made_rw=0

is_ro() {
    [[ ",$(findmnt -no OPTIONS "$1")," == *,ro,* ]]
}

# Capture both states before writing anything: PiKVM's `rw` helper remounts
# / and /boot together, which previously hid /boot's read-only state.
is_ro / && root_was_ro=1
mountpoint -q /boot && is_ro /boot && boot_was_ro=1

cleanup() {
    local rc=$?
    set +e
    sync
    if (( boot_made_rw )) && ! mount -o remount,ro /boot; then
        echo 'WARNING: could not restore /boot read-only' >&2
        (( rc )) || rc=3
    fi
    if (( root_was_ro )) && ! mount -o remount,ro /; then
        echo 'WARNING: could not restore / read-only (a deleted file is still open); it returns to ro on reboot' >&2
        (( rc )) || rc=3
    fi
    exit "$rc"
}
trap cleanup EXIT

if (( root_was_ro )); then mount -o remount,rw /; fi

stamp=$(date +%Y%m%d-%H%M%S)
backup="/root/x735-deploy-backups/$stamp"
mkdir -p "$backup"
for file in /usr/local/bin/x735-fan.sh /usr/local/bin/x735-pwr.sh /usr/local/bin/x735off /etc/systemd/system/x735-fan.service /etc/systemd/system/x735-pwr.service /etc/kvmd/override.d/x735.yaml /boot/config.txt; do
    if [[ -e "$file" ]]; then
        mkdir -p "$backup$(dirname "$file")"
        cp -a "$file" "$backup$file"
    fi
done

boot_changed=0
led_on_13=0
pwm_missing=0
grep -Eq '^[[:space:]]*dtparam=act_led_gpio=13[[:space:]]*$' /boot/config.txt && led_on_13=1
grep -Eq '^[[:space:]]*dtoverlay=pwm,pin=13,func=4[[:space:]]*$' /boot/config.txt || pwm_missing=1

# /boot is only made writable when it actually needs editing.
if (( led_on_13 || pwm_missing )) && (( boot_was_ro )); then
    mount -o remount,rw /boot
    boot_made_rw=1
fi

# Remove only an active GPIO13 activity-LED assignment. Preserve its text as a comment.
if (( led_on_13 )); then
    sed -i -E 's/^([[:space:]]*)dtparam=act_led_gpio=13[[:space:]]*$/\1# disabled by pikvm-x735: dtparam=act_led_gpio=13/' /boot/config.txt
    boot_changed=1
fi
if (( pwm_missing )); then
    # [all] prevents preceding conditional model sections from hiding the overlay.
    printf '\n# Geekworm X735 v3 PWM fan on GPIO13\n[all]\ndtoverlay=pwm,pin=13,func=4\n' >> /boot/config.txt
    boot_changed=1
fi

# Decide restarts from content, before the installed copies are overwritten.
fan_changed=0
pwr_changed=0
cmp -s scripts/x735-fan.sh /usr/local/bin/x735-fan.sh || fan_changed=1
cmp -s systemd/x735-fan.service /etc/systemd/system/x735-fan.service || fan_changed=1
cmp -s scripts/x735-pwr.sh /usr/local/bin/x735-pwr.sh || pwr_changed=1
cmp -s systemd/x735-pwr.service /etc/systemd/system/x735-pwr.service || pwr_changed=1

# Replacing an unchanged script that a daemon is executing leaves the old inode
# open, which blocks remounting / read-only. Only touch files that differ.
install_if_changed() {
    cmp -s "$2" "$3" || install -Dm"$1" "$2" "$3"
}
install_if_changed 0755 scripts/x735-fan.sh /usr/local/bin/x735-fan.sh
install_if_changed 0755 scripts/x735-pwr.sh /usr/local/bin/x735-pwr.sh
install_if_changed 0755 scripts/x735off /usr/local/bin/x735off
install_if_changed 0644 systemd/x735-fan.service /etc/systemd/system/x735-fan.service
install_if_changed 0644 systemd/x735-pwr.service /etc/systemd/system/x735-pwr.service
install_if_changed 0644 pikvm/x735.yaml /etc/kvmd/override.d/x735.yaml

if ! kvmd -m >/dev/null; then
    echo "KVMD configuration validation failed; files backed up at $backup" >&2
    exit 1
fi
systemctl daemon-reload
# kvmd-fan defaults to --pwm-pin 12, which is the X735 BOOT handshake line.
# Mask it so a PiKVM update or a manual enable cannot start it.
fan_units=$(systemctl list-unit-files --no-legend kvmd-fan.service 2>/dev/null || true)
if [[ "$fan_units" == kvmd-fan.service* ]]; then
    systemctl disable --now kvmd-fan.service 2>/dev/null || true
    systemctl mask kvmd-fan.service
fi
if grep -Eqs 'pwm[-_]pin' /etc/kvmd/fan.ini /etc/conf.d/kvmd-fan; then
    echo 'NOTE: custom kvmd-fan pin configured; kvmd-fan is masked regardless.'
fi
systemctl enable x735-fan.service x735-pwr.service

apply_service() {
    local unit=$1 changed=$2
    if ! systemctl is-active --quiet "$unit"; then
        echo "Starting $unit (was not running)."
        systemctl start "$unit"
    elif (( changed )); then
        echo "Restarting $unit (installed files changed)."
        systemctl restart "$unit"
    else
        echo "$unit unchanged and running; not restarted."
    fi
}

if (( boot_changed )); then
    echo "Updated /boot/config.txt; REBOOT REQUIRED to activate GPIO13 PWM."
    echo "Services enabled; not restarting hardware controllers before reboot."
else
    apply_service x735-fan.service "$fan_changed"
    if (( pwr_changed )) && systemctl is-active --quiet x735-pwr.service; then
        echo 'WARNING: x735-pwr changed; restart briefly releases the GPIO12 handshake.'
    fi
    apply_service x735-pwr.service "$pwr_changed"
fi

# Report-only checks: failures never trigger a restart of the power daemon.
problems=0
fail() { echo "CHECK FAIL: $*" >&2; problems=$((problems + 1)); }
ok() { echo "check ok:   $*"; }

line5=$(gpioinfo -c gpiochip0 5 2>&1 || true)
if [[ "$line5" == *'consumer="kvmd'* ]]; then
    fail 'GPIO5 is claimed by KVMD (USB breaker override not effective in running kvmd)'
else
    ok 'GPIO5 not claimed by KVMD'
fi

pin12=$(pinctrl get 12 2>&1 || true)
line12=$(gpioinfo -c gpiochip0 12 2>&1 || true)
if [[ "$pin12" =~ ^\ *12:\ op.*\|\ hi ]] && [[ "$line12" == *'consumer="gpioset"'* ]]; then
    ok 'GPIO12 output HIGH, held by gpioset'
else
    fail "GPIO12 handshake not asserted: $pin12"
fi

pin13=$(pinctrl get 13 2>&1 || true)
if (( boot_changed )); then
    echo 'check skip: PWM (reboot pending)'
elif [[ "$(readlink -f /sys/class/pwm/pwmchip0/device)" != */fe20c000.pwm ]]; then
    fail 'pwmchip0 is not the BCM2711 PWM (fe20c000.pwm)'
elif [[ "$(cat /sys/class/pwm/pwmchip0/pwm1/enable 2>/dev/null)" != 1 || "$pin13" != *PWM0_1* ]]; then
    fail "PWM not active on GPIO13: $pin13"
else
    ok 'PWM0_1 enabled on GPIO13 (pwmchip0/pwm1)'
fi

fan_units=$(systemctl list-unit-files --no-legend kvmd-fan.service 2>/dev/null || true)
if [[ "$fan_units" != kvmd-fan.service* ]]; then
    ok 'kvmd-fan not installed'
elif [[ "$(systemctl is-enabled kvmd-fan.service 2>/dev/null)" == masked ]] &&
     ! systemctl is-active --quiet kvmd-fan.service; then
    ok 'kvmd-fan masked and inactive'
else
    fail 'kvmd-fan is not masked/inactive'
fi

echo "X735 deployed. Backup: $backup"
echo 'KVMD not restarted; restart it only if the USB-breaker override must be reloaded.'
if (( problems )); then
    echo "$problems check(s) failed; services were left as they are." >&2
    exit 2
fi
