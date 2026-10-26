//
//  AtomicFileWriter.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// Writes files atomically: temp file in the same directory → fsync → rename.
///
/// Readers therefore see either the previous complete file or the new
/// complete file, never a partial write.
nonisolated enum AtomicFileWriter {

    enum WriteError: Error {
        case createFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case renameFailed(errno: Int32)
    }

    /// - Parameters:
    ///   - permissions: POSIX mode for the final file. Defaults to owner read/write only.
    static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, permissions)
        guard fd >= 0 else { throw WriteError.createFailed(errno: errno) }

        var success = false
        defer {
            if !success { unlink(tempURL.path) }
        }

        let writeResult: Int = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += written
            }
            return offset
        }
        let writeErrno = errno
        let syncResult = fsync(fd)
        close(fd)
        guard writeResult == data.count, syncResult == 0 else {
            throw WriteError.writeFailed(errno: writeErrno)
        }

        guard rename(tempURL.path, url.path) == 0 else {
            throw WriteError.renameFailed(errno: errno)
        }
        success = true
    }
}
