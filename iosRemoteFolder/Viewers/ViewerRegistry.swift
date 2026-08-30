import Foundation
import UniformTypeIdentifiers

/// A deterministic content-type decision shared by filtering, previews, and viewers.
/// Source adapters keep supplying `ResourceItem.kind`, but it is deliberately the
/// weakest evidence and cannot overrule typed metadata or a known extension.
struct ResolvedContentType: Hashable, Sendable {
    enum Confidence: Int, Hashable, Sendable {
        case none
        case low
        case medium
        case high
        case authoritative
    }

    struct Evidence: Hashable, Sendable {
        enum Source: Hashable, Sendable {
            case directory
            case typeIdentifier
            case mimeType
            case filenameExtension
            case declaredKind
            case signature
        }

        enum Strength: Int, Hashable, Sendable {
            case generic
            case declared
            case inferred
            case typed
            case authoritative
        }

        let source: Source
        let rawValue: String
        let kind: ResourceKind
        let strength: Strength
        let canonicalTypeIdentifier: String?
    }

    enum Diagnostic: Hashable, Sendable {
        case conflictingTypedMetadata(
            typeIdentifier: ResourceKind,
            mimeType: ResourceKind
        )
        case metadataExtensionMismatch(
            metadata: ResourceKind,
            filenameExtension: ResourceKind
        )
        case signatureMismatch(
            expected: ResourceKind,
            signature: ResourceKind,
            formatToken: String
        )
        case declaredKindOverridden(
            declared: ResourceKind,
            signature: ResourceKind,
            formatToken: String
        )
        case unresolved
    }

    enum SignatureProbe: Hashable, Sendable {
        case required
        case notRequired
        case unavailable
        case noMatch
        case matched(ContentSignatureMatch)

        var requiresInspection: Bool {
            self == .required
        }

        var isCacheable: Bool {
            self != .required && self != .unavailable
        }

        fileprivate var fingerprintToken: String {
            switch self {
            case .required:
                "required"
            case .notRequired:
                "not-required"
            case .unavailable:
                "unavailable"
            case .noMatch:
                "no-match"
            case .matched(let match):
                [
                    "matched",
                    match.formatToken,
                    match.strength.rawValue,
                    match.kind.rawValue,
                    match.canonicalTypeIdentifier?.lowercased() ?? "none"
                ].joined(separator: ":")
            }
        }
    }

    let kind: ResourceKind
    let evidence: Set<Evidence>
    let confidence: Confidence
    let diagnostics: Set<Diagnostic>
    let signatureProbe: SignatureProbe

    init(
        kind: ResourceKind,
        evidence: Set<Evidence>,
        confidence: Confidence,
        diagnostics: Set<Diagnostic>,
        signatureProbe: SignatureProbe = .notRequired
    ) {
        self.kind = kind
        self.evidence = evidence
        self.confidence = confidence
        self.diagnostics = diagnostics
        self.signatureProbe = signatureProbe
    }

    var hasBlockingConflict: Bool {
        diagnostics.contains { diagnostic in
            switch diagnostic {
            case .conflictingTypedMetadata, .metadataExtensionMismatch, .signatureMismatch:
                true
            case .declaredKindOverridden, .unresolved:
                false
            }
        }
    }

    var stableFingerprint: String {
        // Native renderers only depend on the resolved kind. System fallback
        // keeps canonical identifiers so distinct unsupported formats do not
        // share a cache key. Evidence source and confidence are intentionally
        // excluded: list metadata often becomes more specific after a HEAD
        // without changing the renderer or bytes.
        let canonicalTypes = kind == .unknown
            ? Set(evidence.compactMap(\.canonicalTypeIdentifier)).sorted()
            : []
        let diagnosticTokens = diagnostics
            .map(\.fingerprintToken)
            .sorted()
        return [
            "resolved-content-v3",
            "kind=\(kind.rawValue)",
            "blocking=\(hasBlockingConflict ? 1 : 0)",
            "diagnostics=\(diagnosticTokens.joined(separator: ","))",
            "canonical=\(canonicalTypes.joined(separator: ","))",
            "signature=\(signatureProbe.fingerprintToken)"
        ].joined(separator: ";")
    }

