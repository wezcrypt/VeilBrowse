#!/usr/bin/env python3
"""Prints the UDID of the best available iPhone simulator (prefers iPhone 15, iOS >= 17)."""

import argparse
import json
import re
import subprocess
import sys


def runtime_version(runtime_id: str) -> tuple[int, ...]:
    match = re.search(r"iOS-(\d+)-(\d+)", runtime_id)
    return tuple(int(part) for part in match.groups()) if match else (0, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefer", default="iPhone 15", help="preferred device name prefix")
    parser.add_argument("--min-ios", default="17.0")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    minimum = tuple(int(x) for x in args.min_ios.split("."))

    try:
        raw = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"], check=True, capture_output=True, text=True
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"simctl failed: {exc}", file=sys.stderr)
        return 1

    candidates = []
    for runtime, devices in json.loads(raw).get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        version = runtime_version(runtime)
        if version < minimum:
            continue
        for device in devices:
            name = device.get("name", "")
            if not name.startswith("iPhone") or not device.get("isAvailable", True):
                continue
            preferred = name == args.prefer or name.startswith(args.prefer + " ")
            candidates.append((preferred, version, name, device["udid"]))

    if not candidates:
        print("no iPhone simulator with iOS >= %s available" % args.min_ios, file=sys.stderr)
        return 1
    candidates.sort(key=lambda c: (c[0], c[1]), reverse=True)
    preferred, version, name, udid = candidates[0]
    if args.verbose:
        print(f"selected {name} (iOS {'.'.join(map(str, version))})", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
