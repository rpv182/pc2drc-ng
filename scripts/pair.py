#!/usr/bin/env python3
"""Pair a Wii U (for the PSK) then pair the GamePad. No /home/root checks, no hardcoded username."""

from __future__ import annotations

import argparse
import json
import os
import pwd
import re
import subprocess
import sys
import time
from pathlib import Path

try:
    import pexpect
except ImportError:
    sys.exit("python3-pexpect is required. Re-run ./install.sh")

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / "vendor" / "upstream"
PREFIX = ROOT / "prefix"
STATE = ROOT / "state"
LOGS = ROOT / "logs"
HOSTAP = UPSTREAM / "drc-hostap"


def real_user() -> str:
    return os.environ.get("SUDO_USER") or os.environ.get("PC2DRC_USER") or pwd.getpwuid(os.getuid()).pw_name


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def need_root() -> None:
    if os.geteuid() != 0:
        die("Run as: sudo ./pair.sh")


def log_path() -> Path:
    LOGS.mkdir(parents=True, exist_ok=True)
    return LOGS / f"pair-{time.strftime('%Y%m%d-%H%M%S')}.log"


def run(cmd: list[str], check: bool = True, **kwargs) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd))
    return subprocess.run(cmd, check=check, **kwargs)


def wifi_ifaces() -> list[str]:
    names = []
    net = Path("/sys/class/net")
    for entry in sorted(net.iterdir()):
        if (entry / "wireless").exists() or (entry / "phy80211").exists():
            names.append(entry.name)
    return names


def choose_iface(prompt: str) -> str:
    ifaces = wifi_ifaces()
    if not ifaces:
        die("No wireless interfaces found. Plug in the USB adapter and retry.")
    labeled = [(name, iface_driver(name)) for name in ifaces]
    recommended = [name for name, drv in labeled if drv in COMPAT_DRIVERS]
    print("Wi-Fi interfaces:")
    for i, (name, driver) in enumerate(labeled):
        tag = ""
        if driver in COMPAT_DRIVERS:
            tag = "  <- use this (RT5572 / 5 GHz AP)"
        elif driver in INCOMPAT_DRIVERS:
            tag = "  <- Intel, will not work"
        print(f"  {i}: {name}  ({driver}){tag}")
    if len(ifaces) == 1:
        print(f"Using the only wireless interface: {ifaces[0]}")
        return ifaces[0]
    if recommended and not sys.stdin.isatty():
        return recommended[0]
    while True:
        raw = input(f"{prompt} [0-{len(ifaces)-1}]: ").strip()
        if raw.isdigit() and int(raw) < len(ifaces):
            return ifaces[int(raw)]
        print("Not a valid number.")


def confirm(question: str) -> bool:
    while True:
        raw = input(f"{question} (y/n): ").strip().lower()
        if raw.startswith("y"):
            return True
        if raw.startswith("n"):
            return False


CTRL_DIR = Path("/var/run/wpa_supplicant_drc")
COMPAT_DRIVERS = {
    "rt2800usb",
    "rt2800pci",
    "rt2x00usb",
    "mt76x2u",
    "mt76x0u",
    "mt76x2",
    "rtl8821ae",
    "rtl8812ae",
    "ath9k",
    "ath10k_pci",
}
INCOMPAT_DRIVERS = {"iwlwifi", "iwldvm", "iwlmvm"}


def iface_driver(iface: str) -> str:
    drv = Path(f"/sys/class/net/{iface}/device/driver")
    if drv.exists():
        return drv.resolve().name
    return "unknown"


def refuse_intel(iface: str) -> None:
    driver = iface_driver(iface)
    if driver in INCOMPAT_DRIVERS and os.environ.get("PC2DRC_ALLOW_INTEL") != "1":
        die(
            f"{iface} is Intel {driver}. It cannot pair or host the GamePad AP. "
            "Plug in the RT5572 USB stick, then run sudo ./pair.sh again "
            "(pick the wlx… / rt2800usb interface, not wlo1)."
        )


