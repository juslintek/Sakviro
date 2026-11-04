#!/bin/bash
# Assemble the Apple Help Book inside an app bundle from docs/help — the same
# files GitHub Pages serves, so the help is written exactly once. Called by
# both the Makefile bundle step and scripts/release.sh, BEFORE codesign.
#
#   scripts/assemble-help.sh dist/Parrot.app
set -euo pipefail

APP="${1:?usage: scripts/assemble-help.sh <path/to/Parrot.app>}"
SRC="docs/help"
BOOK="$APP/Contents/Resources/Parrot.help"
LPROJ="$BOOK/Contents/Resources/en.lproj"

rm -rf "$BOOK"
mkdir -p "$LPROJ"
cp "$SRC"/*.html "$SRC"/help.css "$LPROJ/"
cp -R "$SRC/img" "$LPROJ/img"

DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist")
if [ "$DISPLAY_NAME" = "Sakviro" ]; then
  python3 - "$LPROJ" "$DISPLAY_NAME" <<'PYHELP'
from html import escape, unescape
from html.parser import HTMLParser
import re
from pathlib import Path
import sys

class HelpText(HTMLParser):
    def __init__(self, replace_text=True):
        super().__init__(convert_charrefs=False)
        self.parts = []
        self.protected = []
        self.replace_text = replace_text

    def branded_tag(self, tag, attrs):
        original = self.get_starttag_text()
        if self.protected or tag in ('code', 'pre', 'script', 'style'):
            return original
        names = {'alt', 'title', 'aria-label'}
        if tag == 'meta' and dict(attrs).get('name', '').lower() in ('appletitle', 'description'):
            names.add('content')
        def replace_attr(match):
            if match.group(1).lower() not in names:
                return match.group(0)
            value = unescape(match.group(3))
            branded = value.replace('Parrot Exports', '\x00Exports').replace('Parrot', sys.argv[2]).replace('\x00Exports', 'Parrot Exports')
            return match.group(0) if branded == value else match.group(1) + '=' + match.group(2) + escape(branded, quote=True) + match.group(2)
        return re.sub(r"([\w:-]+)\s*=\s*([\"'])(.*?)\2", replace_attr, original, flags=re.DOTALL)

    def handle_starttag(self, tag, attrs):
        self.parts.append(self.branded_tag(tag, attrs))
        if tag in ('code', 'pre', 'script', 'style'):
            self.protected.append(tag)

    def handle_startendtag(self, tag, attrs):
        self.parts.append(self.branded_tag(tag, attrs))

    def handle_endtag(self, tag):
        self.parts.append(f'</{tag}>')
        if self.protected and self.protected[-1] == tag:
            self.protected.pop()

    def handle_data(self, value):
        if self.replace_text and not self.protected and 'github.com/' not in value:
            value = value.replace('Parrot Exports', '\x00Exports').replace('Parrot', sys.argv[2]).replace('\x00Exports', 'Parrot Exports')
        self.parts.append(value)

    def handle_entityref(self, name): self.parts.append(f'&{name};')
    def handle_charref(self, name): self.parts.append(f'&#{name};')
    def handle_comment(self, value): self.parts.append(f'<!--{value}-->')
    def handle_decl(self, value): self.parts.append(f'<!{value}>')
    def handle_pi(self, value): self.parts.append(f'<?{value}>')

for path in Path(sys.argv[1]).glob('*.html'):
    original = path.read_text()
    if path.name == 'hi.html':
        original = original.replace('← Parrot Help', '← Sakviro Help').replace("<h1>Hi, I'm Uygar 👋</h1>", "<p>About the upstream Parrot project:</p>\n<h1>Hi, I'm Uygar 👋</h1>")
        parser = HelpText(replace_text=False)
        parser.feed(original)
        output = ''.join(parser.parts)
    else:
        if path.name == 'privacy.html':
            start = original.index('  <li><strong>Update check:</strong>')
            end = original.index('</li>', start) + len('</li>')
            original = original[:start] + '  <li><strong>Updates:</strong> Automatic update checks are disabled in this build.</li>' + original[end:]
        elif path.name == 'settings.html':
            start = original.index('Updates take care of themselves:')
            end = original.index('There\'s also an "Open User', start)
            original = original[:start] + 'Automatic updates are disabled in this build. ' + original[end:]
            original = original.replace('(that\'s me saying\n<a href="hi.html">hi</a>)', '(<a href="hi.html">about upstream Parrot</a>)')
        elif path.name == 'getting-started.html':
            start = original.index('<p>Grab the latest DMG')
            end = original.index('</p>', start) + len('</p>')
            original = original[:start] + '<p>For source and installation information, visit the <a href="https://github.com/juslintek/Sakviro">Sakviro repository</a>.</p>' + original[end:]
        elif path.name == 'index.html':
            original = original.replace('alt="Parrot\'s meeting list with waveforms"', 'alt="Meeting list with waveforms"')
            original = original.replace('Parrot is free and open source.\n<a href="https://github.com/turantekin/Parrot">', 'Sakviro is based on the open-source Parrot project.\n<a href="https://github.com/turantekin/Parrot">')
        parser = HelpText()
        parser.feed(original)
        output = ''.join(parser.parts).replace('<em>Sakviro</em> list in Reminders', '<em>Parrot</em> list in Reminders')
        output = output.replace('Sakviro is based on the open-source Sakviro project.', 'Sakviro is based on the open-source Parrot project.')
        output = output.replace('about upstream Sakviro', 'about upstream Parrot')
        output = output.replace('Hi from Uygar', 'About upstream Parrot')
        output = output.replace('href="https://github.com/turantekin/Parrot/releases">releases page', 'href="https://github.com/turantekin/Parrot/releases">upstream Parrot releases page')
    if '<img ' in output:
        output = output.replace('<img ', '<p>Screenshots show the upstream Parrot app and may differ from Sakviro.</p>\n<img ', 1)
    path.write_text(output)
PYHELP
fi

# The book's own identity. HPDBookAccessPath is the landing page; the index
# file is what gives the Help menu's search field results from our pages.
cat > "$BOOK/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>com.uygar.parrot.help</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Parrot Help</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>HPDBookAccessPath</key>
	<string>index.html</string>
	<key>HPDBookIndexPath</key>
	<string>Parrot.helpindex</string>
	<key>HPDBookCSIndexPath</key>
	<string>Parrot.cshelpindex</string>
	<key>HPDBookTitle</key>
	<string>Parrot Help</string>
	<key>HPDBookType</key>
	<string>3</string>
</dict>
</plist>
PLIST
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleHelpBookName $BUNDLE_ID.help" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID.help" "$BOOK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME Help" "$BOOK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :HPDBookTitle $DISPLAY_NAME Help" "$BOOK/Contents/Info.plist"

# Build the search indexes Help Viewer queries. Two formats: the default
# typedstream .helpindex for older viewers, and the Core Spotlight index
# modern macOS actually uses — the legacy one can't even be dumped by
# today's hiutil, and anchor jumps (Settings → About) need anchors (-a)
# present in the CS index.
hiutil -Caf "$LPROJ/Parrot.helpindex" "$LPROJ"
hiutil -C -a -I corespotlight -f "$LPROJ/Parrot.cshelpindex" "$LPROJ"

# A built book is useless unless the app's Info.plist points at it: without
# these two keys Help Viewer says "Help isn't available for Parrot" and the
# Settings → About anchor jump opens the generic macOS help instead. They were
# lost once already (7be0c1d), so fail the build rather than ship silently.
for key in CFBundleHelpBookFolder CFBundleHelpBookName; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || {
    echo "assemble-help: $APP/Contents/Info.plist has no $key; the Help menu would say help isn't available" >&2
    exit 1
  }
done

echo "==> help book assembled ($(ls "$LPROJ"/*.html | wc -l | tr -d ' ') pages, indexed)"
