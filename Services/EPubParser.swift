import Foundation
import Compression

struct EPubMetadata {
    var title: String?
    var author: String?
    var coverImage: Data?
    var spine: [String]
    var manifest: [String: String]
    var opfDirectory: String
}

struct EPubChapter {
    var id: String
    var href: String
    var title: String?
}

enum EPubParser {

    static func parseMetadata(from epubURL: URL) -> EPubMetadata? {
        guard let extractedPath = extractEPub(at: epubURL) else {
            return nil
        }

        guard let containerPath = findContainerXML(in: extractedPath),
              let opfPath = parseContainerForOPF(at: containerPath, basePath: extractedPath) else {
            return nil
        }

        return parseOPF(at: opfPath, basePath: extractedPath)
    }

    static func getChapterContent(for book: Book, chapterHref: String) -> String? {
        guard let fileURL = book.fileURL,
              let extractedPath = getExtractedPath(for: fileURL) else {
            return nil
        }

        guard let metadata = parseMetadata(from: fileURL) else {
            return nil
        }

        let chapterPath = extractedPath
            .appendingPathComponent(metadata.opfDirectory)
            .appendingPathComponent(chapterHref)

        return try? String(contentsOf: chapterPath, encoding: .utf8)
    }

    static func extractAndPrepare(epubURL: URL) -> (extractedPath: URL, metadata: EPubMetadata)? {
        guard let extractedPath = extractEPub(at: epubURL),
              let containerPath = findContainerXML(in: extractedPath),
              let opfPath = parseContainerForOPF(at: containerPath, basePath: extractedPath),
              let metadata = parseOPF(at: opfPath, basePath: extractedPath) else {
            return nil
        }

        return (extractedPath, metadata)
    }

    private static func getExtractedPath(for epubURL: URL) -> URL? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let extractedDir = cacheDir.appendingPathComponent("epub_extracted")
        let bookDir = extractedDir.appendingPathComponent(epubURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: bookDir.path) {
            return bookDir
        }