def unmanage(iface: str) -> None:
    run(["nmcli", "device", "disconnect", iface], check=False)
    run(["nmcli", "device", "set", iface, "managed", "no"], check=False)
    conf_dir = Path("/etc/NetworkManager/conf.d")
    if conf_dir.is_dir():
        (conf_dir / f"99-pc2drc-ng-{iface}.conf").write_text(
            f"[keyfile]\nunmanaged-devices=interface-name:{iface}\n", encoding="utf-8"
        )
        run(["systemctl", "reload", "NetworkManager"], check=False)
    time.sleep(0.8)


def prepare_iface(iface: str) -> None:
    """Take the USB stick away from NetworkManager and leave it in STA mode."""
    unmanage(iface)
    run(["rfkill", "unblock", "wifi"], check=False)
    run(["rfkill", "unblock", "wlan"], check=False)
    run(["rfkill", "unblock", "all"], check=False)
    CTRL_DIR.mkdir(parents=True, exist_ok=True)
    stale = CTRL_DIR / iface
    if stale.exists() or stale.is_socket():
        run([str(wpa_bin("wpa_cli")), "-p", str(CTRL_DIR), "-i", iface, "terminate"], check=False)
        time.sleep(0.3)
        try:
            stale.unlink()
        except OSError:
            pass
    run(["ip", "link", "set", "dev", iface, "down"], check=False)
    run(["iw", "dev", iface, "set", "type", "managed"], check=False)
    run(["ip", "link", "set", "dev", iface, "up"], check=False)
    time.sleep(0.4)


def ld_env() -> dict[str, str]:
    env = os.environ.copy()
    lib = str(PREFIX / "lib")
    env["LD_LIBRARY_PATH"] = lib + ":" + env.get("LD_LIBRARY_PATH", "")
    env["PATH"] = str(PREFIX / "bin") + ":" + env.get("PATH", "")
    return env


def wpa_bin(name: str) -> Path:
    path = HOSTAP / "wpa_supplicant" / name
    if not path.exists():
        die(f"Missing {path}. Run ./install.sh first.")
    return path


def hostapd_bin() -> Path:
    path = HOSTAP / "hostapd" / "hostapd"
    if not path.exists():
        die(f"Missing {path}. Run ./install.sh first.")
    return path


def netboot_bin() -> Path:
    path = HOSTAP / "netboot" / "netboot"
    if not path.exists():
        die(f"Missing {path}. Run ./install.sh first.")
    return path


def pin_from_digits(raw: str) -> str:
    digits = "".join(ch for ch in raw if ch.isdigit())
    if len(digits) == 8 and digits.endswith("5678"):
        return digits
    if len(digits) == 4:
        return digits + "5678"
    die("PIN must be 4 suit digits (0-3) or the full 8-digit WPS PIN.")


def decode_wps_pin() -> str:
    print()
    print("The Wii U shows 4 card-suit symbols. Convert them to digits:")
    print("  Spade = 0   Heart = 1   Diamond = 2   Club = 3")
    print("  Example: spade diamond club diamond  ->  0232  ->  PIN 02325678")
    while True:
        raw = input("Enter the 4 digits: ").strip()
        if raw.isdigit() and len(raw) == 4:
            return pin_from_digits(raw)
        print("Need exactly four digits 0-3.")


