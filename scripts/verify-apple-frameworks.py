#!/usr/bin/env python3
"""Check built-app framework packaging and signatures, without launching/signing it."""
import argparse
import plistlib
import re
import subprocess
from pathlib import Path


def output(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip())
    return result.stdout


def verify(app, allow_unsigned):
    content = app / "Contents" if (app / "Contents/Info.plist").exists() else app
    with (content / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    executables = content / "MacOS" if content != app else app
    executable = executables / info["CFBundleExecutable"]
    if not executable.is_file():
        raise ValueError(f"Missing app executable: {executable}")
    frameworks = content / "Frameworks"
    smb = frameworks / "AMSMB2.framework/AMSMB2"
    if not smb.is_file():
        raise ValueError(f"Missing embedded framework: {smb}")

    # The app may link frameworks from its Debug dylib rather than its launcher.
    binaries = [executable, *executables.glob("*.dylib")]
    binaries += [p / p.stem for p in frameworks.glob("*.framework")]
    app_arches = set(output("lipo", "-archs", str(executable)).split())
    for binary in binaries:
        if not binary.is_file():
            raise ValueError(f"Missing framework executable: {binary}")
        if not app_arches <= set(output("lipo", "-archs", str(binary)).split()):
            raise ValueError(f"Framework architectures do not cover the app: {binary}")
        for dependency in re.findall(r"^\s+(@rpath/\S+\.framework/\S+)\s+\(",
                                     output("otool", "-L", str(binary)), re.MULTILINE):
            relative = dependency.removeprefix("@rpath/")
            if not (frameworks / relative).is_file():
                raise ValueError(f"Unbundled dependency: {dependency} (from {binary.name})")

    if not allow_unsigned:
        # --deep verifies nested code; it does not sign or modify the app.
        output("codesign", "--verify", "--deep", "--strict", str(app))
    print(f"PASS: {app.name} embeds AMSMB2 and its framework dependencies "
          f"for {', '.join(sorted(app_arches))}; "
          + ("signature check skipped (unsigned build)." if allow_unsigned
             else "app and nested signatures verified."))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Built .app bundle")
    parser.add_argument("--allow-unsigned", action="store_true",
                        help="Packaging-only check for CODE_SIGNING_ALLOWED=NO builds")
    args = parser.parse_args()
    try:
        verify(args.app.resolve(), args.allow_unsigned)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"FAIL: {error}\n")
