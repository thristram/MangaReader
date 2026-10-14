#!/usr/bin/env python3
"""Check source membership and preserved signing/schemes in an isolated generator copy."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
def read_project(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))['objects']
with tempfile.TemporaryDirectory(prefix='generator-', dir=root / '.build') as directory:
    fixture = Path(directory)
    app = fixture / 'apps/apple'
    shutil.copytree(root / 'apps/apple', app, ignore=shutil.ignore_patterns('Local.xcconfig', 'xcuserdata'))
    (fixture / 'scripts').mkdir()
    shutil.copy2(root / 'scripts/generate-xcode-project.py', fixture / 'scripts/generate-xcode-project.py')
    project = app / 'MangaReader.xcodeproj/project.pbxproj'
    before = read_project(project)
    schemes = {p.name: p.read_bytes() for p in (project.parent / 'xcshareddata/xcschemes').glob('*.xcscheme')}
    subprocess.run(['python3', str(fixture / 'scripts/generate-xcode-project.py')], check=True, stdout=subprocess.DEVNULL)
    after = read_project(project)
    actual = {o['path'] for o in after.values() if o['isa'] == 'PBXFileReference' and o.get('path', '').endswith('.swift')}
    expected = {p.relative_to(app).as_posix() for p in app.rglob('*.swift') if '.build' not in p.relative_to(app).parts}
    assert actual == expected and 'Shared/LibraryShell.swift' in actual, 'source membership must work below .build'
    for key, original in before.items():
        if original['isa'] == 'XCBuildConfiguration':
            assert all(after[key]['buildSettings'].get(k) == v for k, v in original.get('buildSettings', {}).items()), 'existing build/signing settings changed'
    assert schemes == {p.name: p.read_bytes() for p in (project.parent / 'xcshareddata/xcschemes').glob('*.xcscheme')}, 'user scheme changed'
    assert len([o for o in after.values() if o['isa'] == 'PBXCopyFilesBuildPhase' and o.get('name') == 'Embed Frameworks']) == 2
    once = project.read_bytes()
    subprocess.run(['python3', str(fixture / 'scripts/generate-xcode-project.py')], check=True, stdout=subprocess.DEVNULL)
    assert once == project.read_bytes(), 'generator is not stable'
print('PASS: SwiftUI source membership, stable generation, signing settings/schemes and both embedded-framework phases.')
