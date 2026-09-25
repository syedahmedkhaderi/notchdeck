import AppKit
import Combine
import CoreFoundation
import Darwin
import IOKit

// MARK: - IOAVService

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

/// DDC/CI over the Apple Silicon IOAVService I2C path, the same route
/// MonitorControl uses. Only external monitors speak this protocol.
final class DDC {
    static let chipAddress: UInt8 = 0x37
    static let dataAddress: UInt8 = 0x51
    static let vcpBrightness: UInt8 = 0x10

    private let service: CFTypeRef

    init(service: CFTypeRef) { self.service = service }

    /// Every external display service, in IORegistry order.
    static func externalServices() -> [CFTypeRef] {
        var result: [CFTypeRef] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { continue }
            result.append(service.takeRetainedValue())
        }
        return result
    }

    private static func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Sends one DDC/CI message (opcode first, e.g. [0x01, vcp] to read) and optionally reads the reply.
    private func send(_ message: [UInt8], replyLength: Int = 0) -> [UInt8]? {
        var packet: [UInt8] = [0x80 | UInt8(message.count)] + message + [0]
        packet[packet.count - 1] = DDC.checksum((DDC.chipAddress << 1) ^ DDC.dataAddress, packet[0..<(packet.count - 1)])
        for _ in 0..<5 {
            var wrote = false
            for _ in 0..<2 {
                usleep(10_000)
                wrote = IOAVServiceWriteI2C(service, UInt32(DDC.chipAddress), UInt32(DDC.dataAddress), &packet, UInt32(packet.count)) == 0
            }
            if replyLength == 0 {
                if wrote { return [] }
            } else {
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: replyLength)
                // reply[1] holds the message length, so the checksum follows at 2 + length.
                if IOAVServiceReadI2C(service, UInt32(DDC.chipAddress), 0, &reply, UInt32(reply.count)) == 0 {
                    let end = 2 + Int(reply[1] & 0x7f)
                    if end < reply.count, DDC.checksum(0x50, reply[0..<end]) == reply[end] {
                        return reply
                    }
                }
            }
            usleep(20_000)
        }
        return nil
    }

    /// Reads a VCP feature; returns (current, max) in the monitor's raw units.
    func read(_ vcp: UInt8) -> (current: Int, max: Int)? {
        guard let r = send([0x01, vcp], replyLength: 11), r[2] == 0x02, r[3] == 0x00, r[4] == vcp else { return nil }
        return (Int(r[8]) << 8 | Int(r[9]), Int(r[6]) << 8 | Int(r[7]))
    }

    @discardableResult
    func write(_ vcp: UInt8, _ value: Int) -> Bool {
        send([0x03, vcp, UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]) != nil
    }
}

// MARK: - Built-in panel

/// The internal display goes through the private DisplayServices framework.
private enum BuiltinBrightness {
    typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    }()

    private static let readBrightness: GetFn? = {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetFn.self)
    }()

    private static let writeBrightness: SetFn? = {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetFn.self)
    }()

    static var isAvailable: Bool { readBrightness != nil && writeBrightness != nil }

    static func level(of id: CGDirectDisplayID) -> Double? {
        guard let readBrightness else { return nil }
        var value: Float = 0
        guard readBrightness(id, &value) == 0 else { return nil }
        return Double(value)
    }

    static func setLevel(_ level: Double, of id: CGDirectDisplayID) {
        guard let writeBrightness else { return }
        _ = writeBrightness(id, Float(min(max(level, 0), 1)))
    }
}

// MARK: - Service

/// One row of the brightness widget.
struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    /// 0...1, or nil when the display cannot be read.
    var level: Double?
    var isBuiltin: Bool
    /// False when the panel does not answer DDC, so the slider stays disabled.
    var controllable: Bool
}

