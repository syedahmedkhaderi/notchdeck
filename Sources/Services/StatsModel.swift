import Combine
import Foundation

/// Polls memory and battery for the widgets that are on screen.
final class StatsModel: ObservableObject {
    static let topProcessCount = 4

    @Published private(set) var memory = MemorySample()
    @Published private(set) var battery = BatterySample()
    @Published private(set) var topMemory: [TopProcess] = []

    private let memoryReader = MemoryReader()
    private let batteryReader = BatteryReader()
    private var timer: Timer?
    private var tick = 0
    private var wantsMemory = false
    private var wantsBattery = false
    private var processBusy = false
    private let processQueue = DispatchQueue(label: "notchdeck.processes", qos: .utility)

    /// Starts or stops sampling to match what is visible.
    func configure(memory: Bool, battery: Bool) {
        wantsMemory = memory
        wantsBattery = battery
        guard memory || battery else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        tick = 0
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { configure(memory: false, battery: false) }

    func refresh() {
        if wantsMemory {
            memory = memoryReader.sample()
            // The process list forks `ps`, so it runs off the main thread and
            // less often than the totals.
            if tick % 3 == 0 { refreshProcesses() }
        }
        if wantsBattery {
            let sample = batteryReader.sample()
            if sample != battery { battery = sample }
        }
        tick += 1
    }

    private func refreshProcesses() {
        guard !processBusy else { return }
        processBusy = true
        processQueue.async { [weak self] in
            let top = ProcessReader.topByMemory(Self.topProcessCount)
            DispatchQueue.main.async {
                self?.processBusy = false
                self?.topMemory = top
            }
        }
    }

    // MARK: Formatting helpers

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func durationString(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
