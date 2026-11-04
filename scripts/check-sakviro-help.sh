#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sakviro-help.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
app="$tmpdir/Sakviro.app"
mkdir -p "$app/Contents"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleDisplayName</key><string>Sakviro</string><key>CFBundleIdentifier</key><string>com.linas.parrot.assistant</string><key>CFBundleHelpBookName</key><string>placeholder</string><key>CFBundleHelpBookFolder</key><string>Parrot.help</string></dict></plist>
PLIST
python3 - "$app" <<'PY'
import hashlib
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1])
sources = list(Path('docs/help').glob('*.html'))
before = {p: hashlib.sha256(p.read_bytes()).digest() for p in sources}
subprocess.run(['scripts/assemble-help.sh', str(app)], check=True)
assert before == {p: hashlib.sha256(p.read_bytes()).digest() for p in sources}
PY
python3 - "$app" <<'PY'
from pathlib import Path
import plistlib
import re
import sys

app = Path(sys.argv[1])
book = app / 'Contents/Resources/Parrot.help'
pages = book / 'Contents/Resources/en.lproj'
index = (pages / 'index.html').read_text()
privacy = (pages / 'privacy.html').read_text()
setup = (pages / 'copilot-setup.html').read_text()
assert all(value in index for value in ('Sakviro Help', 'CLI account', 'selected window', 'audio goes'))
assert all(value in privacy for value in ('CLI accounts:', 'selected-window frames', 'Cloud polish sends audio', 'on-device-only mode blocks'))
assert 'never uploaded\n  anywhere by anything' not in privacy
assert 'signed-in CLI account' in setup
assert 'href="https://github.com/turantekin/Parrot"' in index
source = Path('docs/help/privacy.html').read_text()
assert re.findall(r'<code>.*?</code>', source, re.S) == re.findall(r'<code>.*?</code>', privacy, re.S)
assert all(value in privacy for value in ('TypeSafe AI', 'Calendar invites', 'Webhook:'))
with (book / 'Contents/Info.plist').open('rb') as plist:
    metadata = plistlib.load(plist)
with (app / 'Contents/Info.plist').open('rb') as plist:
    app_metadata = plistlib.load(plist)
assert metadata['CFBundleIdentifier'] == app_metadata['CFBundleHelpBookName'] == 'com.linas.parrot.assistant.help'
assert metadata['CFBundleName'] == metadata['HPDBookTitle'] == 'Sakviro Help'
print('Sakviro Help assembly checks passed')
PY
