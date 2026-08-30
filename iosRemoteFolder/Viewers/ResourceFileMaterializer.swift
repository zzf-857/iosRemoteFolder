import Foundation
import UniformTypeIdentifiers

/// Owns one isolated temporary directory containing a complete local resource.
///
/// Call `close()` as soon as the system viewer is dismissed. Deinitialization is
/// a final cleanup guard for interrupted SwiftUI presentation lifecycles.
final class MaterializedResourceFileLease: @unchecked Sendable {
    final class UsageToken: @unchecked Sendable {
        private let stateLock = NSLock()
        private var lease: MaterializedResourceFileLease?

        fileprivate init(lease: MaterializedResourceFileLease) {
            self.lease = lease
        }

        /// Releases this consumer's claim. Repeated calls are harmless.
        func release() {
            let lease = stateLock.withLock {
                defer { self.lease = nil }
                return self.lease
            }
            lease?.releaseUsage()
        }

        deinit {
            release()
        }
    }

    let fileURL: URL
    let displayName: String
    let byteCount: Int64
    let typeIdentifier: String?

    private let directoryURL: URL
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var closeRequested = false
    private var closed = false
    private var activeUsageCount = 0
    private var cleanupInProgress = false

    fileprivate init(
        fileURL: URL,
        displayName: String,
        byteCount: Int64,
        typeIdentifier: String?,
        directoryURL: URL,
        fileManager: FileManager
    ) {
        self.fileURL = fileURL
        self.displayName = displayName
        self.byteCount = byteCount
        self.typeIdentifier = typeIdentifier
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    var isClosed: Bool {
        stateLock.withLock { closed }
    }

    var isCloseRequested: Bool {
        stateLock.withLock { closeRequested }
    }

    /// Keeps the materialized file alive while a system consumer may still read
    /// its URL. New consumers are rejected after the owner requests closure.
    func acquireUsage() -> UsageToken? {
        stateLock.withLock {
            guard !closeRequested, !closed else { return nil }
            activeUsageCount += 1
            return UsageToken(lease: self)
        }
    }

    /// Requests removal of the lease's whole UUID directory. Actual cleanup is
    /// deferred until Quick Look, Share, and Open In release all usage tokens.
    func close() {
        let shouldCleanUp = stateLock.withLock {
            guard !closed else { return false }
            closeRequested = true
            return beginCleanupIfPossible()
        }
        if shouldCleanUp {
            cleanUpDirectory()
        }
    }

    deinit {
        close()
    }

    private func releaseUsage() {
        let shouldCleanUp = stateLock.withLock {
            guard activeUsageCount > 0 else { return false }
            activeUsageCount -= 1
            return beginCleanupIfPossible()
        }
        if shouldCleanUp {
            cleanUpDirectory()
        }
    }

    /// Must only be called while `stateLock` is held.
    private func beginCleanupIfPossible() -> Bool {
        guard closeRequested,
              activeUsageCount == 0,
              !closed,
              !cleanupInProgress else {
            return false
        }
        cleanupInProgress = true
        return true
    }

    private func cleanUpDirectory() {
        let removed: Bool
        do {
            try fileManager.removeItem(at: directoryURL)
            removed = true
        } catch {
            // An externally removed directory is already a successful close.
            // Other failures remain retryable on the next close or deinit.
            removed = !fileManager.fileExists(atPath: directoryURL.path)
        }
        stateLock.withLock {
            cleanupInProgress = false
            if removed {
                closed = true
            }
        }
    }
}

/// Materializes only complete resources whose length is already known and fits
/// an explicit small-file budget. The in-memory `Data` path is intentionally the
/// FMT-003 system-fallback slice; unknown-length streaming and an <=8 MiB working
/// set remain FMT-004 work and are not claimed here.
struct ResourceFileMaterializer: @unchecked Sendable {
    typealias DataWriter = @Sendable (_ data: Data, _ destination: URL) throws -> Void

