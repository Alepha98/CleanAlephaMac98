import Darwin
import Foundation

/// Physical-storage facts that Finder's logical file size does not express.
///
/// APFS full clones have different inodes but the same content identifier. Classic
/// hard links have the same device/inode. In both cases deleting one visible path can
/// reclaim zero bytes, so cleanup estimates must stay conservative.
struct FileStorageFacts: Sendable, Equatable {
    struct InodeKey: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    let logicalBytes: Int64
    let allocatedBytes: Int64
    let inodeKey: InodeKey
    let hardLinkCount: Int
    let contentIdentifier: Int64?
    let mayShareFileContent: Bool
    let isSparse: Bool
    let isPurgeable: Bool
    let isCloudPlaceholder: Bool

    var isHardLinked: Bool { hardLinkCount > 1 }

    static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileContentIdentifierKey,
        .mayShareFileContentKey,
        .isSparseKey,
        .isPurgeableKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    static func read(_ url: URL) -> FileStorageFacts? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              let values = try? url.resourceValues(forKeys: resourceKeys),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }

        let logical = max(0, Int64(values.fileSize ?? Int(info.st_size)))
        let blocks = max(0, Int64(info.st_blocks)) * 512
        let allocated = max(
            0,
            Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? Int(blocks))
        )
        let cloudPlaceholder = (info.st_flags & UInt32(SF_DATALESS)) != 0
            || (values.isUbiquitousItem == true
                && values.ubiquitousItemDownloadingStatus != .current)

        return FileStorageFacts(
            logicalBytes: logical,
            allocatedBytes: allocated,
            inodeKey: InodeKey(
                device: UInt64(bitPattern: Int64(info.st_dev)),
                inode: UInt64(info.st_ino)
            ),
            hardLinkCount: max(1, Int(info.st_nlink)),
            contentIdentifier: values.fileContentIdentifier,
            mayShareFileContent: values.mayShareFileContent == true,
            isSparse: values.isSparse == true || allocated < logical,
            isPurgeable: values.isPurgeable == true,
            isCloudPlaceholder: cloudPlaceholder
        )
    }

    /// A per-item estimate cannot assume that the user will also delete every sibling
    /// clone/link. Zero is intentionally conservative for shared storage.
    func conservativeReclaimableBytes(contentIdentifierPopulation _: Int) -> Int64 {
        if isHardLinked { return 0 }
        // The other clone may live outside the roots this scanner was allowed to read.
        // Partial-clone shared blocks are not exposed by a reliable public byte counter.
        if mayShareFileContent, contentIdentifier != nil {
            return 0
        }
        return allocatedBytes
    }
}
