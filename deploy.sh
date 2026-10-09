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
cleanup() {
    set +e
    if (( boot_was_ro )); then sync; mount -o remount,ro /boot; fi
    if (( root_was_ro )); then sync; mount -o remount,ro /; fi
}
trap cleanup EXIT

if findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then rw; root_was_ro=1; fi
# The boot partition may be separate and read-only even when / is writable.
if mountpoint -q /boot && findmnt -no OPTIONS /boot | tr ',' '\n' | grep -qx ro; then
    mount -o remount,rw /boot
    boot_was_ro=1
fi

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
# Remove only an active GPIO13 activity-LED assignment. Preserve its text as a comment.
if grep -Eq '^[[:space:]]*dtparam=act_led_gpio=13[[:space:]]*$' /boot/config.txt; then
    sed -i -E 's/^([[:space:]]*)dtparam=act_led_gpio=13[[:space:]]*$/\1# disabled by pikvm-x735: dtparam=act_led_gpio=13/' /boot/config.txt
    boot_changed=1
fi
if ! grep -Eq '^[[:space:]]*dtoverlay=pwm,pin=13,func=4[[:space:]]*$' /boot/config.txt; then
    # [all] prevents preceding conditional model sections from hiding the overlay.
    printf '\n# Geekworm X735 v3 PWM fan on GPIO13\n[all]\ndtoverlay=pwm,pin=13,func=4\n' >> /boot/config.txt
    boot_changed=1
fi

install -Dm0755 scripts/x735-fan.sh /usr/local/bin/x735-fan.sh
install -Dm0755 scripts/x735-pwr.sh /usr/local/bin/x735-pwr.sh
install -Dm0755 scripts/x735off /usr/local/bin/x735off
install -Dm0644 systemd/x735-fan.service /etc/systemd/system/x735-fan.service
install -Dm0644 systemd/x735-pwr.service /etc/systemd/system/x735-pwr.service
install -Dm0644 pikvm/x735.yaml /etc/kvmd/override.d/x735.yaml

if ! kvmd -m >/dev/null; then
    echo "KVMD configuration validation failed; files backed up at $backup" >&2
    exit 1
fi
systemctl daemon-reload
# A PiKVM update may re-enable its default fan controller: it must not
# compete with X735 PWM1 on GPIO13.
if systemctl list-unit-files --no-legend kvmd-fan.service 2>/dev/null | grep -q '^kvmd-fan.service'; then
    systemctl disable --now kvmd-fan.service
fi
systemctl enable x735-fan.service x735-pwr.service

if (( boot_changed )); then
    echo "Updated /boot/config.txt; REBOOT REQUIRED to activate GPIO13 PWM."
    echo "Services enabled; not restarting hardware controllers before reboot."
else
    systemctl restart x735-fan.service x735-pwr.service
    systemctl is-active x735-fan.service x735-pwr.service
fi
echo "X735 deployed. Backup: $backup"
echo 'KVMD not restarted; restart it only if the USB-breaker override must be reloaded.'
