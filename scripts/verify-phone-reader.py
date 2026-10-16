#!/usr/bin/env python3
"""Build/run isolated UIKit reader checks on a booted iPhone simulator; leave it open for gesture review."""
import argparse
import json
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", help="Booted iPhone simulator UDID (default: first booted iPhone)")
args = parser.parse_args()
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "-j"]))
candidates = [device for group in devices["devices"].values() for device in group
              if device["state"] == "Booted" and device["name"].startswith("iPhone")]
device = args.device or (candidates[0]["udid"] if candidates else None)
if not device:
    raise SystemExit("Boot an iPhone simulator first, or specify --device UDID.")
subprocess.run(["python3", str(root / "scripts/preview-native-ui.py"), "phone", "--reader-checks",
                "--destination", "platform=iOS Simulator,id=" + device], check=True)
app = root / ".build/native-phone-reader-checks/build-phone/Build/Products/Debug-iphonesimulator/MangaReaderiPhone.app"
bundle = "com.thristram.mangareader.iphone.readerchecks"
subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, bundle, "data"], text=True).strip())
report = container / "Documents/phone-reader-checks.txt"
report.unlink(missing_ok=True)
subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", device, bundle], check=True)
for _ in range(240):
    if report.exists():
        result = report.read_text()
        print(result)
        if not result.startswith("PASS:"):
            raise SystemExit(1)
        break
    time.sleep(0.25)
else:
    raise SystemExit("Timed out waiting for native UIKit reader checks.")
