#!/usr/bin/env bash
# Safe, repeatable installer for the tested PiKVM X735 scripts.
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
for src in scripts/x735-fan.sh scripts/x735-pwr.sh scripts/x735off systemd/x735-fan.service systemd/x735-pwr.service pikvm/x735.yaml; do
    [[ -s "$src" ]] || { echo "Missing/empty: $src (run capture-live.sh on working Pi first)" >&2; exit 1; }
done
command -v gpioset >/dev/null || { echo 'libgpiod tools missing; install with pacman -S libgpiod' >&2; exit 1; }
bash -n scripts/x735-fan.sh scripts/x735-pwr.sh scripts/x735off
if grep -q '^dtparam=act_led_gpio=13' /boot/config.txt || ! grep -qx 'dtoverlay=pwm,pin=13,func=4' /boot/config.txt; then
    echo 'Check /boot/config.txt: GPIO13 must be free and single-channel PWM overlay configured.' >&2
    exit 1
fi
was_ro=0
if findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then rw; was_ro=1; fi
cleanup() { if (( was_ro )); then sync; ro; fi; }
trap cleanup EXIT
stamp=$(date +%Y%m%d-%H%M%S)
backup="/root/x735-deploy-backups/$stamp"
mkdir -p "$backup"
for file in /usr/local/bin/x735-fan.sh /usr/local/bin/x735-pwr.sh /usr/local/bin/x735off /etc/systemd/system/x735-fan.service /etc/systemd/system/x735-pwr.service /etc/kvmd/override.d/x735.yaml; do
  if [[ -e $file ]]; then mkdir -p "$backup$(dirname "$file")"; cp -a "$file" "$backup$file"; fi
done
install -Dm0755 scripts/x735-fan.sh /usr/local/bin/x735-fan.sh
install -Dm0755 scripts/x735-pwr.sh /usr/local/bin/x735-pwr.sh
install -Dm0755 scripts/x735off /usr/local/bin/x735off
install -Dm0644 systemd/x735-fan.service /etc/systemd/system/x735-fan.service
install -Dm0644 systemd/x735-pwr.service /etc/systemd/system/x735-pwr.service
install -Dm0644 pikvm/x735.yaml /etc/kvmd/override.d/x735.yaml
# Validate merged configuration before touching running KVMD.
if ! kvmd -m >/dev/null; then echo 'KVMD configuration validation failed: restore backup and inspect overrides' >&2; exit 1; fi
systemctl daemon-reload
systemctl enable x735-fan x735-pwr
systemctl restart x735-fan x735-pwr
# Do not restart kvmd automatically; doing so interrupts video and UART controls.
echo "X735 files deployed. Backups: $backup"
echo 'If GPIO5 remains claimed by kvmd, restart kvmd deliberately after verifying override priority.'
systemctl is-active x735-fan x735-pwr
