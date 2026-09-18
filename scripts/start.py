#!/usr/bin/env python3
"""Start the GamePad AP, VNC desktop, netboot, and drcvncclient."""

from __future__ import annotations

import json
import os
import pwd
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / "vendor" / "upstream"
PREFIX = ROOT / "prefix"
STATE = ROOT / "state"
LOGS = ROOT / "logs"
HOSTAP = UPSTREAM / "drc-hostap"
CHILDREN: list[subprocess.Popen] = []
CONFIG: dict = {}
CLEANING = False


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    if not CLEANING:
        cleanup()
    sys.exit(1)


def real_user() -> str:
    return os.environ.get("SUDO_USER") or os.environ.get("PC2DRC_USER") or pwd.getpwuid(os.getuid()).pw_name


def real_home(user: str) -> str:
    return pwd.getpwnam(user).pw_dir


def ld_env() -> dict[str, str]:
    env = os.environ.copy()
    lib = str(PREFIX / "lib")
    env["LD_LIBRARY_PATH"] = lib + ":" + env.get("LD_LIBRARY_PATH", "")
    env["PATH"] = str(PREFIX / "bin") + ":" + env.get("PATH", "")
    env["DRC_IFACE"] = CONFIG.get("iface") or env.get("DRC_IFACE", "")
    return env


def load_config() -> dict:
    global CONFIG
    path = STATE / "config.json"
    if not path.exists():
        die("No state/config.json. Run sudo ./pair.sh first.")
    CONFIG = json.loads(path.read_text(encoding="utf-8"))
    return CONFIG


def run(cmd: list[str], check: bool = True, **kwargs) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd))
    kwargs.setdefault("env", ld_env())
    return subprocess.run(cmd, check=check, **kwargs)


def spawn(cmd, log, extra_env=None):
    log.parent.mkdir(parents=True, exist_ok=True)
    handle = open(log, "ab")
    env = ld_env()
    if extra_env:
        env.update(extra_env)
    print("+", " ".join(cmd))
    proc = subprocess.Popen(cmd, env=env, stdout=handle, stderr=subprocess.STDOUT)
    CHILDREN.append(proc)
    return proc


