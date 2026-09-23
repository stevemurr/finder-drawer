import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Immutable inspection results cross the loader's task boundary. Framework
/// images/documents are handed to the main actor once and never mutated here.
struct FilePreviewDocument: @unchecked Sendable {
    enum Kind: String, Sendable { case image, audio, video, pdf, code, text, markdown, other }
    struct Detail: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }
    let url: URL
    let kind: Kind
    var details: [Detail] = []
    var image: NSImage?
    var pdf: PDFDocument?
    var text: String?
    var language: String?
    var duration: Double = 0
    var waveform: [[Float]] = []
    var notice: String?

    static let textLimit = 256 * 1024
    static let codeLanguages = ["swift": "Swift", "py": "Python", "js": "JavaScript", "jsx": "JavaScript",
        "ts": "TypeScript", "tsx": "TypeScript", "json": "JSON", "rs": "Rust", "go": "Go", "sh": "Shell",
        "bash": "Shell", "zsh": "Shell", "c": "C", "h": "C", "cpp": "C++", "css": "CSS", "html": "HTML",
        "xml": "XML", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "rb": "Ruby", "sql": "SQL"]

    static func kind(for url: URL, contentType: UTType?) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        if codeLanguages[ext] != nil { return .code }
        if contentType?.conforms(to: .pdf) == true || ext == "pdf" { return .pdf }
        if contentType?.conforms(to: .image) == true { return .image }
        if contentType?.conforms(to: .movie) == true { return .video }
        if contentType?.conforms(to: .audio) == true { return .audio }
        if contentType?.conforms(to: .text) == true || ["txt", "log", "csv", "ini"].contains(ext) { return .text }
        return .other
    }

    static func load(_ entry: DirectoryEntry) async throws -> Self {
        let work = Task.detached(priority: .userInitiated) { try await inspect(entry) }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func inspect(_ entry: DirectoryEntry) async throws -> Self {
        try Task.checkCancellation()
        var result = Self(url: entry.url, kind: kind(for: entry.url, contentType: entry.contentType))
        if result.kind != .other {
            guard !entry.isDirectory, try entry.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw PreviewError.unreadable }
        }
        switch result.kind {
        case .image: try result.inspectImage()
        case .pdf:
            guard let pdf = PDFDocument(url: entry.url) else { throw PreviewError.unreadable }
            result.pdf = pdf
            result.add("Pages", String(pdf.pageCount))
            if let page = pdf.page(at: 0) {
                let size = page.bounds(for: .mediaBox).size
                result.add("Page size", String(format: "%.0f × %.0f pt", size.width, size.height))
            }
            result.add("PDF version", "\(pdf.majorVersion).\(pdf.minorVersion)")
            result.add("Author", pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)
            result.add("Security", pdf.isLocked ? "Password required" : pdf.isEncrypted ? "Encrypted" : "Not encrypted")
        case .audio, .video: try await result.inspectMedia()
        case .code, .text, .markdown: try result.inspectText()
        case .other: result.add("Kind", entry.kindDescription)
        }
        try Task.checkCancellation()
        return result
    }

    mutating func add(_ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        details.append(.init(label: label, value: value))
    }

    private mutating func inspectImage() throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2000,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary)
        else { throw PreviewError.unreadable }
        image = NSImage(cgImage: thumbnail, size: .zero)
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? thumbnail.width
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? thumbnail.height
        add("Dimensions", "\(width) × \(height)")
        add("Color profile", properties[kCGImagePropertyProfileName as String] as? String)
        if let depth = properties[kCGImagePropertyDepth as String] as? Int { add("Bit depth", "\(depth)-bit / channel") }
        add("Color model", properties[kCGImagePropertyColorModel as String] as? String)
        if let dpi = properties[kCGImagePropertyDPIWidth as String] as? Double { add("Resolution", String(format: "%.0f ppi", dpi)) }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        add("Camera", tiff?[kCGImagePropertyTIFFModel as String] as? String)
        if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { add("ISO", String(iso)) }
        if let f = exif?[kCGImagePropertyExifFNumber as String] as? Double { add("Aperture", String(format: "ƒ/%.1f", f)) }
    }

    private mutating func inspectText() throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.textLimit + 1) ?? Data()
        let truncated = data.count > Self.textLimit
        let sample = data.prefix(Self.textLimit)
        let decoded: String
        let encoding: String
        if sample.starts(with: [0xff, 0xfe]) || sample.starts(with: [0xfe, 0xff]),
           let value = String(data: sample, encoding: .utf16) { decoded = value; encoding = "UTF-16" }
        else {
            guard !sample.contains(0) else { throw PreviewError.binaryText }
            if let value = String(data: sample, encoding: .utf8) { decoded = value; encoding = "UTF-8" }
            else if truncated { decoded = String(decoding: sample, as: UTF8.self); encoding = "UTF-8 (partial)" }
            else if let value = String(data: sample, encoding: .windowsCP1252) { decoded = value; encoding = "Windows-1252" }
            else { throw PreviewError.binaryText }
        }
        text = decoded
        language = Self.codeLanguages[url.pathExtension.lowercased()]
        add(kind == .code ? "Language" : "Format", language ?? (kind == .markdown ? "Markdown" : "Plain text"))
        add("Encoding", encoding)
        add("Line endings", decoded.contains("\r\n") ? "CRLF" : "LF")
        add(truncated ? "Lines shown" : "Lines", String(decoded.components(separatedBy: .newlines).count))
        add(truncated ? "Words shown" : "Words", String(decoded.split(whereSeparator: { $0.isWhitespace }).count))
        if truncated { notice = "Showing the first 256 KB. Open the file to read the rest." }
    }

    private mutating func inspectMedia() async throws {
        let asset = AVURLAsset(url: url)
        let seconds = try await asset.load(.duration).seconds
        duration = seconds.isFinite ? max(0, seconds) : 0
        if kind == .video, let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let display = size.applying(transform)
            add("Resolution", "\(Int(abs(display.width))) × \(Int(abs(display.height)))")
            let fps = try await track.load(.nominalFrameRate)
            add("Frame rate", String(format: "%.3f fps", fps))
            if let format = try await track.load(.formatDescriptions).first {
                add("Codec", Self.fourCC(CMFormatDescriptionGetMediaSubType(format)))
                add("Color primaries", Self.colorName(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String))
                add("Transfer function", Self.colorName(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String))
                add("Color matrix", Self.colorName(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String))
                let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
                if let depth = extensions["BitsPerComponent"] as? NSNumber { add("Bit depth", "\(depth)-bit") }
            }
        }
        if let track = try await asset.loadTracks(withMediaType: .audio).first,
           let format = try await track.load(.formatDescriptions).first,
           let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            add("Sample rate", String(format: "%g kHz", audio.mSampleRate / 1000))
            add("Channels", audio.mChannelsPerFrame == 2 ? "Stereo · L / R" : audio.mChannelsPerFrame == 1 ? "Mono" : "\(audio.mChannelsPerFrame) channels")
            if audio.mBitsPerChannel > 0 { add("Audio bit depth", "\(audio.mBitsPerChannel)-bit") }
            if kind == .audio { add("Encoding", Self.fourCC(audio.mFormatID)) }
        }
        add("Duration", Self.time(duration))
        if kind == .audio {
            // An unavailable waveform never prevents supported media playback.
            waveform = (try? Self.sampleWaveform(url)) ?? []
        }
    }

    static func sampleWaveform(_ url: URL, bins: Int = 180) throws -> [[Float]] {
        let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = audio.length
        guard length > 0, bins > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 2048) else { return [] }
        let channels = min(2, Int(audio.processingFormat.channelCount))
        var peaks = Array(repeating: Array(repeating: Float(0), count: bins), count: channels)
        for bin in 0..<bins {
            try Task.checkCancellation()
            audio.framePosition = min(length - 1, AVAudioFramePosition(Double(bin) / Double(bins) * Double(length)))
            try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(2048, length - audio.framePosition)))
            guard let samples = buffer.floatChannelData else { break }
            for channel in 0..<channels {
                var peak: Float = 0
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[channel][frame])) }
                peaks[channel][bin] = min(1, peak)
            }
        }
        return peaks
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(min(seconds, Double(Int.max / 2)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }

    static func colorName(_ value: String?) -> String? {
        guard let value else { return nil }
        return ["ITU_R_709_2": "Rec. 709", "ITU_R_2020": "Rec. 2020", "P3_D65": "Display P3",
                "SMPTE_ST_2084_PQ": "PQ (HDR)", "ITU_R_2100_HLG": "HLG", "IEC_sRGB": "sRGB"][value] ?? value
    }

    static func fourCC(_ value: UInt32) -> String {
        let known: [UInt32: String] = [kAudioFormatLinearPCM: "Linear PCM", kAudioFormatMPEG4AAC: "AAC",
            kAudioFormatAppleLossless: "Apple Lossless", kAudioFormatMPEGLayer3: "MP3",
            kCMVideoCodecType_H264: "H.264", kCMVideoCodecType_HEVC: "HEVC",
            kCMVideoCodecType_AppleProRes422: "Apple ProRes 422", kCMVideoCodecType_AppleProRes422HQ: "Apple ProRes 422 HQ"]
        return known[value] ?? String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }, encoding: .ascii) ?? "Unknown"
    }
}

enum PreviewError: LocalizedError {
    case unreadable, binaryText
    var errorDescription: String? {
        switch self {
        case .unreadable: "This file could not be previewed."
        case .binaryText: "This file contains binary data and cannot be displayed as text."
        }
    }
}
