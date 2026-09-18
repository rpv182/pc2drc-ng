# Troubleshooting

Logs land in `logs/`. Pairing and start keep timestamped files. Always attach those if you want help.

## Original pc2drc errors this rewrite is meant to kill

| What you saw | Why | What we do instead |
|---|---|---|
| `User directory is not /home/root` | Scripts used `$HOME` after `sudo` and `USERNAME` | `SUDO_USER` + `getent passwd` |
| `CConn: unable connect to socket: Connection refused (111)` | VNC started as user `thefloppydriver`, gnome-session exploded, client connected immediately | VNC as the real user, openbox, wait until `:5901` listens |
| `vncserver is not defined` | `print(vncserver.before)` after a failed spawn | That variable is gone |
| `Kernel patch not working` / `Hunk FAILED` | DKMS patch against whatever `apt-get source` dumped | **No kernel rebuild.** TSF comes from mac80211 debugfs |
| `drcvncclient` link errors | Missing `-lpthread -ldl` | Injected at build time |
| `openssl-1.0.1u` / ftp.openssl.org | Dead URL, GCC 11+ refuses the tree | OpenSSL **1.0.2u** built into `./prefix` only |
| Stage scripts require folder name `pc2drc` | Hardcoded | Folder can be `pc2drc-ng` |

**Could not connect to wpa_supplicant**

That is `wpa_cli` failing to attach after `wpa_supplicant` started. Typical causes:

- Intel onboard Wi-Fi (`wlo1` / `iwlwifi`) was selected. Plug in the **RT5572 USB** stick and pick `wlx… (rt2800usb)`.
- A leftover control socket in `/var/run/wpa_supplicant_drc`.
- NetworkManager still owning the stick.

`pair.sh` now refuses Intel, recreates the control socket, and calls `wpa_cli -i <iface>`. Re-run:

```bash
cd ~/pc2drc-ng
git pull
sudo bash ./pair.sh
```

## Pairing

**Wii U not found in scan**

- Red SYNC on the **console faceplate**, not the GamePad
- USB adapter must be the one in 5 GHz range
- NetworkManager must not own that iface (`nmcli device set $IFACE managed no`)

**WPS timeout**

- Suits: spade=0 heart=1 diamond=2 club=3, then append `5678`
- Keep the GamePad off / far away while pairing the PC to the Wii U so the pad does not steal the session

**hostapd: Beacon set failed / invalid argument**

- That is the modified Wii U cipher vs a too-new hostapd. We still build the old `drc-hostap` against prefix OpenSSL 1.0.2. If this happens, paste `logs/hostapd-*.log`

## Start / video

**GamePad connects then says it cannot find the Wii U**

- Normal until netboot + drcvncclient are running. Leave `./start.sh` up, power the pad on again

**Black screen**

- TSF is missing or stuck at `0xfff…`. Run `sudo ./lib/tsf.sh wlanX` after hostapd is up
- Intel Wi-Fi will always black-screen
- `192.168.1.0/24` already in use on another interface — disconnect that LAN

**VNC 111 again**

- `sudo ./stop.sh` then `sudo ./start.sh`
- Read `~/.vnc/*.log` for the real user (not `/root/.vnc`)
- Confirm `ss -lnt | grep 5901`

**Random disconnects**

- USB 2.0 hub / long cable. Plug the dongle into the PC
- Interference on 5 GHz; original project also has this as an unfixed bug

## Fresh Ubuntu install / `Unable to locate package`

A 20.04 desktop ISO leaves apt looking at `cdrom://Ubuntu 20.04…` plus `main restricted` only. That is why a first `sudo ./install.sh` used to die with:

```
E: Unable to locate package yasm
E: Unable to locate package ffmpeg
E: Package 'openbox' has no installation candidate
E: Package 'xterm' has no installation candidate
```

Those packages live in **universe**. `install.sh` now disables the CDROM source, enables universe, and re-runs `apt-get update` before installing anything. Re-run `sudo bash ./install.sh` on the same tree; it is safe to resume.

If it still cannot see `ffmpeg` after that, paste `/etc/apt/sources.list` and `ls /etc/apt/sources.list.d/`.

## `Temporary failure resolving` / `Could not resolve host: github.com`

The packages stage got far enough; then DNS died. Typical on a fresh 20.04 box with flaky Wi-Fi or a broken `systemd-resolved` stub (`127.0.0.53`).

`install.sh` now:

- skips `linux-headers-generic` / `dkms` (this rewrite does not patch the kernel; on 20.04 HWE those pull unused 5.4 headers)
- retries apt and `git clone`
- if name lookup fails, points DNS at 1.1.1.1 / 8.8.8.8

Re-run:

```bash
cd ~/pc2drc-ng
git pull
sudo bash ./install.sh
```

A failed clone may leave an empty `vendor/upstream`; the installer deletes that and retries. Ethernet is more reliable than Wi-Fi while it downloads.

## `target already defined - linux-x86_64`

OpenSSL 1.0.2 `./config` already detects the OS. Passing `linux-x86_64` a second time aborts configure before `make`. Re-run `sudo bash ./install.sh`; apt packages and libnl are skipped when already present.

Do **not** run `./pair.sh` until install prints `Install finished.` `wpa_supplicant` does not exist until the OpenSSL/hostapd build completes.

If `rm -rf ~/pc2drc-ng` says Permission denied, the previous run created root-owned `prefix/` / `logs/`:

```bash
sudo rm -rf ~/pc2drc-ng
```

## Ubuntu 20.04 specifically

20.04 still works as a *build host* if you have ESM/mirrors, but:

- `apt-get source linux-image-unsigned-$(uname -r)` is what the old installer used, and it is the first thing that dies on a non-clean 20.04
- We never call that
- If `apt-get update` itself fails because 20.04 is EOL, switch to 22.04/24.04. This project cannot resurrect Ubuntu archives

## Cleanup

```bash
sudo ./stop.sh
```

That unkills NetworkManager on the USB adapter. Your onboard Ethernet / other Wi-Fi should have stayed up the whole time.
