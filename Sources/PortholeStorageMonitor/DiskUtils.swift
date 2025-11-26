import Foundation

struct DiskUtils {
    static func getFreeDiskSpace() -> String {
        let fileURL = URL(fileURLWithPath: "/")
        do {
            let values = try fileURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                let gb = Double(capacity) / 1_000_000_000
                return String(format: "%.1f GB", gb)
            }
        } catch {
            print("Error retrieving disk space: \(error)")
        }
        return "N/A"
    }

    static func getTrashAndPurgeableSize() -> String {
        // Calculate Trash size
        let fileManager = FileManager.default
        var trashSize: Int64 = 0

        // Get Trash URL
        if let trashURL = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first {
            trashSize = folderSize(at: trashURL)
        }

        // Purgeable space is tricky. volumeAvailableCapacityForImportantUsageKey includes purgeable space.
        // volumeAvailableCapacityKey does NOT include purgeable space (it's strictly free).
        // So Purgeable ~= Important - StrictlyFree
        // However, Apple docs say volumeAvailableCapacityForImportantUsageKey is the amount available for storing new data.
        // Let's try to estimate purgeable by checking the difference between "Available" and "Available for Important Usage" if possible,
        // or just rely on what the system reports as "Purgeable" if we can find a key, but there isn't a direct "Purgeable" key in URLResourceKey.
        // A common approximation is (Total - Free) - Used, but that's hard too.
        //
        // Actually, `URLResourceKey.volumeTotalCapacityKey` and `URLResourceKey.volumeAvailableCapacityKey`.
        // `volumeAvailableCapacityKey` is "The volume’s available capacity in bytes." (This often excludes purgeable).
        // `volumeAvailableCapacityForImportantUsageKey` is "The volume’s available capacity in bytes for storing important resources." (Includes purgeable).
        // So Purgeable ~= ImportantUsage - Available.

        var purgeableSize: Int64 = 0
        let rootURL = URL(fileURLWithPath: "/")
        do {
            let values = try rootURL.resourceValues(forKeys: [
                .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
            if let available = values.volumeAvailableCapacity,
                let important = values.volumeAvailableCapacityForImportantUsage
            {
                if important > available {
                    purgeableSize = Int64(important) - Int64(available)
                }
            }
        } catch {
            print("Error calculating purgeable: \(error)")
        }

        let totalBytes = trashSize + purgeableSize
        let gb = Double(totalBytes) / 1_000_000_000
        return String(format: "%.1f GB", gb)
    }

    private static func folderSize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var size: Int64 = 0

        guard
            let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
        else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [
                    .fileSizeKey, .isDirectoryKey,
                ])
                if let isDirectory = resourceValues.isDirectory, isDirectory {
                    continue
                }
                if let fileSize = resourceValues.fileSize {
                    size += Int64(fileSize)
                }
            } catch {
                print("Error getting size for \(fileURL): \(error)")
            }
        }
        return size
    }

    static func emptyTrash() {
        let script = "tell application \"Finder\" to empty trash"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript Error: \(error)")
            }
        }
    }
}