    var fallbackDescription: String? {
        if diagnostics.contains(where: { diagnostic in
            if case .conflictingTypedMetadata = diagnostic { return true }
            return false
        }) {
            return "文件类型元数据互相冲突"
        }
        if diagnostics.contains(where: { diagnostic in
            if case .metadataExtensionMismatch = diagnostic { return true }
            return false
        }) {
            return "文件类型与扩展名不一致"
        }
        if diagnostics.contains(where: { diagnostic in
            if case .signatureMismatch = diagnostic { return true }
            return false
        }) {
            return "文件签名与声明类型不一致"
        }
        return diagnostics.contains(.unresolved)
            ? "无法从资源元数据确认内容类型"
            : nil
    }

    static func resolve(
        resource: ResourceItem,
        metadata: ResourceMetadata
    ) -> ResolvedContentType {
        resolveBase(resource: resource, metadata: metadata)
            .markingSignatureRequirement()
    }

    static func resolve(
        resource: ResourceItem,
        metadata: ResourceMetadata,
        signatureProbe: SignatureProbe
    ) -> ResolvedContentType {
        let preliminary = resolve(resource: resource, metadata: metadata)
        guard preliminary.signatureProbe.requiresInspection else {
            return preliminary
        }
        switch signatureProbe {
        case .required:
            return preliminary
        case .notRequired:
            return preliminary.withSignatureProbe(.notRequired)
        case .unavailable:
            return preliminary.withSignatureProbe(.unavailable)
        case .noMatch:
            return preliminary.withSignatureProbe(.noMatch)
        case .matched(let match):
            return preliminary.merging(signature: match)
        }
    }

    private static func resolveBase(
        resource: ResourceItem,
        metadata: ResourceMetadata
    ) -> ResolvedContentType {
        var evidence: Set<Evidence> = [
            Evidence(
                source: .declaredKind,
                rawValue: resource.kind.rawValue,
                kind: resource.kind,
                strength: .declared,
                canonicalTypeIdentifier: nil
            )
        ]

        if metadata.isDirectory {
            evidence.insert(Evidence(
                source: .directory,
                rawValue: "true",
                kind: .folder,
                strength: .authoritative,
                canonicalTypeIdentifier: nil
            ))
        }

        let identifierEvidence = typeIdentifierEvidence(metadata.typeIdentifier)
        let mimeEvidence = mimeTypeEvidence(metadata.mimeType)
        let extensionEvidence = filenameExtensionEvidence(resource.path)
        if let identifierEvidence { evidence.insert(identifierEvidence) }
        if let mimeEvidence { evidence.insert(mimeEvidence) }
        if let extensionEvidence { evidence.insert(extensionEvidence) }

        // Authoritative directory metadata always blocks content reads. A source-
        // declared folder remains the conservative fallback unless concrete typed
        // metadata identifies a file; extensions alone cannot override it because
        // directory names legitimately contain dots.
        if metadata.isDirectory
            || (resource.kind == .folder
                && ![identifierEvidence, mimeEvidence]
                    .compactMap({ $0 })
                    .contains(where: \.isConcreteTypedFile)) {
            return ResolvedContentType(
                kind: .folder,
                evidence: evidence,
                confidence: metadata.isDirectory ? .authoritative : .low,
                diagnostics: []
            )
        }

        let identifierKind = identifierEvidence?.candidateKind
        let mimeKind = mimeEvidence?.candidateKind
        if typedEvidenceConflicts(identifierEvidence, mimeEvidence) {
            return ResolvedContentType(
                kind: .unknown,
                evidence: evidence,
                confidence: .none,
                diagnostics: [.conflictingTypedMetadata(
                    typeIdentifier: identifierKind ?? .unknown,
                    mimeType: mimeKind ?? .unknown
                )]
            )
        }

        let metadataKind = preferredKind(identifierKind, mimeKind)
        let extensionKind = extensionEvidence?.candidateKind
        if extensionConflicts(
            identifierEvidence: identifierEvidence,
            mimeEvidence: mimeEvidence,
            metadataKind: metadataKind,
            extensionEvidence: extensionEvidence,
            extensionKind: extensionKind
        ) {
            return ResolvedContentType(
                kind: .unknown,
                evidence: evidence,
                confidence: .none,
                diagnostics: [.metadataExtensionMismatch(
                    metadata: metadataKind ?? .unknown,
                    filenameExtension: extensionKind ?? .unknown
                )]
            )
        }

        if let metadataKind {
            return ResolvedContentType(
                kind: preferredKind(metadataKind, extensionKind) ?? metadataKind,
                evidence: evidence,
                confidence: .high,
                diagnostics: []
            )
        }
        if let extensionKind {
            return ResolvedContentType(
                kind: extensionKind,
                evidence: evidence,
                confidence: .medium,
                diagnostics: []
            )
        }
        if [identifierEvidence, mimeEvidence]
            .compactMap({ $0 })
            .contains(where: \.isConcreteTyped) {
            // A concrete system type that has no native ResourceKind (Office,
            // archives, packages, and similar formats) still outranks the
            // adapter's coarse hint. Keep it on the system-fallback path.
            return ResolvedContentType(
                kind: .unknown,
                evidence: evidence,
                confidence: .high,
                diagnostics: []
            )
        }
        if extensionEvidence?.hasConcreteSystemType == true {
            // Known system-only extensions (Office, iWork, archives, and similar)
            // must outrank a coarse declared kind even without typed metadata.
            return ResolvedContentType(
                kind: .unknown,
                evidence: evidence,
                confidence: .medium,
                diagnostics: []
            )
        }
        if let declaredKind = resource.kind.contentCandidate {
            return ResolvedContentType(
                kind: declaredKind,
                evidence: evidence,
                confidence: .low,
                diagnostics: []
            )
        }
        return ResolvedContentType(
            kind: .unknown,
            evidence: evidence,
            confidence: .none,
            diagnostics: [.unresolved]
        )
    }

