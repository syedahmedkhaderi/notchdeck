import AppKit
import Foundation

/// Album art for the player.
///
/// macOS will not hand the now-playing artwork to third-party apps any more, so
/// the art is looked up from public sources using the track title and artist that
/// the accessibility tree gives us: first the iTunes catalogue, and, for the
/// remixes and edits the catalogue does not carry, the YouTube thumbnail of the
/// matching video. Results are cached in memory and on disk so a track is only
/// ever looked up once, and misses are remembered for the session so an
/// unfindable track is not re-queried on every poll.
final class ArtworkService {
    static let shared = ArtworkService()

    private let lock = NSLock()
    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var misses: Set<String> = []
    private let queue = DispatchQueue(label: "notchdeck.artwork", qos: .utility)

    private let folder: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("NotchDeck/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Cache key for a track: the same song must always produce the same key.
    static func key(title: String, artist: String) -> String {
        "\(title)|\(artist)".lowercased()
    }

    /// An image already in memory, if the track has been seen before.
    func cached(_ key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return memory[key]
    }

    /// Looks the track up, calling `completion` on the main thread when art arrives.
    func artwork(title: String, artist: String, completion: @escaping (NSImage?) -> Void) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count > 1 else { completion(nil); return }
        let key = Self.key(title: title, artist: artist)

        if let image = cached(key) { completion(image); return }
        lock.lock()
        let knownMiss = misses.contains(key)
        lock.unlock()
        if knownMiss { completion(nil); return }

        lock.lock()
        guard inFlight.insert(key).inserted else { lock.unlock(); return }
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.inFlight.remove(key)
                self.lock.unlock()
            }

            let image = self.imageFromDisk(key) ?? self.lookup(title: title, artist: artist)
            if let image {
                self.lock.lock()
                self.memory[key] = image
                self.lock.unlock()
                self.writeToDisk(image, key: key)
            } else {
                self.lock.lock()
                self.misses.insert(key)
                self.lock.unlock()
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: Catalogue lookup

    /// iTunes first because it carries real cover art; YouTube when the track is
    /// an edit, mash-up or slowed version the catalogue does not list.
    private func lookup(title: String, artist: String) -> NSImage? {
        itunes(title: title, artist: artist) ?? youtube(title: title, artist: artist)
    }

    private func itunes(title: String, artist: String) -> NSImage? {
        guard let url = searchURL(title: title, artist: artist),
              let data = fetch(url),
              let results = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = results["results"] as? [[String: Any]], !hits.isEmpty else { return nil }

        let lead = artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let wanted = Self.normalize(title)
        let wantedArtist = Self.normalize(lead)

        var best = hits[0]
        var bestScore = -1
        for hit in hits {
            var score = 0
            let track = Self.normalize(hit["trackName"] as? String ?? "")
            if track == wanted { score += 6 }
            else if track.hasPrefix(wanted) || wanted.hasPrefix(track) { score += 3 }
            else if track.contains(wanted) { score += 1 }
            let name = Self.normalize(hit["artistName"] as? String ?? "")
            if !wantedArtist.isEmpty, name.contains(wantedArtist) { score += 4 }
            if score > bestScore { bestScore = score; best = hit }
        }

        guard let artwork = best["artworkUrl100"] as? String, let artworkURL = Self.largeArtworkURL(artwork),
              let data = fetch(artworkURL) else { return nil }
        return NSImage(data: data)
    }

    private func searchURL(title: String, artist: String) -> URL? {
        let lead = artist.components(separatedBy: ",").first ?? artist
        let term = "\(title) \(lead)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "6")
        ]
        return components?.url
    }

