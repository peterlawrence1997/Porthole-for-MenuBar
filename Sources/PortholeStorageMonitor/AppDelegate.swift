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
        }

        setupMenu()
        DiskActivityTracker.shared.start()
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

        DiskActivityTracker.shared.onUpdate = { [weak self] in
            guard let self = self else { return }
            self.rebuildActivityItems()
        }
    }

    @objc func updateDiskSpace() {
        guard let bytes = DiskUtils.getFreeDiskSpaceBytes() else { return }
        let tracker = DiskActivityTracker.shared
        tracker.recordFreeSpace(bytes: bytes)
        let delta = tracker.shouldShowMenuBarArrow() ? tracker.freeSpaceDelta() : nil
        // Number only — the "GB" label lives inside the compact drive icon.
        let text = DiskUtils.formatGB(bytes).replacingOccurrences(of: " GB", with: "")
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            button.attributedTitle = Self.tickerTitle(text: text, delta: delta)
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

    static func tickerTitle(text: String, delta: Int64?) -> NSAttributedString {
        let attributed = NSMutableAttributedString()

        if let delta = delta {
            let arrow = delta > 0 ? "▲ " : "▼ "
            let color: NSColor = delta > 0 ? .systemGreen : .systemRed
            let arrowAttr = NSAttributedString(
                string: arrow,
                attributes: [
                    .foregroundColor: color,
                    .font: NSFont.menuBarFont(ofSize: 0),
                ]
            )
            attributed.append(arrowAttr)
        }

        // Thin space keeps a small gap between the number and the drive icon,
        // which sits to the right of the title (imagePosition = .imageRight).
        let textAttr = NSAttributedString(
            string: text + "\u{2009}",
            attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
        )
        attributed.append(textAttr)

        return attributed
    }

    static func activityRowTitle(name: String, deltaBytes: Int64) -> NSAttributedString {
        let attributed = NSMutableAttributedString()

        let nameAttr = NSAttributedString(
            string: name + " — ",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.menuFont(ofSize: 0),
            ]
        )
        attributed.append(nameAttr)

        let arrow = deltaBytes > 0 ? "▲ " : "▼ "
        let color: NSColor = deltaBytes > 0 ? .systemRed : .systemGreen
        let amount = DiskUtils.formatGB(abs(deltaBytes))

        let amountAttr = NSAttributedString(
            string: arrow + amount,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.menuFont(ofSize: 0),
            ]
        )
        attributed.append(amountAttr)

        return attributed
    }

    func rebuildActivityItems() {
        guard let menu = statusItem.menu else { return }
        for item in menu.items where (90...110).contains(item.tag) { menu.removeItem(item) }
        guard let anchor = menu.items.firstIndex(where: { $0.tag == 3 }) else { return }
        var idx = anchor + 1

        let sep = NSMenuItem.separator()
        sep.tag = 90
        menu.insertItem(sep, at: idx)
        idx += 1

        let header = NSMenuItem(title: "Activity — Last Hour", action: nil, keyEquivalent: "")
        header.tag = 91
        header.isEnabled = false
        menu.insertItem(header, at: idx)
        idx += 1

        switch DiskActivityTracker.shared.topMovers() {
        case nil:
            let placeholder = NSMenuItem(title: "Gathering data…", action: nil, keyEquivalent: "")
            placeholder.tag = 92
            placeholder.isEnabled = false
            menu.insertItem(placeholder, at: idx)
        case let entries? where entries.isEmpty:
            let placeholder = NSMenuItem(title: "No significant activity", action: nil, keyEquivalent: "")
            placeholder.tag = 92
            placeholder.isEnabled = false
            menu.insertItem(placeholder, at: idx)
        case let entries?:
            var tag = 100
            for entry in entries {
                switch entry {
                case .directory(let url, let name, let delta):
                    let item = NSMenuItem(title: "", action: #selector(openActivityDirectory(_:)), keyEquivalent: "")
                    item.tag = tag
                    tag += 1
                    item.target = self
                    item.representedObject = url
                    item.attributedTitle = Self.activityRowTitle(name: name, deltaBytes: delta)
                    menu.insertItem(item, at: idx)
                    idx += 1
                case .remainder(let delta):
                    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    item.tag = 93
                    item.isEnabled = false
                    item.attributedTitle = Self.activityRowTitle(name: "System & other", deltaBytes: delta)
                    menu.insertItem(item, at: idx)
                    idx += 1
                }
            }
        }
    }

    @objc func openActivityDirectory(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
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
        rebuildActivityItems()
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