def init_wpa(conf: Path, iface: str, log: Path) -> "pexpect.spawn":
    CTRL_DIR.mkdir(parents=True, exist_ok=True)
    sock = CTRL_DIR / iface
    if sock.exists():
        try:
            sock.unlink()
        except OSError:
            pass
    cmd = f"{wpa_bin('wpa_supplicant')} -dd -Dnl80211 -i{iface} -c{conf}"
    child = pexpect.spawn(cmd, env=ld_env(), encoding="utf-8", timeout=10)
    child.logfile = open(log, "a", encoding="utf-8")
    try:
        child.expect("Successfully initialized wpa_supplicant", timeout=10)
    except pexpect.ExceptionPexpect:
        extra = (child.before or "")[-800:]
        die(
            "wpa_supplicant failed to start on "
            f"{iface} ({iface_driver(iface)}). {extra.strip() or 'See logs/pair-*.log'}"
        )
    for _ in range(20):
        if sock.exists() and child.isalive():
            break
        time.sleep(0.25)
    else:
        die(
            f"wpa_supplicant started but created no control socket at {sock}. "
            "NetworkManager may still own the interface, or this adapter cannot run nl80211."
        )
    return child


def scan_wiiu(iface: str) -> str:
    print("Scanning for Wii U pairing SSID (WiiU…_STA1)...")
    for attempt in range(8):
        proc = subprocess.run(
            ["iw", "dev", iface, "scan"],
            check=False,
            capture_output=True,
            text=True,
        )
        match = re.search(r"WiiU[0-9a-fA-F]{12}[0-9a-fA-F]{12}_STA1", proc.stdout)
        if not match:
            match = re.search(r"WiiU[0-9a-fA-F]{23}_STA1", proc.stdout)
        if match:
            return match.group(0)
        print(f"  not found (try {attempt+1}/8). Press the red SYNC button on the Wii U faceplate.")
        time.sleep(2)
    die("Wii U not seen in scan. Put it in GamePad pairing mode and retry.")


def mac_from_sta_ssid(ssid: str) -> str:
    # WiiUaabbccddeefaabbccddeeff_STA1 -> aa:bb:cc:dd:ee:ff
    payload = ssid[len("WiiU") :].split("_")[0]
    mac_hex = payload[:12]
    return ":".join(mac_hex[i : i + 2] for i in range(0, 12, 2)).lower()


def read_psk(conf: Path) -> tuple[str, str]:
    text = conf.read_text(encoding="utf-8", errors="replace")
    psk = re.search(r"psk=([0-9a-fA-F]{64})", text)
    ssid = re.search(r'ssid="(WiiU[^"]+)"', text)
    if not psk:
        die("WPS finished but no 64-hex PSK was written. Pairing failed.")
    return (ssid.group(1) if ssid else ""), psk.group(1)


def pair_wiiu(iface: str, log: Path, pin: str | None = None, noninteractive: bool = False) -> tuple[str, str, str]:
    src = HOSTAP / "conf" / "get_psk.conf.orig"
    if not src.exists():
        src = HOSTAP / "wpa_supplicant" / "get_psk.conf.orig"
    if not src.exists():
        die(f"Missing get_psk.conf.orig under {HOSTAP}")
    conf = HOSTAP / "wpa_supplicant" / "get_psk.conf"
    text = src.read_text(encoding="utf-8", errors="replace")
    if "ctrl_interface=" not in text:
        text = "ctrl_interface=/var/run/wpa_supplicant_drc\nupdate_config=1\n" + text
    conf.write_text(text, encoding="utf-8")

    prepare_iface(iface)
    print()
    print("Turn the Wii U ON, wait ~15s, press the red SYNC button on the faceplate twice,")
    print("then enter the 4 suit symbols as digits.")
    if not noninteractive:
        input("Press Enter when the Wii U is showing the pairing symbols...")
    if pin:
        pin = pin_from_digits(pin)
    else:
        pin = decode_wps_pin()

    wpa = init_wpa(conf, iface, log)
    ssid = scan_wiiu(iface)
    bssid = mac_from_sta_ssid(ssid)
    print(f"Found Wii U  ssid={ssid}  bssid={bssid}")

    cli = pexpect.spawn(
        f"{wpa_bin('wpa_cli')} -p{CTRL_DIR} -i{iface}",
        env=ld_env(),
        encoding="utf-8",
        timeout=20,
    )
    cli.logfile = open(log, "a", encoding="utf-8")
    try:
        idx = cli.expect(
            ["> ", "Interactive mode", "Could not connect to wpa_supplicant"],
            timeout=15,
        )
    except pexpect.ExceptionPexpect:
        die(f"wpa_cli could not attach to {iface}. See {log}")
    if idx == 2:
        die(
            f"Could not connect to wpa_supplicant on {iface} ({iface_driver(iface)}). "
            "Plug in the RT5572 USB stick and pick that interface. "
            f"Control socket: {CTRL_DIR / iface}"
        )

    print("Starting WPS PIN pairing...")
    cli.sendline(f"wps_pin {bssid} {pin}")
    try:
        cli.expect("WPS-CRED-RECEIVED", timeout=25)
        cli.expect("WPS-SUCCESS", timeout=25)
    except pexpect.ExceptionPexpect:
        print(cli.before or "")
        die("WPS pairing timed out. Re-enter pairing mode on the Wii U and run ./pair.sh again.")

    time.sleep(1)
    got_ssid, psk = read_psk(conf)
    if not got_ssid:
        got_ssid = "WiiU" + bssid.replace(":", "")
    print(f"PSK obtained. SSID will be {got_ssid}")
    try:
        cli.sendline("terminate")
        time.sleep(1)
    except Exception:
        pass
    for child in (cli, wpa):
        try:
            child.terminate(force=True)
        except Exception:
            pass
    return iface, got_ssid, psk


