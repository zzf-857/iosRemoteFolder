import Foundation

struct ContentSignatureMatch: Hashable, Sendable {
    enum Strength: String, Hashable, Sendable {
        case exact
        case container
        case heuristic
    }

    let formatToken: String
    let kind: ResourceKind
    let canonicalTypeIdentifier: String?
    let strength: Strength

    var fingerprintToken: String {
        "signature:v1:\(formatToken):\(strength.rawValue):\(kind.rawValue):\(canonicalTypeIdentifier ?? "none")"
    }
}

/// Pure, bounded signature recognition. Callers own all I/O and must provide no
/// more than the first `maximumBytes` bytes of a resource.
enum ContentSignatureSniffer {
    static let maximumBytes = 4 * 1024

    static func sniff(_ prefix: Data) -> ContentSignatureMatch? {
        guard prefix.count <= maximumBytes else { return nil }
        let bytes = Array(prefix)
        guard !bytes.isEmpty else { return nil }

        if containsPDFHeader(bytes) {
            return exact(.pdf, kind: .pdf)
        }
        if starts(bytes, with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return exact(.png, kind: .image)
        }
        if starts(bytes, with: [0xFF, 0xD8, 0xFF]) {
            return exact(.jpeg, kind: .image)
        }
        if starts(bytes, withASCII: "GIF87a") || starts(bytes, withASCII: "GIF89a") {
            return exact(.gif, kind: .image)
        }
        if let riff = riffMatch(bytes) {
            return riff
        }
        if starts(bytes, with: [0x50, 0x4B, 0x03, 0x04])
            || starts(bytes, with: [0x50, 0x4B, 0x05, 0x06])
            || starts(bytes, with: [0x50, 0x4B, 0x07, 0x08]) {
            return container(.zip)
        }
        if starts(bytes, withASCII: "fLaC") {
            return exact(.flac, kind: .audio)
        }
        if let bmff = isoBaseMediaMatch(bytes) {
            return bmff
        }
        if let ebml = ebmlMatch(bytes) {
            return ebml
        }
        if isValidID3Header(bytes) {
            return exact(.mp3, kind: .audio)
        }
        if isValidMPEGAudioFrameHeader(bytes) {
            return heuristic(.mp3, kind: .audio)
        }
        if isValidADTSHeader(bytes) {
            return heuristic(.aac, kind: .audio)
        }
        if let textBOM = textBOMMatch(bytes) {
            return textBOM
        }
        if isLikelyUTF8Text(bytes) {
            return heuristic(.likelyUTF8Text, kind: .text)
        }
        return nil
    }

    private enum Format: String {
        case pdf
        case png
        case jpeg
        case gif
        case webP = "webp"
        case wav
        case heif
        case avif
        case zip
        case flac
        case mp3
        case aac
        case isoBMFF = "iso-bmff"
        case ebml
        case matroska
        case webM = "webm"
        case utf8BOM = "utf8-bom"
        case utf16LittleEndian = "utf16-le"
        case utf16BigEndian = "utf16-be"
        case utf32LittleEndian = "utf32-le"
        case utf32BigEndian = "utf32-be"
        case likelyUTF8Text = "likely-utf8-text"

        var canonicalTypeIdentifier: String? {
            switch self {
            case .pdf: "com.adobe.pdf"
            case .png: "public.png"
            case .jpeg: "public.jpeg"
            case .gif: "com.compuserve.gif"
            case .webP: "org.webmproject.webp"
            case .wav: "com.microsoft.waveform-audio"
            case .heif: "public.heif"
            case .avif: "public.avif"
            case .zip: "public.zip-archive"
            case .flac: "org.xiph.flac"
            case .mp3: "public.mp3"
            case .aac: "public.aac-audio"
            case .matroska: "org.matroska.mkv"
            case .webM: "org.webmproject.webm"
            case .utf8BOM, .likelyUTF8Text: "public.utf8-plain-text"
            case .utf16LittleEndian, .utf16BigEndian: "public.utf16-plain-text"
            case .isoBMFF, .ebml, .utf32LittleEndian, .utf32BigEndian: nil
            }
        }
    }

