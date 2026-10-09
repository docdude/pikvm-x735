# PiKVM X735 v3.0 deployment

For a Raspberry Pi 4B using PiKVM OS, a Geekworm X735 v3.0, CSI TC358743 video/audio, USB SSD, and separate HKS401 UART integration.

This repository contains the scripts captured from the tested working PiKVM, rather than reconstructed examples. Use `./capture-live.sh` only when intentionally refreshing these sources from a known-good running system.

## Bootstrap on the working PiKVM

1. Unpack or clone this project onto PiKVM; run `./capture-live.sh` as root.
2. Inspect `git diff` / `git status` and confirm the captured files, particularly live-mode settings and shutdown behavior.

## Deploy after an update

```bash
rw
cd /root/pikvm-x735
git pull --ff-only
./deploy.sh
# installer restores read-only mode only if it was read-only on entry
ro
```

The installer backs up the deployed files **and `/boot/config.txt`**, installs the GPIO13 PWM overlay if missing, comments out an active `dtparam=act_led_gpio=13`, installs the scripts and units, validates the merged KVMD configuration, disables `kvmd-fan` if present, and enables the X735 services. If it modified boot configuration, **reboot** before expecting PWM fan operation: the installer intentionally skips restarting the X735 services in this case. If no boot change was necessary, it restarts them. It does **not** automatically restart KVMD, because doing so interrupts capture and UART controls. The script refuses conflicting PWM overlays and requires manual resolution.

## Required boot configuration

Your tested working configuration uses:

```ini
dtoverlay=pwm,pin=13,func=4
```

Do not assign `act_led_gpio=13`; GPIO 18 belongs to I2S audio. On first deploy, inspect the backup of `/boot/config.txt` and reboot if the installer reports changes. The installer does not automatically remove unrelated device-tree overlays. `tc358743-audio` owns GPIO 20 during ordinary operation; `x735off` temporarily unbinds and rebinds `bcm2835-i2s` to issue the software shutdown signal.

## GPIO allocation

- BCM5: X735 button event input; must not be claimed by PiKVM V3 USB breaker.
- BCM12: X735 handshake output held by persistent `gpioset`.
- BCM13: X735 PWM fan (`pwmchip0/pwm1`).
- BCM20: X735 software-off, shared with TC358743 PCM_DIN; only hand off during intentional shutdown.

## Validate

```bash
systemctl is-active kvmd x735-fan x735-pwr
systemctl show x735-pwr -p Environment
pinctrl get 12 20
vcgencmd get_throttled
findmnt -no OPTIONS /
```

`x735off` **turns the power off**. Never use it for a deployment smoke test. Physical power-off and software power-off were verified in the original setup; confirm behavior again after any meaningful upstream changes.
