#!/usr/bin/env python3
"""After a Mac build, verify background reader loading in an isolated native bundle."""
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
derived = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / ".build/xcode-swiftui-mac").resolve()
products = derived / "Build/Products/Debug"
target = root / ".build/reader-loading-checks.app/Contents"
(target / "MacOS").mkdir(parents=True, exist_ok=True)
sources = sorted((root / "apps/apple/Shared").glob("*.swift"))
sources += [p for p in sorted((root / "apps/apple/Mac").glob("*.swift")) if p.name != "AppDelegate.swift"]
include = root / "packages/AMSMB2/Dependencies/libsmb2/include"
subprocess.run([
    "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
    "-target", "arm64-apple-macos26.0", "-I", str(products),
    "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap"),
    "-Xcc", "-I" + str(include), "-F", str(products / "PackageFrameworks"),
    "-framework", "AMSMB2", "-Xlinker", "-rpath", "-Xlinker", str(products / "PackageFrameworks"),
    *map(str, sources), str(root / "scripts/native-ui-fixtures.swift"),
    str(root / "scripts/verify-reader-loading.swift"), str(root / "scripts/collection-loading-checks.swift"),
    str(products / "MangaCore.o"),
    "-o", str(target / "MacOS/ReaderLoadingChecks"),
], check=True)
info = plistlib.loads((products / "MangaReaderMac.app/Contents/Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.thristram.mangareader.readerloadingchecks",
            CFBundleExecutable="ReaderLoadingChecks", OAuthClientID="configure-test-client")
info.pop("CFBundleURLTypes", None)
(target / "Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run([str(target / "MacOS/ReaderLoadingChecks")], check=True, timeout=60)
