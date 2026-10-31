import AppKit
import Combine
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration
import MacDailyCore

// Percentages use 0...100; all byte counters are bytes and rates are bytes/second.
enum MonitorMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, battery, temperature
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: L10n.text("内存")
        case .disk: "Macintosh HD"
        case .network: L10n.text("网络")
        case .battery: L10n.text("电池")
        case .temperature: L10n.text("温度")
        }
    }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .battery: "battery.100"
        case .temperature: "thermometer.medium"
        }
    }
}

struct SystemSnapshot: Sendable {
    var timestamp = Date()
    var uptime: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var gpu: Double?
    var gpuRenderer: Double?
    var gpuTiler: Double?
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var memoryCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0
    var diskReadRate: Double = 0
    var diskWriteRate: Double = 0
    var uploadRate: Double = 0
    var downloadRate: Double = 0
    var memoryPressure = "正常"
    var interface = ""
    var localIP = ""
    var chipName = ""
    var cpuCores = 0
    var gpuCores: Int?
    var batteryLevel: Double?
    var batteryHealth: Double?
    var charging = false
    var onAC = false
    var temperatureSource = ""
}

struct MonitorProcess: Identifiable, Sendable {
    var id: Int32
    var name: String
    var cpu: Double
    var memory: UInt64
}

@MainActor
final class SystemMonitorService: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var history: [SystemSnapshot] = []
    @Published private(set) var processes: [MonitorProcess] = []
    @Published private(set) var interfaces: [String] = []
    var onSnapshot: (() -> Void)?

    private let sampler = MonitorSampler()
    private var samplingTask: Task<Void, Never>?
    private var visible = false
    private var menuNetwork = false
    private var temperature = false
    private var selectedInterface: String?
    private var detail: MonitorMetric?
    private var batterySource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var generation = 0
    var samplingInterval: TimeInterval? { visible ? 2 : (menuNetwork ? 5 : nil) }

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        batterySource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<SystemMonitorService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak service] in
                guard let service, service.visible else { return }
                let value = await service.sampler.batterySnapshot()
                service.snapshot.batteryLevel = value.batteryLevel
                service.snapshot.batteryHealth = value.batteryHealth
                service.snapshot.charging = value.charging
                service.snapshot.onAC = value.onAC
                service.onSnapshot?()
            }
        }, context)?.takeRetainedValue()
        if let batterySource { CFRunLoopAddSource(CFRunLoopGetMain(), batterySource, .commonModes) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartSampling() }
        }
    }

    func setDemand(visible: Bool, menuNetwork: Bool, temperature: Bool, interface: String?) {
        guard self.visible != visible || self.menuNetwork != menuNetwork || self.temperature != temperature || selectedInterface != interface else { return }
        self.visible = visible; self.menuNetwork = menuNetwork; self.temperature = temperature
        selectedInterface = interface
        restartSampling()
    }

    func setProcessDetail(_ detail: MonitorMetric?) {
        guard self.detail != detail else { return }
        self.detail = detail
        if detail != .cpu && detail != .memory { processes = [] }
        restartSampling(resetRates: false)
    }

    private func restartSampling(resetRates: Bool = true) {
        generation += 1
        samplingTask?.cancel(); samplingTask = nil
        guard let interval = samplingInterval else { processes = []; return }
        let generation = generation
        let networkOnly = !visible
        let temperature = temperature && visible
        let interface = selectedInterface
        let detail = visible ? detail : nil
        samplingTask = Task { [weak self, sampler] in
            if resetRates { await sampler.resetRates() }
            while !Task.isCancelled {
                let result = await sampler.sample(networkOnly: networkOnly, temperature: temperature, interface: interface, detail: detail)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.snapshot = result.snapshot
                self.interfaces = result.interfaces
                self.processes = result.processes
                if !networkOnly {
                    self.history.removeAll { result.snapshot.timestamp.timeIntervalSince($0.timestamp) > 600 }
                    self.history.append(result.snapshot)
                }
                self.onSnapshot?()
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        samplingTask?.cancel(); samplingTask = nil
        visible = false; menuNetwork = false
        processes = []; history = []
        if let batterySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .commonModes) }
        batterySource = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}

