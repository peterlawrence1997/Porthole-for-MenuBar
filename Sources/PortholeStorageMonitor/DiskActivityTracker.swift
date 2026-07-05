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
    private let queue = DispatchQueue(label: "com.porthole.diskactivity", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var isScanning = false
    private var dirtyCheckTimer: Timer?
    private var fullPassTimer: Timer?

    var onUpdate: (() -> Void)?

    private init() {}

    func start() {
        queue.async {
            self.buildTrackedDirectories()
            self.performFullPass()
            self.startEventStream()
            self.scheduleTimers()
        }
    }

    func recordFreeSpace(bytes: Int64) {
        queue.async {
            let sample = SizeSample(date: Date(), bytes: bytes)
            self.freeHistory.append(sample)
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
            guard hasValidHistoryBaseline() else { return nil }

            var entries: [(displayName: String, url: URL?, delta: Int64)] = []

            for dir in trackedDirs {
                guard let delta = delta(in: dirHistory[dir.url.path] ?? []) else { continue }
                if abs(delta) >= config.listThreshold {
                    entries.append((displayName: dir.displayName, url: dir.url, delta: delta))
                }
            }

            entries.sort { abs($0.delta) > abs($1.delta) }
            let dirEntries = entries.prefix(config.listLimit).map { entry -> ActivityEntry in
                .directory(url: entry.url!, displayName: entry.displayName, deltaBytes: entry.delta)
            }

            guard let freeDelta = delta(in: freeHistory) else { return Array(dirEntries) }
            let trackedDelta = entries.prefix(config.listLimit).reduce(0) { $0 + $1.delta }
            let remainder = (-freeDelta) - trackedDelta

            var result = Array(dirEntries)
            if abs(remainder) >= config.listThreshold {
                result.append(.remainder(deltaBytes: remainder))
            }

            return result.isEmpty ? [] : result
        }
    }

    func shouldShowMenuBarArrow() -> Bool {
        return queue.sync {
            guard let freeDelta = delta(in: freeHistory) else { return false }
            guard abs(freeDelta) >= config.menuBarThreshold else { return false }

            let hasTrackedMovement = trackedDirs.contains { dir in
                if let delta = delta(in: dirHistory[dir.url.path] ?? []) {
                    return abs(delta) >= config.listThreshold
                }
                return false
            }
            return hasTrackedMovement
        }
    }

    // MARK: - Private Helpers

    private func delta(in samples: [SizeSample]) -> Int64? {
        guard !samples.isEmpty else { return nil }

        let now = Date()
        let window = config.window

        let baseline = samples.last(where: { now.timeIntervalSince($0.date) <= window })
            ?? (samples.first.map { sample in
                (now.timeIntervalSince(sample.date) >= config.window * config.minHistoryFraction) ? sample : nil
            } ?? nil)

        guard let baseline = baseline else { return nil }
        guard let latest = samples.last else { return nil }

        return latest.bytes - baseline.bytes
    }

    private func pruneHistory(of samples: inout [SizeSample]) {
        let threshold = Date().addingTimeInterval(-config.retention)
        samples.removeAll { $0.date < threshold }
    }

    private func hasValidHistoryBaseline() -> Bool {
        guard !freeHistory.isEmpty else { return false }
        return delta(in: freeHistory) != nil
    }

    private func buildTrackedDirectories() {
        var dirs: [TrackedDirectory] = []

        let fileManager = FileManager.default
        guard let homeURL = fileManager.urls(for: .userDirectory, in: .userDomainMask).first else {
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: homeURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for url in contents {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    dirs.append(
                        TrackedDirectory(url: url, displayName: url.lastPathComponent)
                    )
                }
            }
        } catch {
            print("Error building tracked directories: \(error)")
        }

        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            dirs.append(TrackedDirectory(url: cachesURL, displayName: "Caches"))
        }

        let trashURL = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first ?? URL(
            fileURLWithPath: NSHomeDirectory() + "/.Trash"
        )
        dirs.append(TrackedDirectory(url: trashURL, displayName: "Trash"))

        let tempDir = NSTemporaryDirectory()
        if !tempDir.isEmpty {
            let tempUrl = URL(fileURLWithPath: tempDir)
            let systemTempUrl = tempUrl.deletingLastPathComponent()
            dirs.append(TrackedDirectory(url: systemTempUrl, displayName: "System Temp"))
        }

        self.trackedDirs = dirs
    }

    private func performFullPass() {
        guard !isScanning else { return }
        isScanning = true

        let directoriesSnapshot = trackedDirs
        var scanResults: [String: Int64] = [:]
        let startTime = Date()

        for dir in directoriesSnapshot {
            let result = calculateDirectorySize(at: dir.url)
            scanResults[dir.url.path] = result.bytes

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 20 {
                var updatedDir = dir
                updatedDir.expensive = true
                if let index = self.trackedDirs.firstIndex(where: { $0.url == dir.url }) {
                    self.trackedDirs[index] = updatedDir
                }
                break
            }
        }

        for (path, bytes) in scanResults {
            let sample = SizeSample(date: Date(), bytes: bytes)
            dirHistory[path, default: []].append(sample)
            pruneHistory(of: &dirHistory[path]!)
        }

        isScanning = false

        DispatchQueue.main.async {
            self.onUpdate?()
        }
    }

    private func calculateDirectorySize(at url: URL) -> (bytes: Int64, elapsed: TimeInterval) {
        let startTime = Date()
        let fileManager = FileManager.default
        var size: Int64 = 0

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]

        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [],
                errorHandler: nil
            )
        else {
            return (0, Date().timeIntervalSince(startTime))
        }

        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

                if resourceValues.isRegularFile != true {
                    continue
                }

                if resourceValues.isSymbolicLink == true {
                    continue
                }

                if let size_ = resourceValues.totalFileAllocatedSize {
                    size += Int64(size_)
                } else if let size_ = resourceValues.fileAllocatedSize {
                    size += Int64(size_)
                } else if let size_ = resourceValues.fileSize {
                    size += Int64(size_)
                }
            } catch {
                continue
            }
        }

        return (size, Date().timeIntervalSince(startTime))
    }

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
            scheduleFixedIntervalScanning()
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
            self.eventStream = nil
            scheduleFixedIntervalScanning()
        }
    }

    private func scheduleFixedIntervalScanning() {
        DispatchQueue.main.async {
            self.fullPassTimer = Timer.scheduledTimer(
                withTimeInterval: self.config.fullPassInterval * 10,
                repeats: true
            ) { _ in
                self.queue.async {
                    self.performFullPass()
                }
            }
        }
    }

    private func scheduleTimers() {
        DispatchQueue.main.async {
            self.dirtyCheckTimer = Timer.scheduledTimer(
                withTimeInterval: self.config.dirtyCheckInterval,
                repeats: true
            ) { _ in
                self.queue.async {
                    self.checkDirtyDirectories()
                }
            }

            self.fullPassTimer = Timer.scheduledTimer(
                withTimeInterval: self.config.fullPassInterval,
                repeats: true
            ) { _ in
                self.queue.async {
                    self.performFullPass()
                }
            }
        }
    }

    private func checkDirtyDirectories() {
        let now = Date()
        var dirsToScan: [TrackedDirectory] = []

        for dir in trackedDirs {
            guard let dirtySince = dir.dirtySince else { continue }
            let timeSinceDirty = now.timeIntervalSince(dirtySince)
            let throttle = dir.expensive ? config.rescanThrottle * 3 : config.rescanThrottle

            if timeSinceDirty >= throttle {
                dirsToScan.append(dir)
            }
        }

        guard !dirsToScan.isEmpty else { return }

        for dir in dirsToScan {
            if let index = trackedDirs.firstIndex(where: { $0.url == dir.url }) {
                trackedDirs[index].dirtySince = nil
            }

            let result = calculateDirectorySize(at: dir.url)
            let sample = SizeSample(date: Date(), bytes: result.bytes)
            dirHistory[dir.url.path, default: []].append(sample)
            pruneHistory(of: &dirHistory[dir.url.path]!)
        }

        DispatchQueue.main.async {
            self.onUpdate?()
        }
    }

    private func markDirty(paths: [String]) {
        queue.async {
            let now = Date()
            for path in paths {
                if let index = self.trackedDirs.firstIndex(where: { $0.url.path == path
                    || path.hasPrefix($0.url.path)
                }) {
                    if self.trackedDirs[index].dirtySince == nil {
                        self.trackedDirs[index].dirtySince = now
                    }
                }
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