    private static func exact(_ format: Format, kind: ResourceKind) -> ContentSignatureMatch {
        match(format, strength: .exact, overridingKind: kind)
    }

    private static func container(_ format: Format) -> ContentSignatureMatch {
        match(format, strength: .container, overridingKind: .unknown)
    }

    private static func heuristic(_ format: Format, kind: ResourceKind) -> ContentSignatureMatch {
        match(format, strength: .heuristic, overridingKind: kind)
    }

    private static func match(
        _ format: Format,
        strength: ContentSignatureMatch.Strength,
        overridingKind kind: ResourceKind
    ) -> ContentSignatureMatch {
        ContentSignatureMatch(
            formatToken: format.rawValue,
            kind: kind,
            canonicalTypeIdentifier: format.canonicalTypeIdentifier,
            strength: strength
        )
    }

    private static func containsPDFHeader(_ bytes: [UInt8]) -> Bool {
        let signature = Array("%PDF-".utf8)
        let searchCount = min(bytes.count, 1_024)
        guard searchCount >= signature.count else { return false }
        for offset in 0...(searchCount - signature.count)
        where starts(bytes, with: signature, at: offset) {
            return true
        }
        return false
    }

    private static func riffMatch(_ bytes: [UInt8]) -> ContentSignatureMatch? {
        guard bytes.count >= 12,
              starts(bytes, withASCII: "RIFF"),
              let payloadSize = littleEndianUInt32(bytes, at: 4),
              payloadSize >= 4 else {
            return nil
        }
        if starts(bytes, withASCII: "WEBP", at: 8) {
            return exact(.webP, kind: .image)
        }
        if starts(bytes, withASCII: "WAVE", at: 8) {
            return exact(.wav, kind: .audio)
        }
        return nil
    }

    private static func isoBaseMediaMatch(
        _ bytes: [UInt8]
    ) -> ContentSignatureMatch? {
        guard bytes.count >= 16,
              starts(bytes, withASCII: "ftyp", at: 4),
              let size32 = bigEndianUInt32(bytes, at: 0) else {
            return nil
        }

        let brandOffset: Int
        let compatibleBrandOffset: Int
        let minimumSize: UInt64
        let boxSize: UInt64
        if size32 == 1 {
            guard bytes.count >= 24,
                  let extendedSize = bigEndianUInt64(bytes, at: 8) else {
                return nil
            }
            brandOffset = 16
            compatibleBrandOffset = 24
            minimumSize = 24
            boxSize = extendedSize
        } else {
            guard size32 != 0 else { return nil }
            brandOffset = 8
            compatibleBrandOffset = 16
            minimumSize = 16
            boxSize = UInt64(size32)
        }

        guard boxSize >= minimumSize,
              boxSize <= UInt64(bytes.count),
              (boxSize - minimumSize).isMultiple(of: 4),
              let boxEnd = Int(exactly: boxSize),
              let majorBrand = fourCC(bytes, at: brandOffset) else {
            return nil
        }

        var brands: Set<String> = [majorBrand]
        var offset = compatibleBrandOffset
        while offset + 4 <= boxEnd {
            guard let brand = fourCC(bytes, at: offset) else { return nil }
            brands.insert(brand)
            offset += 4
        }

        let avifBrands: Set<String> = ["avif", "avis"]
        if !brands.isDisjoint(with: avifBrands) {
            return exact(.avif, kind: .image)
        }

        let heifBrands: Set<String> = [
            "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"
        ]
        if !brands.isDisjoint(with: heifBrands) {
            return exact(.heif, kind: .image)
        }

        // MP4, QuickTime, and M4A brands establish an ISO BMFF container, but
        // the prefix does not establish whether its tracks are audio or video.
        return container(.isoBMFF)
    }

