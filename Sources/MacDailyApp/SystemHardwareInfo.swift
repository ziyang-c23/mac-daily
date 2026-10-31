import MacDailyCore
import AppKit
import Combine
import Darwin
import IOKit

struct SystemInfoRow: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
}

@MainActor
final class SystemHardwareInfo: ObservableObject {
    @Published private(set) var rows: [SystemInfoRow] = []
    private var loadTask: Task<[SystemInfoRow], Never>?

    func load() async {
        if let loadTask { rows = await loadTask.value; return }
        let task = Task.detached(priority: .utility) { HardwareInfoReader.read() }
        loadTask = task
        rows = await task.value
    }
}

private enum HardwareInfoReader {
    static func read() -> [SystemInfoRow] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let system = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)" + L10n.text("（%@）", string("kern.osversion"))
        var rows = [SystemInfoRow(id: "os", title: L10n.text("系统版本"), value: system),
                    SystemInfoRow(id: "model", title: L10n.text("型号标识符"), value: string("hw.model"))]
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if platform != 0 {
            if let serial = property(platform, "IOPlatformSerialNumber") as? String {
                rows.append(SystemInfoRow(id: "serial", title: L10n.text("序列号"), value: serial))
            }
            IOObjectRelease(platform)
        }
        let cores = integer("hw.physicalcpu")
        var groups: [String] = []
        let levels = integer("hw.nperflevels")
        for index in 0..<levels {
            let name = string("hw.perflevel\(index).name")
            let count = integer("hw.perflevel\(index).physicalcpu")
            guard count > 0 else { continue }
            let label: String
            switch name.lowercased() {
            case "performance", "super": label = L10n.text("性能")
            case "efficiency": label = L10n.text("能效")
            default: label = name
            }
            groups.append("\(count) \(label)")
        }
        let cpu = L10n.text("%@ · %@ 核", String(describing: string("machdep.cpu.brand_string")), String(describing: cores)) + (groups.isEmpty ? "" : L10n.text("（%@）", groups.joined(separator: " + ")))
        rows.append(SystemInfoRow(id: "cpu", title: "CPU", value: cpu))
        if let gpu = gpuDescription() { rows.append(SystemInfoRow(id: "gpu", title: "GPU", value: gpu)) }
        let gibibytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        rows.append(SystemInfoRow(id: "memory", title: L10n.text("内存"), value: String(format: "%.0f GB", gibibytes)))
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey]
        if let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            rows.append(SystemInfoRow(id: "volume", title: L10n.text("启动磁盘"), value: volume.volumeName ?? "/"))
            if let disk = physicalDiskDescription() {
                let capacity = volume.volumeTotalCapacity.map { String(format: "%.2f GB", Double($0) / 1_000_000_000) }
                rows.append(SystemInfoRow(id: "disk", title: L10n.text("磁盘型号"), value: disk + (capacity.map { L10n.text("（%@）", $0) } ?? "")))
            }
        }
        if let status = sipStatus() { rows.append(SystemInfoRow(id: "sip", title: L10n.text("系统完整性保护"), value: status)) }
        return rows
    }

    private static func gpuDescription() -> String? {
        let accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard accelerator != 0 else { return nil }
        defer { IOObjectRelease(accelerator) }
        let model: String
        if let name = property(accelerator, "model") as? String { model = name }
        else if let data = property(accelerator, "model") as? Data { model = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self) }
        else { model = string("machdep.cpu.brand_string") }
        let cores: Int?
        if let number = property(accelerator, "gpu-core-count") as? NSNumber { cores = number.intValue }
        else if let data = property(accelerator, "gpu-core-count") as? Data, data.count >= 4 {
            cores = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        } else { cores = nil }
        return model + (cores.map { L10n.text(" · %@ 核", String(describing: $0)) } ?? "")
    }

    private static func physicalDiskDescription() -> String? {
        var mount = statfs()
        guard statfs("/", &mount) == 0 else { return nil }
        let name = withUnsafePointer(to: &mount.f_mntfromname) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }.replacingOccurrences(of: "/dev/", with: "")
        var current = name.withCString { IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, $0)) }
        var mediaName: String?
        while current != 0 {
            if IOObjectConformsTo(current, "IOMedia") != 0, property(current, "Whole") as? Bool == true {
                var buffer = [CChar](repeating: 0, count: 128)
                if IORegistryEntryGetName(current, &buffer) == KERN_SUCCESS {
                    mediaName = String(cString: buffer).replacingOccurrences(of: " Media", with: "")
                }
            }
            if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 {
                IOObjectRelease(current)
                return mediaName
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            current = status == KERN_SUCCESS ? parent : 0
        }
        return nil
    }

    private static func sipStatus() -> String? {
        // The function returns configuration bits; zero is the default SIP state.
        typealias GetConfiguration = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csr_get_active_config") else { return nil }
        let getConfiguration = unsafeBitCast(symbol, to: GetConfiguration.self)
        var flags: UInt32 = 0
        guard getConfiguration(&flags) == 0 else { return nil }
        if flags == 0 { return L10n.text("已启用") }
        if flags & 0x77f == 0x77f { return L10n.text("已关闭") }
        return String(format: L10n.text("自定义配置（0x%X）"), flags)
    }

    private static func property(_ entry: io_registry_entry_t, _ name: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private static func integer(_ name: String) -> Int {
        var value: Int32 = 0
        var count = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &count, nil, 0) == 0 ? Int(value) : 0
    }
    private static func string(_ name: String) -> String {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname(name, &bytes, &count, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}
