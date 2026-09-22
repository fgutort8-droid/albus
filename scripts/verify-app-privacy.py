#!/usr/bin/env python3
"""Catch missing bundle resources before App Store upload, not just in source review."""
import argparse
import plistlib
from pathlib import Path


def verify(app: Path) -> None:
    expected = Path(__file__).resolve().parents[1] / "ios/App/Albus/PrivacyInfo.xcprivacy"
    with expected.open("rb") as f:
        source = plistlib.load(f)
    with (app / "PrivacyInfo.xcprivacy").open("rb") as f:
        bundled = plistlib.load(f)
    assert bundled == source, "bundled privacy manifest differs from source"
    assert bundled["NSPrivacyTracking"] is False, "tracking declaration changed"
    assert not bundled["NSPrivacyTrackingDomains"], "unexpected tracking domains"
    with (app / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    assert info.get("ITSAppUsesNonExemptEncryption") is False, "export-compliance property missing/incorrect"
    print("PASS: built app manifest matches source; tracking=false; ITSAppUsesNonExemptEncryption=false.")
    for path in sorted(app.rglob("PrivacyInfo.xcprivacy")):
        if "PlugIns" not in path.relative_to(app).parts:
            with path.open("rb") as f:
                plistlib.load(f)
            print("Manifest:", path.relative_to(app))
    print("SDK inventory is evidence of presence only; see docs/app-store/verification.md for absent SDK manifests.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, help="Built .app directory")
    args = parser.parse_args()
    verify(args.app)