def write_hostapd_conf(iface: str, ssid: str, psk: str) -> Path:
    templates = [
        HOSTAP / "conf" / "wiiu_ap_normal.conf.DONOTTOUCH",
        HOSTAP / "conf" / "wiiu_ap_normal.conf",
    ]
    template = next((p for p in templates if p.exists()), None)
    if template is None:
        die(f"No hostapd template in {HOSTAP / 'conf'}")
    text = template.read_text(encoding="utf-8", errors="replace")
    text = re.sub(r"^interface=.*$", f"interface={iface}", text, flags=re.M)
    text = re.sub(r"^ssid=.*$", f"ssid={ssid}", text, flags=re.M)
    text = re.sub(r"^wpa_psk=.*$", f"wpa_psk={psk}", text, flags=re.M)
    # Some templates use placeholder tokens from the original installer.
    text = text.replace("ssid=ssid", f"ssid={ssid}")
    text = text.replace("wpa_psk=wpa_psk", f"wpa_psk={psk}")
    STATE.mkdir(parents=True, exist_ok=True)
    dest = STATE / "hostapd-wiiu.conf"
    dest.write_text(text, encoding="utf-8")
    # Also keep a copy where the original scripts expected it.
    (HOSTAP / "conf" / "generated_ap_normal.conf").write_text(text, encoding="utf-8")
    return dest


