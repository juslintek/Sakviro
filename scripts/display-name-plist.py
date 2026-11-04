#!/usr/bin/env python3
import plistlib
import sys

path, name = sys.argv[1:]
with open(path, 'rb') as source:
    plist = plistlib.load(source)
for key in ('NSMicrophoneUsageDescription', 'NSScreenCaptureUsageDescription',
            'NSAudioCaptureUsageDescription', 'NSRemindersFullAccessUsageDescription',
            'NSCalendarsFullAccessUsageDescription'):
    plist[key] = plist[key].replace('$(PRODUCT_DISPLAY_NAME)', name)
for entry, key in ((plist['CFBundleDocumentTypes'][0], 'CFBundleTypeName'),
                   (plist['UTExportedTypeDeclarations'][0], 'UTTypeDescription')):
    entry[key] = entry[key].replace('$(PRODUCT_DISPLAY_NAME)', name)
with open(path, 'wb') as target:
    plistlib.dump(plist, target, sort_keys=False)
