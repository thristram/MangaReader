#!/usr/bin/env python3
"""Export the editable mock using the preserved standalone preview shell."""
from pathlib import Path
import html, re
root=Path(__file__).resolve().parents[1]
source=(root/'docs/mock/manga-ui.fragment.html').read_text()
if len(source.encode())>1_000_000:raise SystemExit('Mock exceeds 1 MB')
if re.search(r'<(?:!doctype|html|head|body)\b',source,re.I):raise SystemExit('Expected an HTML fragment')
# The preserved mock uses only state storage; no external app/account requests.
for api in re.findall(r'window\.openai(?:\?\.|\.)(\w+)',source):
 if api not in {'widgetState','setWidgetState'}:raise SystemExit('Host-only API must be removed before export: '+api)
shell=(root/'scripts/mock-preview-shell.html').read_text()
assert shell.count('__MANGA_MOCK_FRAGMENT__')==1
(root/'docs/mock/index.html').write_text(shell.replace('__MANGA_MOCK_FRAGMENT__',html.escape(source.strip(),quote=True)))
print('Updated docs/mock/index.html')
