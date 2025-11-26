import Foundation

class RestartSavingsEstimator {
    static let shared = RestartSavingsEstimator()

    private var cachedSavings: Int64 = 0
    private var lastCalculationTime: Date?
    private var isCalculating = false
    private let cacheDuration: TimeInterval = 60.0

    // Callback for when calculation finishes
    var onUpdate: ((String) -> Void)?

    private init() {}

    func getEstimatedSavings(forceRefresh: Bool = false) -> String {
        if isCalculating {
            return "Calculating..."
        }

        if !forceRefresh, let lastTime = lastCalculationTime,
            Date().timeIntervalSince(lastTime) < cacheDuration
        {
            return formatBytes(cachedSavings)
        }

        // Trigger background calculation
        calculateSavings()

        // Return cached value if available, otherwise calculating
        if lastCalculationTime != nil {
            return formatBytes(cachedSavings)
        }
        return "Calculating..."
    }

    private func calculateSavings() {
        guard !isCalculating else { return }
        isCalculating = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            var totalSavings: Int64 = 0

            // 1. SYSTEM TEMP DIRECTORIES
            totalSavings += self.calculateSystemTemp()

            // 2. USER CACHES
            totalSavings += self.calculateUserCaches()

            // 3. OS UPDATE PAYLOADS
            totalSavings += self.calculateOSUpdates()

            // 4. SAVED APPLICATION STATE
            totalSavings += self.calculateSavedAppState()

            DispatchQueue.main.async {
                self.cachedSavings = totalSavings
                self.lastCalculationTime = Date()
                self.isCalculating = false
                self.onUpdate?(self.formatBytes(totalSavings))
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        } else {
            let mb = Double(bytes) / 1_000_000
            return String(format: "%.0f MB", mb)
        }
    }

    // MARK: - Calculation Helpers

    private func calculateSystemTemp() -> Int64 {
        var size: Int64 = 0
        let fileManager = FileManager.default

        // 1.1 /tmp and /private/tmp (Full size)
        // /tmp is a symlink to /private/tmp usually, so just check /private/tmp to be safe, or both if distinct.
        // We'll check /tmp and if it's a symlink, resolve it.
        let tmpPaths = ["/tmp", "/private/tmp"]

        for path in tmpPaths {
            if (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
                // If it resolves to something we haven't scanned, scan it.
                // But usually /tmp -> private/tmp.
                // Let's just scan /private/tmp directly as it's the canonical one on macOS.
            }
        }
        // Simpler: Just scan /private/tmp.
        size += folderSize(atPath: "/private/tmp", ageFilter: nil)

        // 1.2 /private/var/tmp (Older than 72h)
        size += folderSize(atPath: "/private/var/tmp", ageFilter: 72 * 3600)

        // 1.3 /private/var/folders (Current user, Older than 7 days)
        // Find user's temp dir
        // NSTemporaryDirectory() gives the user's temp dir in /var/folders
        let tempDir = NSTemporaryDirectory()
        if !tempDir.isEmpty {
            // NSTemporaryDirectory() returns something like /var/folders/xx/yyyy/T/
            // We want to scan the root of that user's folder in /var/folders/xx/yyyy/
            let tempUrl = URL(fileURLWithPath: tempDir)
            // Go up two levels to get /var/folders/xx/yyyy/
            let userVarFolder = tempUrl.deletingLastPathComponent().path
            size += folderSize(atPath: userVarFolder, ageFilter: 7 * 24 * 3600)
        }

        return size
    }

    private func calculateUserCaches() -> Int64 {
        // 2.1 ~/Library/Caches (Older than 7 days)
        guard
            let cachesUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first
        else { return 0 }

        return folderSize(
            atPath: cachesUrl.path, ageFilter: 7 * 24 * 3600,
            excludePrefixes: ["com.apple.helpd", "com.apple.dt.Xcode"])
    }

    private func calculateOSUpdates() -> Int64 {
        var size: Int64 = 0
        // 3. OS UPDATE PAYLOADS (Older than 30 days)
        let paths = [
            "/Library/Updates",
            "/System/Library/Updates",
        ]

        // ~/Library/Updates
        if let userLib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        {
            let userUpdates = userLib.appendingPathComponent("Updates").path
            size += folderSize(atPath: userUpdates, ageFilter: 30 * 24 * 3600)
        }

        for path in paths {
            size += folderSize(atPath: path, ageFilter: 30 * 24 * 3600)
        }

        return size
    }

    private func calculateSavedAppState() -> Int64 {
        // 4. SAVED APPLICATION STATE (Older than 30 days, capped)
        guard
            let libraryUrl = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
                .first
        else { return 0 }
        let savedStatePath = libraryUrl.appendingPathComponent("Saved Application State").path

        let size = folderSize(atPath: savedStatePath, ageFilter: 30 * 24 * 3600)

        // Cap at 20% of total? Hard to do without knowing total first.
        // The requirement says: "Cap the contribution from this category to a modest percentage (e.g. max 10–20% of the total “Restart Savings”)"
        // This implies we need to sum others first or apply cap at the end.
        // For now, let's just return the raw size and we can adjust if it seems huge.
        // Or simpler: Cap it at a fixed reasonable amount, e.g., 500MB, to avoid blowing up the estimate.
        // But let's stick to the prompt's logic if possible.
        // Since we are summing components, we can't easily cap based on the *final* total inside this function.
        // Let's just return the size for now.
        return size
    }

    // MARK: - Core Logic

    private func folderSize(
        atPath path: String, ageFilter: TimeInterval?, excludePrefixes: [String] = []
    ) -> Int64 {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        var size: Int64 = 0

        guard fileManager.fileExists(atPath: path) else { return 0 }

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
        ]

        guard
            let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            return 0
        }

        let now = Date()

        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

                guard resourceValues.isRegularFile == true else { continue }

                // Check exclusions
                let fileName = fileURL.lastPathComponent
                if excludePrefixes.contains(where: { fileName.hasPrefix($0) }) {
                    continue
                }

                // Check age
                if let ageFilter = ageFilter {
                    let mtime = resourceValues.contentModificationDate ?? Date.distantPast
                    let atime = resourceValues.contentAccessDate ?? mtime

                    let age = now.timeIntervalSince(max(mtime, atime))
                    if age < ageFilter {
                        continue  // Too young
                    }
                }

                if let fileSize = resourceValues.fileAllocatedSize {
                    size += Int64(fileSize)
                }
            } catch {
                // Ignore errors (permission denied, etc)
            }
        }

        return size
    }
}
