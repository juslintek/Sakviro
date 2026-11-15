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
from html import unescape
import plistlib
import re
import sys

app = Path(sys.argv[1])
book = app / 'Contents/Resources/Parrot.help'
pages = book / 'Contents/Resources/en.lproj'
index = (pages / 'index.html').read_text()
privacy = (pages / 'privacy.html').read_text()
setup = (pages / 'copilot-setup.html').read_text()
plain = lambda html: re.sub(r'\s+', ' ', unescape(re.sub(r'<[^>]+>', ' ', html))).strip()
index_text, privacy_text, setup_text = map(plain, (index, privacy, setup))
assert all(value in index_text for value in ('Sakviro Help', 'Audio, transcription and transcript polish stay on your Mac', 'signed-in assistant CLI connections', 'receive meeting text and relevant context', 'frames from your selected window'))
assert all(value in privacy_text for value in ('Audio recordings are saved on your Mac', 'backups or file sharing can copy them elsewhere', 'Transcription and transcript polish run with on-device models', 'Meeting text, matched knowledge base snippets', 'selected-window images can go too', 'not the whole video recording', 'Account connections are held, including requests with images', 'webhooks are blocked'))
assert 'never uploaded anywhere by anything' not in privacy_text
assert all(value in setup_text for value in ('sign in through that CLI', 'Gemini and custom CLI connections support text only', 'Images are sent only when screen context is allowed', 'Audio, transcription and transcript polish stay on this Mac', 'account connections stay selected but are held'))
assert 'href="https://github.com/turantekin/Parrot"' in index
source = Path('docs/help/privacy.html').read_text()
assert re.findall(r'<code>.*?</code>', source, re.S) == re.findall(r'<code>.*?</code>', privacy, re.S)
assert all(value in privacy for value in ('Calendar invites', 'Webhook:'))
with (book / 'Contents/Info.plist').open('rb') as plist:
    metadata = plistlib.load(plist)
with (app / 'Contents/Info.plist').open('rb') as plist:
    app_metadata = plistlib.load(plist)
assert metadata['CFBundleIdentifier'] == app_metadata['CFBundleHelpBookName'] == 'com.linas.parrot.assistant.help'
assert metadata['CFBundleName'] == metadata['HPDBookTitle'] == 'Sakviro Help'
print('Sakviro Help assembly checks passed')
PY