def wait_port(host: str, port: int, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        sock = socket.socket()
        sock.settimeout(1)
        try:
            sock.connect((host, port))
            sock.close()
            return True
        except OSError:
            time.sleep(0.3)
        finally:
            try:
                sock.close()
            except OSError:
                pass
    return False


def kill_tree(name: str) -> None:
    subprocess.run(["killall", "-q", name], check=False)


def find_drcvnc() -> Path:
    candidates = [
        UPSTREAM / "libdrc-vnc" / "drcvncclient" / "src" / "drcvncclient",
        UPSTREAM / "libdrc-vnc" / "drcvncclient" / "drcvncclient",
        PREFIX / "bin" / "drcvncclient",
    ]
    for path in candidates:
        if path.exists():
            return path
    die("drcvncclient binary not found. Re-run ./install.sh")


def find_vnc_server() -> list[str]:
    for name in ("tigervncserver", "vncserver"):
        path = shutil.which(name)
        if path:
            return [path]
    die("tigervncserver not installed")


def start_vnc(user: str) -> None:
    display = ":1"
    # Always kill a stale :1 so we don't get Connection refused against a dead socket.
    run(find_vnc_server() + ["-kill", display], check=False)
    time.sleep(0.5)
    xstartup = ROOT / "conf" / "vnc-xstartup"
    if not xstartup.exists():
        die(f"Missing {xstartup}")
    os.chmod(xstartup, 0o755)
    home = real_home(user)
    vnc_dir = Path(home) / ".vnc"
    vnc_dir.mkdir(mode=0o700, exist_ok=True)
    os.chown(vnc_dir, pwd.getpwnam(user).pw_uid, pwd.getpwnam(user).pw_gid)

    cmd = [
        "runuser",
        "-u",
        user,
        "--",
        *find_vnc_server(),
        display,
        "-geometry",
        "854x480",
        "-depth",
        "24",
        "-localhost",
        "yes",
        "-SecurityTypes",
        "None",
        "-xstartup",
        str(xstartup),
    ]
    # TigerVNC 1.10 (Ubuntu 20.04) understands -localhost yes; 1.12+ prefers -localhost.
    print("Starting VNC :1 at 854x480 for", user)
    result = run(cmd, check=False)
    if result.returncode != 0:
        cmd = [c for c in cmd if c != "yes"]
        result = run(cmd, check=False)
    if result.returncode != 0:
        die("tigervncserver failed. Install tigervnc-standalone-server and openbox, then retry.")
    if not wait_port("127.0.0.1", 5901, timeout=25):
        die(
            "VNC started but nothing is listening on 127.0.0.1:5901 "
            "(the original 111 Connection refused bug). Check ~/.vnc/*.log"
        )
    print("VNC is listening on 127.0.0.1:5901")


def start_ap(cfg: dict, log: Path) -> None:
    iface = cfg["iface"]
    conf = STATE / "hostapd-wiiu.conf"
    if not conf.exists():
        die("Missing state/hostapd-wiiu.conf. Re-run ./pair.sh")
    run(["nmcli", "device", "set", iface, "managed", "no"], check=False)
    kill_tree("hostapd")
    kill_tree("wpa_supplicant")
    run(["iw", "reg", "set", "US"], check=False)
    run(["ip", "link", "set", "dev", iface, "up"])
    run(["ip", "addr", "flush", "dev", iface], check=False)
    run(["ip", "addr", "add", "192.168.1.10/24", "dev", iface])
    run(["ip", "link", "set", "mtu", "1800", "dev", iface])
    hapd = HOSTAP / "hostapd" / "hostapd"
    run([str(hapd), "-B", str(conf)], check=True)
    time.sleep(1)
    # -B daemonizes; don't track it as a child. Confirm the iface has the address.
    addr = run(["ip", "-o", "-4", "addr", "show", "dev", iface], check=False, capture_output=True, text=True)
    if "192.168.1.10" not in (addr.stdout or ""):
        run(["ip", "addr", "add", "192.168.1.10/24", "dev", iface], check=False)


def start_netboot(cfg: dict, log: Path) -> subprocess.Popen:
    nb = HOSTAP / "netboot" / "netboot"
    mac = cfg["gamepad_mac"]
    print(f"Waiting for GamePad {mac}. Power it on now.")
    return spawn([str(nb), "192.168.1.255", "192.168.1.10", "192.168.1.11", mac], log)


def probe_tsf(iface: str) -> None:
    script = ROOT / "lib" / "tsf.sh"
    result = run(["bash", str(script), iface], check=False)
    if result.returncode != 0:
        print()
        print("WARNING: no usable TSF value yet. Video will be black without TSF.")
        print("         RT5572/rt2800usb adapters work. Intel iwlwifi does not.")
        print("         After hostapd is up, re-run: sudo ./lib/tsf.sh", iface)


def cleanup(*_args) -> None:
    global CLEANING
    if CLEANING:
        return
    CLEANING = True
    print("\nStopping pc2drc-ng...")
    for proc in CHILDREN:
        try:
            proc.terminate()
        except Exception:
            pass
    for name in ("drcvncclient", "hostapd", "netboot", "Xtigervnc", "X0tigervnc"):
        kill_tree(name)
    try:
        run(find_vnc_server() + ["-kill", ":1"], check=False)
    except Exception:
        pass
    time.sleep(0.3)
    for proc in CHILDREN:
        try:
            proc.kill()
        except Exception:
            pass


def main() -> int:
    if os.geteuid() != 0:
        die("Run as: sudo ./start.sh")
    if not HOSTAP.exists():
        die("vendor/upstream missing. Run ./install.sh first.")
    cfg = load_config()
    user = real_user()
    log_dir = LOGS
    log_dir.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")

    signal.signal(signal.SIGINT, lambda *_: (cleanup(), sys.exit(0)))
    signal.signal(signal.SIGTERM, lambda *_: (cleanup(), sys.exit(0)))

    if not (Path("/sys/class/net") / cfg["iface"]).exists():
        die(f"Interface {cfg['iface']} is gone. Plug the USB adapter back in, or re-run ./pair.sh")

    uinput = Path("/dev/uinput")
    if uinput.exists():
        os.chmod(uinput, 0o666)

    start_vnc(user)
    start_ap(cfg, log_dir / f"hostapd-{stamp}.log")
    probe_tsf(cfg["iface"])
    start_netboot(cfg, log_dir / f"netboot-{stamp}.log")

    print()
    print("Starting drcvncclient. The GamePad should show the 854x480 nested desktop.")
    print("Ctrl+C stops everything.")
    client = find_drcvnc()
    env = ld_env()
    env["DRC_IFACE"] = cfg["iface"]
    try:
        subprocess.check_call([str(client), ":1"], env=env)
    except subprocess.CalledProcessError as exc:
        die(f"drcvncclient exited {exc.returncode}. See logs/ and TSF probe output.")
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