def pair_gamepad(iface: str, hostapd_conf: Path, log: Path) -> str:
    run(["iw", "reg", "set", "US"], check=False)
    run(["ip", "link", "set", "dev", iface, "up"], check=False)
    run(["ip", "addr", "flush", "dev", iface], check=False)
    run(["ip", "addr", "add", "192.168.1.10/24", "dev", iface], check=False)
    run(["ip", "link", "set", "mtu", "1800", "dev", iface], check=False)

    print()
    print("Starting hostapd. Power ON the GamePad now (Wii U should stay OFF / unplugged).")
    hapd = pexpect.spawn(
        f"{hostapd_bin()} -dd {hostapd_conf}",
        env=ld_env(),
        encoding="utf-8",
        timeout=None,
    )
    hapd.logfile = open(log, "a", encoding="utf-8")
    try:
        hapd.expect(r"pairwise key handshake completed \(RSN\)", timeout=180)
    except pexpect.ExceptionPexpect:
        die("Gamepad did not complete WPA handshake. Is this the USB adapter, 5 GHz, and the PSK from the Wii U?")

    before = hapd.before or ""
    mac_match = re.findall(r"(?:AP-STA-CONNECTED )?([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})", before)
    if not mac_match:
        mac_match = re.findall(r"([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})", before)
    if not mac_match:
        die("hostapd connected but we could not parse the GamePad MAC. Check the pair log.")
    gamepad = mac_match[-1].lower()
    print(f"GamePad associated: {gamepad}")

    print("Running netboot DHCP so the GamePad gets 192.168.1.11 ...")
    nb = pexpect.spawn(
        f"{netboot_bin()} 192.168.1.255 192.168.1.10 192.168.1.11 {gamepad}",
        env=ld_env(),
        encoding="utf-8",
        timeout=40,
    )
    nb.logfile = open(log, "a", encoding="utf-8")
    try:
        nb.expect("matched", timeout=30)
    except pexpect.ExceptionPexpect:
        print("WARNING: netboot did not print 'matched'. Start may still work; we saved the MAC anyway.")
    try:
        hapd.terminate(force=True)
        nb.terminate(force=True)
    except Exception:
        pass
    run(["killall", "hostapd"], check=False)
    return gamepad


def save_state(data: dict) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    path = STATE / "config.json"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    (HOSTAP / "conf" / "generated_netboot_info.conf").write_text(data["gamepad_mac"], encoding="utf-8")
    print(f"Saved {path}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Pair a Wii U GamePad with pc2drc-ng")
    parser.add_argument("--iface", help="USB Wi-Fi interface used for the GamePad AP")
    parser.add_argument("--pin", help="4 suit digits (0-3) shown on the Wii U")
    parser.add_argument("--skip-wiiu", action="store_true", help="Reuse the PSK already in state/config.json")
    parser.add_argument("--noninteractive", action="store_true", help="No prompts; for the GamePad UI")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    need_root()
    if not HOSTAP.exists():
        die("vendor/upstream missing. Run ./install.sh first.")
    log = log_path()
    print(f"Logging to {log}")
    print(f"Running as root for user {real_user()}")

    if args.noninteractive:
        skip = "skip" if args.skip_wiiu else ""
        ifaces = wifi_ifaces()
        if args.iface:
            iface = args.iface
        elif len(ifaces) == 1:
            iface = ifaces[0]
        else:
            recommended = [n for n in ifaces if iface_driver(n) in COMPAT_DRIVERS]
            if recommended:
                iface = recommended[0]
            else:
                die("Pass --iface when more than one wireless adapter is present.")
        if iface not in ifaces:
            die(f"Interface {iface} not found.")
    else:
        skip = input('Press Enter to pair with a Wii U, or type "skip" if you already have a PSK: ').strip().lower()
        iface = args.iface or choose_iface("Which USB Wi-Fi adapter should talk to the Wii U / GamePad?")
        if not confirm(f"Use {iface}?"):
            iface = choose_iface("Pick another interface:")
    refuse_intel(iface)
    prepare_iface(iface)

    if skip == "skip":
        cfg = STATE / "config.json"
        if not cfg.exists():
            die("No state/config.json yet; cannot skip Wii U pairing.")
        data = json.loads(cfg.read_text(encoding="utf-8"))
        ssid, psk = data["ssid"], data["psk"]
        print(f"Reusing SSID {ssid}")
    else:
        iface, ssid, psk = pair_wiiu(iface, log, pin=args.pin, noninteractive=args.noninteractive)

    hostapd_conf = write_hostapd_conf(iface, ssid, psk)
    gamepad = pair_gamepad(iface, hostapd_conf, log)
    save_state(
        {
            "iface": iface,
            "ssid": ssid,
            "psk": psk,
            "gamepad_mac": gamepad,
            "user": real_user(),
        }
    )
    print()
    print("Pairing complete. Unplug / power off the Wii U, then run:")
    print("  sudo ./start.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
