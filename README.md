# PiKVM X735 v3.0 deployment

For a Raspberry Pi 4B using PiKVM OS, a Geekworm X735 v3.0, CSI TC358743 video/audio, USB SSD, and separate HKS401 UART integration.

This repository contains the scripts captured from the tested working PiKVM, rather than reconstructed examples. Use `./capture-live.sh` only when intentionally refreshing these sources from a known-good running system.

## Bootstrap on the working PiKVM

1. Unpack or clone this project onto PiKVM; run `./capture-live.sh` as root.
2. Inspect `git diff` / `git status` and confirm the captured files, particularly live-mode settings and shutdown behavior.

## Deploy after an update

```bash
cd /home/pikvm-x735
git pull --ff-only   # needs / writable: run `rw` first, `ro` after
./deploy.sh
```

`deploy.sh` records the read-only state of `/` and `/boot` independently before writing, makes `/boot` writable only if `config.txt` must change, and restores each mount to its original state on exit.

The installer backs up the deployed files **and `/boot/config.txt`**, installs the GPIO13 PWM overlay if missing, comments out an active `dtparam=act_led_gpio=13`, installs only the scripts and units whose content differs from the installed copy (replacing a script a running daemon is executing would leave a deleted inode open and block remounting `/` read-only), validates the merged KVMD configuration, **masks** `kvmd-fan` if present, and enables the X735 services. If it modified boot configuration, **reboot** before expecting PWM fan operation: the installer intentionally skips restarting the X735 services in this case. Otherwise each X735 service is restarted **only if its installed script or unit actually changed** (compared with `cmp`), or started if it was not running. An unchanged, running `x735-pwr` is never restarted, so a no-change deploy does not touch the GPIO12 handshake. It does **not** automatically restart KVMD, because doing so interrupts capture and UART controls. The script refuses conflicting PWM overlays and requires manual resolution.

After deploying, report-only checks verify: GPIO5 not claimed by KVMD, GPIO12 output HIGH and held by `gpioset` or `x735-boot`, PWM0_1 active on GPIO13 via `pwmchip0` = `fe20c000.pwm` (skipped when a reboot is pending), and `kvmd-fan` masked and inactive. Failures exit with status 2 but never restart the power daemon. If a mount cannot be restored to read-only, the script warns and exits with status 3.

## Power daemon: legacy `x735-pwr` or split `x735-boot` + `x735-button`

| `X735_POWER_DAEMON` | Units | GPIO12 (BOOT) | GPIO5 (button) |
| --- | --- | --- | --- |
| `pwr` (default) | `x735-pwr` | `gpioset` inside `x735-pwr.sh` | polled with `gpioget` |
| `split` | `x735-boot`, `x735-button` | `x735-boot.sh` (`gpioset -C x735-boot`, held until the final shutdown stage) | `gpiomon` edge events in `x735-button.sh` |

In split mode the button handler can be changed and restarted without releasing GPIO12. Both designs claim GPIO5 and GPIO12, so they must never run together: `deploy.sh` only *enables* the selected design while the other is running and reports `REBOOT to switch over`; it never stops the running daemon. Switch with `X735_POWER_DAEMON=split ./deploy.sh` then reboot; roll back with `X735_POWER_DAEMON=pwr ./deploy.sh` then reboot. Run every later deploy with the same `X735_POWER_DAEMON` value. `x735-button.service` ships with `X735_ACTION=live`; set it to `log` in the unit to observe presses without acting on them.

### Testing the button handler

`tests/test-x735-button.sh` loads `gpio-mockup` and drives exact pulses through a simulated chip in log mode, never touching real GPIO: 100/300/500/750/1500 ms, a bounced 400 ms press, a line already high at start, and a replay of the observed unanswered shutdown request (GPIO5 high ~48 s after a 632 ms detection; default 5 s, `X735_TEST_HOLD=48` for the full replay). Each held pulse must act exactly once.

On real hardware in log mode, test **only short (reboot-length) presses**. An unanswered long press is not a safe test: GPIO5 cleared after ~48 s in earlier testing, but whether the X735 cuts power at that point is not established. Perform the first real long press with `X735_ACTION=live`, so Linux shuts down cleanly.

