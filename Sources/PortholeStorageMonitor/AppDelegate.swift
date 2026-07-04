import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
            button.imagePosition = .imageRight
            button.imageEdgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        }

        setupMenu()
        updateDiskSpace()

        // Update every 60 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            self.updateDiskSpace()
        }
    }

    /// Loads the compact disk-drive glyph as a template image so AppKit tints it
    /// automatically for light/dark mode, selection, and wallpaper tinting.
    static func makeMenuBarIcon() -> NSImage? {
        // Bundle.main.Resources is where the packaged .app ships the icon (see bundle.sh);
        // Bundle.module covers `swift run` during local development.
        let url = Bundle.main.url(forResource: "CompactIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "CompactIcon", withExtension: "png")
        guard let url, let icon = NSImage(contentsOf: url) else { return nil }

        let height: CGFloat = 18
        let width = height * (icon.size.width / icon.size.height)
        icon.size = NSSize(width: width, height: height)
        icon.isTemplate = true
        return icon
    }

    func setupMenu() {
        let menu = NSMenu()

        let trashItem = NSMenuItem(
            title: "Calculating...", action: #selector(showEmptyTrashAlert), keyEquivalent: "")
        trashItem.tag = 1
        menu.addItem(trashItem)

        let restartSavingsItem = NSMenuItem(
            title: "Restart Savings — Calculating...", action: nil, keyEquivalent: "")
        restartSavingsItem.tag = 2
        restartSavingsItem.isEnabled = false  // Informational only
        menu.addItem(restartSavingsItem)

        let downloadsItem = NSMenuItem(
            title: "Downloads — Calculating...", action: #selector(openDownloadsFolder),
            keyEquivalent: "")
        downloadsItem.tag = 3
        menu.addItem(downloadsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        // Update the menu item text when the menu is about to open
        menu.delegate = self
    }

    @objc func updateDiskSpace() {
        let freeSpace = DiskUtils.getFreeDiskSpace()
        let numberOnly = freeSpace.replacingOccurrences(of: " GB", with: "")
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                button.title = numberOnly
            }
        }
    }

    @objc func showEmptyTrashAlert() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash & Purgeable?"
        alert.informativeText =
            "Are you sure you want to continue emptying trash / removing purgeable files?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            DiskUtils.emptyTrash()
            // Refresh stats after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.updateTrashMenuItem()
                self.updateDiskSpace()
            }
        }
    }

    @objc func openDownloadsFolder() {
        DownloadsMonitor.shared.openDownloadsFolder()
    }

    func updateTrashMenuItem() {
        guard let menu = statusItem.menu, let item = menu.item(withTag: 1) else { return }
        let size = DiskUtils.getTrashAndPurgeableSize()
        item.title = "Trash + Purgeable: \(size)"
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateTrashMenuItem()
        updateRestartSavingsItem()
        updateDownloadsItem()
    }

    func updateRestartSavingsItem() {
        guard let menu = statusItem.menu, let item = menu.item(withTag: 2) else { return }

        // Get current estimate (returns "Calculating..." or cached value)
        let estimate = RestartSavingsEstimator.shared.getEstimatedSavings()
        item.title = "Restart Savings — \(estimate)"

        // If it was calculating, the callback will update it later
        RestartSavingsEstimator.shared.onUpdate = { [weak self] newValue in
            DispatchQueue.main.async {
                guard let self = self, let menu = self.statusItem.menu,
                    let item = menu.item(withTag: 2)
                else { return }
                item.title = "Restart Savings — \(newValue)"
            }
        }
    }

    func updateDownloadsItem() {
        guard let menu = statusItem.menu, let item = menu.item(withTag: 3) else { return }

        let size = DownloadsMonitor.shared.getDownloadsSize()
        item.title = "Downloads — \(size)"

        DownloadsMonitor.shared.onUpdate = { [weak self] newValue in
            DispatchQueue.main.async {
                guard let self = self, let menu = self.statusItem.menu,
                    let item = menu.item(withTag: 3)
                else { return }
                item.title = "Downloads — \(newValue)"
            }
        }
    }
}