    private func markingSignatureRequirement() -> ResolvedContentType {
        guard kind != .folder,
              !hasBlockingConflict,
              confidence.rawValue <= Confidence.medium.rawValue || kind == .unknown else {
            return withSignatureProbe(.notRequired)
        }
        return withSignatureProbe(.required)
    }

    private func withSignatureProbe(_ probe: SignatureProbe) -> ResolvedContentType {
        ResolvedContentType(
            kind: kind,
            evidence: evidence,
            confidence: confidence,
            diagnostics: diagnostics,
            signatureProbe: probe
        )
    }

    private func merging(signature match: ContentSignatureMatch) -> ResolvedContentType {
        let signatureEvidence = Evidence(
            source: .signature,
            rawValue: match.formatToken,
            kind: match.kind,
            strength: match.evidenceStrength,
            canonicalTypeIdentifier: match.canonicalTypeIdentifier
        )
        let mergedEvidence = evidence.union([signatureEvidence])
        let concreteEvidence = evidence.filter { evidence in
            evidence.source != .declaredKind
                && evidence.source != .directory
                && evidence.strength != .generic
                && (evidence.candidateKind != nil || evidence.canonicalTypeIdentifier != nil)
        }
        let hasOnlyWeakDeclaredHint = concreteEvidence.isEmpty

        if match.strength == .heuristic {
            guard kind == .unknown,
                  concreteEvidence.isEmpty,
                  match.kind != .unknown else {
                return replacing(
                    evidence: mergedEvidence,
                    signatureProbe: .matched(match)
                )
            }
            return replacing(
                kind: match.kind,
                evidence: mergedEvidence,
                confidence: .medium,
                diagnostics: diagnostics.removingUnresolved,
                signatureProbe: .matched(match)
            )
        }

        if match.strength == .container {
            if concreteEvidence.isEmpty, kind == .unknown {
                return replacing(
                    evidence: mergedEvidence,
                    confidence: Self.strongerConfidence(confidence, .high),
                    diagnostics: diagnostics.removingUnresolved,
                    signatureProbe: .matched(match)
                )
            }
            if concreteEvidence.isEmpty,
               Self.container(match, isCompatibleWith: kind) {
                return replacing(
                    evidence: mergedEvidence,
                    confidence: Self.strongerConfidence(confidence, .high),
                    signatureProbe: .matched(match)
                )
            }
            if Self.container(match, isCompatibleWith: concreteEvidence) {
                return replacing(
                    evidence: mergedEvidence,
                    confidence: Self.strongerConfidence(confidence, .high),
                    diagnostics: diagnostics.removingUnresolved,
                    signatureProbe: .matched(match)
                )
            }
            if hasOnlyWeakDeclaredHint {
                var updatedDiagnostics = diagnostics.removingUnresolved
                updatedDiagnostics.insert(.declaredKindOverridden(
                    declared: kind,
                    signature: .unknown,
                    formatToken: match.formatToken
                ))
                return replacing(
                    kind: .unknown,
                    evidence: mergedEvidence,
                    confidence: .high,
                    diagnostics: updatedDiagnostics,
                    signatureProbe: .matched(match)
                )
            }
            return blockingSignatureMismatch(match, evidence: mergedEvidence)
        }

        guard match.kind != .unknown else {
            return replacing(
                evidence: mergedEvidence,
                signatureProbe: .matched(match)
            )
        }
        if concreteEvidence.contains(where: {
            Self.exactSignature(signatureEvidence, conflictsWith: $0)
        }) {
            return blockingSignatureMismatch(match, evidence: mergedEvidence)
        }
        if kind == .unknown {
            return replacing(
                kind: match.kind,
                evidence: mergedEvidence,
                confidence: .high,
                diagnostics: diagnostics.removingUnresolved,
                signatureProbe: .matched(match)
            )
        }
        if Self.areCompatible(kind, match.kind) {
            return replacing(
                kind: Self.preferredKind(kind, match.kind) ?? kind,
                evidence: mergedEvidence,
                confidence: .high,
                signatureProbe: .matched(match)
            )
        }
        if hasOnlyWeakDeclaredHint {
            var updatedDiagnostics = diagnostics.removingUnresolved
            updatedDiagnostics.insert(.declaredKindOverridden(
                declared: kind,
                signature: match.kind,
                formatToken: match.formatToken
            ))
            return replacing(
                kind: match.kind,
                evidence: mergedEvidence,
                confidence: .high,
                diagnostics: updatedDiagnostics,
                signatureProbe: .matched(match)
            )
        }
        return blockingSignatureMismatch(match, evidence: mergedEvidence)
    }

