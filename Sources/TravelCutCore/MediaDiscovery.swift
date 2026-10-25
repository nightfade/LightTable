import AVFoundation
import Foundation

enum MediaDiscovery {
    private static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mts", "m2ts",
    ]

    static func discoverVideos(in folder: URL, excludingFolders: [URL] = []) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let excludedPaths = excludingFolders.map { $0.standardizedFileURL.path + "/" }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let standardizedURL = url.standardizedFileURL
            let values = try? standardizedURL.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let name = standardizedURL.lastPathComponent.lowercased()
                let hasTravelCutMarker = FileManager.default.fileExists(
                    atPath: standardizedURL.appendingPathComponent("selection.json").path
                )
                if name.hasPrefix("travelcut 高光片段") || name.hasPrefix("lighttable 高光") || name.hasPrefix("lighttable 增稳") || hasTravelCutMarker {
                    enumerator.skipDescendants()
                }
                continue
            }
            if excludedPaths.contains(where: { standardizedURL.path.hasPrefix($0) }) {
                continue
            }

            guard values?.isRegularFile == true, values?.isHidden != true else { continue }
            guard supportedExtensions.contains(standardizedURL.pathExtension.lowercased()) else { continue }
            if standardizedURL.lastPathComponent.lowercased().hasPrefix("travel-highlights") {
                continue
            }
            urls.append(standardizedURL)
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func probe(_ urls: [URL], captureDates: [String: String] = [:]) async -> [SourceVideo] {
        var sources: [SourceVideo] = []
        for url in urls {
            guard let source = await probe(url) else { continue }
            sources.append(applyingCaptureDate(captureDates[url.standardizedFileURL.path] ?? captureDates[url.path], to: source))
        }
        return sources.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private static func probe(_ url: URL) async -> SourceVideo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite,
              duration >= 0.1,
              let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
        else {
            return nil
        }

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let frameRate = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 0)
        let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
        let codec = formatDescriptions.first.map(codecName) ?? "unknown"
        let isHDR = formatDescriptions.contains(where: isHDRFormat)
        let assetMetadata = (try? await asset.load(.metadata)) ?? []
        let metadata = await metadataRecords(assetMetadata)
        let fileValues = try? url.resourceValues(forKeys: [
            .creationDateKey, .contentModificationDateKey, .fileSizeKey,
        ])
        let embeddedCreationDate = await assetCreationDate(asset)
        let createdAt = embeddedCreationDate
            ?? fileValues?.creationDate
            ?? fileValues?.contentModificationDate
            ?? .distantPast

        return SourceVideo(
            url: url,
            duration: duration,
            createdAt: createdAt,
            modifiedAt: fileValues?.contentModificationDate ?? createdAt,
            hasAudio: !audioTracks.isEmpty,
            width: Int(abs(orientedRect.width).rounded()),
            height: Int(abs(orientedRect.height).rounded()),
            nominalFrameRate: frameRate,
            codec: codec,
            isHDR: isHDR,
            fileSize: Int64(fileValues?.fileSize ?? 0),
            metadata: metadata
        )
    }

    /// Uses LightTable's zoned creation time when it has one: Sony keeps the offset only in its
    /// XML, and Gyroflow output keeps only UTC. The value is added as a QuickTime creation date
    /// record so `ClipOrganizer.captureTimeZone` picks up the camera's zone.
    static func applyingCaptureDate(_ value: String?, to source: SourceVideo) -> SourceVideo {
        guard let value, let iso = isoCaptureDate(value),
              let date = ISO8601DateFormatter().date(from: iso)
        else { return source }
        let record = MediaMetadataRecord(identifier: "mdta/com.apple.quicktime.creationdate", keySpace: "mdta",
                                         key: "com.apple.quicktime.creationdate", value: iso)
        let others = source.metadata.filter { !(($0.identifier ?? $0.key ?? "").contains("com.apple.quicktime.creationdate")) }
        return SourceVideo(url: source.url, duration: source.duration, createdAt: date, modifiedAt: source.modifiedAt,
                           hasAudio: source.hasAudio, width: source.width, height: source.height,
                           nominalFrameRate: source.nominalFrameRate, codec: source.codec, isHDR: source.isHDR,
                           fileSize: source.fileSize, metadata: others + [record])
    }

    /// `2025:10:26 14:10:41-08:00` (exiftool) or ISO 8601 → `2025-10-26T14:10:41-08:00`.
    /// Values without an offset are rejected: they cannot fix the day folder.
    static func isoCaptureDate(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 19, text[text.index(text.startIndex, offsetBy: 4)] == ":" {
            var characters = Array(text)
            characters[4] = "-"
            characters[7] = "-"
            characters[10] = "T"
            text = String(characters)
        }
        // Drop fractional seconds, which ISO8601DateFormatter rejects by default.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            text.removeSubrange(dot..<zone)
        }
        guard text.count > 19, ClipOrganizer.timeZone(fromISO8601: text) != nil else { return nil }
        return text
    }

    private static func assetCreationDate(_ asset: AVAsset) async -> Date? {
        guard let item = try? await asset.load(.creationDate) else { return nil }
        if let date = try? await item.load(.dateValue) { return date }
        guard let value = try? await item.load(.stringValue) else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func metadataRecords(_ items: [AVMetadataItem]) async -> [MediaMetadataRecord] {
        var records: [MediaMetadataRecord] = []
        for item in items {
            let stringValue = try? await item.load(.stringValue)
            let numberValue = try? await item.load(.numberValue)
            let dateValue = try? await item.load(.dateValue)
            let value = stringValue
                ?? numberValue?.stringValue
                ?? dateValue.map { ISO8601DateFormatter().string(from: $0) }
            records.append(MediaMetadataRecord(
                identifier: item.identifier?.rawValue,
                keySpace: item.keySpace?.rawValue,
                key: item.commonKey?.rawValue ?? String(describing: item.key),
                value: value
            ))
        }
        return records
    }

    private static func codecName(_ description: CMFormatDescription) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xff),
            UInt8((subtype >> 16) & 0xff),
            UInt8((subtype >> 8) & 0xff),
            UInt8(subtype & 0xff),
        ]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.allSatisfy(\.isASCII) ? text : String(format: "0x%08x", subtype)
    }

    private static func isHDRFormat(_ description: CMFormatDescription) -> Bool {
        let text = String(describing: CMFormatDescriptionGetExtensions(description)).lowercased()
        return text.contains("itu_r_2020")
            || text.contains("itur_2020")
            || text.contains("smpte_st_2084")
            || text.contains("hlg")
            || text.contains("pq")
    }
}
