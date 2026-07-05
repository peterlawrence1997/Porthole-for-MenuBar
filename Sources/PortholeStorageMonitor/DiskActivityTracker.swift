import Foundation
import CoreServices

final class DiskActivityTracker {
    static let shared = DiskActivityTracker()

    struct Config {
        let window: TimeInterval
        let minHistoryFraction: Double
        let retention: TimeInterval
        let rescanThrottle: TimeInterval
        let dirtyCheckInterval: TimeInterval
        let fullPassInterval: TimeInterval
        let fallbackPassInterval: TimeInterval  // used when FSEvents is unavailable
        let expensiveScanThreshold: TimeInterval
        let menuBarThreshold: Int64
        let listThreshold: Int64
        let listLimit: Int

        static func fromEnvironment() -> Config {
            let isFastScan = ProcessInfo.processInfo.environment["PORTHOLE_FAST_SCAN"] == "1"
            if isFastScan {
                return Config(
                    window: 120,
                    minHistoryFraction: 0.75,
                    retention: 6 * 3600,
                    rescanThrottle: 15,
                    dirtyCheckInterval: 5,
                    fullPassInterval: 60,
                    fallbackPassInterval: 30,
                    expensiveScanThreshold: 20,
                    menuBarThreshold: 500_000_000,
                    listThreshold: 100_000_000,
                    listLimit: 5
                )
            } else {
                return Config(
                    window: 3600,
                    minHistoryFraction: 0.75,
                    retention: 6 * 3600,
                    rescanThrottle: 300,
                    dirtyCheckInterval: 60,
                    fullPassInterval: 3600,
                    fallbackPassInterval: 600,
                    expensiveScanThreshold: 20,
                    menuBarThreshold: 2_000_000_000,
                    listThreshold: 100_000_000,
                    listLimit: 5
                )
            }
        }
    }

    struct TrackedDirectory {
        let url: URL
        let displayName: String
        var expensive: Bool = false
        var dirtySince: Date?
        var lastScanStart: Date?
    }

    struct SizeSample: Codable {
        let date: Date
        let bytes: Int64
    }

    enum ActivityEntry {
        case directory(url: URL, displayName: String, deltaBytes: Int64)
        case remainder(deltaBytes: Int64)
    }

