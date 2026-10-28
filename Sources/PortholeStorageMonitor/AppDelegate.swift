import Cocoa
import QuartzCore
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private static var mainColumnEdge: CGFloat = 220
    private static var lockedColumnEdges: [ObjectIdentifier: CGFloat] = [:]
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
    private var processMemoryMenu: NSMenu?
    private var isRefreshingProcesses = false
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

        let diskItem = NSMenuItem(title: "Disk Available", action: nil, keyEquivalent: "")
        diskItem.tag = 4
        diskItem.attributedTitle = Self.menuColumns(label: "Disk Available", value: "Calculating…")
        diskItem.image = Self.menuSymbol("internaldrive", description: "Disk")
        diskItem.toolTip = "Free space on the startup disk. The arrow shows whether available space has risen or fallen over the last hour; this is not the same as total disk activity."
        menu.addItem(diskItem)

        let memoryItem = NSMenuItem(title: "RAM Used", action: nil, keyEquivalent: "")
        memoryItem.tag = 5
        memoryItem.attributedTitle = Self.menuColumns(label: "RAM Used", value: "Calculating…")
        memoryItem.image = Self.menuSymbol("memorychip", description: "Memory")
        memoryItem.toolTip = "Active, wired, and compressed memory in use. macOS can reclaim inactive and cached memory as needed. The arrow compares readings from the last 10 minutes."
        let processMenu = NSMenu(title: "Top RAM Processes")
        processMenu.autoenablesItems = false
        processMenu.addItem(NSMenuItem(
            title: "Gathering process memory…", action: nil, keyEquivalent: ""))
        memoryItem.submenu = processMenu
        processMemoryMenu = processMenu
        menu.addItem(memoryItem)

        let pressureItem = NSMenuItem(title: "Memory Pressure", action: nil, keyEquivalent: "")
        pressureItem.tag = 6
        pressureItem.attributedTitle = Self.menuColumns(label: "Memory Pressure", value: "Calculating…")
        pressureItem.image = Self.menuSymbol("waveform.path.ecg", description: "Memory pressure")
        pressureItem.toolTip = "Memory pressure reflects how comfortably macOS can meet memory demand; it is more useful than RAM usage alone."
        menu.addItem(pressureItem)

        menu.addItem(NSMenuItem.separator())

        let trashItem = NSMenuItem(
            title: "Trash + Purgeable", action: #selector(showEmptyTrashAlert), keyEquivalent: "")
        trashItem.tag = 1
        trashItem.attributedTitle = Self.menuColumns(label: "Trash + Purgeable", value: "Calculating…")
        trashItem.toolTip =
            "Combined size of Trash and macOS purgeable space (local Time Machine snapshots and other system-managed data). Click to empty Trash and purgeable space."
        menu.addItem(trashItem)

        let restartSavingsItem = NSMenuItem(
            title: "Restart Savings", action: nil, keyEquivalent: "")
        restartSavingsItem.tag = 2
        restartSavingsItem.attributedTitle = Self.menuColumns(label: "Restart Savings", value: "Calculating…")
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
                title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let credit = NSMenuItem(
            title: "Porthole v\(version) (\(build))", action: nil,
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
            label: "Disk Available", value: DiskUtils.formatGB(bytes),
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
            let total = MemoryUtils.formatCapacity(snapshot.totalBytes)
            Self.setTrendTitle(
                on: statusItem.menu?.item(withTag: 5),
                label: "RAM Used",
                value: "\(used) / \(total)",
                delta: memoryDelta(), risingIsGood: false)
            statusItem.menu?.item(withTag: 5)?.toolTip =
                "Active, wired, and compressed RAM in use; cached RAM is reclaimable. "
                + Self.trendExplanation(
                    delta: memoryDelta(), metric: "RAM use", window: "last 10 minutes")
                + " Memory pressure below is the better indicator of whether you need to act."
            Self.setPressureTitle(on: statusItem.menu?.item(withTag: 6), pressure: snapshot.pressure)
            statusItem.menu?.item(withTag: 6)?.toolTip = Self.pressureExplanation(snapshot.pressure)
        } else {
            statusItem.menu?.item(withTag: 5)?.attributedTitle =
                Self.menuColumns(label: "RAM Used", value: "Unavailable")
            statusItem.menu?.item(withTag: 6)?.attributedTitle =
                Self.menuColumns(label: "Memory Pressure", value: "Unavailable")
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

    private static func menuColumns(
        label: String, value: String, valueColor: NSColor = .labelColor,
        rightEdge: CGFloat? = nil
    ) -> NSMutableAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: rightEdge ?? mainColumnEdge, options: [:])]
        style.defaultTabInterval = 0
        style.lineBreakMode = .byTruncatingMiddle
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(
            string: label + "\t",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ])
        title.append(NSAttributedString(
            string: value,
            attributes: [
                .font: font,
                .foregroundColor: valueColor,
                .paragraphStyle: style,
            ]))
        return title
    }

    private static func fitColumns(in menu: NSMenu?) {
        guard let menu else { return }
        let rows = menu.items.compactMap { item -> (NSMenuItem, NSAttributedString, NSRange)? in
            guard let title = item.attributedTitle else { return nil }
            let tab = (title.string as NSString).range(of: "\t")
            guard tab.location != NSNotFound else { return nil }
            return (item, title, tab)
        }
        // Measure each label/value pair without its tab, preserving fonts.
        // A common trailing edge aligns values without a fixed-width menu.
        let measuredEdge = ceil(rows.map { _, title, tab -> CGFloat in
            let label = title.attributedSubstring(from: NSRange(location: 0, length: tab.location))
            let value = title.attributedSubstring(from: NSRange(
                location: tab.location + 1, length: title.length - tab.location - 1))
            return label.size().width + 20 + value.size().width
        }.max() ?? 0)
        let edge = lockedColumnEdges[ObjectIdentifier(menu)] ?? measuredEdge
        if menu.supermenu == nil { mainColumnEdge = edge }
        for (item, title, _) in rows {
            let fitted = NSMutableAttributedString(attributedString: title)
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: edge, options: [:])]
            style.defaultTabInterval = 0
            fitted.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: 0, length: fitted.length))
            item.attributedTitle = fitted
        }
    }

    private static func setTrendTitle(
        on item: NSMenuItem?, label: String, value: String,
        delta: Int64?, risingIsGood: Bool
    ) {
        guard let item else { return }
        let arrow: String
        let arrowColor: NSColor
        if let delta, abs(delta) >= 100_000_000 {
            arrow = delta > 0 ? "↑ " : "↓ "
            arrowColor = (risingIsGood == (delta > 0)) ? .systemGreen : .systemRed
        } else {
            arrow = ""
            arrowColor = .labelColor
        }
        let title = menuColumns(label: label, value: arrow + value)
        if !arrow.isEmpty {
            title.addAttribute(
                .foregroundColor, value: arrowColor,
                range: NSRange(location: (label as NSString).length + 1,
                               length: (arrow as NSString).length))
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
        item.attributedTitle = menuColumns(
            label: "Memory Pressure", value: pressure.rawValue, valueColor: color)
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

    private func refreshProcessMemoryMenu() {
        guard !isRefreshingProcesses else { return }
        isRefreshingProcesses = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = ProcessMemoryUtils.topProcesses()
            DispatchQueue.main.async {
                guard let self, let menu = self.processMemoryMenu else { return }
                self.isRefreshingProcesses = false
                menu.removeAllItems()

                let heading = NSMenuItem(
                    title: "Highest resident memory", action: nil, keyEquivalent: "")
                heading.isEnabled = false
                heading.toolTip =
                    "Resident memory (RSS) is physical memory currently held by each process. Shared memory can appear in more than one process, so these values do not sum to total RAM used."
                menu.addItem(heading)
                menu.addItem(.separator())

                guard let entries else {
                    menu.addItem(NSMenuItem(
                        title: "Process details unavailable", action: nil, keyEquivalent: ""))
                    return
                }
                if entries.isEmpty {
                    menu.addItem(NSMenuItem(
                        title: "No processes found", action: nil, keyEquivalent: ""))
                }
                for entry in entries {
                    let shortName = String(entry.name.prefix(26))
                    let item = NSMenuItem(
                        title: shortName,
                        action: nil, keyEquivalent: "")
                    item.attributedTitle = Self.menuColumns(
                        label: shortName,
                        value: ProcessMemoryUtils.formatResidentBytes(entry.residentBytes))
                    item.toolTip =
                        "\(entry.name) (PID \(entry.pid)): \(ProcessMemoryUtils.formatResidentBytes(entry.residentBytes)) of resident physical memory. Values are a snapshot and may change quickly."
                    menu.addItem(item)
                }
                Self.fitColumns(in: menu)
            }
        }
    }

    private func refreshStatusItem() {
        Self.fitColumns(in: statusItem.menu)
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
            button.toolTip = "RAM used: \(MemoryUtils.formatGB(snapshot.usedBytes)) of \(MemoryUtils.formatCapacity(snapshot.totalBytes)). \(Self.pressureExplanation(snapshot.pressure))"
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
        let arrow = deltaBytes > 0 ? "▲ " : "▼ "
        let color: NSColor = deltaBytes > 0 ? .systemRed : .systemGreen
        let amount = DiskUtils.formatGB(abs(deltaBytes))
        return menuColumns(
            label: String(name.prefix(26)), value: arrow + amount, valueColor: color)
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

        let header = NSMenuItem(title: "Activity (Last Hour)", action: nil, keyEquivalent: "")
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
        item.attributedTitle = Self.menuColumns(label: "Trash + Purgeable", value: size)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMemory()
        refreshProcessMemoryMenu()
        updateTrashMenuItem()
        updateRestartSavingsItem()
        updateDiskUsageToolMenuItem()
        rebuildActivityItems()
        Self.fitColumns(in: menu)
        Self.lockedColumnEdges[ObjectIdentifier(menu)] = Self.mainColumnEdge
    }

    func menuDidClose(_ menu: NSMenu) {
        Self.lockedColumnEdges.removeValue(forKey: ObjectIdentifier(menu))
    }

    func updateRestartSavingsItem() {
        guard let menu = statusItem.menu, let item = menu.item(withTag: 2) else { return }

        // Get current estimate (returns "Calculating..." or cached value)
        let estimate = RestartSavingsEstimator.shared.getEstimatedSavings()
        item.attributedTitle = Self.menuColumns(label: "Restart Savings", value: estimate)

        // If it was calculating, the callback will update it later
        RestartSavingsEstimator.shared.onUpdate = { [weak self] newValue in
            DispatchQueue.main.async {
                guard let self = self, let menu = self.statusItem.menu,
                    let item = menu.item(withTag: 2)
                else { return }
                item.attributedTitle = Self.menuColumns(
                    label: "Restart Savings", value: newValue)
                Self.fitColumns(in: menu)
            }
        }
    }
}
