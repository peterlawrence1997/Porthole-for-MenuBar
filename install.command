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
./bundle.sh

if [ $? -ne 0 ]; then
    echo "Error: Build failed."
    read -p "Press Enter to exit..."
    exit 1
fi

echo ""
echo "Build successful!"
echo ""

APP_NAME="Porthole - Storage Monitor.app"

# Ask to move to Applications
read -p "Do you want to move the app to your Applications folder? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Moving to /Applications..."
    # Remove existing if present
    if [ -d "/Applications/${APP_NAME}" ]; then
        rm -rf "/Applications/${APP_NAME}"
    fi
    mv "${APP_NAME}" /Applications/
    echo "Done! You can now find Porthole in your Applications folder."
else
    echo "Okay, the app is located in this folder: ${DIR}/${APP_NAME}"
fi

echo ""
echo "Installation Complete!"
read -p "Press Enter to close..."