    private func blockingSignatureMismatch(
        _ match: ContentSignatureMatch,
        evidence: Set<Evidence>
    ) -> ResolvedContentType {
        ResolvedContentType(
            kind: .unknown,
            evidence: evidence,
            confidence: .none,
            diagnostics: [.signatureMismatch(
                expected: kind,
                signature: match.kind,
                formatToken: match.formatToken
            )],
            signatureProbe: .matched(match)
        )
    }

    private func replacing(
        kind: ResourceKind? = nil,
        evidence: Set<Evidence>? = nil,
        confidence: Confidence? = nil,
        diagnostics: Set<Diagnostic>? = nil,
        signatureProbe: SignatureProbe
    ) -> ResolvedContentType {
        ResolvedContentType(
            kind: kind ?? self.kind,
            evidence: evidence ?? self.evidence,
            confidence: confidence ?? self.confidence,
            diagnostics: diagnostics ?? self.diagnostics,
            signatureProbe: signatureProbe
        )
    }

    private static func strongerConfidence(
        _ first: Confidence,
        _ second: Confidence
    ) -> Confidence {
        first.rawValue >= second.rawValue ? first : second
    }

    private static func container(
        _ match: ContentSignatureMatch,
        isCompatibleWith kind: ResourceKind
    ) -> Bool {
        switch match.formatToken {
        case "iso-bmff", "ebml", "matroska", "webm":
            kind == .audio || kind == .video
        case "zip":
            false
        default:
            false
        }
    }

    private static func container(
        _ match: ContentSignatureMatch,
        isCompatibleWith evidence: Set<Evidence>
    ) -> Bool {
        !evidence.isEmpty && evidence.allSatisfy {
            container(match, isCompatibleWith: $0)
        }
    }

