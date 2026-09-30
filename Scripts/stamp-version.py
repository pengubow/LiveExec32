#!/usr/bin/env python3
"""Stamp a built bundle before signing, using the package release version."""

import argparse
import plistlib
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", type=Path)
    parser.add_argument("version")
    arguments = parser.parse_args()

    with arguments.plist.open("rb") as source:
        info = plistlib.load(source)
    info["CFBundleShortVersionString"] = arguments.version
    with arguments.plist.open("wb") as destination:
        plistlib.dump(info, destination, fmt=plistlib.FMT_BINARY, sort_keys=False)


if __name__ == "__main__":
    main()