    let config = Config.fromEnvironment()
    private var trackedDirs: [TrackedDirectory] = []
    private var dirHistory: [String: [SizeSample]] = [:]
    private var freeHistory: [SizeSample] = []
    // State queue: guards all mutable state; only short operations run here so the
    // main thread's queue.sync reads never wait behind a directory scan.
    private let queue = DispatchQueue(label: "com.porthole.diskactivity.state", qos: .utility)
    // Scan queue: file enumeration only; results are handed back to the state queue.
    private let scanQueue = DispatchQueue(label: "com.porthole.diskactivity.scan", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var usingFallback = false
    private var isScanning = false
    private var dirtyCheckTimer: Timer?
    private var fullPassTimer: Timer?

    var onUpdate: (() -> Void)?

    private init() {}

    func start() {
        queue.async {
            self.buildTrackedDirectories()
            self.startEventStream()
            self.scheduleTimers()
            self.performFullPass()
        }
    }

    func recordFreeSpace(bytes: Int64) {
        queue.async {
            self.freeHistory.append(SizeSample(date: Date(), bytes: bytes))
            self.pruneHistory(of: &self.freeHistory)
        }
    }

    func freeSpaceDelta() -> Int64? {
        return queue.sync {
            delta(in: freeHistory)
        }
    }

    func topMovers() -> [ActivityEntry]? {
        return queue.sync {
            guard let freeDelta = delta(in: freeHistory) else { return nil }

            var entries: [(displayName: String, url: URL, delta: Int64)] = []
            var trackedTotal: Int64 = 0

            for dir in trackedDirs {
                guard let d = delta(in: dirHistory[dir.url.path] ?? []) else { continue }
                trackedTotal += d
                if abs(d) >= config.listThreshold {
                    entries.append((displayName: dir.displayName, url: dir.url, delta: d))
                }
            }

            entries.sort { abs($0.delta) > abs($1.delta) }
            var result = entries.prefix(config.listLimit).map { entry -> ActivityEntry in
                .directory(url: entry.url, displayName: entry.displayName, deltaBytes: entry.delta)
            }

            // Everything outside the tracked set, in aggregate. Negated because
            // free space falling means usage rising.
            let remainder = (-freeDelta) - trackedTotal
            if abs(remainder) >= config.listThreshold {
                result.append(.remainder(deltaBytes: remainder))
            }

            return result
        }
    }

    func shouldShowMenuBarArrow() -> Bool {
        return queue.sync {
            guard let freeDelta = delta(in: freeHistory),
                abs(freeDelta) >= config.menuBarThreshold
            else { return false }

            // Attribution guard: only show the arrow when at least one tracked
            // directory moved too, so purgeable/snapshot churn doesn't cry wolf.
            return trackedDirs.contains { dir in
                if let d = delta(in: dirHistory[dir.url.path] ?? []) {
                    return abs(d) >= config.listThreshold
                }
                return false
            }
        }
    }

    // MARK: - Delta / history helpers (state queue only)

    private func delta(in samples: [SizeSample]) -> Int64? {
        guard let latest = samples.last, let oldest = samples.first else { return nil }
        let now = Date()

        // Baseline: newest sample at least `window` old.
        if let baseline = samples.last(where: { now.timeIntervalSince($0.date) >= config.window }) {
            return latest.bytes - baseline.bytes
        }
        // Young history: accept the oldest sample if it covers most of the window.
        if now.timeIntervalSince(oldest.date) >= config.window * config.minHistoryFraction {
            return latest.bytes - oldest.bytes
        }
        return nil
    }

    private func pruneHistory(of samples: inout [SizeSample]) {
        let threshold = Date().addingTimeInterval(-config.retention)
        // Keep one sample older than the window so a baseline always exists.
        while samples.count > 1 && samples[0].date < threshold {
            samples.removeFirst()
        }
    }

    // MARK: - Tracked directory set (state queue only)

    private func buildTrackedDirectories() {
        var dirs: [TrackedDirectory] = []
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser

        // Visible top-level home folders, excluding ~/Library (covered by Caches below).
        if let contents = try? fileManager.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in contents {
                guard url.lastPathComponent != "Library" else { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    dirs.append(TrackedDirectory(url: url, displayName: url.lastPathComponent))
                }
            }
        }

        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            dirs.append(TrackedDirectory(url: cachesURL, displayName: "Caches"))
        }

        let trashURL = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? homeURL.appendingPathComponent(".Trash")
        dirs.append(TrackedDirectory(url: trashURL, displayName: "Trash"))

        let tempDir = NSTemporaryDirectory()
        if !tempDir.isEmpty {
            // NSTemporaryDirectory() -> /var/folders/xx/yyyy/T/; track /var/folders/xx/yyyy/
            let systemTempUrl = URL(fileURLWithPath: tempDir).deletingLastPathComponent()
            dirs.append(TrackedDirectory(url: systemTempUrl, displayName: "System Temp"))
        }

