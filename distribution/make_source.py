#!/usr/bin/env python3
"""Writes the SideStore / AltStore source (source.json) for an Aeolus .ipa.

Version, build number and privacy strings are read from the .ipa itself, so the source always
matches the file SideStore downloads (SideStore checks this, and the SHA-256, before installing).

    make_source.py <ipa> <download-url> <out.json> [--notes TEXT]
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import zipfile

REPO = "https://github.com/aeolus-crypto/Aeolus-Wallet-iOS"
ICON = "https://raw.githubusercontent.com/aeolus-crypto/Aeolus-Wallet-iOS/main/design/master_1024.png"
TINT = "#2F6BFF"


def app_info_plist(ipa):
    with zipfile.ZipFile(ipa) as z:
        names = [n for n in z.namelist()
                 if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2]
        if len(names) != 1:
            raise SystemExit(f"expected one Payload/*.app/Info.plist, found {names}")
        return plistlib.loads(z.read(names[0]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("download_url")
    ap.add_argument("out")
    ap.add_argument("--notes", default="Test build.")
    a = ap.parse_args()

    info = app_info_plist(a.ipa)
    data = open(a.ipa, "rb").read()
    privacy = {k: v for k, v in sorted(info.items()) if k.startswith("NS") and k.endswith("UsageDescription")}

    source = {
        "name": "Aeolus Wallet",
        "identifier": "com.aeolus.wallet.source",
        "subtitle": "Zephyr Protocol wallet for iOS",
        "description": "Official source for the Aeolus Wallet iOS app. Each person signs the app "
                       "with their own Apple ID in SideStore; nobody else ever sees your Apple ID.",
        "iconURL": ICON,
        "website": REPO,
        "tintColor": TINT,
        "apps": [{
            "name": "Aeolus Wallet",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "Aeolus",
            "subtitle": "Non-custodial Zephyr wallet",
            "localizedDescription": "Non-custodial wallet for Zephyr Protocol (ZPH, ZSD, ZRS, ZYS). "
                                    "Keys stay on your iPhone. TEST BUILD: use small amounts and keep "
                                    "your seed phrase safe.",
            "iconURL": ICON,
            "tintColor": TINT,
            "category": "utilities",
            "screenshots": [],
            "versions": [{
                "version": info["CFBundleShortVersionString"],
                "buildVersion": str(info["CFBundleVersion"]),
                "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "localizedDescription": a.notes,
                "downloadURL": a.download_url,
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "minOSVersion": info.get("MinimumOSVersion", "15.0"),
            }],
            "appPermissions": {"entitlements": [], "privacy": privacy},
        }],
        "news": [],
    }
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(source, f, indent=2)
        f.write("\n")
    v = source["apps"][0]["versions"][0]
    print(f"{a.out}: {info['CFBundleIdentifier']} {v['version']} ({v['buildVersion']}), {v['size']} bytes")


if __name__ == "__main__":
    main()