private struct MonitorSample: Sendable {
    var snapshot: SystemSnapshot
    var interfaces: [String]
    var processes: [MonitorProcess]
}

private actor MonitorSampler {
    private var snapshot = SystemSnapshot()
    private var previousCPU: [UInt64]?
    private var networkReceivedRate = MonitorCounterRate()
    private var networkSentRate = MonitorCounterRate()
    private var diskReadRate = MonitorCounterRate()
    private var diskWriteRate = MonitorCounterRate()
    private var previousProcesses: [Int32: (user: UInt64, system: UInt64)] = [:]
    private var processTime: Double?
    private var capacityTime: Double = -30
    private var temperatureReader: SMCTemperatureReader?

    func batterySnapshot() -> SystemSnapshot {
        readBattery()
        return snapshot
    }

    func resetRates() {
        previousCPU = nil; networkReceivedRate.reset(); networkSentRate.reset()
        diskReadRate.reset(); diskWriteRate.reset()
        previousProcesses = [:]; processTime = nil
    }

    func sample(networkOnly: Bool, temperature: Bool, interface: String?, detail: MonitorMetric?) -> MonitorSample {
        let now = ProcessInfo.processInfo.systemUptime
        snapshot.timestamp = Date(); snapshot.uptime = now
        let names = readNetwork(selected: interface, now: now)
        if !networkOnly {
            snapshot.chipName = sysctlString("machdep.cpu.brand_string")
            snapshot.cpuCores = ProcessInfo.processInfo.processorCount
            readCPU(); readMemory(); readGPU(); readDisk(now: now); readBattery()
            if now - capacityTime >= 30 {
                let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
                if let value = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
                    snapshot.diskFree = UInt64(max(0, value.volumeAvailableCapacity ?? 0))
                    snapshot.diskTotal = UInt64(max(0, value.volumeTotalCapacity ?? 0))
                }
                capacityTime = now
            }
            if temperature {
                if temperatureReader == nil { temperatureReader = SMCTemperatureReader() }
                let reading = temperatureReader?.read()
                snapshot.cpuTemperature = reading?.cpu; snapshot.gpuTemperature = reading?.gpu
                snapshot.temperatureSource = reading?.source ?? L10n.text("未读取到温度")
            } else {
                temperatureReader = nil
                snapshot.cpuTemperature = nil; snapshot.gpuTemperature = nil; snapshot.temperatureSource = ""
            }
        }
        let processes = !networkOnly && (detail == .cpu || detail == .memory) ? readProcesses(detail: detail!, now: now) : []
        return MonitorSample(snapshot: snapshot, interfaces: names, processes: processes)
    }

    private func readCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return }
        let ticks = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { previousCPU = ticks }
        guard let previousCPU else { snapshot.cpuUser = 0; snapshot.cpuSystem = 0; return }
        let delta = zip(ticks, previousCPU).map { $0 >= $1 ? $0 - $1 : 0 }
        let total = Double(delta.reduce(0, +))
        guard total > 0 else { return }
        snapshot.cpuUser = Double(delta[0] + delta[3]) / total * 100
        snapshot.cpuSystem = Double(delta[1]) / total * 100
    }

    private func readMemory() {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return }
        let pages = Int64(info.active_count) + Int64(info.inactive_count) + Int64(info.speculative_count) + Int64(info.wire_count) + Int64(info.compressor_page_count) - Int64(info.purgeable_count) - Int64(info.external_page_count)
        snapshot.memoryTotal = ProcessInfo.processInfo.physicalMemory
        snapshot.memoryUsed = min(snapshot.memoryTotal, UInt64(max(0, pages)) * UInt64(vm_page_size))
        snapshot.memoryCompressed = UInt64(info.compressor_page_count) * UInt64(vm_page_size)
        var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { snapshot.swapUsed = swap.xsu_used }
        var pressure: Int32 = 0; size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 {
            snapshot.memoryPressure = pressure == 4 ? "较高" : (pressure == 2 ? "偏高" : "正常")
        }
    }

    private func readGPU() {
        snapshot.gpu = nil; snapshot.gpuRenderer = nil; snapshot.gpuTiler = nil; snapshot.gpuCores = nil
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        let accelerator = IOIteratorNext(iterator)
        guard accelerator != 0 else { return }
        defer { IOObjectRelease(accelerator) }
        if let values = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
            snapshot.gpu = (values["Device Utilization %"] as? NSNumber)?.doubleValue
            snapshot.gpuRenderer = (values["Renderer Utilization %"] as? NSNumber)?.doubleValue
            snapshot.gpuTiler = (values["Tiler Utilization %"] as? NSNumber)?.doubleValue
        }
        if let number = IORegistryEntryCreateCFProperty(accelerator, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            snapshot.gpuCores = number.intValue
        } else if let data = IORegistryEntryCreateCFProperty(accelerator, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data, data.count >= 4 {
            snapshot.gpuCores = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
    }

    private func readDisk(now: Double) {
        // Follow the mounted startup volume through its APFS ancestors to the
        // physical block driver. APFS child-volume counters are not added again.
        var mount = statfs()
        guard statfs("/", &mount) == 0 else { return }
        let name = withUnsafePointer(to: &mount.f_mntfromname) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }.replacingOccurrences(of: "/dev/", with: "")
        var current = name.withCString { IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, $0)) }
        while current != 0 {
            if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 {
                defer { IOObjectRelease(current) }
                var identifier: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(current, &identifier)
                if let values = IORegistryEntryCreateCFProperty(current, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                   let read = (values["Bytes (Read)"] as? NSNumber)?.uint64Value,
                   let write = (values["Bytes (Write)"] as? NSNumber)?.uint64Value {
                    snapshot.diskReadRate = diskReadRate.sample(identity: String(identifier), value: read, time: now)
                    snapshot.diskWriteRate = diskWriteRate.sample(identity: String(identifier), value: write, time: now)
                }
                return
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            current = result == KERN_SUCCESS ? parent : 0
        }
        diskReadRate.reset(); diskWriteRate.reset()
        snapshot.diskReadRate = 0; snapshot.diskWriteRate = 0
    }

    private func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        snapshot.batteryLevel = nil; snapshot.batteryHealth = nil
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            snapshot.batteryLevel = maximum > 0 ? current / maximum * 100 : nil
            snapshot.charging = description[kIOPSIsChargingKey] as? Bool ?? false
            snapshot.onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        }
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if battery != 0 {
            defer { IOObjectRelease(battery) }
            if let values = IORegistryEntryCreateCFProperty(battery, "BatteryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let capacity = (values["FullChargeCapacity"] as? NSNumber)?.doubleValue,
               let design = (values["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0 {
                snapshot.batteryHealth = min(100, capacity / design * 100)
            }
        }
    }

    private func readNetwork(selected: String?, now: Double) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var counters: [String: (received: UInt64, sent: UInt64)] = [:]
        var ips: [String: String] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = head
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let value = current.pointee
            guard let address = value.ifa_addr, value.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: value.ifa_name)
            if address.pointee.sa_family == UInt8(AF_LINK), let data = value.ifa_data, name != "lo0" {
                let info = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = (UInt64(info.ifi_ibytes), UInt64(info.ifi_obytes))
            }
            if address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { ips[name] = String(cString: host) }
            }
        }
        let names = counters.keys.sorted()
        let state = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = state?["PrimaryInterface"] as? String
        let physical = names.filter { $0.hasPrefix("en") && ips[$0] != nil }
        let automatic = (primary.flatMap { physical.contains($0) ? $0 : nil }) ?? physical.first
        let chosen: String?
        if let selected, !selected.isEmpty { chosen = counters[selected] == nil ? nil : selected }
        else { chosen = automatic }
        guard let chosen, let counts = counters[chosen] else {
            snapshot.interface = "未连接"; snapshot.localIP = ""; snapshot.downloadRate = 0; snapshot.uploadRate = 0
            networkReceivedRate.reset(); networkSentRate.reset(); return names
        }
        snapshot.downloadRate = networkReceivedRate.sample(identity: chosen, value: counts.received, time: now)
        snapshot.uploadRate = networkSentRate.sample(identity: chosen, value: counts.sent, time: now)
        snapshot.interface = chosen; snapshot.localIP = ips[chosen] ?? ""
        return names
    }

    private func readProcesses(detail: MonitorMetric, now: Double) -> [MonitorProcess] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        var next: [Int32: (user: UInt64, system: UInt64)] = [:]
        let elapsed = processTime.map { now - $0 } ?? 0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
        let rows = pids.prefix(max(0, Int(filled)) / MemoryLayout<pid_t>.stride).compactMap { pid -> MonitorProcess? in
            guard pid > 0 else { return nil }
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size else { return nil }
            next[pid] = (info.pti_total_user, info.pti_total_system)
            let cpu: Double
            if let old = previousProcesses[pid], elapsed > 0, info.pti_total_user >= old.user, info.pti_total_system >= old.system {
                cpu = Double(info.pti_total_user - old.user + info.pti_total_system - old.system) * nanosecondsPerTick / elapsed / 1_000_000_000 * 100
            } else { cpu = 0 }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let count = proc_name(pid, &buffer, UInt32(buffer.count))
            let name = count > 0 ? String(cString: buffer) : L10n.text("进程 %@", String(describing: pid))
            return MonitorProcess(id: pid, name: name, cpu: cpu, memory: info.pti_resident_size)
        }
        previousProcesses = next; processTime = now
        return Array(rows.sorted { detail == .cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }.prefix(10))
    }

    private func sysctlString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}

