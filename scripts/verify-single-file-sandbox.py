#!/usr/bin/env python3
"""Build/run isolated sandboxed import checks; select the generated fixtures in its open panel."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

root = Path(__file__).resolve().parents[1]
products = root / ".build/xcode-swiftui-mac/Build/Products/Debug"
fixture = root / (".build/single-file-sandbox-fixtures-" + uuid.uuid4().hex)
fixture.mkdir(parents=True)
for operation in ["Keep", "Move"]:
    for extension in ["mp4", "webm", "pdf"]:
        # Byte/grant tests, not codec playback tests. PDFKit has an explicit
        # one-page fallback for an unreadable imported PDF.
        (fixture / (operation + " Regal's shower 日本語." + extension)).write_bytes(
            ("synthetic " + extension + " media").encode())
app = root / ".build/single-file-sandbox-checks.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Frameworks").mkdir(exist_ok=True)
framework = contents / "Frameworks/AMSMB2.framework"
if framework.exists():
    shutil.rmtree(framework)
shutil.copytree(products / "PackageFrameworks/AMSMB2.framework", framework, symlinks=True)
source = root / ".build/single-file-sandbox-entry.swift"
source.write_text((root / "scripts/verify-single-file-sandbox.swift").read_text().replace(
    "FIXTURE_DIRECTORY", str(fixture)))
sources = sorted((root / "apps/apple/Shared").glob("*.swift"))
sources += [p for p in sorted((root / "apps/apple/Mac").glob("*.swift")) if p.name != "AppDelegate.swift"]
subprocess.run([
    "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macos26.0",
    "-I", str(products), "-F", str(products / "PackageFrameworks"), "-framework", "AMSMB2",
    "-Xcc", "-fmodule-map-file=" + str(root / "packages/AMSMB2/Dependencies/libsmb2/include/module.modulemap"),
    "-Xcc", "-I" + str(root / "packages/AMSMB2/Dependencies/libsmb2/include"),
    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
    *map(str, sources), str(root / "scripts/native-ui-fixtures.swift"), str(source),
    str(products / "MangaCore.o"), "-o", str(contents / "MacOS/SingleFileSandboxChecks"),
], check=True)
info = plistlib.loads((products / "MangaReaderMac.app/Contents/Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.thristram.mangareader.singlefilesandbox",
            CFBundleExecutable="SingleFileSandboxChecks", OAuthClientID="configure-test-client")
info.pop("CFBundleURLTypes", None)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", "--entitlements",
                str(root / "apps/apple/Config/MangaReaderMac.entitlements"), str(app)], check=True)
print("Select all six synthetic files in:", fixture, flush=True)
subprocess.run([str(contents / "MacOS/SingleFileSandboxChecks")], check=True)
