#!/usr/bin/env python3
"""Small local UI for pair + VNC host (the last two pc2drc stages)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "ui"
STATE = ROOT / "state"
VENDOR = ROOT / "vendor" / "upstream"
LOGS = ROOT / "logs"

START_PROC = None
START_LOCK = threading.Lock()
PAIR_LOCK = threading.Lock()
LAST_LOG = ""


def linux() -> bool:
    return sys.platform.startswith("linux")


def installed() -> bool:
    return (VENDOR / "drc-hostap").is_dir()


def paired() -> bool:
    return (STATE / "config.json").is_file()


def streaming() -> bool:
    with START_LOCK:
        return START_PROC is not None and START_PROC.poll() is None


def load_config() -> dict:
    path = STATE / "config.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def wifi_ifaces() -> list:
    names = []
    net = Path("/sys/class/net")
    if not net.is_dir():
        return names
    for entry in sorted(net.iterdir()):
        if (entry / "wireless").exists() or (entry / "phy80211").exists():
            driver = "unknown"
            drv = entry / "device" / "driver"
            if drv.exists():
                driver = drv.resolve().name
            names.append({"name": entry.name, "driver": driver})
    return names


def run_logged(cmd: list[str]) -> tuple[int, str]:
    LOGS.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True)
    text = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, text[-8000:]


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(UI), **kwargs)

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[ui] " + (fmt % args) + "\n")

    def _json(self, payload: dict, code: int = 200) -> None:
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/status":
            self._json(
                {
                    "linux": linux(),
                    "installed": installed(),
                    "paired": paired(),
                    "streaming": streaming(),
                    "root": os.geteuid() == 0 if hasattr(os, "geteuid") else False,
                    "demo": not linux(),
                    "config": load_config(),
                    "ifaces": wifi_ifaces()
                    if linux()
                    else [{"name": "wlx-rt5572", "driver": "rt2800usb"}],
                }
            )
            return
        if path in ("/", "/index.html"):
            self.path = "/index.html"
        return SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self) -> None:
        global START_PROC, LAST_LOG
        path = urlparse(self.path).path
        body = self._body()

        if not linux():
            self._json({"error": "Pair/host only run on Linux. This is the demo UI."}, 400)
            return

        if path == "/api/pair":
            if os.geteuid() != 0:
                self._json({"error": "Restart the UI with sudo ./ui.sh"}, 400)
                return
            if not installed():
                self._json({"error": "Run sudo ./install.sh first."}, 400)
                return
            iface = body.get("iface") or ""
            pin = body.get("pin") or ""
            skip = bool(body.get("skip_wiiu"))
            cmd = [sys.executable, str(ROOT / "scripts" / "pair.py"), "--noninteractive"]
            if iface:
                cmd += ["--iface", iface]
            if skip:
                cmd += ["--skip-wiiu"]
            elif pin:
                cmd += ["--pin", pin]
            else:
                self._json({"error": "Need a 4-digit suit PIN, or skip Wii U pairing."}, 400)
                return
            if not PAIR_LOCK.acquire(blocking=False):
                self._json({"error": "Pairing already running."}, 409)
                return
            try:
                code, text = run_logged(cmd)
                LAST_LOG = text
                if code != 0:
                    self._json({"error": text or "pair.py failed", "log": text}, 500)
                    return
                self._json({"ok": True, "log": text})
            finally:
                PAIR_LOCK.release()
            return

        if path == "/api/start":
            if os.geteuid() != 0:
                self._json({"error": "Restart the UI with sudo ./ui.sh"}, 400)
                return
            if not paired():
                self._json({"error": "Pair the GamePad first."}, 400)
                return
            with START_LOCK:
                if START_PROC is not None and START_PROC.poll() is None:
                    self._json({"ok": True, "log": "Already streaming."})
                    return
                logf = LOGS
                logf.mkdir(parents=True, exist_ok=True)
                handle = open(logf / "ui-start.log", "ab")
                START_PROC = subprocess.Popen(
                    [sys.executable, str(ROOT / "scripts" / "start.py")],
                    cwd=str(ROOT),
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                )
            self._json({"ok": True, "log": "VNC host started. Power on the GamePad."})
            return

        if path == "/api/stop":
            with START_LOCK:
                if START_PROC is not None and START_PROC.poll() is None:
                    START_PROC.terminate()
            subprocess.run([str(ROOT / "scripts" / "stop.sh")], cwd=str(ROOT), check=False)
            self._json({"ok": True, "log": "Stopped."})
            return

        self._json({"error": "unknown endpoint"}, 404)


def main() -> int:
    port = int(os.environ.get("PC2DRC_UI_PORT", "8540"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"pc2drc-ng UI  http://127.0.0.1:{port}")
    print("Pair + VNC host only. Install (stages 0-2) stays in the terminal.")
    if linux() and hasattr(os, "geteuid") and os.geteuid() != 0:
        print("Not root: open the page, but Pair/Start need: sudo ./ui.sh")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nUI stopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