    private static func ebmlMatch(_ bytes: [UInt8]) -> ContentSignatureMatch? {
        guard starts(bytes, with: [0x1A, 0x45, 0xDF, 0xA3]) else { return nil }
        guard let headerSize = ebmlVariableInteger(bytes, at: 4),
              !headerSize.isUnknown,
              let contentSize = Int(exactly: headerSize.value) else {
            return container(.ebml)
        }

        let contentStart = 4 + headerSize.length
        guard contentStart <= bytes.count else { return container(.ebml) }
        let availableContentSize = bytes.count - contentStart
        let contentEnd = contentStart + min(contentSize, availableContentSize)
        var offset = contentStart
        while offset < contentEnd {
            guard let elementIDLength = ebmlElementIDLength(bytes[offset]),
                  offset + elementIDLength <= contentEnd else {
                break
            }
            let elementID = Array(bytes[offset..<(offset + elementIDLength)])
            offset += elementIDLength
            guard let elementSize = ebmlVariableInteger(bytes, at: offset),
                  !elementSize.isUnknown,
                  let valueSize = Int(exactly: elementSize.value),
                  elementSize.length <= contentEnd - offset else {
                break
            }
            offset += elementSize.length
            guard valueSize <= contentEnd - offset else { break }

            if elementID == [0x42, 0x82],
               let docType = String(
                   bytes: bytes[offset..<(offset + valueSize)],
                   encoding: .ascii
               )?.lowercased() {
                if docType == "webm" { return container(.webM) }
                if docType == "matroska" { return container(.matroska) }
            }
            offset += valueSize
        }
        return container(.ebml)
    }

    private static func isValidID3Header(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 10,
              starts(bytes, withASCII: "ID3"),
              (2...4).contains(bytes[3]),
              bytes[4] != 0xFF else {
            return false
        }
        return bytes[6...9].allSatisfy { $0 & 0x80 == 0 }
    }

    private static func isValidMPEGAudioFrameHeader(_ bytes: [UInt8]) -> Bool {
        guard let header = bigEndianUInt32(bytes, at: 0),
              header & 0xFFE0_0000 == 0xFFE0_0000 else {
            return false
        }
        let version = (header >> 19) & 0x3
        let layer = (header >> 17) & 0x3
        let bitrateIndex = (header >> 12) & 0xF
        let sampleRateIndex = (header >> 10) & 0x3
        let emphasis = header & 0x3
        return version != 0x1
            && layer != 0
            && (1...14).contains(bitrateIndex)
            && sampleRateIndex != 0x3
            && emphasis != 0x2
    }

