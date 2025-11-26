import Cocoa
import Foundation

class DownloadsMonitor {
    static let shared = DownloadsMonitor()

    private var cachedSize: String?
    private var lastCalculationTime: Date?
    private let cacheDuration: TimeInterval = 30.0  // 30 seconds
    private var isCalculating = false

    // Callback for when calculation finishes
    var onUpdate: ((String) -> Void)?

    private init() {}

    func getDownloadsSize() -> String {
        // If we have a fresh cache, return it
        if let size = cachedSize, let lastTime = lastCalculationTime,
            Date().timeIntervalSince(lastTime) < cacheDuration
        {
            return size
        }

        // If already calculating, return last known or "Calculating..."
        if isCalculating {
            return cachedSize ?? "Calculating..."
        }

        // Start background calculation
        calculateSize()

        return cachedSize ?? "Calculating..."
    }

    private func calculateSize() {
        isCalculating = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let fileManager = FileManager.default
            guard
                let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask)
                    .first
            else {
                self.finishCalculation(size: "Error")
                return
            }

            var totalSize: Int64 = 0

            let resourceKeys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey,
            ]

            guard
                let enumerator = fileManager.enumerator(
                    at: downloadsURL,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: nil
                )
            else {
                self.finishCalculation(size: "Error")
                return
            }

            for case let fileURL as URL in enumerator {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

                    // Skip directories
                    if let isDirectory = resourceValues.isDirectory, isDirectory {
                        continue
                    }

                    // Skip symbolic links (implicit in enumerator unless we check, but let's be safe if needed,
                    // though default enumerator follows symlinks? Actually default does NOT follow symlinks for directory recursion unless specified,
                    // but it might return symlinks themselves. We want to avoid double counting if we were following.
                    // The prompt says "Skip symbolic links".
                    // Let's check if it's a symlink.
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink
                    {
                        continue
                    }

                    // Prefer totalFileAllocatedSize, then fileAllocatedSize, then fileSize
                    if let size = resourceValues.totalFileAllocatedSize {
                        totalSize += Int64(size)
                    } else if let size = resourceValues.fileAllocatedSize {
                        totalSize += Int64(size)
                    } else if let size = resourceValues.fileSize {
                        totalSize += Int64(size)
                    }
                } catch {
                    // Ignore errors for individual files
                }
            }

            let gb = Double(totalSize) / 1_000_000_000
            let formattedSize = String(format: "%.1f GB", gb)

            self.finishCalculation(size: formattedSize)
        }
    }

    private func finishCalculation(size: String) {
        DispatchQueue.main.async {
            self.cachedSize = size
            self.lastCalculationTime = Date()
            self.isCalculating = false
            self.onUpdate?(size)
        }
    }

    func openDownloadsFolder() {
        let fileManager = FileManager.default
        if let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        {
            NSWorkspace.shared.open(downloadsURL)
        }
    }
}