Hardware result in log mode (split daemon): a reboot-length press measured 490 ms, was classified as reboot and not executed; GPIO12 stayed high throughout (sampled every 50 ms).

Hardware results in live mode (split daemon), timed against a 0.2 s ping and the journal:

| Test | Result |
| --- | --- |
| Reboot-length press | 489 ms, reboot started 10 ms later; came back with both units active |
| ~3 s press | poweroff 600 ms into the press; GPIO12 released 0.18 s later; last ping 10.7 s after poweroff began; X735 cut power ~2-3 s after that (observed dark 10-11 s after release) |
| `x735off` | X735 shutdown pulse began ~1.35 s after GPIO20 went high; poweroff 600 ms later; last ping 10.8 s after poweroff began |

After each power-off, `/` and `PIPST`/`PIMSD` were `clean` and `/boot` had no dirty bit. The X735 did not cut power when GPIO12 dropped early in shutdown; whether it waits for the Pi to halt or applies a fixed delay is not established. `x735-boot` therefore uses `DefaultDependencies=no` (no `Conflicts=shutdown.target`): systemd no longer stops it during shutdown, so `gpioset` is only killed in the final stage and GPIO12 stays high until just before power-off or reboot. `deploy.sh` never restarts a running `x735-boot`; a changed `x735-boot` applies at the next reboot. "orphan cleanup on readonly fs" on `PIPST`/`PIMSD` appears on every boot, including after clean shutdowns, and is not a power-loss indicator.

## Required boot configuration

Your tested working configuration uses:

```ini
dtoverlay=pwm,pin=13,func=4
```

Do not assign `act_led_gpio=13`; GPIO 18 belongs to I2S audio. On first deploy, inspect the backup of `/boot/config.txt` and reboot if the installer reports changes. The installer does not automatically remove unrelated device-tree overlays. `tc358743-audio` owns GPIO 20 during ordinary operation; `x735off` temporarily unbinds and rebinds `bcm2835-i2s` to issue the software shutdown signal.

## GPIO allocation

Chips are resolved by `x735-chip` from verified identifiers rather than probe-order numbers: the GPIO controller labelled `pinctrl-bcm2711` whose lines 5, 12 and 20 are named `GPIO5`/`GPIO12`/`GPIO20`, and the PWM chip whose device is `fe20c000.pwm`. It fails unless exactly one chip matches; `x735-boot`, `x735-button`, `x735-fan.sh` (one line changed from upstream) and `x735off` refuse to run rather than guess. The legacy `x735-pwr.sh` is unchanged and still uses `/dev/gpiochip0`.

- BCM5: X735 button event input; must not be claimed by PiKVM V3 USB breaker. Held continuously by `gpiomon` in split mode, so no other process may request it.
- BCM12: X735 handshake output held by persistent `gpioset` (`x735-pwr` or `x735-boot`). Also the default PWM pin of PiKVM's `kvmd-fan` (`--pwm-pin 12`), which is why `kvmd-fan` is masked. Restarting `x735-pwr` briefly releases this line; `deploy.sh` never restarts a running `x735-boot`.
- BCM13: X735 PWM fan (channel 1 of the `fe20c000.pwm` chip).
- BCM20: X735 software-off; also TC358743 PCM_DIN, claimed by the `bcm2835-i2s` driver. The TC358743 audio header is currently **not wired** to the Pi, so nothing else drives this line; `x735off` only needs to release the driver's pinmux claim. If the audio header is connected, the TC358743's data output and the X735 input share GPIO20 and the electrical interaction must be established before using `x735off`.

## Validate

```bash
systemctl is-active kvmd x735-fan x735-pwr          # legacy
systemctl is-active kvmd x735-fan x735-boot x735-button   # split
systemctl show x735-pwr x735-button -p Environment
pinctrl get 12 20
vcgencmd get_throttled
findmnt -no OPTIONS /
```

`x735off` **turns the power off**. Never use it for a deployment smoke test. It refuses to run unless the active power daemon (`x735-button` or `x735-pwr`) is in `X735_ACTION=live`, or if GPIO20's pinmux cannot be read. Physical power-off and software power-off were verified in the original setup; confirm behavior again after any meaningful upstream changes.
