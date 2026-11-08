import Foundation

/// !-команда: «!yt котики» → поиск на YouTube. Список правится в Settings → Search → Bangs (BangStore)
struct Bang: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var name: String
    var template: String   // %s — место для запроса

    init(key: String, name: String, template: String) { self.key = key; self.name = name; self.template = template }

    func url(query: String) -> URL? {
        if query.isEmpty {
            guard let c = URLComponents(string: template.replacingOccurrences(of: "%s", with: "")),
                  let scheme = c.scheme, let host = c.host else { return nil }
            return URL(string: "\(scheme)://\(host)/")
        }
        return Omnibox.fill(template, query)
    }
}

enum Omnibox {
    /// Неизвестные !-команды отдаются DuckDuckGo — он знает тысячи сокращений.
    static let fallbackBangs = "https://duckduckgo.com/?q=%s"

    /// Действующие !-команды: свой список из настроек (или встроенные)
    static var bangs: [Bang] { BangStore.shared.list }

    /// Встроенные — с ними Sapfire приходит и к ним возвращает «Restore Built-in». Только всемирные сайты;
    /// Википедия и переводчик — на языке Mac (английская Википедия — отдельно, если язык не английский)
    static var builtIn: [Bang] {
        let lang = String(Locale.preferredLanguages.first?.prefix(2) ?? "en").lowercased()
        var list = [
            Bang(key: "g", name: "Google", template: "https://www.google.com/search?q=%s"),
            Bang(key: "i", name: "Google Images", template: "https://www.google.com/search?tbm=isch&q=%s"),
            Bang(key: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
            Bang(key: "w", name: "Wikipedia", template: "https://\(lang).wikipedia.org/w/index.php?search=%s"),
        ]
        if lang != "en" { list.append(Bang(key: "we", name: "Wikipedia (EN)", template: "https://en.wikipedia.org/w/index.php?search=%s")) }
        list += [
            Bang(key: "ddg", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"),
            Bang(key: "tr", name: "Translate", template: "https://translate.google.com/?sl=auto&tl=\(lang)&op=translate&text=%s"),
            Bang(key: "m", name: "Maps", template: "https://www.google.com/maps/search/%s"),
            Bang(key: "gh", name: "GitHub", template: "https://github.com/search?q=%s"),
            Bang(key: "r", name: "Reddit", template: "https://www.reddit.com/search/?q=%s"),
            Bang(key: "c", name: "Claude", template: "https://claude.ai/new?q=%s"),
            Bang(key: "gpt", name: "ChatGPT", template: "https://chatgpt.com/?q=%s"),
            Bang(key: "p", name: "Perplexity", template: "https://www.perplexity.ai/search?q=%s"),
            Bang(key: "a", name: "Amazon", template: "https://www.amazon.com/s?k=%s"),
            Bang(key: "imdb", name: "IMDb", template: "https://www.imdb.com/find/?q=%s"),
            Bang(key: "so", name: "Stack Overflow", template: "https://stackoverflow.com/search?q=%s"),
        ]
        return list
    }

    private static let queryAllowed: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&+=?#")
        return s
    }()

    static func fill(_ template: String, _ q: String) -> URL? {
        let enc = q.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? q
        return URL(string: template.replacingOccurrences(of: "%s", with: enc))
    }

    /// Находит !-команду где угодно в строке: «котики !yt» тоже сработает.
    static func parseBang(_ input: String) -> (key: String, query: String)? {
        var words = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let i = words.firstIndex(where: { $0.hasPrefix("!") && $0.count > 1 }) else { return nil }
        let key = String(words[i].dropFirst()).lowercased()
        words.remove(at: i)
        return (key, words.joined(separator: " "))
    }

    static func url(for raw: String, incognito: Bool = false) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let parsed = parseBang(input) {
            if let b = bangs.first(where: { $0.key == parsed.key }) { return b.url(query: parsed.query) }
            return fill(fallbackBangs, input)
        }
        if let u = directURL(input) { return u }
        return fill(SearchEngine.current(incognito: incognito).template, input)
    }

    static func label(for raw: String, incognito: Bool = false) -> String {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = parseBang(input) {
            let q = parsed.query
            if let b = bangs.first(where: { $0.key == parsed.key }) {
                return q.isEmpty ? "Open \(b.name)" : "\(b.name): \(q)"
            }
            return "DuckDuckGo: \(input)"
        }
        if directURL(input) != nil { return "Open \(input)" }
        return "\(SearchEngine.current(incognito: incognito).name): \(input)"
    }

    static func directURL(_ input: String) -> URL? {
        if input.contains(" ") { return nil }
        let lower = input.lowercased()
        for scheme in ["http://", "https://", "file://", "about:"] where lower.hasPrefix(scheme) {
            return URL(string: input)
        }
        if lower.hasPrefix("localhost") || lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + input)
        }
        guard input.contains("."), let u = URL(string: "https://" + input), let host = u.host,
              let tld = host.split(separator: ".").last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) else { return nil }
        return u
    }
}


/// Свои !-команды (Settings → Search → Bangs): хранятся целиком, пока не вернули встроенные
@Observable
final class BangStore {
    static let shared = BangStore()
    private static let key = "bangs"
    private(set) var list: [Bang]
    /// Список отличается от встроенного
    var customized: Bool { UserDefaults.standard.data(forKey: Self.key) != nil }

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let v = try? JSONDecoder().decode([Bang].self, from: d) { list = v }
        else { list = Omnibox.builtIn }
    }

    func update(_ b: Bang) {
        guard let i = list.firstIndex(where: { $0.id == b.id }) else { return }
        var v = b
        v.key = Self.clean(v.key)
        list[i] = v
        save()
    }
    @discardableResult
    func add() -> Bang {
        var n = 1
        while list.contains(where: { $0.key == "new\(n == 1 ? "" : String(n))" }) { n += 1 }
        let b = Bang(key: "new\(n == 1 ? "" : String(n))", name: "New", template: "https://example.com/search?q=%s")
        list.insert(b, at: 0)
        save()
        return b
    }
    func remove(_ b: Bang) { list.removeAll { $0.id == b.id }; save() }
    func restore() {
        list = Omnibox.builtIn
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// Ключ — строчными, без «!» и пробелов
    static func clean(_ k: String) -> String {
        k.lowercased().filter { !$0.isWhitespace && $0 != "!" }
    }
    /// Что не так с командой (nil — всё хорошо)
    func problem(_ b: Bang) -> String? {
        if b.key.isEmpty { return "Needs a key" }
        if list.contains(where: { $0.id != b.id && $0.key == b.key }) { return "!\(b.key) is already used" }
        if !b.template.contains("%s") { return "Put %s where the search text goes" }
        if URL(string: b.template.replacingOccurrences(of: "%s", with: "x"))?.host == nil { return "Not a web address" }
        return nil
    }

    private func save() {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
