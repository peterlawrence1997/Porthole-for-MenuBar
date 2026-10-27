import Darwin
import Foundation

struct MemorySnapshot {
    enum Pressure: String {
        case normal = "Normal"
        case warning = "Warning"
        case critical = "Critical"
        case unavailable = "Unavailable"
    }

    let usedBytes: UInt64
    let totalBytes: UInt64
    let pressure: Pressure

    var usedPercentage: Int {
        Int((Double(usedBytes) / Double(totalBytes) * 100).rounded())
    }
}

struct MemoryUtils {
    static func currentSnapshot() -> MemorySnapshot? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return nil }

        // Active, wired, and compressed pages are in use. Inactive/file-backed
        // pages are reclaimable, so counting all non-free pages overstates use.
        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let usedBytes = min(totalBytes, usedPages * UInt64(pageSize))

        return MemorySnapshot(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            pressure: currentPressure())
    }

    private static func currentPressure() -> MemorySnapshot.Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return .unavailable }

        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unavailable
        }
    }

    static func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
