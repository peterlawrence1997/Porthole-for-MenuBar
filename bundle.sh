#!/bin/bash

# Set TMPDIR to a known valid location to avoid Swift compiler issues in some environments
export TMPDIR="/tmp"

APP_NAME="Porthole - Storage Monitor"
EXECUTABLE_NAME="PortholeStorageMonitor"
APP_BUNDLE="${APP_NAME}.app"
ICON_SCRIPT="generate_icon.swift"

echo "Building ${APP_NAME}..."
swift build -c release

echo "Creating App Bundle Structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "Copying Executable..."
cp ".build/release/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/"

echo "Copying Menu Bar Icon..."
cp "Sources/PortholeStorageMonitor/Resources/CompactIcon.png" "${APP_BUNDLE}/Contents/Resources/"

echo "Copying Info.plist..."
cp "Info.plist" "${APP_BUNDLE}/Contents/"

echo "Generating Icon..."
swift "${ICON_SCRIPT}"

echo "Creating Iconset..."
mkdir -p DiskSpaceApp.iconset
sips -z 16 16     AppIcon.png --out DiskSpaceApp.iconset/icon_16x16.png
sips -z 32 32     AppIcon.png --out DiskSpaceApp.iconset/icon_16x16@2x.png
sips -z 32 32     AppIcon.png --out DiskSpaceApp.iconset/icon_32x32.png
sips -z 64 64     AppIcon.png --out DiskSpaceApp.iconset/icon_32x32@2x.png
sips -z 128 128   AppIcon.png --out DiskSpaceApp.iconset/icon_128x128.png
sips -z 256 256   AppIcon.png --out DiskSpaceApp.iconset/icon_128x128@2x.png
sips -z 256 256   AppIcon.png --out DiskSpaceApp.iconset/icon_256x256.png
sips -z 512 512   AppIcon.png --out DiskSpaceApp.iconset/icon_256x256@2x.png
sips -z 512 512   AppIcon.png --out DiskSpaceApp.iconset/icon_512x512.png
sips -z 1024 1024 AppIcon.png --out DiskSpaceApp.iconset/icon_512x512@2x.png

echo "Converting to .icns..."
iconutil -c icns DiskSpaceApp.iconset
cp DiskSpaceApp.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "Cleaning up..."
rm AppIcon.png
rm -rf DiskSpaceApp.iconset
rm DiskSpaceApp.icns

echo "Signing App Bundle..."
xattr -cr "${APP_BUNDLE}"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Done! ${APP_BUNDLE} created."