    private static func container(
        _ match: ContentSignatureMatch,
        isCompatibleWith evidence: Evidence
    ) -> Bool {
        let acceptedTokens: Set<String>
        switch match.formatToken {
        case "zip":
            acceptedTokens = zipContainerTokens
        case "iso-bmff":
            acceptedTokens = isoBaseMediaContainerTokens
        case "webm":
            acceptedTokens = webMContainerTokens
        case "matroska":
            acceptedTokens = matroskaContainerTokens
        case "ebml":
            acceptedTokens = webMContainerTokens.union(matroskaContainerTokens)
        default:
            return false
        }

        let tokens = compatibilityTokens(for: evidence)
        if !tokens.isDisjoint(with: acceptedTokens) {
            return true
        }

        // A filename extension or a concrete system type names a format, not
        // merely a broad media family. If it did not match the allowlist above,
        // treating it as compatible would miss MP3/BMFF and MP4/EBML conflicts.
        if evidence.source == .filenameExtension
            || evidence.canonicalTypeIdentifier != nil {
            return false
        }
        return container(match, isCompatibleWith: evidence.kind)
    }

    private static func compatibilityTokens(for evidence: Evidence) -> Set<String> {
        var tokens: Set<String> = [evidence.rawValue.lowercased()]
        if let identifier = evidence.canonicalTypeIdentifier?.lowercased() {
            tokens.insert(identifier)
            if let preferredExtension = UTType(identifier)?.preferredFilenameExtension {
                tokens.insert(preferredExtension.lowercased())
            }
        }
        return tokens
    }

    private static func exactSignature(
        _ signature: Evidence,
        conflictsWith other: Evidence
    ) -> Bool {
        guard signature.kind != .unknown else { return false }
        if let otherKind = other.candidateKind,
           !areCompatible(signature.kind, otherKind) {
            return true
        }
        if signature.kind.isTextLike, other.kind.isTextLike {
            return false
        }
        guard let signatureIdentifier = signature.canonicalTypeIdentifier?.lowercased(),
              let otherIdentifier = other.canonicalTypeIdentifier?.lowercased() else {
            return false
        }
        guard signatureIdentifier != otherIdentifier else { return false }
        if exactTypeIdentifierFamilies.contains(where: {
            $0.contains(signatureIdentifier) && $0.contains(otherIdentifier)
        }) {
            return false
        }
        guard let signatureType = UTType(signatureIdentifier),
              let otherType = UTType(otherIdentifier) else {
            return true
        }
        return !signatureType.conforms(to: otherType)
            && !otherType.conforms(to: signatureType)
    }

    private static let zipContainerTokens: Set<String> = [
        "zip", "application/zip", "application/x-zip-compressed", "public.zip-archive",
        "docx", "docm", "dotx", "dotm",
        "xlsx", "xlsm", "xltx", "xltm",
        "pptx", "pptm", "potx", "potm", "ppsx", "ppsm",
        "pages", "numbers", "keynote", "epub", "jar", "war", "ear",
        "apk", "ipa", "cbz", "kmz", "xpi",
        "odt", "ods", "odp", "odg", "odf", "odm",
        "ott", "ots", "otp", "otg", "oth"
    ]

    private static let isoBaseMediaContainerTokens: Set<String> = [
        "mp4", "m4v", "mov", "m4a", "m4b", "m4p", "m4r", "3gp", "3g2",
        "video/mp4", "audio/mp4", "video/quicktime", "audio/x-m4a",
        "public.mpeg-4", "public.mpeg-4-audio", "com.apple.quicktime-movie"
    ]

    private static let exactTypeIdentifierFamilies: [Set<String>] = [
        ["public.heic", "public.heif"]
    ]

    private static let webMContainerTokens: Set<String> = [
        "webm", "video/webm", "audio/webm", "org.webmproject.webm"
    ]

    private static let matroskaContainerTokens: Set<String> = [
        "mkv", "mka", "mk3d", "video/x-matroska", "audio/x-matroska",
        "org.matroska.mkv", "org.matroska.mka"
    ]

    private static let genericMIMETypes: Set<String> = [
        "application/binary",
        "application/octet-stream",
        "application/unknown",
        "application/x-binary",
        "application/x-unknown",
        "binary/octet-stream"
    ]

    private static let genericTypeIdentifiers: Set<String> = [
        "public.content",
        "public.data",
        "public.item"
    ]

