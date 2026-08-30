import Foundation
import Testing

@testable import iosRemoteFolder

@Suite("内容签名嗅探")
struct ContentSignatureSnifferTests {
    @Test("文档与图片 magic bytes 精确识别")
    func recognizesDocumentAndImageSignatures() {
        let cases: [(Data, Token, ResourceKind)] = [
            (Data("%PDF-1.7".utf8), .pdf, .pdf),
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), .png, .image),
            (Data([0xFF, 0xD8, 0xFF]), .jpeg, .image),
            (Data("GIF87a".utf8), .gif, .image),
            (Data("GIF89a".utf8), .gif, .image),
        ]

        for (data, format, kind) in cases {
            #expect(ContentSignatureSniffer.sniff(data) == exact(format, kind: kind))
        }
    }

    @Test("RIFF form type 区分 WebP 与 WAV")
    func distinguishesRIFFFormTypes() {
        #expect(
            ContentSignatureSniffer.sniff(riff(formType: "WEBP"))
                == exact(.webP, kind: .image)
        )
        #expect(
            ContentSignatureSniffer.sniff(riff(formType: "WAVE"))
                == exact(.wav, kind: .audio)
        )
        #expect(ContentSignatureSniffer.sniff(riff(formType: "AVI ")) == nil)

        var invalidSize = riff(formType: "WAVE")
        invalidSize.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        #expect(ContentSignatureSniffer.sniff(invalidSize) == nil)
    }

    @Test("ISO BMFF brands 仅对 HEIF 与 AVIF 给出图片结论")
    func classifiesISOBaseMediaBrandsConservatively() {
        for brand in ["avif", "avis"] {
            #expect(
                ContentSignatureSniffer.sniff(ftyp(majorBrand: brand))
                    == exact(.avif, kind: .image)
            )
        }
        for brand in ["heic", "heix", "hevc", "hevx", "mif1", "msf1"] {
            #expect(
                ContentSignatureSniffer.sniff(ftyp(majorBrand: brand))
                    == exact(.heif, kind: .image)
            )
        }

        #expect(
            ContentSignatureSniffer.sniff(
                ftyp(majorBrand: "mif1", compatibleBrands: ["avif"])
            ) == exact(.avif, kind: .image)
        )
        #expect(
            ContentSignatureSniffer.sniff(
                ftyp(
                    majorBrand: "isom",
                    compatibleBrands: ["avif"],
                    usesExtendedSize: true
                )
            ) == exact(.avif, kind: .image)
        )
        for brand in ["isom", "mp41", "mp42", "qt  ", "M4A "] {
            #expect(
                ContentSignatureSniffer.sniff(ftyp(majorBrand: brand))
                    == container(.isoBMFF)
            )
        }
        #expect(
            ContentSignatureSniffer.sniff(ftyp(majorBrand: "fake"))
                == container(.isoBMFF)
        )
    }

    @Test("ZIP 只报告容器且不猜测 Office 或 iWork")
    func reportsZIPAsAmbiguousContainer() {
        for signature in [
            Data([0x50, 0x4B, 0x03, 0x04]),
            Data([0x50, 0x4B, 0x05, 0x06]),
            Data([0x50, 0x4B, 0x07, 0x08]),
        ] {
            #expect(ContentSignatureSniffer.sniff(signature) == container(.zip))
        }

        var officeLike = Data([0x50, 0x4B, 0x03, 0x04])
        officeLike.append(Data("[Content_Types].xml word/document.xml".utf8))
        #expect(ContentSignatureSniffer.sniff(officeLike) == container(.zip))
    }

    @Test("FLAC、MP3 与 AAC 按证据强度识别")
    func recognizesAudioSignaturesWithSafeStrengths() {
        #expect(
            ContentSignatureSniffer.sniff(Data("fLaC".utf8))
                == exact(.flac, kind: .audio)
        )
        #expect(
            ContentSignatureSniffer.sniff(
                Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            ) == exact(.mp3, kind: .audio)
        )
        #expect(
            ContentSignatureSniffer.sniff(Data([0xFF, 0xFB, 0x90, 0x64]))
                == heuristic(.mp3, kind: .audio)
        )
        #expect(
            ContentSignatureSniffer.sniff(
                Data([0xFF, 0xF1, 0x50, 0x80, 0x00, 0xFF, 0xFC])
            ) == heuristic(.aac, kind: .audio)
        )
    }

    @Test("EBML DocType 可细分 WebM 与 Matroska，缺失时保持容器")
    func recognizesEBMLContainers() {
        #expect(ContentSignatureSniffer.sniff(ebml(docType: "webm")) == container(.webM))
        #expect(
            ContentSignatureSniffer.sniff(ebml(docType: "matroska"))
                == container(.matroska)
        )
        #expect(
            ContentSignatureSniffer.sniff(Data([0x1A, 0x45, 0xDF, 0xA3]))
                == container(.ebml)
        )
        #expect(
            ContentSignatureSniffer.sniff(
                Data([
                    0x1A, 0x45, 0xDF, 0xA3,
                    0x01, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                ])
            ) == container(.ebml)
        )
    }

    @Test("BOM 精确识别且 UTF-32 优先于 UTF-16")
    func recognizesTextByteOrderMarks() {
        let cases: [([UInt8], Token)] = [
            ([0xEF, 0xBB, 0xBF], .utf8BOM),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
        ]
        for (bytes, format) in cases {
            #expect(
                ContentSignatureSniffer.sniff(Data(bytes))
                    == exact(format, kind: .text)
            )
        }
    }

    @Test("无 BOM 文本启发式允许截断尾标量并拒绝二进制")
    func detectsLikelyUTF8TextConservatively() {
        #expect(
            ContentSignatureSniffer.sniff(Data("plain UTF-8 text\n".utf8))
                == heuristic(.likelyUTF8Text, kind: .text)
        )
        #expect(
            ContentSignatureSniffer.sniff(Data("中文与日本語テキスト".utf8))
                == heuristic(.likelyUTF8Text, kind: .text)
        )

        var truncatedScalar = Data("prefix 中文".utf8)
        truncatedScalar.removeLast()
        #expect(
            ContentSignatureSniffer.sniff(truncatedScalar)
                == heuristic(.likelyUTF8Text, kind: .text)
        )

        #expect(ContentSignatureSniffer.sniff(Data(repeating: 0, count: 64)) == nil)
        #expect(ContentSignatureSniffer.sniff(Data(repeating: 0xFF, count: 64)) == nil)
        #expect(
            ContentSignatureSniffer.sniff(Data((0..<64).map { UInt8($0 % 8) }))
                == nil
        )
        #expect(
            ContentSignatureSniffer.sniff(Data([0xF0, 0x80, 0x80, 0x80, 0x41, 0x42, 0x43, 0x44]))
                == nil
        )
    }

    @Test("截断与伪造头不会升级成目标二进制格式")
    func rejectsTruncatedAndFalsePositiveHeaders() {
        let cases: [(Data, Token)] = [
            (Data("%PDF".utf8), .pdf),
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A]), .png),
            (Data([0xFF, 0xD8]), .jpeg),
            (Data("GIF89".utf8), .gif),
            (Data("RIFF\u{04}\0\0\0WAV".utf8), .wav),
            (Data([0x50, 0x4B, 0x03]), .zip),
            (Data("fLa".utf8), .flac),
            (Data([0x1A, 0x45, 0xDF]), .ebml),
        ]
        for (data, forbiddenFormat) in cases {
            #expect(matchedFormat(ContentSignatureSniffer.sniff(data)) != forbiddenFormat)
        }

        #expect(ContentSignatureSniffer.sniff(Data([0xFF, 0xE0, 0x00, 0x00])) == nil)
        #expect(ContentSignatureSniffer.sniff(Data(repeating: 0xFF, count: 16)) == nil)
        #expect(
            ContentSignatureSniffer.sniff(
                Data([0xFF, 0xF1, 0x7C, 0x80, 0x00, 0xFF, 0xFC])
            ) == nil
        )
        #expect(ContentSignatureSniffer.sniff(malformedFTYP(size: 12)) == nil)
        #expect(ContentSignatureSniffer.sniff(malformedFTYP(size: 128)) == nil)
    }

    @Test("PDF 搜索边界与 4 KiB 输入预算固定")
    func enforcesPDFAndProbeBoundaries() {
        for offset in [0, 512, 1_019] {
            var bytes = Data(repeating: 0x01, count: offset)
            bytes.append(Data("%PDF-".utf8))
            #expect(ContentSignatureSniffer.sniff(bytes) == exact(.pdf, kind: .pdf))
        }
        for offset in [1_020, 1_023, 1_024] {
            var bytes = Data(repeating: 0x01, count: offset)
            bytes.append(Data("%PDF-".utf8))
            #expect(matchedFormat(ContentSignatureSniffer.sniff(bytes)) != .pdf)
        }

        #expect(ContentSignatureSniffer.maximumBytes == 4_096)
        #expect(ContentSignatureSniffer.sniff(Data(repeating: 0x01, count: 4_096)) == nil)
        #expect(ContentSignatureSniffer.sniff(Data(repeating: 0x01, count: 4_097)) == nil)
    }

    @Test("Match 暴露稳定 token、UTI、kind 与容器证据")
    func matchCarriesStableIntegrationEvidence() {
        let matches: [ContentSignatureMatch] = [
            exact(.pdf, kind: .pdf),
            container(.zip),
            heuristic(.mp3, kind: .audio),
        ]
        #expect(Set(matches.map(\.fingerprintToken)).count == matches.count)
        #expect(matches[0].formatToken == "pdf")
        #expect(matches[0].canonicalTypeIdentifier == "com.adobe.pdf")
        #expect(matches[0].kind == .pdf)
        #expect(matches[1].strength == .container)
        #expect(matches[1].kind == .unknown)
        #expect(matches[1].canonicalTypeIdentifier == "public.zip-archive")
    }

    private func exact(
        _ format: Token,
        kind: ResourceKind
    ) -> ContentSignatureMatch {
        ContentSignatureMatch(
            formatToken: format.rawValue,
            kind: kind,
            canonicalTypeIdentifier: format.canonicalTypeIdentifier,
            strength: .exact
        )
    }

    private func container(
        _ format: Token
    ) -> ContentSignatureMatch {
        ContentSignatureMatch(
            formatToken: format.rawValue,
            kind: .unknown,
            canonicalTypeIdentifier: format.canonicalTypeIdentifier,
            strength: .container
        )
    }

    private func heuristic(
        _ format: Token,
        kind: ResourceKind
    ) -> ContentSignatureMatch {
        ContentSignatureMatch(
            formatToken: format.rawValue,
            kind: kind,
            canonicalTypeIdentifier: format.canonicalTypeIdentifier,
            strength: .heuristic
        )
    }

    private func matchedFormat(
        _ result: ContentSignatureMatch?
    ) -> Token? {
        result.flatMap { Token(rawValue: $0.formatToken) }
    }

    private enum Token: String {
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

    private func riff(formType: String) -> Data {
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [4, 0, 0, 0])
        data.append(Data(formType.utf8))
        return data
    }

    private func ftyp(
        majorBrand: String,
        compatibleBrands: [String] = [],
        usesExtendedSize: Bool = false
    ) -> Data {
        let boxSize = UInt64((usesExtendedSize ? 24 : 16) + compatibleBrands.count * 4)
        let size32 = usesExtendedSize ? UInt32(1) : UInt32(boxSize)
        var data = Data(bigEndianBytes(size32))
        data.append(Data("ftyp".utf8))
        if usesExtendedSize {
            data.append(contentsOf: bigEndianBytes(boxSize))
        }
        data.append(Data(majorBrand.utf8))
        data.append(contentsOf: [0, 0, 0, 0])
        for brand in compatibleBrands {
            data.append(Data(brand.utf8))
        }
        return data
    }

    private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private func malformedFTYP(size: UInt32) -> Data {
        var data = Data([
            UInt8((size >> 24) & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ])
        data.append(Data("ftypfake".utf8))
        data.append(contentsOf: [0, 0, 0, 0])
        return data
    }

    private func ebml(docType: String) -> Data {
        let contentSize = 2 + 1 + docType.utf8.count
        var data = Data([0x1A, 0x45, 0xDF, 0xA3, UInt8(0x80 | contentSize)])
        data.append(contentsOf: [0x42, 0x82, UInt8(0x80 | docType.utf8.count)])
        data.append(Data(docType.utf8))
        return data
    }
}
