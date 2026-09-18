# Hardware

The GamePad is not a generic VNC tablet. It joins a **5 GHz WPA2 AP** that pretends to be a Wii U, and it timestamps video with the Wi-Fi **TSF** clock. If either of those is missing, you get a black screen or no association.

## Known-good adapters

- Ralink / MediaTek **RT5572** USB sticks (`rt2800usb`) — this is what original pc2drc used
- Some Atheros ath9k/ath10k cards that can AP on channel 36+
- Some Realtek rtl8821ae / rtl8812ae cards (hit or miss)

## Will not work

- **Intel iwlwifi** (`iwlmvm` / `iwldvm`): no `get_tsf()`, and 5 GHz AP is blocked by LAR
- Most laptop internal Intel AX200/AX210/etc.
- 2.4 GHz-only dongles
- WSL2 / a VM without USB passthrough of the whole dongle

## How to check

```bash
sudo ./scripts/check-system.sh
sudo ./lib/tsf.sh
```

You want:

- `iw phy` lists **AP** and **5180 MHz** without `disabled` / `no IR` on channel 36
- TSF values that **change** over time, not `0xffffffffffffffff`

If TSF is all `ff`, the driver has no `get_tsf`. A mac80211 sysfs patch will not save you; you need a different adapter (or a driver patch, which this installer does not attempt).

## Regulatory domain

```bash
sudo iw reg set US
sudo iw reg get
```

If the country stays `00` or `99` and 5 GHz stays `no IR`, that adapter will not host the GamePad AP.