        return extractEPub(at: epubURL)
    }

    private static func extractEPub(at epubURL: URL) -> URL? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let extractedDir = cacheDir.appendingPathComponent("epub_extracted")
        let bookDir = extractedDir.appendingPathComponent(epubURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: bookDir.path) {
            return bookDir
        }

        do {
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
            try ZipArchive.extract(from: epubURL, to: bookDir)
            return bookDir
        } catch {
            print("Failed to extract ePub: \(error)")
            try? FileManager.default.removeItem(at: bookDir)
            return nil
        }
    }

    private static func findContainerXML(in extractedPath: URL) -> URL? {
        let containerPath = extractedPath
            .appendingPathComponent("META-INF")
            .appendingPathComponent("container.xml")

        if FileManager.default.fileExists(atPath: containerPath.path) {
            return containerPath
        }
        return nil
    }

    private static func parseContainerForOPF(at containerPath: URL, basePath: URL) -> URL? {
        guard let data = try? Data(contentsOf: containerPath),
              let xmlString = String(data: data, encoding: .utf8) else {
            return nil
        }

        let pattern = #"full-path\s*=\s*"([^"]+\.opf)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString)),
              let range = Range(match.range(at: 1), in: xmlString) else {
            return nil
        }

        let opfRelativePath = String(xmlString[range])
        return basePath.appendingPathComponent(opfRelativePath)
    }

    private static func parseOPF(at opfPath: URL, basePath: URL) -> EPubMetadata? {
        guard let data = try? Data(contentsOf: opfPath),
              let xmlString = String(data: data, encoding: .utf8) else {
            return nil
        }

        let opfDirectory = opfPath.deletingLastPathComponent().path
            .replacingOccurrences(of: basePath.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var metadata = EPubMetadata(
            title: nil,
            author: nil,
            coverImage: nil,
            spine: [],
            manifest: [:],
            opfDirectory: opfDirectory
        )

        metadata.title = extractTag(from: xmlString, tag: "dc:title")
            ?? extractTag(from: xmlString, tag: "title")

        metadata.author = extractTag(from: xmlString, tag: "dc:creator")
            ?? extractTag(from: xmlString, tag: "creator")

        let manifestPattern = #"<item[^>]+id\s*=\s*"([^"]+)"[^>]+href\s*=\s*"([^"]+)"[^>]*/?"#
        if let manifestRegex = try? NSRegularExpression(pattern: manifestPattern, options: .caseInsensitive) {
            let matches = manifestRegex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
            for match in matches {
                if let idRange = Range(match.range(at: 1), in: xmlString),
                   let hrefRange = Range(match.range(at: 2), in: xmlString) {
                    let id = String(xmlString[idRange])
                    let href = String(xmlString[hrefRange])
                    metadata.manifest[id] = href
                }
            }
        }

        let spinePattern = #"<itemref[^>]+idref\s*=\s*"([^"]+)""#
        if let spineRegex = try? NSRegularExpression(pattern: spinePattern, options: .caseInsensitive) {
            let matches = spineRegex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
            for match in matches {
                if let idRange = Range(match.range(at: 1), in: xmlString) {
                    metadata.spine.append(String(xmlString[idRange]))
                }
            }
        }

        if let coverHref = findCoverImage(in: xmlString, manifest: metadata.manifest) {
            let coverPath = basePath
                .appendingPathComponent(opfDirectory)
                .appendingPathComponent(coverHref)
            metadata.coverImage = try? Data(contentsOf: coverPath)
        }

        return metadata
    }

    private static func extractTag(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>([^<]+)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func findCoverImage(in xmlString: String, manifest: [String: String]) -> String? {
        let coverMetaPattern = #"<meta[^>]+name\s*=\s*"cover"[^>]+content\s*=\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: coverMetaPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString)),
           let range = Range(match.range(at: 1), in: xmlString) {
            let coverId = String(xmlString[range])
            if let href = manifest[coverId] {
                return href
            }
        }

        let imageExtensions = ["jpg", "jpeg", "png", "gif"]
        for (id, href) in manifest {
            let lowerId = id.lowercased()
            let lowerHref = href.lowercased()
            if lowerId.contains("cover") || lowerHref.contains("cover") {
                if imageExtensions.contains(where: { lowerHref.hasSuffix($0) }) {
                    return href
                }
            }
        }

        return nil
    }
}

/// Minimal ZIP archive reader for ePub extraction
enum ZipArchive {

    struct ZipEntry {
        let fileName: String
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let compressionMethod: UInt16
        let dataOffset: Int
    }

    static func extract(from sourceURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let entries = try parseEntries(from: data)

        let fileManager = FileManager.default

        for entry in entries {
            let destinationPath = destinationURL.appendingPathComponent(entry.fileName)

            if entry.fileName.hasSuffix("/") {
                try fileManager.createDirectory(at: destinationPath, withIntermediateDirectories: true)
                continue
            }

            let parentDir = destinationPath.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            let compressedData = data.subdata(in: entry.dataOffset..<entry.dataOffset+Int(entry.compressedSize))

            let fileData: Data
            if entry.compressionMethod == 0 {
                fileData = compressedData
            } else if entry.compressionMethod == 8 {
                fileData = try decompressDeflate(compressedData, uncompressedSize: Int(entry.uncompressedSize))
            } else {
                continue
            }

            try fileData.write(to: destinationPath)
        }
    }

    private static func parseEntries(from data: Data) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var offset = 0
        let localFileHeaderSignature: UInt32 = 0x04034b50

        while offset + 30 < data.count {
            let signature = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }

            guard signature == localFileHeaderSignature else { break }

            let compressionMethod = data.subdata(in: offset+8..<offset+10).withUnsafeBytes { $0.load(as: UInt16.self) }
            let compressedSize = data.subdata(in: offset+18..<offset+22).withUnsafeBytes { $0.load(as: UInt32.self) }
            let uncompressedSize = data.subdata(in: offset+22..<offset+26).withUnsafeBytes { $0.load(as: UInt32.self) }
            let fileNameLength = data.subdata(in: offset+26..<offset+28).withUnsafeBytes { $0.load(as: UInt16.self) }
            let extraFieldLength = data.subdata(in: offset+28..<offset+30).withUnsafeBytes { $0.load(as: UInt16.self) }

            let fileNameStart = offset + 30
            let fileNameEnd = fileNameStart + Int(fileNameLength)
            let fileName = String(data: data.subdata(in: fileNameStart..<fileNameEnd), encoding: .utf8) ?? ""

            let dataOffset = fileNameEnd + Int(extraFieldLength)

            entries.append(ZipEntry(
                fileName: fileName,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                compressionMethod: compressionMethod,
                dataOffset: dataOffset
            ))

            offset = dataOffset + Int(compressedSize)
        }

        return entries
    }

    private static func decompressDeflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        var decompressedData = Data(count: uncompressedSize)
        let result = decompressedData.withUnsafeMutableBytes { destBuffer in
            data.withUnsafeBytes { srcBuffer in
                compression_decode_buffer(
                    destBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    uncompressedSize,
                    srcBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        if result == 0 {
            throw NSError(domain: "ZipArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Decompression failed"])
        }

        return decompressedData.prefix(result)
    }
}
