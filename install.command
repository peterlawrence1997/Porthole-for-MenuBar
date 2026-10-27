#!/bin/bash

# Get the directory where this script is located
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# Set TMPDIR to a known valid location to avoid Swift compiler issues in some environments
export TMPDIR="/tmp"

echo "----------------------------------------------------------------"
echo "  Porthole for MenuBar - Installer"
echo "----------------------------------------------------------------"
echo ""

# Check for Swift
if ! command -v swift &> /dev/null; then
    echo "Error: Swift is not installed."
    echo "Please install Xcode or the Command Line Tools for Xcode."
    echo "You can try running: xcode-select --install"
    echo ""
    read -p "Press Enter to exit..."
    exit 1
fi

echo "Building and Packaging..."
STAGING_DIR="$(mktemp -d /private/tmp/porthole-install.XXXXXX)"
PORTHOLE_BUNDLE_OUTPUT_DIR="$STAGING_DIR" ./bundle.sh

if [ $? -ne 0 ]; then
    echo "Error: Build failed."
    read -p "Press Enter to exit..."
    exit 1
fi

echo ""
echo "Build successful!"
echo ""

APP_NAME="Porthole - Storage Monitor.app"
BUILT_APP="$STAGING_DIR/$APP_NAME"

if ! codesign --verify --deep "$BUILT_APP"; then
    echo "Error: The packaged app did not pass signature verification."
    read -p "Press Enter to exit..."
    exit 1
fi

# Ask to move to Applications
read -p "Do you want to move the app to your Applications folder? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Moving to /Applications..."
    BACKUP_APP="$STAGING_DIR/previous-$APP_NAME"
    if [ -d "/Applications/${APP_NAME}" ]; then
        if ! mv "/Applications/${APP_NAME}" "$BACKUP_APP"; then
            echo "Error: Could not move the previous app out of /Applications."
            exit 1
        fi
    fi
    if ! mv "$BUILT_APP" /Applications/; then
        echo "Error: Could not install the new app."
        if [ -d "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "/Applications/${APP_NAME}"
        fi
        exit 1
    fi
    echo "Done! You can now find Porthole in your Applications folder."
    if [ -d "$BACKUP_APP" ]; then
        echo "The previous version is backed up at: $BACKUP_APP"
    fi
else
    echo "Okay, the app is located at: $BUILT_APP"
fi

echo ""
echo "Installation Complete!"
read -p "Press Enter to close..."