    private static func typeIdentifierEvidence(_ identifier: String?) -> Evidence? {
        guard let identifier = normalized(identifier) else { return nil }
        let isGeneric = genericTypeIdentifiers.contains(identifier)
        let type = UTType(identifier)
        return Evidence(
            source: .typeIdentifier,
            rawValue: identifier,
            kind: isGeneric ? .unknown : kind(forTypeIdentifier: identifier) ?? .unknown,
            strength: isGeneric ? .generic : .typed,
            canonicalTypeIdentifier: isGeneric ? nil : concreteIdentifier(for: type)
        )
    }

    private static func mimeTypeEvidence(_ mimeType: String?) -> Evidence? {
        guard let rawValue = normalized(mimeType),
              let mediaType = rawValue
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !mediaType.isEmpty else {
            return nil
        }
        let isGeneric = genericMIMETypes.contains(mediaType)
        let type = UTType(mimeType: mediaType)
        return Evidence(
            source: .mimeType,
            rawValue: mediaType,
            kind: isGeneric ? .unknown : kind(forMIMEType: mediaType) ?? .unknown,
            strength: isGeneric ? .generic : .typed,
            canonicalTypeIdentifier: isGeneric ? nil : concreteIdentifier(for: type)
        )
    }

    private static func filenameExtensionEvidence(_ path: String) -> Evidence? {
        let extensionName = (path as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !extensionName.isEmpty else { return nil }
        let type = UTType(filenameExtension: extensionName)
        return Evidence(
            source: .filenameExtension,
            rawValue: extensionName,
            kind: kind(forExtension: extensionName) ?? .unknown,
            strength: .inferred,
            canonicalTypeIdentifier: concreteIdentifier(for: type)
        )
    }

    private static func typedEvidenceConflicts(
        _ first: Evidence?,
        _ second: Evidence?
    ) -> Bool {
        guard let first, let second else { return false }
        if let firstKind = first.candidateKind,
           let secondKind = second.candidateKind,
           !areCompatible(firstKind, secondKind) {
            return true
        }
        return concreteTypesConflict(first, second)
    }

    private static func extensionConflicts(
        identifierEvidence: Evidence?,
        mimeEvidence: Evidence?,
        metadataKind: ResourceKind?,
        extensionEvidence: Evidence?,
        extensionKind: ResourceKind?
    ) -> Bool {
        guard let extensionEvidence else { return false }
        if let metadataKind,
           let extensionKind,
           !areCompatible(metadataKind, extensionKind) {
            return true
        }
        return [identifierEvidence, mimeEvidence]
            .compactMap { $0 }
            .contains { concreteTypesConflict($0, extensionEvidence) }
    }

    private static func concreteTypesConflict(
        _ first: Evidence,
        _ second: Evidence
    ) -> Bool {
        // Plain-text metadata is commonly paired with a more specific JSON,
        // HTML, XML, or Markdown extension. These are safe viewer-compatible
        // refinements even when their sibling UTTypes do not conform directly.
        if first.kind.isTextLike, second.kind.isTextLike {
            return false
        }
        guard let firstIdentifier = first.canonicalTypeIdentifier,
              let secondIdentifier = second.canonicalTypeIdentifier,
              let firstType = UTType(firstIdentifier),
              let secondType = UTType(secondIdentifier) else {
            return false
        }
        return firstType != secondType
            && !firstType.conforms(to: secondType)
            && !secondType.conforms(to: firstType)
    }

    private static func concreteIdentifier(for type: UTType?) -> String? {
        guard let type else { return nil }
        let identifier = type.identifier.lowercased()
        guard !genericTypeIdentifiers.contains(identifier),
              !identifier.hasPrefix("dyn.") else {
            return nil
        }
        return identifier
    }

    private static func kind(forTypeIdentifier identifier: String) -> ResourceKind? {
        if identifier.localizedCaseInsensitiveContains("markdown") {
            return .markdown
        }
        guard let type = UTType(identifier) else { return nil }
        return kind(for: type)
    }

    private static func kind(forMIMEType mimeType: String) -> ResourceKind? {
        if mimeType == "application/pdf" { return .pdf }
        if mimeType == "text/markdown" || mimeType == "text/x-markdown" {
            return .markdown
        }
        if mimeType.hasPrefix("text/") { return .text }
        if let type = UTType(mimeType: mimeType), let resolvedKind = kind(for: type) {
            return resolvedKind
        }

        // Some valid vendor media MIME types map to dynamic UTTypes that do not
        // conform to the public media hierarchy. Preserve the declared family;
        // the selected decoder still validates the actual bytes before display.
        let components = mimeType.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, !components[1].isEmpty else { return nil }
        switch components[0] {
        case "image": return .image
        case "video": return .video
        case "audio": return .audio
        default: return nil
        }
    }

    private static func kind(forExtension extensionName: String) -> ResourceKind? {
        switch extensionName {
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        case "txt", "text", "log": return .text
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp": return .image
        case "mp4", "mov", "m4v", "mkv": return .video
        case "mp3", "m4a", "aac", "flac", "wav": return .audio
        default:
            guard let type = UTType(filenameExtension: extensionName) else { return nil }
            return kind(for: type)
        }
    }

    private static func kind(for type: UTType) -> ResourceKind? {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) { return .text }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    private static func preferredKind(
        _ first: ResourceKind?,
        _ second: ResourceKind?
    ) -> ResourceKind? {
        switch (first, second) {
        case (.some(.markdown), _), (_, .some(.markdown)):
            .markdown
        case (.some(let first), .some(let second)) where first == second:
            first
        case (.some(let first), _):
            first
        case (_, .some(let second)):
            second
        default:
            nil
        }
    }

    private static func areCompatible(_ first: ResourceKind, _ second: ResourceKind) -> Bool {
        first == second || (first.isTextLike && second.isTextLike)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

private extension ResolvedContentType.Diagnostic {
    var fingerprintToken: String {
        switch self {
        case .conflictingTypedMetadata(let typeIdentifier, let mimeType):
            "typed-conflict:\(typeIdentifier.rawValue):\(mimeType.rawValue)"
        case .metadataExtensionMismatch(let metadata, let filenameExtension):
            "extension-conflict:\(metadata.rawValue):\(filenameExtension.rawValue)"
        case .signatureMismatch(let expected, let signature, let formatToken):
            "signature-conflict:\(expected.rawValue):\(signature.rawValue):\(formatToken)"
        case .declaredKindOverridden(let declared, let signature, let formatToken):
            "declared-overridden:\(declared.rawValue):\(signature.rawValue):\(formatToken)"
        case .unresolved:
            "unresolved"
        }
    }
}

private extension ContentSignatureMatch {
    var evidenceStrength: ResolvedContentType.Evidence.Strength {
        switch strength {
        case .heuristic: .inferred
        case .container: .typed
        case .exact: .authoritative
        }
    }
}

private extension Set where Element == ResolvedContentType.Diagnostic {
    var removingUnresolved: Set<Element> {
        subtracting([.unresolved])
    }
}

private extension ResolvedContentType.Evidence {
    var candidateKind: ResourceKind? {
        kind == .unknown || kind == .folder ? nil : kind
    }

    var isConcreteTyped: Bool {
        strength == .typed && canonicalTypeIdentifier != nil
    }

    var hasConcreteSystemType: Bool {
        canonicalTypeIdentifier != nil
    }

    var isConcreteTypedFile: Bool {
        guard isConcreteTyped,
              let canonicalTypeIdentifier,
              let type = UTType(canonicalTypeIdentifier) else {
            return false
        }
        return !type.conforms(to: .folder)
    }
}

extension ResourceItem {
    var resolvedContentType: ResolvedContentType {
        ResolvedContentType.resolve(resource: self, metadata: metadata)
    }

    func resolvedContentType(using metadata: ResourceMetadata) -> ResolvedContentType {
        ResolvedContentType.resolve(resource: self, metadata: metadata)
    }
}

enum ResolvedContentTypeProbe {
    static func resolve(
        resource: ResourceItem,
        metadata: ResourceMetadata,
        session: ResourceContentSession
    ) async throws -> ResolvedContentType {
        let preliminary = resource.resolvedContentType(using: metadata)
        guard preliminary.signatureProbe.requiresInspection else {
            return preliminary
        }

        let prefix: Data
        do {
            prefix = try await session.readSignaturePrefix()
        } catch {
            let mapped = ResourceSourceError.mapping(error)
            guard mapped == .capabilityUnavailable else { throw mapped }
            return ResolvedContentType.resolve(
                resource: resource,
                metadata: metadata,
                signatureProbe: .unavailable
            )
        }
        try Task.checkCancellation()
        let match = ContentSignatureSniffer.sniff(prefix)
        return ResolvedContentType.resolve(
            resource: resource,
            metadata: metadata,
            signatureProbe: match.map(ResolvedContentType.SignatureProbe.matched) ?? .noMatch
        )
    }
}

enum ViewerKind: String, Sendable {
    case pdfReader
    case markdownReader
    case textReader
    case imageViewer
    case videoPlayer
    case musicPlayer
    case systemPreview
}

enum ViewerPreparation: Hashable, Sendable {
    case none
    case text(maximumBytes: Int64)
    case pdf(maximumBytes: Int64)
    case image(maximumBytes: Int64)
    case audio(maximumBytes: Int64)
    case video(maximumBytes: Int64)
    case file(maximumBytes: Int64)
}

struct ViewerResolution: Hashable, Sendable {
    let kind: ViewerKind
    let preparation: ViewerPreparation
    let fallbackDescription: String?
    let contentType: ResolvedContentType
}

struct ViewerRegistry {
    static let systemFallbackMaximumBytes: Int64 = 64 * 1024 * 1024

    static func viewer(for resource: ResourceItem) -> ViewerKind {
        resolve(resource: resource, metadata: resource.metadata).kind
    }

    /// Resolution only describes preparation; it performs no source request or materialization.
    static func resolve(
        resource: ResourceItem,
        metadata: ResourceMetadata
    ) -> ViewerResolution {
        resolve(contentType: resource.resolvedContentType(using: metadata))
    }

    static func resolve(contentType: ResolvedContentType) -> ViewerResolution {
        switch contentType.kind {
        case .folder:
            return unsupported("文件夹不能作为内容打开", contentType: contentType)
        case .pdf:
            return ViewerResolution(
                kind: .pdfReader,
                preparation: .pdf(maximumBytes: 50 * 1024 * 1024),
                fallbackDescription: nil,
                contentType: contentType
            )
        case .text:
            return ViewerResolution(
                kind: .textReader,
                preparation: .text(maximumBytes: 10 * 1024 * 1024),
                fallbackDescription: nil,
                contentType: contentType
            )
        case .markdown:
            return ViewerResolution(
                kind: .markdownReader,
                preparation: .text(maximumBytes: 10 * 1024 * 1024),
                fallbackDescription: nil,
                contentType: contentType
            )
        case .image:
            return ViewerResolution(
                kind: .imageViewer,
                preparation: .image(maximumBytes: 50 * 1024 * 1024),
                fallbackDescription: nil,
                contentType: contentType
            )
        case .audio:
            return ViewerResolution(
                kind: .musicPlayer,
                preparation: .audio(maximumBytes: 50 * 1024 * 1024),
                fallbackDescription: nil,
                contentType: contentType
            )
        case .video:
            return ViewerResolution(
                kind: .videoPlayer,
                preparation: .video(maximumBytes: 50 * 1024 * 1024),
                fallbackDescription: nil,
                contentType: contentType
            )
        case .unknown:
            return unsupported(
                contentType.fallbackDescription ?? "无法从资源元数据确认内容类型",
                contentType: contentType
            )
        }
    }

    private static func unsupported(
        _ description: String,
        contentType: ResolvedContentType
    ) -> ViewerResolution {
        ViewerResolution(
            kind: .systemPreview,
            preparation: contentType.kind == .folder || contentType.hasBlockingConflict
                ? .none
                : .file(maximumBytes: systemFallbackMaximumBytes),
            fallbackDescription: description,
            contentType: contentType
        )
    }
}

private extension ResourceKind {
    var isTextLike: Bool {
        self == .text || self == .markdown
    }

    var contentCandidate: ResourceKind? {
        switch self {
        case .pdf, .markdown, .text, .image, .video, .audio:
            self
        case .folder, .unknown:
            nil
        }
    }
}
