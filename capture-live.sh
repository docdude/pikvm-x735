#!/usr/bin/env bash
# Run on the WORKING PiKVM as root, from the repository directory.
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
for spec in \
  '/usr/local/bin/x735-fan.sh scripts/x735-fan.sh' \
  '/usr/local/bin/x735-pwr.sh scripts/x735-pwr.sh' \
  '/usr/local/bin/x735off scripts/x735off' \
  '/etc/systemd/system/x735-fan.service systemd/x735-fan.service' \
  '/etc/systemd/system/x735-pwr.service systemd/x735-pwr.service'; do
  read -r source target <<< "$spec"
  [[ -f "$source" ]] || { echo "Missing $source" >&2; exit 1; }
  cp "$source" "$target"
done
# A dedicated GPIO override, avoiding capture of unrelated HKS401 settings.
cat > pikvm/x735.yaml <<'YAML'
kvmd:
    gpio:
        drivers:
            unused_breaker:
                type: cmd
                cmd: [/usr/bin/true]
        scheme:
            __v3_usb_breaker__:
                driver: unused_breaker
                pin: 0
                mode: output
                initial: false
                switch: true
YAML
chmod +x scripts/*.sh scripts/x735off
bash -n scripts/x735-pwr.sh scripts/x735-fan.sh scripts/x735off
echo 'Captured live scripts and units. Review git diff before committing.'
