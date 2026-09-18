# pc2drc-ng

Stream a Linux desktop to a **Wii U GamePad**. This is a from-scratch installer/runtime around the archived [thefloppydriver/pc2drc](https://github.com/thefloppydriver/pc2drc) stack, because that project is archived and the Ubuntu 20.04 “just run these five scripts” path does not actually work.

You still need a Wii U **once** (to steal the PSK), a GamePad, and a **5 GHz USB Wi-Fi stick whose driver exports TSF** (RT5572 / `rt2800usb` is the known-good one).

## Why the original installer dies

These are the bugs people hit on 20.04. **Paste your log if you hit a new one.**

1. **`User directory is not /home/root`** — scripts treated `sudo` as if `$HOME` were still `/home/$USER`.
2. **VNC `Connection refused (111)`** — `stage-4` starts TigerVNC as the hardcoded user `thefloppydriver`, launches `gnome-session`, then immediately connects. The server is never listening.
3. **`stage-1-kernel-patch` hunk failures** — it `apt-get source`s the running kernel and force-patches `mac80211`. That patch does not apply to HWE kernels, and 20.04 kernel source fetch is a mess now that 20.04 is EOL.
4. **OpenSSL 1.0.1u** — the URL is dead and modern GCC will not build it.
5. **`drcvncclient` link failure** — missing `-lpthread -ldl`, then the script prints “All modules built successfully” anyway.

## What this rewrite changes

- **One installer.** `sudo ./install.sh`
- **No kernel rebuild** for TSF. libdrc is patched to read mac80211 **debugfs** (`/sys/kernel/debug/ieee80211/phyX/tsf`) as well as the old `/sys/class/net/*/tsf` sysfs file.
- **OpenSSL 1.0.2u + libnl 1.1.4 in `./prefix` only.** System OpenSSL 3 is left alone. The Wii U `drc-hostap` fork still needs the old crypto.
- **Real user detection** via `SUDO_USER`. Folder does not have to be named `pc2drc`.
- **VNC is 854x480 + openbox**, and we wait until `127.0.0.1:5901` is up before starting `drcvncclient`.
- **NetworkManager is only told to ignore the USB stick.** Your Ethernet / other Wi-Fi stays up.
- **Logs** go to `logs/`. State goes to `state/config.json`.

## Host OS

| Distro | Status |
|---|---|
| Ubuntu 22.04 / 24.04 | intended |
| Debian 12 / 13 | intended |
| Ubuntu 20.04 | supported as a build host, but 20.04 archives are dying; if `apt-get update` fails, use 22.04 |
| Windows / WSL | no. USB 5 GHz AP + TSF needs native Linux |

This repo can live on a Windows machine; **run the scripts on the Linux box**.

## Install

On the **Linux** PC (not Windows, not WSL):

```bash
sudo apt-get install -y git
git clone https://github.com/rpv182/pc2drc-ng.git
cd pc2drc-ng
sudo bash ./install.sh
```

That one script is stages 0–2 (packages, OpenSSL/libnl prefix, hostapd, libdrc, drcvncclient).

Then pair + host VNC from one UI:

```bash
sudo bash ./ui.sh
```

Open `http://127.0.0.1:8540` — Pair GamePad, then Start stream. Stop with the Stop button or `sudo bash ./stop.sh`.

`pair.sh` / `start.sh` still work if you want the terminal instead.

### Pairing cheatsheet

Wii U suit code: **spade=0 heart=1 diamond=2 club=3**, then append `5678`.

Keep the GamePad off while pairing the PC to the Wii U. After pairing, power the Wii U off so the GamePad talks to the PC AP instead.

## Hardware

See [docs/HARDWARE.md](docs/HARDWARE.md). Short version: **not Intel Wi-Fi**. Buy an RT5572 USB adapter.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

If install/pair/start still explodes, send:

- `logs/` (the timestamped files)
- `uname -r` and `cat /etc/os-release`
- `lsusb` and `sudo ./lib/tsf.sh`

Those are more useful than a screenshot of the last line.

## Still inherited from upstream

These are not magically fixed:

- x264 artifacting on the GamePad
- occasional disconnects
- GamePad → `/dev/uinput` is incomplete
- no audio
- a Wii U is still required for the first pair