        self.trackedDirs = dirs.filter {
            fileManager.isReadableFile(atPath: $0.url.path)
        }
    }

    // MARK: - Scanning

    // Must be called on the state queue.
    private func performFullPass() {
        guard !isScanning else { return }
        for i in trackedDirs.indices {
            trackedDirs[i].dirtySince = nil
        }
        requestScan(of: trackedDirs)
    }

    // Must be called on the state queue. Enumeration happens on scanQueue so the
    // state queue stays responsive; results hop back here.
    private func requestScan(of dirs: [TrackedDirectory]) {
        guard !dirs.isEmpty, !isScanning else { return }
        isScanning = true

        scanQueue.async {
            var results: [(path: String, bytes: Int64, elapsed: TimeInterval)] = []
            for dir in dirs {
                let result = Self.calculateDirectorySize(at: dir.url)
                results.append((dir.url.path, result.bytes, result.elapsed))
            }

            self.queue.async {
                let now = Date()
                for r in results {
                    self.dirHistory[r.path, default: []].append(
                        SizeSample(date: now, bytes: r.bytes))
                    self.pruneHistory(of: &self.dirHistory[r.path]!)

                    if let i = self.trackedDirs.firstIndex(where: { $0.url.path == r.path }) {
                        self.trackedDirs[i].lastScanStart = now
                        if r.elapsed > self.config.expensiveScanThreshold {
                            self.trackedDirs[i].expensive = true
                        }
                    }
                }
                self.isScanning = false
                DispatchQueue.main.async { self.onUpdate?() }
            }
        }
    }

    // Must be called on the state queue.
    private func checkDirtyDirectories() {
        guard !isScanning else { return }  // keep dirty flags; retry next tick
        let now = Date()
        var toScan: [TrackedDirectory] = []

        for i in trackedDirs.indices {
            guard trackedDirs[i].dirtySince != nil else { continue }
            let throttle =
                trackedDirs[i].expensive ? config.rescanThrottle * 3 : config.rescanThrottle
            if let last = trackedDirs[i].lastScanStart, now.timeIntervalSince(last) < throttle {
                continue  // scanned recently; stays dirty, picked up later
            }
            trackedDirs[i].dirtySince = nil
            toScan.append(trackedDirs[i])
        }

        requestScan(of: toScan)
    }

    private static func calculateDirectorySize(at url: URL) -> (bytes: Int64, elapsed: TimeInterval)
    {
        let startTime = Date()
        var size: Int64 = 0

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]

        // Deliberately no skip options: package contents and hidden files count
        // toward real disk usage, which is what free space measures.
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [],
                errorHandler: nil
            )
        else {
            return (0, Date().timeIntervalSince(startTime))
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { continue }

            if let s = values.totalFileAllocatedSize {
                size += Int64(s)
            } else if let s = values.fileAllocatedSize {
                size += Int64(s)
            } else if let s = values.fileSize {
                size += Int64(s)
            }
        }

        return (size, Date().timeIntervalSince(startTime))
    }

    // MARK: - FSEvents

    // Must be called on the state queue (before scheduleTimers, so usingFallback is set).
    private func startEventStream() {
        let paths = trackedDirs.map { $0.url.path } as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info = info else { return }
            let tracker = Unmanaged<DiskActivityTracker>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            tracker.markDirty(paths: Array(paths.prefix(Int(count))))
        }

        eventStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            )
        )

        guard let stream = eventStream else {
            print("Failed to create FSEventStream, falling back to fixed-interval scanning")
            usingFallback = true
            return
        }

        FSEventStreamScheduleWithRunLoop(
            stream,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        if !FSEventStreamStart(stream) {
            print("Failed to start FSEventStream, falling back to fixed-interval scanning")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
            usingFallback = true
        }
    }

    private func markDirty(paths: [String]) {
        queue.async {
            let now = Date()
            for path in paths {
                let normalized = Self.normalize(path)
                if let index = self.trackedDirs.firstIndex(where: { dir in
                    let root = Self.normalize(dir.url.path)
                    return normalized == root || normalized.hasPrefix(root + "/")
                }) {
                    if self.trackedDirs[index].dirtySince == nil {
                        self.trackedDirs[index].dirtySince = now
                    }
                }
            }
        }
    }

    // FSEvents reports resolved paths (/private/var/...) while we track the
    // symlinked form (/var/...); trailing slashes vary too. Normalize both sides.
    private static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/private/") {
            p = String(p.dropFirst("/private".count))
        }
        while p.count > 1 && p.hasSuffix("/") {
            p = String(p.dropLast())
        }
        return p
    }

    // MARK: - Timers

    // Must be called on the state queue, after startEventStream.
    private func scheduleTimers() {
        let fallback = usingFallback
        DispatchQueue.main.async {
            if !fallback {
                self.dirtyCheckTimer = Timer.scheduledTimer(
                    withTimeInterval: self.config.dirtyCheckInterval,
                    repeats: true
                ) { [weak self] _ in
                    guard let self = self else { return }
                    self.queue.async { self.checkDirtyDirectories() }
                }
            }

            let passInterval =
                fallback ? self.config.fallbackPassInterval : self.config.fullPassInterval
            self.fullPassTimer = Timer.scheduledTimer(
                withTimeInterval: passInterval,
                repeats: true
            ) { [weak self] _ in
                guard let self = self else { return }
                self.queue.async { self.performFullPass() }
            }
        }
    }

    deinit {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
