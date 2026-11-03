import Foundation

struct WebSource: Codable, Hashable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

enum WebSearchError: LocalizedError {
    case noResults
    case blocked(Int)

    var errorDescription: String? {
        switch self {
        case .noResults: "No web results found."
        case .blocked(let code): "The search service returned HTTP \(code)."
        }
    }
}

enum WebSearch {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: config)
    }()

    static func context(for query: String, results limit: Int = 5, pages: Int = 2) async throws -> (context: String, sources: [WebSource]) {
        let sources = try await search(query, limit: limit)
        let excerpts = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, source) in sources.prefix(pages).enumerated() {
                group.addTask { (i, await pageText(source.url, limit: 1500)) }
            }
            var out: [Int: String] = [:]
            for await (i, text) in group { if let text { out[i] = text } }
            return out
        }
        let date = Date().formatted(date: .long, time: .omitted)
        var lines = ["Web search results for \"\(query)\" (searched \(date)):"]
        for (i, source) in sources.enumerated() {
            lines.append("")
            lines.append("[\(i + 1)] \(source.title)")
            lines.append("URL: \(source.url)")
            if !source.snippet.isEmpty { lines.append(source.snippet) }
            if let excerpt = excerpts[i] { lines.append("Excerpt: \(excerpt)") }
        }
        lines.append("")
        lines.append("Use these results when they are relevant and cite them like [1]. If they don't answer the question, say so.")
        return (lines.joined(separator: "\n"), sources)
    }

    static func search(_ query: String, limit: Int = 5) async throws -> [WebSource] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebSearchError.blocked(http.statusCode)
        }
        let results = parse(String(decoding: data, as: UTF8.self), limit: limit)
        if results.isEmpty { throw WebSearchError.noResults }
        return results
    }

    static func parse(_ html: String, limit: Int) -> [WebSource] {
        let link = try! NSRegularExpression(pattern: #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snippet = try! NSRegularExpression(pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        var results: [WebSource] = []
        var seen = Set<String>()
        for block in html.components(separatedBy: "class=\"result results_links").dropFirst() {
            if block.contains("result--ad") { continue }
            let ns = block as NSString
            guard let m = link.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)) else { continue }
            let url = resolve(decodeEntities(ns.substring(with: m.range(at: 1))))
            guard url.hasPrefix("http"), !seen.contains(url) else { continue }
            seen.insert(url)
            let title = plain(ns.substring(with: m.range(at: 2)))
            var text = ""
            if let s = snippet.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)) {
                text = plain(ns.substring(with: s.range(at: 1)))
            }
            results.append(WebSource(title: title, url: url, snippet: text))
            if results.count >= limit { break }
        }
        return results
    }

    static func pageText(_ urlString: String, limit: Int) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").contains("html"),
              data.count < 3_000_000 else { return nil }
        let text = readable(String(decoding: data, as: UTF8.self))
        guard text.count > 80 else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func readable(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "form", "aside"] {
            s = s.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let paragraph = try! NSRegularExpression(pattern: #"<p[^>]*>([\s\S]*?)</p>"#, options: [.caseInsensitive])
        let ns = s as NSString
        let paragraphs = paragraph.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { plain(ns.substring(with: $0.range(at: 1))) }
            .filter { $0.count > 60 }
        if paragraphs.count >= 2 { return paragraphs.joined(separator: " ") }
        return plain(s)
    }

    static func plain(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(stripped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&#x2F;", "/")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    private static func resolve(_ href: String) -> String {
        var url = href.hasPrefix("//") ? "https:" + href : href
        if let components = URLComponents(string: url), components.path.hasPrefix("/l/"),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            url = target
        }
        return url
    }
}