    static let defaultRootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("iosRemoteFolder", isDirectory: true)
        .appendingPathComponent("system-fallback-v1", isDirectory: true)

    private static let maximumFilenameBytes = 128
    private static let maximumExtensionBytes = 16

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let dataWriter: DataWriter

    init(
        rootDirectory: URL = Self.defaultRootDirectory,
        fileManager: FileManager = .default,
        dataWriter: @escaping DataWriter = { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.dataWriter = dataWriter
    }

    /// Reads a known-size complete body through the controlled content session,
    /// then gives the resulting local file an independently owned lifetime.
    func materialize(
        session: ResourceContentSession,
        suggestedFilename: String,
        suggestedTypeIdentifier: String? = nil,
        maximumBytes: Int64
    ) async throws -> MaterializedResourceFileLease {
        try Self.checkCancellation()
        guard maximumBytes >= 0 else {
            throw ResourceSourceError.invalidReference
        }

        let metadata = try await session.fetchMetadata()
        guard let byteCount = metadata.byteSize,
              byteCount >= 0,
              byteCount <= maximumBytes else {
            throw ResourceSourceError.responseTooLarge
        }

        let data: Data
        if byteCount == 0 {
            data = Data()
        } else {
            data = try await session.readData(maximumBytes: maximumBytes)
        }
        try Self.checkCancellation()
        return try await materialize(
            data: data,
            knownByteCount: byteCount,
            suggestedFilename: suggestedFilename,
            suggestedTypeIdentifier: suggestedTypeIdentifier,
            maximumBytes: maximumBytes
        )
    }

    /// Writes a complete, already bounded body. Validation happens before any
    /// directory is created, so a rejected resource performs zero writes.
    @concurrent
    func materialize(
        data: Data,
        knownByteCount: Int64,
        suggestedFilename: String,
        suggestedTypeIdentifier: String? = nil,
        maximumBytes: Int64
    ) async throws -> MaterializedResourceFileLease {
        do {
            try Self.checkCancellation()
            guard maximumBytes >= 0, knownByteCount >= 0 else {
                throw ResourceSourceError.invalidReference
            }
            guard knownByteCount <= maximumBytes else {
                throw ResourceSourceError.responseTooLarge
            }
            guard let actualByteCount = Int64(exactly: data.count),
                  actualByteCount == knownByteCount else {
                throw ResourceSourceError.invalidResponse
            }

            let typeIdentifier = Self.normalizedTypeIdentifier(suggestedTypeIdentifier)
            let displayName = Self.safeFilename(
                for: suggestedFilename,
                suggestedTypeIdentifier: typeIdentifier
            )
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.checkCancellation()

            let directoryURL = rootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            var transferredDirectoryOwnership = false
            defer {
                if !transferredDirectoryOwnership {
                    try? fileManager.removeItem(at: directoryURL)
                }
            }

            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.checkCancellation()

            let fileURL = directoryURL.appendingPathComponent(
                displayName,
                isDirectory: false
            )
            try dataWriter(data, fileURL)
            try Self.checkCancellation()

            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let persistedSize = attributes[.size] as? NSNumber,
                  persistedSize.int64Value == knownByteCount else {
                throw ResourceSourceError.invalidResponse
            }

            let lease = MaterializedResourceFileLease(
                fileURL: fileURL,
                displayName: displayName,
                byteCount: knownByteCount,
                typeIdentifier: typeIdentifier,
                directoryURL: directoryURL,
                fileManager: fileManager
            )
            transferredDirectoryOwnership = true
            return lease
        } catch let error as ResourceSourceError {
            throw error
        } catch is CancellationError {
            throw ResourceSourceError.cancelled
        } catch {
            throw ResourceSourceError.mapping(error)
        }
    }

    /// Produces one visible path component while preserving a short ASCII file
    /// extension so Quick Look and receiving apps can resolve the document type.
    static func safeFilename(
        for suggestedFilename: String,
        suggestedTypeIdentifier: String? = nil
    ) -> String {
        let slashNormalized = suggestedFilename.replacingOccurrences(of: "\\", with: "/")
        let leaf = slashNormalized.split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .precomposedStringWithCanonicalMapping ?? ""
        let pathExtension = (leaf as NSString).pathExtension
        let originalExtension = asciiExtension(pathExtension)
        let extensionValue = originalExtension.isEmpty
            ? preferredFilenameExtension(for: suggestedTypeIdentifier)
            : originalExtension
        let rawStem: String
        if pathExtension.isEmpty {
            rawStem = leaf
        } else {
            rawStem = (leaf as NSString).deletingPathExtension
        }

        let cleanedStem = sanitizeStem(rawStem)
        let suffix = extensionValue.isEmpty ? "" : ".\(extensionValue)"
        let stemBudget = max(1, maximumFilenameBytes - suffix.utf8.count)
        var boundedStem = prefix(cleanedStem, maximumUTF8Bytes: stemBudget)
        if boundedStem.isEmpty {
            boundedStem = "resource"
        }
        return boundedStem + suffix
    }

    private static func asciiExtension(_ value: String) -> String {
        let bytes = value.utf8
        guard !bytes.isEmpty,
              bytes.count <= maximumExtensionBytes,
              bytes.allSatisfy({ byte in
            switch byte {
            case 48...57, 65...90, 97...122:
                true
            default:
                false
            }
        }) else {
            return ""
        }
        return value
    }

    private static func normalizedTypeIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let type = UTType(value),
              !type.conforms(to: .folder) else {
            return nil
        }
        return type.identifier
    }