/// Drives external monitor brightness over DDC and the built-in panel through
/// DisplayServices, so the notch can replace a separate brightness menu bar app.
///
/// DDC traffic sleeps between retries, so every read and write happens on a
/// private queue; the widget only ever touches published state on the main thread.
final class BrightnessService: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []

    private let queue = DispatchQueue(label: "notchdeck.brightness", qos: .utility)
    private var services: [CGDirectDisplayID: DDC] = [:]
    private var maxValues: [CGDirectDisplayID: Int] = [:]
    private var timer: Timer?
    private var started = false
    private var scanning = false
    private var pendingWork: DispatchWorkItem?

    var hasExternalDisplay: Bool { displays.contains { !$0.isBuiltin } }

    // MARK: Lifecycle

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            let service = Unmanaged<BrightnessService>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { service.scheduleScan() }
        }, context)
    }

    /// Sampling only runs while the panel is on screen.
    func start() {
        guard !started else { return }
        started = true
        scan()
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.scan() }
        t.tolerance = 1.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        pendingWork?.cancel()
        pendingWork = nil
    }

    private func scheduleScan() {
        guard started else { return }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pendingWork = work
        // Displays change in bursts (connect, wake, resolution change); let them settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: Reading

    func scan() {
        guard !scanning else { return }
        scanning = true

        let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String, Bool)? in
            guard let id = screen.displayID else { return nil }
            return (id, screen.localizedName, CGDisplayIsBuiltin(id) != 0)
        }.sorted { $0.0 < $1.0 }

        let builtin = screens.filter { $0.2 }.compactMap { id, name, _ -> DisplayInfo? in
            guard let level = BuiltinBrightness.level(of: id) else { return DisplayInfo(id: id, name: name, level: nil, isBuiltin: true, controllable: false) }
            return DisplayInfo(id: id, name: name, level: level, isBuiltin: true, controllable: BuiltinBrightness.isAvailable)
        }

        let externalScreens = screens.filter { !$0.2 }
        queue.async { [weak self] in
            guard let self else { return }
            // A reconnect makes the old IOAVService handles go stale, so rebuild them.
            let services = DDC.externalServices()
            self.services = Dictionary(uniqueKeysWithValues: zip(externalScreens.map(\.0), services.map { DDC(service: $0) }))
            var result: [DisplayInfo] = []
            for (index, screen) in externalScreens.enumerated() {
                let id = screen.0
                var level: Double?
                var controllable = false
                if let ddc = self.services[id] ?? (index < services.count ? DDC(service: services[index]) : nil) {
                    self.services[id] = ddc
                    if let value = ddc.read(DDC.vcpBrightness), value.max > 0 {
                        self.lock.lock()
                        self.maxValues[id] = value.max
                        self.lock.unlock()
                        level = Double(value.current) / Double(value.max)
                        controllable = true
                    }
                }
                result.append(DisplayInfo(id: id, name: screen.1, level: level, isBuiltin: false, controllable: controllable))
            }
            let builtinResult = builtin
            DispatchQueue.main.async {
                self.scanning = false
                self.displays = builtinResult + result
            }
        }
    }

    // MARK: Writing

    /// Sets brightness (0...1). DDC writes coalesce so dragging stays smooth.
    func setLevel(_ level: Double, for display: DisplayInfo) {
        guard display.controllable else { return }
        let clamped = min(max(level, 0), 1)
        if let index = displays.firstIndex(where: { $0.id == display.id }) {
            displays[index].level = clamped
        }
        if display.isBuiltin {
            BuiltinBrightness.setLevel(clamped, of: display.id)
            return
        }
        lock.lock()
        let maxValue = max(maxValues[display.id] ?? 100, 1)
        let raw = Int((clamped * Double(maxValue)).rounded())
        pending[display.id] = raw
        let startWorker = writing.insert(display.id).inserted
        lock.unlock()
        guard startWorker else { return }
        queue.async { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                guard let value = self.pending.removeValue(forKey: display.id) else {
                    self.writing.remove(display.id)
                    self.lock.unlock()
                    return
                }
                self.lock.unlock()
                self.services[display.id]?.write(DDC.vcpBrightness, value)
            }
        }
    }

    private let lock = NSLock()
    private var pending: [CGDirectDisplayID: Int] = [:]
    private var writing: Set<CGDirectDisplayID> = []
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
