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
derived = Path(sys.argv[1]) if len(sys.argv) > 1 else root / ".build/xcode-swiftui-mac"
products = derived.resolve() / "Build/Products/Debug"
target = root / ".build/welcome-state-checks.app/Contents"
(target / "MacOS").mkdir(parents=True, exist_ok=True)
sources = sorted((root / "apps/apple/Shared").glob("*.swift"))
sources += [p for p in sorted((root / "apps/apple/Mac").glob("*.swift"))
            if p.name != "AppDelegate.swift"]
subprocess.run([
    "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macos26.0", "-I", str(products),
    "-Xcc", "-fmodule-map-file=" + str(root / "packages/AMSMB2/Dependencies/libsmb2/include/module.modulemap"),
    "-Xcc", "-I" + str(root / "packages/AMSMB2/Dependencies/libsmb2/include"),
    "-F", str(products / "PackageFrameworks"), "-framework", "AMSMB2",
    "-Xlinker", "-rpath", "-Xlinker", str(products / "PackageFrameworks"),
    *map(str, sources), str(root / "scripts/native-ui-fixtures.swift"), str(root / "scripts/verify-mac-auth-ui.swift"), str(root / "scripts/author-removal-checks.swift"), str(root / "scripts/import-responsiveness-checks.swift"), str(root / "scripts/single-file-import-checks.swift"), str(root / "scripts/reader-controls-checks.swift"),
    str(products / "MangaCore.o"), "-o", str(target / "MacOS/WelcomeChecks"),
], check=True)
info = plistlib.loads((products / "MangaReaderMac.app/Contents/Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.thristram.mangareader.welcomechecks",
            CFBundleExecutable="WelcomeChecks", OAuthClientID="configure-test-client")
info.pop("CFBundleURLTypes", None)
(target / "Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run([str(target / "MacOS/WelcomeChecks")], check=True)
