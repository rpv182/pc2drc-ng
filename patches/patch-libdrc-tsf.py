#!/usr/bin/env python3
"""Rewrite libdrc GetTsf() so it can use mac80211 debugfs instead of a patched kernel."""

from __future__ import annotations

import pathlib
import sys

REPLACEMENT = r'''
int GetTsf(u64 *tsf) {
  static int fd = -1;
  static int ascii_mode = -1;
  char probe[64];
  ssize_t n;

  if (fd == -1) {
    std::string drc_if;
    std::vector<std::string> paths;
    const char* env_if = getenv("DRC_IFACE");
    const char* env_path = getenv("DRC_TSF_PATH");

    if (env_path && env_path[0]) {
      paths.push_back(env_path);
    }

    if (GetInterfaceOfIpv4("192.168.1.10", &drc_if) != 0) {
      if (env_if && env_if[0]) {
        drc_if = env_if;
      }
    }

    if (!drc_if.empty()) {
      paths.push_back(std::string("/sys/class/net/") + drc_if + "/device/tsf");
      paths.push_back(std::string("/sys/class/net/") + drc_if + "/tsf");

      char phy[256];
      std::string phy_link = std::string("/sys/class/net/") + drc_if + "/phy80211";
      n = readlink(phy_link.c_str(), phy, sizeof(phy) - 1);
      if (n > 0) {
        phy[n] = 0;
        const char* phyname = strrchr(phy, '/');
        phyname = phyname ? phyname + 1 : phy;
        paths.push_back(std::string("/sys/kernel/debug/ieee80211/") + phyname + "/tsf");
        paths.push_back(std::string("/sys/kernel/debug/ieee80211/") + phyname +
                        "/netdev:" + drc_if + "/tsf");
      }
    }

    for (size_t i = 0; i < paths.size(); ++i) {
      fd = open(paths[i].c_str(), O_RDONLY);
      if (fd >= 0) {
        break;
      }
    }

    if (fd == -1) {
      return -1;
    }
  }

  n = pread(fd, probe, sizeof(probe) - 1, 0);
  if (n <= 0) {
    perror("pread failed - GetTsf");
    return -1;
  }
  probe[n] = 0;

  if (ascii_mode == -1) {
    ascii_mode = (probe[0] == '0' && probe[1] == 'x') ||
                 (n != (ssize_t)sizeof(*tsf) && isxdigit((unsigned char)probe[0]));
  }

  if (ascii_mode) {
    *tsf = strtoull(probe, NULL, 0);
    return 0;
  }

  if (n < (ssize_t)sizeof(*tsf)) {
    perror("pread failed - GetTsf");
    return -1;
  }
  memcpy(tsf, probe, sizeof(*tsf));
  return 0;
}
'''

INCLUDES = """
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <fcntl.h>
#include <unistd.h>
"""


def inject_includes(text: str) -> str:
    extra = [line for line in INCLUDES.strip().splitlines() if line and line not in text]
    if not extra:
        return text
    # Insert after the last #include block near the top.
    lines = text.splitlines(keepends=True)
    last_include = 0
    for i, line in enumerate(lines[:80]):
        if line.startswith("#include"):
            last_include = i
    insert_at = last_include + 1
    snippet = "".join(e + ("\n" if not e.endswith("\n") else "") for e in extra) + "\n"
    lines.insert(insert_at, snippet)
    return "".join(lines)


def replace_gettsf(text: str) -> str:
    start = text.find("int GetTsf(")
    if start < 0:
        raise SystemExit("Could not find int GetTsf( in tsf-linux.cpp")
    # Brace match from the function start.
    brace = text.find("{", start)
    depth = 0
    end = None
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        raise SystemExit("Could not find end of GetTsf()")
    return text[:start] + REPLACEMENT.strip() + text[end:]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch-libdrc-tsf.py path/to/tsf-linux.cpp", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    original = path.read_text(encoding="utf-8", errors="replace")
    backup = path.with_suffix(path.suffix + ".pc2drc-ng.bak")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    updated = inject_includes(replace_gettsf(original))
    path.write_text(updated, encoding="utf-8")
    print(f"patched {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