    /// The catalogue hands out 100pt thumbnails; the same path serves a big one.
    static func largeArtworkURL(_ raw: String) -> URL? {
        let large = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: large) ?? URL(string: raw)
    }

    // MARK: YouTube lookup

    /// Fallback for the edits and mash-ups the catalogue does not list: search
    /// YouTube, take the result whose title matches the track, and pull that
    /// video's thumbnail. No API key or login is involved.
    ///
    /// Each result object gives the id immediately before its own title, so the
    /// id closest ahead of a title belongs to it. Both lists are walked once, in
    /// order, which keeps the parse linear over what is a large HTML document.
    private func youtube(title: String, artist: String) -> NSImage? {
        let wanted = Self.normalize(title)
        guard wanted.count > 3 else { return nil }

        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.youtubeSearchURL(query), let data = fetch(url),
              let html = String(data: data, encoding: .utf8) else { return nil }

        var best: (id: String, score: Int)?
        for (id, rawTitle) in Self.youtubeResults(in: html) {
            let candidate = Self.normalize(rawTitle)
            var score = 0
            if candidate == wanted { score = 6 }
            else if candidate.hasPrefix(wanted) { score = 5 }
            else if candidate.contains(wanted) { score = 4 }
            else if wanted.contains(candidate), candidate.count > 6 { score = 3 }
            guard score > 0 else { continue }
            if best == nil || score > best!.score { best = (id, score) }
            if score == 6 { break }
        }

        guard let id = best?.id else { return nil }
        for variant in ["maxresdefault", "hq720", "hqdefault", "mqdefault"] {
            guard let thumbnail = URL(string: "https://i.ytimg.com/vi/\(id)/\(variant).jpg"),
                  let image = fetchImage(thumbnail) else { continue }
            return Self.trimmingLetterbox(image)
        }
        return nil
    }

    /// The smaller YouTube stills (`hqdefault`, `mqdefault`) are 4:3 frames with
    /// the 16:9 video pillarboxed inside them. Cropping to the centred 16:9 band
    /// drops the black bars, which would otherwise show as bands across the cover.
    static func trimmingLetterbox(_ image: NSImage) -> NSImage {
        guard let rep = image.representations.first else { return image }
        let width = CGFloat(rep.pixelsWide)
        let height = CGFloat(rep.pixelsHigh)
        guard width > 0, height > 0 else { return image }

        let band = (width * 9 / 16).rounded()
        guard height > band + 2,
              let full = rep.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cgImage = full.cropping(
                  to: CGRect(x: 0, y: ((height - band) / 2).rounded(), width: width, height: band)
              ) else { return image }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: band))
    }

    private static func youtubeSearchURL(_ query: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components?.url
    }

    private static let titlePattern = try! NSRegularExpression(
        pattern: "\"title\":\\{\"runs\":\\[\\{\"text\":\"(.*?)\"\\}\\]"
    )
    private static let idPattern = try! NSRegularExpression(
        pattern: "\"videoId\":\"([A-Za-z0-9_-]{11})\""
    )

    /// The `(videoId, title)` pairs of a results page, in the order shown.
    static func youtubeResults(in html: String) -> [(id: String, title: String)] {
        let text = html as NSString
        let full = NSRange(location: 0, length: text.length)
        let titles = titlePattern.matches(in: html, range: full)
        let ids = idPattern.matches(in: html, range: full)
        guard !titles.isEmpty, !ids.isEmpty else { return [] }

        var results: [(id: String, title: String)] = []
        var cursor = 0
        for title in titles {
            var id: String?
            while cursor < ids.count, ids[cursor].range.location < title.range.location {
                id = text.substring(with: ids[cursor].range(at: 1))
                cursor += 1
            }
            guard let id else { continue }
            results.append((id, unescape(text.substring(with: title.range(at: 1)))))
            if results.count == 12 { break }
        }
        return results
    }

    /// Titles arrive as JSON fragments, so `&` and friends are still escaped.
    private static func unescape(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: "\\\"", with: "\"")
        out = out.replacingOccurrences(of: "\\/", with: "/")
        guard out.contains("\\u") else { return out }

        let ns = out as NSString
        let pattern = try! NSRegularExpression(pattern: "\\\\u([0-9a-fA-F]{4})")
        var result = ""
        var last = 0
        for match in pattern.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = ns.substring(with: match.range(at: 1))
            if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            }
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    private func fetchImage(_ url: URL) -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .returnCacheDataElseLoad
        let semaphore = DispatchSemaphore(value: 0)
        var image: NSImage?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data, data.count > 2_000 {
                image = NSImage(data: data)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 7)
        return image
    }

    private func fetch(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 7)
        return result
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(stripped))
    }

    // MARK: Disk cache

    private func fileURL(_ key: String) -> URL? {
        guard let folder else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return folder.appendingPathComponent(String(hash, radix: 16) + ".img")
    }

    private func imageFromDisk(_ key: String) -> NSImage? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private func writeToDisk(_ image: NSImage, key: String) {
        guard let url = fileURL(key),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? jpeg.write(to: url)
    }
}
