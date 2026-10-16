#!/usr/bin/env python3
"""After a Debug Mac build, reproduce pending-CLOSE teardown using synthetic socketpairs."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
products = root / ".build/xcode-swiftui-mac/Build/Products/Debug"
include = root / "packages/AMSMB2/Dependencies/libsmb2/include"
binary = root / ".build/smb-handle-lifecycle-checks"
subprocess.run([
    "xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos26.0",
    "-I", str(products), "-F", str(products / "PackageFrameworks"), "-framework", "AMSMB2",
    "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap"), "-Xcc", "-I" + str(include),
    "-Xlinker", "-rpath", "-Xlinker", str(products / "PackageFrameworks"),
    str(root / "scripts/verify-smb-handle-lifecycle.swift"), "-o", str(binary),
], check=True)
subprocess.run([str(binary)], check=True, timeout=30)