// AppleSMC's read-only user-client request layout is 80 bytes on supported macOS.
// Commands here only enumerate keys, read key metadata and read values.
private final class SMCTemperatureReader {
    private var connection: io_connect_t = 0
    private var sensors: [(key: String, type: UInt32, size: Int)] = []
    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS,
              let countBytes = bytes(for: "#KEY"), countBytes.count >= 4 else { return }
        let count = countBytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        for index in 0..<count {
            guard let response = call(key: 0, command: 8, data: index) else { continue }
            let code = response.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let key = String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? ""
            guard key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tg"), let metadata = metadata(for: key) else { continue }
            if metadata.type == Self.code("flt ") || metadata.type == Self.code("sp78") { sensors.append((key, metadata.type, metadata.size)) }
        }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    func read() -> (cpu: Double?, gpu: Double?, source: String) {
        var cpu: [Double] = [], gpu: [Double] = [], names: [String] = []
        for sensor in sensors {
            guard let data = bytes(for: sensor.key, metadata: (sensor.type, sensor.size)) else { continue }
            let temperature: Double
            if sensor.type == Self.code("flt "), data.count >= 4 {
                temperature = Double(data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
            } else if data.count >= 2 {
                temperature = Double(Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))) / 256
            } else { continue }
            guard temperature.isFinite, temperature > 0, temperature < 150 else { continue }
            if sensor.key.hasPrefix("Tg") { gpu.append(temperature) } else { cpu.append(temperature) }
            names.append(sensor.key)
        }
        return (cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
                gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count),
                names.isEmpty ? L10n.text("未读取到温度") : L10n.text("AppleSMC · %@ · 同组均值", String(describing: names.joined(separator: ", "))))
    }
    private static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private func metadata(for key: String) -> (type: UInt32, size: Int)? {
        guard let response = call(key: Self.code(key), command: 9) else { return nil }
        let size = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
        let type = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
        return (type, Int(size))
    }
    private func bytes(for key: String, metadata: (type: UInt32, size: Int)? = nil) -> [UInt8]? {
        guard let metadata = metadata ?? self.metadata(for: key), metadata.size <= 32,
              let response = call(key: Self.code(key), command: 5, size: metadata.size) else { return nil }
        return Array(response[48..<(48 + metadata.size)])
    }
    private func call(key: UInt32, command: UInt8, data: UInt32 = 0, size: Int = 0) -> [UInt8]? {
        guard connection != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes { buffer in
            buffer.storeBytes(of: key, as: UInt32.self)
            buffer.storeBytes(of: UInt32(size), toByteOffset: 28, as: UInt32.self)
            buffer.storeBytes(of: data, toByteOffset: 44, as: UInt32.self)
        }
        input[42] = command
        var count = 80
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, destination.baseAddress, &count)
            }
        }
        return result == KERN_SUCCESS && output[40] == 0 ? output : nil
    }
}