    private static func preferredFilenameExtension(for typeIdentifier: String?) -> String {
        guard let typeIdentifier = normalizedTypeIdentifier(typeIdentifier),
              let preferredExtension = UTType(typeIdentifier)?.preferredFilenameExtension else {
            return ""
        }
        return asciiExtension(preferredExtension)
    }

    private static func sanitizeStem(_ value: String) -> String {
        var result = ""
        var previousWasReplacement = false

        for scalar in value.unicodeScalars {
            let shouldReplace = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || scalar == "/"
                || scalar == "\\"
                || scalar == ":"
                || isBidirectionalControl(scalar.value)
            if shouldReplace {
                if !previousWasReplacement {
                    result.append("_")
                }
                previousWasReplacement = true
            } else {
                result.unicodeScalars.append(scalar)
                previousWasReplacement = false
            }
        }

        return result.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".")
            )
        )
    }

    private static func isBidirectionalControl(_ value: UInt32) -> Bool {
        switch value {
        case 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            true
        default:
            false
        }
    }

    private static func prefix(_ value: String, maximumUTF8Bytes: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumUTF8Bytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func checkCancellation() throws {
        guard !Task.isCancelled else {
            throw ResourceSourceError.cancelled
        }
    }
}

extension ResolvedContentType {
    /// The strongest concrete system type that can safely label a materialized
    /// fallback file. Blocking conflicts never reach file preparation.
    var preferredSystemTypeIdentifier: String? {
        guard !hasBlockingConflict else { return nil }
        return evidence
            .compactMap { evidence -> (priority: Int, rawValue: String, identifier: String)? in
                guard let identifier = evidence.canonicalTypeIdentifier else { return nil }
                let priority: Int
                switch evidence.source {
                case .typeIdentifier:
                    priority = 0
                case .mimeType:
                    priority = 1
                case .filenameExtension:
                    priority = 2
                case .directory, .declaredKind:
                    return nil
                }
                return (priority, evidence.rawValue, identifier)
            }
            .sorted {
                if $0.priority != $1.priority {
                    return $0.priority < $1.priority
                }
                if $0.rawValue != $1.rawValue {
                    return $0.rawValue < $1.rawValue
                }
                return $0.identifier < $1.identifier
            }
            .first?
            .identifier
    }
}
