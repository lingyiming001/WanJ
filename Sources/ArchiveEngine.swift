import Foundation

enum ArchiveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum CompressionFormat: String, CaseIterable {
    case zip, sevenZip = "7z", tar, tarGzip = "tar.gz", tarBzip2 = "tar.bz2", tarXz = "tar.xz"
    var title: String {
        switch self {
        case .zip: return "ZIP · 通用格式"
        case .sevenZip: return "7Z · 高压缩率"
        case .tar: return "TAR · 仅打包"
        case .tarGzip: return "TAR.GZ · gzip 压缩"
        case .tarBzip2: return "TAR.BZ2 · bzip2 压缩"
        case .tarXz: return "TAR.XZ · xz 压缩"
        }
    }
    var arguments: [String] {
        switch self {
        case .zip: return ["--format", "zip"]
        case .sevenZip: return ["--format", "7zip"]
        case .tar: return ["--format", "pax"]
        case .tarGzip: return ["--format", "pax", "-z"]
        case .tarBzip2: return ["--format", "pax", "-j"]
        case .tarXz: return ["--format", "pax", "-J"]
        }
    }
}

/// Runs the system archiver directly without a shell. Work stays inside a fresh,
/// private directory on the destination volume until the operation succeeds.
final class ArchiveJob {
    static let suffixes = ["tar.bz2", "tar.gz", "tar.xz", "tbz2", "tgz", "txz", "tbz", "zip", "7z", "rar", "tar", "gz", "bz2"]
    static let fm = FileManager.default
    let process = Process()
    let staging: URL
    let payload: URL
    let proposed: URL
    let outputExtension: String?
    let log: URL
    private var handles: [FileHandle] = []

    static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in suffixes where name.lowercased().hasSuffix("." + suffix) {
            return String(name.dropLast(suffix.count + 1))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func cleanName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"), !name.contains("\n") else {
            throw ArchiveError.message("请输入有效名称，不能包含 /、: 或换行。")
        }
        return name
    }

    init(archive: URL, destination: URL) throws {
        let name = try Self.cleanName(Self.stem(of: archive))
        staging = destination.appendingPathComponent(".archive-job-" + UUID().uuidString)
        payload = staging.appendingPathComponent("contents")
        proposed = destination.appendingPathComponent(name)
        outputExtension = nil
        log = staging.appendingPathComponent("error.log")
        try Self.fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try Self.fm.createDirectory(at: payload, withIntermediateDirectories: false)
            // A bare .gz/.bz2 is a compressed stream rather than an archive.
            let lower = archive.lastPathComponent.lowercased()
            let isGzip = lower.hasSuffix(".gz") && !lower.hasSuffix(".tar.gz")
            let isBzip = lower.hasSuffix(".bz2") && !lower.hasSuffix(".tar.bz2")
            if isGzip || isBzip {
                let output = payload.appendingPathComponent(try Self.cleanName(archive.deletingPathExtension().lastPathComponent))
                guard Self.fm.createFile(atPath: output.path, contents: nil) else { throw ArchiveError.message("无法创建解压文件。") }
                let handle = try FileHandle(forWritingTo: output)
                handles.append(handle)
                process.standardOutput = handle
                process.executableURL = URL(fileURLWithPath: isGzip ? "/usr/bin/gzip" : "/usr/bin/bzip2")
                process.arguments = ["-dc", "--", archive.path]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                // Do not add -P: default path traversal and symlink protections are required.
                process.arguments = ["-xf", archive.path, "-C", payload.path, "--no-same-owner", "--no-same-permissions"]
            }
            try launch()
        } catch { cleanup(); throw error }
    }

    init(inputs: [URL], destination: URL, name: String, format: CompressionFormat) throws {
        guard !inputs.isEmpty else { throw ArchiveError.message("请先选择要压缩的文件或文件夹。") }
        let base = try Self.cleanName(name)
        var sources: [URL] = []
        for url in inputs.map({ $0.standardizedFileURL }) {
            guard Self.fm.fileExists(atPath: url.path) else { throw ArchiveError.message("找不到所选项目：\(url.lastPathComponent)") }
            // If a real folder is selected, its children are already included.
            let covered = inputs.contains { parent in
                guard parent.standardizedFileURL != url,
                      let info = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      info.isDirectory == true, info.isSymbolicLink != true else { return false }
                return url.path.hasPrefix(parent.standardizedFileURL.path + "/")
            }
            if !covered && !sources.contains(url) { sources.append(url) }
        }
        // ZIP/7Z readers commonly compare file names without case sensitivity.
        var seen = Set<String>()
        for url in sources {
            guard seen.insert(url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ArchiveError.message("所选项目存在同名文件或文件夹：\(url.lastPathComponent)。请先改名，避免压缩后冲突。")
            }
        }
        staging = destination.appendingPathComponent(".archive-job-" + UUID().uuidString)
        payload = staging.appendingPathComponent("archive." + format.rawValue)
        proposed = destination.appendingPathComponent(base + "." + format.rawValue)
        outputExtension = format.rawValue
        log = staging.appendingPathComponent("error.log")
        try Self.fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            // Exclude our work directory even when saving inside a selected folder.
            var args = ["-c", "-f", payload.path] + format.arguments
            args += ["--exclude", staging.lastPathComponent]
            for url in sources {
                // ./ prevents leading '-' and '@' in names being parsed as instructions.
                args += ["-C", url.deletingLastPathComponent().path, "./" + url.lastPathComponent]
            }
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["COPYFILE_DISABLE"] = "1"
            process.environment = environment
            try launch()
        } catch { cleanup(); throw error }
    }

    private func launch() throws {
        guard Self.fm.createFile(atPath: log.path, contents: nil) else { throw ArchiveError.message("无法写入保存位置，请检查权限。") }
        let handle = try FileHandle(forWritingTo: log)
        handles.append(handle)
        process.standardError = handle
        if process.standardOutput == nil { process.standardOutput = FileHandle.nullDevice }
        process.standardInput = FileHandle.nullDevice
        defer { closeHandles() }
        try process.run()
    }

    private func closeHandles() { for handle in handles { try? handle.close() }; handles.removeAll() }

    func errorDetail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 6000 ? size - 6000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finish() throws -> URL {
        guard process.terminationStatus == 0 else {
            throw ArchiveError.message(errorDetail().isEmpty ? "操作失败，请检查文件是否完整、格式是否受支持。" : errorDetail())
        }
        var output = proposed
        var index = 2
        let base = outputExtension.map { String(proposed.lastPathComponent.dropLast($0.count + 1)) } ?? proposed.lastPathComponent
        while Self.fm.fileExists(atPath: output.path) {
            let name = base + " (\(index))" + (outputExtension.map { "." + $0 } ?? "")
            output = proposed.deletingLastPathComponent().appendingPathComponent(name)
            index += 1
        }
        // moveItem fails instead of replacing a path created by a concurrent writer.
        try Self.fm.moveItem(at: payload, to: output)
        cleanup()
        return output
    }

    func cleanup() { closeHandles(); try? Self.fm.removeItem(at: staging) }
}
