# Porthole - Storage Monitor

A simple macOS menu bar application that displays available disk space and RAM usage.

## Features

- Shows available disk space and RAM used in the menu bar, alternating once per minute.
- Hover over the menu bar item to temporarily peek at the other metric.
- Keeps disk space, RAM used/total, and macOS memory pressure visible together in the menu.
- Hover over RAM Used in the menu for the five processes using the most resident memory.
- Opens DaisyDisk from the menu when installed, or macOS Storage Settings otherwise.

RAM used is estimated from active, wired, and compressed memory. Memory pressure is the
system's current Normal, Warning, or Critical level; it is not the percentage of RAM used.

## How to Install

Since this is a custom app shared directly, you'll need to build it once on your machine. Don't worry, it's automated!

1. **Unzip** the folder if you haven't already.
2. Double-click the **`install.command`** file.
   - *Note: If it says it can't be opened because it's from an unidentified developer, right-click (or Control-click) the file and select "Open", then click "Open" in the dialog.*
3. A terminal window will open and build the app.
4. Follow the prompts to move the app to your **Applications** folder.

## Requirements

- macOS
- **Xcode Command Line Tools** (The script will let you know if you need them. Usually, running `xcode-select --install` in Terminal fixes this).

## Usage

- Launch **DiskSpaceApp** from your Applications folder.
- Look for the hard drive icon in your menu bar.
- Click it to see available space or clean up trash.
