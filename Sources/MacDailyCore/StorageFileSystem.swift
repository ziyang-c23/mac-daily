import Darwin
import Foundation

public enum StorageFileSystem {
    /// Pure classification shared by native metadata handling and placeholder tests.
    public static func isCloudPlaceholder(fileFlags: UInt32, ubiquitous: Bool = false, downloaded: Bool = true) -> Bool {
        fileFlags & 0x40000000 != 0 || (ubiquitous && !downloaded)
    }

    /// Reads metadata only. lstat deliberately preserves symbolic-link identity.
    public static func entry(at url: URL) throws -> StorageEntry {
        let path = url.standardizedFileURL.path
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kind = info.st_mode & mode_t(S_IFMT)
        let directory = kind == mode_t(S_IFDIR), symlink = kind == mode_t(S_IFLNK)
        var package = false, cloud = isCloudPlaceholder(fileFlags: UInt32(info.st_flags)) // SF_DATALESS, including File Provider placeholders.
        var allocated = max(0, Int64(info.st_blocks) * 512)
        if !symlink {
            let values = try? url.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey, .totalFileAllocatedSizeKey])
            package = values?.isPackage ?? false
            if let size = values?.totalFileAllocatedSize { allocated = max(0, Int64(size)) }
            if values?.isUbiquitousItem == true {
                let status = values?.ubiquitousItemDownloadingStatus
                cloud = isCloudPlaceholder(fileFlags: UInt32(info.st_flags), ubiquitous: true, downloaded: status == .current || status == .downloaded)
            }
        }
        let identity = "\(info.st_dev):\(info.st_ino)"
        let signature = "\(identity):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_flags)"
        return StorageEntry(path: path, isDirectory: directory, isRegularFile: kind == mode_t(S_IFREG), isPackage: package, isSymlink: symlink,
            isCloudPlaceholder: cloud, logicalBytes: symlink || directory ? 0 : max(0, info.st_size),
            allocatedBytes: symlink || directory ? 0 : allocated,
            modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
            linkCount: Int(info.st_nlink), identity: identity, volumeID: String(info.st_dev), metadataSignature: signature)
    }

    public static func isInside(path: String, root: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let r = URL(fileURLWithPath: root).standardizedFileURL.path
        return p == r || p.hasPrefix(r == "/" ? "/" : r + "/")
    }
    public static func normalizedRoots(_ urls: [URL]) -> [URL] {
        let ordered = Set(urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }).sorted {
            if $0.count == $1.count { return $0 < $1 }; return $0.count < $1.count
        }
        var paths: [String] = []
        for path in ordered where !paths.contains(where: { isInside(path: path, root: $0) }) { paths.append(path) }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    public static func hasSymlinkAncestor(_ url: URL) -> Bool {
        var current = url.standardizedFileURL.deletingLastPathComponent()
        while current.path != "/" {
            var info = stat()
            guard current.path.withCString({ lstat($0, &info) }) == 0 else { return true }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
}

public struct StorageVolume: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let rootURL: URL
    public let capacityURL: URL
    public let totalBytes: Int64
    public let availableBytes: Int64
    public init(id: String, name: String, rootURL: URL, capacityURL: URL, totalBytes: Int64, availableBytes: Int64) {
        self.id = id; self.name = name; self.rootURL = rootURL; self.capacityURL = capacityURL
        self.totalBytes = totalBytes; self.availableBytes = availableBytes
    }
    /// Startup System/Data is represented once; remote and hidden volumes are omitted.
    public static func catalog() -> [StorageVolume] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsInternalKey,
                                       .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        var urls = manager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        urls.removeAll { $0.standardizedFileURL.path == "/" || $0.path.hasPrefix("/System/Volumes/") }
        urls.insert(URL(fileURLWithPath: "/", isDirectory: true), at: 0)
        var seen = Set<String>(), result: [StorageVolume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal == true else { continue }
            let startup = url.path == "/"
            if !startup && values.volumeIsBrowsable == false { continue }
            let scanRoot = startup && manager.fileExists(atPath: "/System/Volumes/Data")
                ? URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true) : url
            let id = values.volumeUUIDString ?? url.path
            guard seen.insert(id).inserted else { continue }
            result.append(.init(id: id, name: values.volumeName ?? (startup ? "Macintosh HD" : url.lastPathComponent),
                                rootURL: scanRoot, capacityURL: url,
                                totalBytes: Int64(values.volumeTotalCapacity ?? 0), availableBytes: Int64(values.volumeAvailableCapacity ?? 0)))
        }
        return result
    }
}
