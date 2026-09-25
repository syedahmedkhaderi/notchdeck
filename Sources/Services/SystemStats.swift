import AppKit
import Darwin
import IOKit
import IOKit.ps

// MARK: - Memory

enum MemoryPressure: String {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"

    var color: NSColor {
        switch self {
        case .normal: return NSColor(red: 101 / 255, green: 196 / 255, blue: 102 / 255, alpha: 1)
        case .warning: return NSColor(red: 1, green: 0.78, blue: 0.25, alpha: 1)
        case .critical: return NSColor(red: 1, green: 0.35, blue: 0.31, alpha: 1)
        }
    }
}

struct MemorySample {
    var total: Double = 0
    var used: Double = 0
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var swapUsed: Double = 0
    var swapTotal: Double = 0
    var pressure: MemoryPressure = .normal
    var usage: Double { total > 0 ? used / total : 0 }
}

final class MemoryReader {
    private let total = Double(ProcessInfo.processInfo.physicalMemory)

    func sample() -> MemorySample {
        var s = MemorySample(total: total)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let active = Double(stats.active_count) * page
            let inactive = Double(stats.inactive_count) * page
            let speculative = Double(stats.speculative_count) * page
            let wired = Double(stats.wire_count) * page
            let compressed = Double(stats.compressor_page_count) * page
            let purgeable = Double(stats.purgeable_count) * page
            let external = Double(stats.external_page_count) * page
            s.used = active + inactive + speculative + wired + compressed - purgeable - external
            s.wired = wired
            s.compressed = compressed
            s.app = max(0, s.used - wired - compressed)
            s.cached = purgeable + external
        }

        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            s.pressure = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        }

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = Double(swap.xsu_used)
            s.swapTotal = Double(swap.xsu_total)
        }
        return s
    }
}

// MARK: - Battery

struct BatterySample: Equatable {
    var present = false
    var level: Double = 0
    var isCharging = false
    var isCharged = false
    var onAC = false
    var minutesRemaining: Int?
    var health: Int?
    var cycles: Int?
    var designCapacity: Int?
    var maxCapacity: Int?
    var temperature: Double?
    var voltage: Double?
    var amperage: Double?
    var adapterWatts: Int?

    var power: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * a
    }

    var statusText: String {
        if !present { return "No battery" }
        if isCharged { return "Fully charged" }
        if isCharging { return "Charging" }
        if onAC { return "Plugged in, not charging" }
        return "On battery"
    }
}

final class BatteryReader {
    func sample() -> BatterySample {
        var s = BatterySample()

        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        if let d = descriptions.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) {
            s.present = true
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            s.level = max > 0 ? Double(current) / Double(max) : 0
            s.onAC = d[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue
            s.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.isCharged = d[kIOPSIsChargedKey] as? Bool ?? false
            let minutes = (s.isCharging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
            s.minutesRemaining = minutes > 0 ? minutes : nil
        }

        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            s.adapterWatts = details[kIOPSPowerAdapterWattsKey] as? Int
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return s }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return s }

        let batteryData = dict["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            if let value = (dict[key] as? NSNumber) { return Int(value.int64Value) }
            if let value = (batteryData[key] as? NSNumber) { return Int(value.int64Value) }
            return nil
        }

        s.cycles = int("CycleCount")
        s.designCapacity = int("DesignCapacity")
        s.maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? int("FullChargeCapacity")
        if let max = s.maxCapacity, let design = s.designCapacity, design > 0 {
            s.health = min(100, Int((Double(max) * 100 / Double(design)).rounded()))
        }
        if s.minutesRemaining == nil {
            let minutes = int("TimeRemaining") ?? int("AvgTimeToEmpty") ?? -1
            s.minutesRemaining = minutes > 0 ? minutes : nil
        }
        s.voltage = int("Voltage").map { Double($0) / 1000 }
        s.amperage = (int("InstantAmperage") ?? int("Amperage")).map { Double($0) / 1000 }
        s.temperature = int("Temperature").map { Double($0) / 100 }
        if s.temperature == nil { s.temperature = BatteryReader.packTemperature() }
        return s
    }

    /// The battery node itself has no thermometer on Apple Silicon; the pack
    /// one level down publishes it in hundredths of a degree.
    private static func packTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let data = dict["BatteryData"] as? [String: Any],
              let raw = (data["Temperature"] ?? data["VirtualTemperature"]) as? NSNumber else { return nil }
        return Double(raw.intValue) / 100
    }
}

// MARK: - Processes

struct TopProcess: Identifiable {
    let pid: Int
    let name: String
    let memory: Double
    var id: Int { pid }
}

enum ProcessReader {
    /// The `limit` processes holding the most resident memory. App names are
    /// resolved only for those rows, not for every process on the system.
    static func topByMemory(_ limit: Int) -> [TopProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let rows: [(pid: Int, rss: Double, comm: Substring)] = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let rss = Double(parts[1]) else { return nil }
            return (pid, rss, parts[2])
        }
        return rows.sorted { $0.rss > $1.rss }.prefix(limit).map { row in
            let name = NSRunningApplication(processIdentifier: pid_t(row.pid))?.localizedName ?? String(row.comm)
            return TopProcess(pid: row.pid, name: name, memory: row.rss * 1024)
        }
    }
}

// MARK: - Misc

func byteString(_ bytes: Double) -> String {
    let gb = bytes / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", bytes / 1_048_576)
}
