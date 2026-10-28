import Foundation

struct ProcessMemoryEntry {
    let pid: Int32
    let name: String
    let residentBytes: UInt64
}

enum ProcessMemoryUtils {
    static func topProcesses(limit: Int = 5) -> [ProcessMemoryEntry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let listing = String(data: data, encoding: .utf8)
        else { return nil }

        let entries = listing.split(whereSeparator: \.isNewline).compactMap { line -> ProcessMemoryEntry? in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                let pid = Int32(fields[0]),
                let residentKiB = UInt64(fields[1]),
                residentKiB > 0
            else { return nil }

            let path = String(fields[2])
            let name = URL(fileURLWithPath: path).lastPathComponent
            return ProcessMemoryEntry(
                pid: pid, name: name.isEmpty ? path : name,
                residentBytes: residentKiB * 1024)
        }
        return Array(entries.sorted { $0.residentBytes > $1.residentBytes }.prefix(limit))
    }

    static func formatResidentBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