    private static func isValidADTSHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 7,
              bytes[0] == 0xFF,
              bytes[1] & 0xF6 == 0xF0 else {
            return false
        }
        let frequencyIndex = (bytes[2] >> 2) & 0xF
        let channelConfiguration = ((bytes[2] & 0x1) << 2) | (bytes[3] >> 6)
        let headerLength = bytes[1] & 0x1 == 0 ? 9 : 7
        let frameLength = (Int(bytes[3] & 0x3) << 11)
            | (Int(bytes[4]) << 3)
            | Int(bytes[5] >> 5)
        return frequencyIndex != 0xF
            && (1...7).contains(channelConfiguration)
            && frameLength >= headerLength
    }

    private static func textBOMMatch(_ bytes: [UInt8]) -> ContentSignatureMatch? {
        if starts(bytes, with: [0x00, 0x00, 0xFE, 0xFF]) {
            return exact(.utf32BigEndian, kind: .text)
        }
        if starts(bytes, with: [0xFF, 0xFE, 0x00, 0x00]) {
            return exact(.utf32LittleEndian, kind: .text)
        }
        if starts(bytes, with: [0xEF, 0xBB, 0xBF]) {
            return exact(.utf8BOM, kind: .text)
        }
        if starts(bytes, with: [0xFE, 0xFF]) {
            return exact(.utf16BigEndian, kind: .text)
        }
        if starts(bytes, with: [0xFF, 0xFE]) {
            return exact(.utf16LittleEndian, kind: .text)
        }
        return nil
    }

    private static func isLikelyUTF8Text(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 8,
              !bytes.contains(0),
              isValidUTF8Prefix(bytes) else {
            return false
        }

        let allowedControls: Set<UInt8> = [0x09, 0x0A, 0x0C, 0x0D]
        let suspiciousControlCount = bytes.reduce(into: 0) { count, byte in
            if (byte < 0x20 && !allowedControls.contains(byte)) || byte == 0x7F {
                count += 1
            }
        }
        if suspiciousControlCount == 0 { return true }
        return bytes.count >= 256 && suspiciousControlCount * 100 <= bytes.count
    }

    /// Validates complete UTF-8 scalars and permits only a well-formed scalar
    /// truncated by the end of the bounded prefix.
    private static func isValidUTF8Prefix(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let first = bytes[offset]
            if first <= 0x7F {
                offset += 1
                continue
            }

            let length: Int
            let secondRange: ClosedRange<UInt8>
            switch first {
            case 0xC2...0xDF:
                length = 2
                secondRange = 0x80...0xBF
            case 0xE0:
                length = 3
                secondRange = 0xA0...0xBF
            case 0xE1...0xEC, 0xEE...0xEF:
                length = 3
                secondRange = 0x80...0xBF
            case 0xED:
                length = 3
                secondRange = 0x80...0x9F
            case 0xF0:
                length = 4
                secondRange = 0x90...0xBF
            case 0xF1...0xF3:
                length = 4
                secondRange = 0x80...0xBF
            case 0xF4:
                length = 4
                secondRange = 0x80...0x8F
            default:
                return false
            }

            if offset + 1 >= bytes.count { return true }
            guard secondRange.contains(bytes[offset + 1]) else { return false }
            for continuationOffset in 2..<length {
                if offset + continuationOffset >= bytes.count { return true }
                guard (0x80...0xBF).contains(bytes[offset + continuationOffset]) else {
                    return false
                }
            }
            offset += length
        }
        return true
    }

    private static func starts(
        _ bytes: [UInt8],
        with signature: [UInt8],
        at offset: Int = 0
    ) -> Bool {
        guard offset >= 0,
              signature.count <= bytes.count - min(offset, bytes.count),
              offset <= bytes.count else {
            return false
        }
        return bytes[offset..<(offset + signature.count)].elementsEqual(signature)
    }

    private static func starts(
        _ bytes: [UInt8],
        withASCII signature: String,
        at offset: Int = 0
    ) -> Bool {
        starts(bytes, with: Array(signature.utf8), at: offset)
    }

    private static func fourCC(_ bytes: [UInt8], at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func bigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func bigEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        return (0..<8).reduce(into: UInt64(0)) { value, index in
            value = (value << 8) | UInt64(bytes[offset + index])
        }
    }

    private struct EBMLVariableInteger {
        let value: UInt64
        let length: Int
        let isUnknown: Bool
    }

    private static func ebmlVariableInteger(
        _ bytes: [UInt8],
        at offset: Int
    ) -> EBMLVariableInteger? {
        guard offset >= 0, offset < bytes.count else { return nil }
        let first = bytes[offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, offset + length <= bytes.count else { return nil }

        let markerMask = UInt8(0xFF >> length)
        var value = UInt64(first & markerMask)
        for index in 1..<length {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        let valueBitCount = length * 7
        let unknownValue = (UInt64(1) << valueBitCount) - 1
        return EBMLVariableInteger(
            value: value,
            length: length,
            isUnknown: value == unknownValue
        )
    }

    private static func ebmlElementIDLength(_ first: UInt8) -> Int? {
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        return length <= 4 ? length : nil
    }
}
