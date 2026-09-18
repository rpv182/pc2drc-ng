const pill = document.getElementById("status-pill");
const banner = document.getElementById("banner");
const ifaceSel = document.getElementById("iface");
const pinDisplay = document.getElementById("pin-display");
const logEl = document.getElementById("log");
const skipWiiu = document.getElementById("skip-wiiu");

const DEMO = {
  linux: false,
  installed: false,
  paired: false,
  streaming: false,
  demo: true,
  ifaces: [{ name: "wlx-rt5572 (demo)", driver: "rt2800usb" }],
};

let pin = "";
let demoMode = false;

function setPill(text, cls) {
  pill.textContent = text;
  pill.className = "pill " + (cls || "");
}

function log(text) {
  logEl.textContent = text;
  logEl.scrollTop = logEl.scrollHeight;
}

async function api(path, opts) {
  const res = await fetch(path, Object.assign({ headers: { "Content-Type": "application/json" } }, opts || {}));
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

async function refresh() {
  let st;
  try {
    st = await api("/api/status");
    demoMode = !!st.demo;
  } catch (err) {
    demoMode = true;
    st = DEMO;
    banner.textContent = "Demo UI (no backend). On Linux after install.sh, run: sudo ./ui.sh";
  }

  if (demoMode && st === DEMO) {
    setPill("demo", "busy");
  } else if (!st.linux) {
    setPill("windows", "busy");
    banner.textContent = "This UI is the pair + VNC host. Radio/VNC only run on Linux.";
  } else if (!st.installed) {
    setPill("install first", "bad");
    banner.textContent = "Run sudo ./install.sh (stages 0–2) before pairing.";
  } else if (st.streaming) {
    setPill("streaming", "ok");
  } else if (st.paired) {
    setPill("paired", "ok");
  } else {
    setPill("ready", "");
  }

  const ifaces = st.ifaces || DEMO.ifaces;
  const current = ifaceSel.value;
  ifaceSel.innerHTML = "";
  ifaces.forEach((item) => {
    const opt = document.createElement("option");
    opt.value = item.name;
    opt.textContent = item.driver ? item.name + "  (" + item.driver + ")" : item.name;
    ifaceSel.appendChild(opt);
  });
  if (current) ifaceSel.value = current;
  if (st.config && st.config.iface) ifaceSel.value = st.config.iface;
  skipWiiu.checked = !!(st.paired && !pin);
  return st;
}

function renderPin() {
  pinDisplay.textContent = (pin + "----").slice(0, 4).split("").join(" ");
}

document.getElementById("suits").addEventListener("click", (ev) => {
  const btn = ev.target.closest("button[data-digit]");
  if (!btn || pin.length >= 4) return;
  pin += btn.getAttribute("data-digit");
  renderPin();
});

document.getElementById("pin-clear").addEventListener("click", () => {
  pin = "";
  renderPin();
});

document.getElementById("btn-pair").addEventListener("click", async () => {
  if (demoMode) {
    log("Demo: would pair adapter " + ifaceSel.value + (skipWiiu.checked ? " (skip Wii U)" : " pin " + pin));
    setPill("paired (demo)", "ok");
    return;
  }
  if (!skipWiiu.checked && pin.length !== 4) {
    log("Enter the 4 suit symbols from the Wii U, or check “already have PSK”.");
    return;
  }
  setPill("pairing", "busy");
  log("Pairing… keep the Wii U in sync mode, GamePad off until it asks.");
  try {
    const data = await api("/api/pair", {
      method: "POST",
      body: JSON.stringify({
        iface: ifaceSel.value,
        pin: pin,
        skip_wiiu: skipWiiu.checked,
      }),
    });
    log(data.log || "Pairing finished.");
    await refresh();
  } catch (err) {
    setPill("pair failed", "bad");
    log(String(err.message || err));
  }
});

document.getElementById("btn-start").addEventListener("click", async () => {
  if (demoMode) {
    log("Demo: would start VNC host + drcvncclient. Power on the GamePad after that.");
    setPill("streaming (demo)", "ok");
    return;
  }
  setPill("starting", "busy");
  log("Starting VNC host…");
  try {
    const data = await api("/api/start", { method: "POST", body: "{}" });
    log(data.log || "Stream running. Power on the GamePad.");
    await refresh();
  } catch (err) {
    setPill("start failed", "bad");
    log(String(err.message || err));
  }
});

document.getElementById("btn-stop").addEventListener("click", async () => {
  if (demoMode) {
    log("Demo: stop.");
    setPill("ready", "");
    return;
  }
  try {
    const data = await api("/api/stop", { method: "POST", body: "{}" });
    log(data.log || "Stopped.");
    await refresh();
  } catch (err) {
    log(String(err.message || err));
  }
});

renderPin();
refresh();
setInterval(() => {
  refresh().catch(() => {});
}, 4000);
