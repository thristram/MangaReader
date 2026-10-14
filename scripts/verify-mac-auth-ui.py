#!/usr/bin/env python3
"""After the Mac build, check the real auth container in an isolated test bundle.

No tokens, production login, or server writes. Synthetic VerifiedAccount values
exercise UI transitions only; they are not API authentication evidence.
"""
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
derived = Path(sys.argv[1]) if len(sys.argv) > 1 else root / ".build/xcode-mac"
products = derived.resolve() / "Build/Products/Debug"
target = root / ".build/welcome-state-checks.app/Contents"
(target / "MacOS").mkdir(parents=True, exist_ok=True)
sources = [p for p in sorted((root / "apps/apple/Shared").glob("*.swift"))
           if p.name != "SMBMedia.swift"]
sources += [p for p in sorted((root / "apps/apple/Mac").glob("*.swift"))
            if p.name != "AppDelegate.swift"]
subprocess.run([
    "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-I", str(products),
    *map(str, sources), str(root / "scripts/verify-mac-auth-ui.swift"),
    str(products / "MangaCore.o"), "-o", str(target / "MacOS/WelcomeChecks"),
], check=True)
info = plistlib.loads((products / "MangaReaderMac.app/Contents/Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.thristram.mangareader.welcomechecks",
            CFBundleExecutable="WelcomeChecks", OAuthClientID="configure-test-client")
info.pop("CFBundleURLTypes", None)
(target / "Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run([str(target / "MacOS/WelcomeChecks")], check=True)
