import Cocoa
import QuartzCore
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let daisyDiskURL = URL(fileURLWithPath: "/Applications/DaisyDisk.app")
    private static let storageSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.Storage")!

    var statusItem: NSStatusItem!
    var timer: Timer?
    private var hoverTimer: Timer?
    private var diskIcon: NSImage?
    private var memoryIcon: NSImage?
    private var diskText: String?
    private var diskDelta: Int64?
    private var memorySnapshot: MemorySnapshot?
    private var memoryHistory: [(date: Date, usedBytes: UInt64)] = []
    private var showingMemory = false
    private var isHoveringStatusItem = false
    private var hoverShowingMemory: Bool?
    private var displayedMemory: Bool?
    private var statusItemWidth: CGFloat = 0

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        diskIcon = Self.makeMenuBarIcon(named: "CompactIcon")
        memoryIcon = Self.makeMenuBarIcon(named: "CompactRAMIcon")

        if let button = statusItem.button {
            button.wantsLayer = true
            button.image = diskIcon
            button.imagePosition = .imageRight
        }

        setupMenu()
        DiskActivityTracker.shared.start()
        updateDiskSpace()
        updateMemory()

        // Status bar buttons don't reliably deliver tracking-area events while
        // the app is inactive. Poll the pointer against the button's screen rect.
        let hoverTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateHoverState()
        }
        self.hoverTimer = hoverTimer
        RunLoop.main.add(hoverTimer, forMode: .common)

        // Refresh both readings and alternate the compact menu bar display.
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            self.showingMemory.toggle()
            self.updateDiskSpace()
            self.updateMemory()
        }
    }

    /// Loads the compact disk-drive glyph as a template image so AppKit tints it
    /// automatically for light/dark mode, selection, and wallpaper tinting.
    static func makeMenuBarIcon(named name: String) -> NSImage? {
        // Bundle.main.Resources is where the packaged .app ships the icon (see bundle.sh);
        // Bundle.module covers `swift run` during local development.
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let icon = NSImage(contentsOf: url) else { return nil }

        let height: CGFloat = 18
        let width = height * (icon.size.width / icon.size.height)
        icon.size = NSSize(width: width, height: height)
        icon.isTemplate = true
        return icon
    }

    func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let diskItem = NSMenuItem(title: "Disk Available — Calculating…", action: nil, keyEquivalent: "")
        diskItem.tag = 4
        diskItem.image = Self.menuSymbol("internaldrive", description: "Disk")
        diskItem.toolTip = "Free space on the startup disk. The arrow shows whether available space has risen or fallen over the last hour; this is not the same as total disk activity."
        menu.addItem(diskItem)

        let memoryItem = NSMenuItem(title: "RAM Used — Calculating…", action: nil, keyEquivalent: "")
        memoryItem.tag = 5
        memoryItem.image = Self.menuSymbol("memorychip", description: "Memory")
        memoryItem.toolTip = "Active, wired, and compressed memory in use. macOS can reclaim inactive and cached memory as needed. The arrow compares readings from the last 10 minutes."
        menu.addItem(memoryItem)

        let pressureItem = NSMenuItem(title: "Memory Pressure — Calculating…", action: nil, keyEquivalent: "")
        pressureItem.tag = 6
        pressureItem.image = Self.menuSymbol("waveform.path.ecg", description: "Memory pressure")
        pressureItem.toolTip = "Memory pressure reflects how comfortably macOS can meet memory demand; it is more useful than RAM usage alone."
        menu.addItem(pressureItem)

        menu.addItem(NSMenuItem.separator())

        let trashItem = NSMenuItem(
            title: "Calculating...", action: #selector(showEmptyTrashAlert), keyEquivalent: "")
        trashItem.tag = 1
        trashItem.toolTip =
            "Combined size of Trash and macOS purgeable space (local Time Machine snapshots and other system-managed data). Click to empty Trash and purgeable space."
        menu.addItem(trashItem)

        let restartSavingsItem = NSMenuItem(
            title: "Restart Savings — Calculating...", action: nil, keyEquivalent: "")
        restartSavingsItem.tag = 2
        restartSavingsItem.image = Self.menuSymbol("arrow.clockwise", description: "Restart")
        restartSavingsItem.toolTip =
            "Estimated space a restart would free: old system caches, temp files, OS update payloads, and saved app state that are safe to clear after a reboot. This is a different, narrower estimate than Trash + Purgeable above."
        menu.addItem(restartSavingsItem)

        menu.addItem(NSMenuItem.separator())

        let diskUsageToolItem = NSMenuItem(
            title: "", action: #selector(openDiskUsageTool), keyEquivalent: "")
        diskUsageToolItem.tag = 3
        diskUsageToolItem.target = self
        menu.addItem(diskUsageToolItem)
        updateDiskUsageToolMenuItem(diskUsageToolItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let credit = NSMenuItem(
            title: "Porthole v\(version) (\(build)) · by Peter Lawrence", action: nil,
            keyEquivalent: "")
        credit.image = Self.menuSymbol("info.circle", description: "About Porthole")
        credit.attributedTitle = NSAttributedString(
            string: credit.title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        credit.toolTip = "Porthole for MenuBar, by Peter Lawrence. Version \(version), build \(build)."
        menu.addItem(credit)

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
        diskDelta = tracker.shouldShowMenuBarArrow() ? tracker.freeSpaceDelta() : nil
        // Number only — the "GB" label lives inside the compact drive icon.
        diskText = DiskUtils.formatGB(bytes).replacingOccurrences(of: " GB", with: "")
        let freeDelta = tracker.freeSpaceDelta()
        Self.setTrendTitle(
            on: statusItem.menu?.item(withTag: 4),
            text: "Disk Available — \(DiskUtils.formatGB(bytes))",
            delta: freeDelta, risingIsGood: true)
        statusItem.menu?.item(withTag: 4)?.toolTip =
            "Free space on the startup disk. "
            + Self.trendExplanation(delta: freeDelta, metric: "Available space", window: "last hour")
            + " Green means more free space; red means less."
        refreshStatusItem()
    }

    func updateMemory() {
        memorySnapshot = MemoryUtils.currentSnapshot()
        if let snapshot = memorySnapshot {
            recordMemory(usedBytes: snapshot.usedBytes)
            let used = MemoryUtils.formatGB(snapshot.usedBytes)
            let total = MemoryUtils.formatGB(snapshot.totalBytes)
            Self.setTrendTitle(
                on: statusItem.menu?.item(withTag: 5),
                text: "RAM Used — \(used) / \(total) (\(snapshot.usedPercentage)%)",
                delta: memoryDelta(), risingIsGood: false)
            statusItem.menu?.item(withTag: 5)?.toolTip =
                "Active, wired, and compressed RAM in use; cached RAM is reclaimable. "
                + Self.trendExplanation(
                    delta: memoryDelta(), metric: "RAM use", window: "last 10 minutes")
                + " Memory pressure below is the better indicator of whether you need to act."
            Self.setPressureTitle(on: statusItem.menu?.item(withTag: 6), pressure: snapshot.pressure)
            statusItem.menu?.item(withTag: 6)?.toolTip = Self.pressureExplanation(snapshot.pressure)
        } else {
            statusItem.menu?.item(withTag: 5)?.title = "RAM Used — Unavailable"
            statusItem.menu?.item(withTag: 6)?.title = "Memory Pressure — Unavailable"
        }
        refreshStatusItem()
    }

    private func recordMemory(usedBytes: UInt64) {
        let now = Date()
        if let last = memoryHistory.last, now.timeIntervalSince(last.date) < 30 { return }
        memoryHistory.append((now, usedBytes))
        memoryHistory.removeAll { now.timeIntervalSince($0.date) > 11 * 60 }
    }

    private func memoryDelta() -> Int64? {
        guard let newest = memoryHistory.last,
            let oldest = memoryHistory.first,
            newest.date.timeIntervalSince(oldest.date) >= 60
        else { return nil }
        let baseline = memoryHistory.last {
            newest.date.timeIntervalSince($0.date) >= 10 * 60
        } ?? oldest
        return Int64(newest.usedBytes) - Int64(baseline.usedBytes)
    }

    private static func setTrendTitle(
        on item: NSMenuItem?, text: String, delta: Int64?, risingIsGood: Bool
    ) {
        guard let item else { return }
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let delta, abs(delta) >= 100_000_000 {
            let arrow = delta > 0 ? "  ↑" : "  ↓"
            let color: NSColor = (risingIsGood == (delta > 0)) ? .systemGreen : .systemRed
            title.append(NSAttributedString(
                string: arrow, attributes: [.font: font, .foregroundColor: color]))
        }
        item.attributedTitle = title
    }

    private static func trendExplanation(delta: Int64?, metric: String, window: String) -> String {
        guard let delta, abs(delta) >= 100_000_000 else {
            return "No significant change measured yet in the \(window)."
        }
        let direction = delta > 0 ? "rose" : "fell"
        return "\(metric) \(direction) by \(DiskUtils.formatGB(abs(delta))) over the \(window)."
    }

    private static func setPressureTitle(on item: NSMenuItem?, pressure: MemorySnapshot.Pressure) {
        guard let item else { return }
        let color: NSColor
        switch pressure {
        case .normal: color = .systemGreen
        case .warning: color = .systemOrange
        case .critical: color = .systemRed
        case .unavailable: color = .secondaryLabelColor
        }
        let title = NSMutableAttributedString(
            string: "Memory Pressure — ",
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ])
        title.append(NSAttributedString(
            string: pressure.rawValue,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: color]))
        item.attributedTitle = title
    }

    private static func pressureExplanation(_ pressure: MemorySnapshot.Pressure) -> String {
        switch pressure {
        case .normal:
            return "Normal: macOS has enough memory for current demand. High RAM use alone is not a problem when pressure is normal."
        case .warning:
            return "Warning: macOS is working harder to meet memory demand. You may notice slowdowns; closing memory-heavy apps can help."
        case .critical:
            return "Critical: memory demand is high and performance may be affected. Consider closing memory-heavy apps."
        case .unavailable:
            return "macOS did not provide a memory-pressure reading. RAM usage is still shown above."
        }
    }

    private static func menuSymbol(_ name: String, description: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let diskTitle = Self.tickerTitle(text: diskText ?? "—", delta: diskDelta)
        let memoryTitle = memorySnapshot.map { snapshot in
            Self.tickerTitle(
                text: MemoryUtils.formatGB(snapshot.usedBytes).replacingOccurrences(of: " GB", with: ""),
                delta: nil)
        }

        // Reserve the larger of the two current readings so hover doesn't
        // resize the hit area, but release space when an old trend arrow clears.
        let widestTitle = max(diskTitle.size().width, memoryTitle?.size().width ?? 0)
        let widestIcon = max(diskIcon?.size.width ?? 0, memoryIcon?.size.width ?? 0)
        let requiredWidth = ceil(widestTitle + widestIcon + 6)
        if requiredWidth != statusItemWidth {
            statusItemWidth = requiredWidth
            statusItem.length = requiredWidth
        }

        let wantsMemory = (hoverShowingMemory ?? showingMemory) && memorySnapshot != nil
        if let displayedMemory, displayedMemory != wantsMemory,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = .fromTop
            transition.duration = 0.22
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.layer?.add(transition, forKey: "metricReel")
        }
        displayedMemory = wantsMemory

        if wantsMemory,
            let snapshot = memorySnapshot,
            let memoryTitle = memoryTitle
        {
            button.image = memoryIcon
            button.attributedTitle = memoryTitle
            button.toolTip = "RAM used: \(MemoryUtils.formatGB(snapshot.usedBytes)) of \(MemoryUtils.formatGB(snapshot.totalBytes)) (\(snapshot.usedPercentage)%). \(Self.pressureExplanation(snapshot.pressure))"
        } else {
            button.image = diskIcon
            button.attributedTitle = diskTitle
            button.toolTip = diskText.map {
                "Startup disk available: \($0) GB. "
                    + Self.trendExplanation(
                        delta: DiskActivityTracker.shared.freeSpaceDelta(),
                        metric: "Available space", window: "last hour")
            } ?? "Startup disk space is unavailable."
        }
    }

    private func updateHoverState() {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let isHovering = buttonRect.contains(NSEvent.mouseLocation)
        guard isHovering != isHoveringStatusItem else { return }

        isHoveringStatusItem = isHovering
        hoverShowingMemory = isHovering && memorySnapshot != nil ? !showingMemory : nil
        refreshStatusItem()
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
        guard let anchor = menu.items.firstIndex(where: { $0.tag == 2 }) else { return }
        var idx = anchor + 1

        let sep = NSMenuItem.separator()
        sep.tag = 90
        menu.insertItem(sep, at: idx)
        idx += 1

        let header = NSMenuItem(title: "Activity — Last Hour", action: nil, keyEquivalent: "")
        header.tag = 91
        header.isEnabled = false
        header.toolTip =
            "Net change in folder sizes over the last hour, ranked by size. Red means a folder grew (using space); green means it shrank (freeing space)."
        menu.insertItem(header, at: idx)
        idx += 1

        switch DiskActivityTracker.shared.topMovers() {
        case nil:
            let placeholder = NSMenuItem(title: "Gathering data…", action: nil, keyEquivalent: "")
            placeholder.tag = 92
            placeholder.isEnabled = false
            placeholder.toolTip =
                "Porthole needs a bit more history before it can show hourly changes. Check back shortly."
            menu.insertItem(placeholder, at: idx)
        case let entries? where entries.isEmpty:
            let placeholder = NSMenuItem(title: "No significant activity", action: nil, keyEquivalent: "")
            placeholder.tag = 92
            placeholder.isEnabled = false
            placeholder.toolTip =
                "No tracked folder changed by more than 100 MB in the last hour."
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
                    let direction = delta > 0 ? "grew" : "shrank"
                    item.toolTip =
                        "\(name) \(direction) by \(DiskUtils.formatGB(abs(delta))) in the last hour. Click to open this folder in Finder."
                    menu.insertItem(item, at: idx)
                    idx += 1
                case .remainder(let delta):
                    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    item.tag = 93
                    item.isEnabled = false
                    item.attributedTitle = Self.activityRowTitle(name: "System & other", deltaBytes: delta)
                    item.toolTip =
                        "Estimated change across everything not individually tracked (e.g. app support files, system data) over the last hour."
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

    @objc func openDiskUsageTool() {
        if FileManager.default.fileExists(atPath: Self.daisyDiskURL.path) {
            NSWorkspace.shared.open(Self.daisyDiskURL)
        } else {
            NSWorkspace.shared.open(Self.storageSettingsURL)
        }
    }

    func updateDiskUsageToolMenuItem(_ item: NSMenuItem? = nil) {
        guard let item = item ?? statusItem.menu?.item(withTag: 3) else { return }

        if FileManager.default.fileExists(atPath: Self.daisyDiskURL.path) {
            item.title = "Open DaisyDisk"
            item.toolTip = "Launch DaisyDisk to inspect disk usage."
        } else {
            item.title = "Open Storage Settings"
            item.toolTip = "Open macOS Storage Settings to inspect disk usage."
        }
    }

    func updateTrashMenuItem() {
        guard let menu = statusItem.menu, let item = menu.item(withTag: 1) else { return }
        let size = DiskUtils.getTrashAndPurgeableSize()
        item.title = "Trash + Purgeable — \(size)"
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMemory()
        updateTrashMenuItem()
        updateRestartSavingsItem()
        updateDiskUsageToolMenuItem()
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
}
