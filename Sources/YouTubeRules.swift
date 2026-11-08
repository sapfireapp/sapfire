import Foundation
import WebKit

// MARK: - YouTube: свежие правила uBlock Origin

/// YouTube воюет с блокировщиками, и uBlock Origin отвечает ему правками за дни: новые ключи рекламы в данных плеера,
/// подмены ответов, обход заглушки «Блокировщики рекламы нарушают Условия». Эти правки живут в uAssets
/// (quick-fixes.txt и filters.txt, GPL-3.0). Sapfire берёт оттуда строки для YouTube, переводит их в простую таблицу
/// (`rules`) и отдаёт её своему скрипту на странице (`YouTubeAds.engine`) — тот исполняет знакомые ему приёмы uBO
/// (json-prune, подмена ответов, set, nano-stb, rpnt/rmnt, trusted-edit-inbound-object и др.). Незнакомые приёмы
/// пропускаются (`unsupported` — в журнал), их добавляем с новой версией.
/// Обновление — вместе со списками блокировщика (FilterLists): при запуске только из файла или вложенного в программу
/// снимка (Filters/ubo-youtube.txt, tools/filters.sh), в сеть — через 10 минут после запуска, дальше раз в 6 часов.
enum UBOYouTube {
    static let id = "youtube"           // строка в Settings → Privacy (выключатель — BlockerPrefs, как у списков)
    static let sources = [
        "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt",
        "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt",
    ]
    static let updatedKey = "filters.updated.youtube"
    private static let maxAge: TimeInterval = 5 * 3600     // таймер списков — раз в 6 часов

    static var file: URL { FilterLists.dir.appendingPathComponent("ubo-youtube.txt") }

    /// Из полного списка uBO — только нужное: строки про YouTube и условия препроцессора (!#if / !#else / !#endif)
    static func relevant(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("!#") || ($0.contains("youtube") && !$0.hasPrefix("!")) }
            .joined(separator: "\n")
    }

    // MARK: Таблица правил для страницы

    private static var cachedJSON: String?
    /// Правила для скрипта страницы (JSON). Лениво: из скачанного файла, иначе из снимка в программе
    static var json: String {
        if let j = cachedJSON { return j }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? FilterLists.bundled("ubo-youtube")?.text ?? ""
        let j = encode(parse(text))
        cachedJSON = j
        return j
    }

    private static func set(_ text: String) {
        let j = encode(parse(text))
        DispatchQueue.main.async {
            guard j != cachedJSON else { return }
            cachedJSON = j
            YouTubeAds.rulesChanged()
        }
    }

    // MARK: Обновление

    /// Вызывается из FilterLists.updateIfNeeded. `download: false` — только из файла / снимка, в сеть не ходить
    static func updateIfNeeded(force: Bool = false, download: Bool = true) {
        guard ContentBlocker.shared.enabled, BlockerPrefs.shared.isOn(id) else { return }
        let last = UserDefaults.standard.double(forKey: updatedKey)
        if last == 0, let b = FilterLists.bundled("ubo-youtube"), !FileManager.default.fileExists(atPath: file.path) {
            UserDefaults.standard.set(b.date.timeIntervalSince1970, forKey: updatedKey)
        }
        guard force || (download && Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: updatedKey) > maxAge) else { return }
        let group = DispatchGroup()
        var parts = [String](repeating: "", count: sources.count)
        var ok = true
        let lock = NSLock()
        for (i, s) in sources.enumerated() {
            guard let url = URL(string: s) else { continue }
            group.enter()
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                defer { group.leave() }
                let text = data.flatMap { (resp as? HTTPURLResponse)?.statusCode == 200 ? String(data: $0, encoding: .utf8) : nil }
                lock.lock(); defer { lock.unlock() }
                if let text { parts[i] = relevant(text) } else { ok = false }
            }.resume()
        }
        group.notify(queue: .global(qos: .utility)) {
            // Только если пришли оба файла и в них есть правила для плеера — иначе остаётся прежнее
            let text = parts.joined(separator: "\n")
            guard ok, text.contains("+js(") else { return }
            try? text.data(using: .utf8)?.write(to: file, options: .atomic)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: updatedKey)
            set(text)
        }
    }

    // MARK: Разбор строк uBO

    /// Что исполняет скрипт страницы: имя приёма uBO → вид правила
    private static let kinds: [String: String] = [
        "json-prune": "prune", "json-prune-fetch-response": "prune-fetch", "jpfr": "prune-fetch",
        "json-prune-xhr-response": "prune-xhr", "jpxr": "prune-xhr",
        "trusted-replace-fetch-response": "repl-fetch", "trusted-rpfr": "repl-fetch",
        "trusted-replace-xhr-response": "repl-xhr", "trusted-rpxr": "repl-xhr",
        "set": "set", "set-constant": "set", "trusted-set": "set", "trusted-set-constant": "set",
        "nano-stb": "stb", "nano-setTimeout-booster": "stb",
        "rpnt": "rpnt", "replace-node-text": "rpnt", "trusted-rpnt": "rpnt", "trusted-replace-node-text": "rpnt",
        "rmnt": "rmnt", "remove-node-text": "rmnt",
        "trusted-edit-inbound-object": "edit",
        "trusted-replace-outbound-text": "out",
        "trusted-prevent-dom-bypass": "bypass",
    ]

    /// Препроцессор uBO: мы не Firefox, не MV3 и не умеем фильтровать HTML — все условия ложны
    private static func evalIf(_ expr: String) -> Bool {
        let e = expr.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        return e.components(separatedBy: "||").contains { conj in
            conj.components(separatedBy: "&&").allSatisfy { t in
                let t = t.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("!")      // любое «не X» истинно, любое «X» ложно
            }
        }
    }

    private static func isYouTube(_ d: String) -> Bool { d == "youtube.com" || d.hasSuffix(".youtube.com") }

    /// Аргументы +js(...): через запятую, «\,» — запятая внутри аргумента; кавычки по краям снимаются
    static func args(_ body: Substring) -> [String] {
        var out: [String] = [], cur = "", prev: Character = " "
        for ch in body {
            if ch == "," && prev != "\\" { out.append(cur); cur = "" } else { cur.append(ch) }
            prev = ch
        }
        out.append(cur)
        return out.map { a in
            var s = a.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\,", with: ",")
            if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "'" || f == "\"" || f == "`" { s = String(s.dropFirst().dropLast()) }
            return s
        }
    }

    /// Пары «ключ, значение» после обязательных аргументов (propsToMatch, sedCount, condition…)
    private static func options(_ a: [String], from i: Int) -> [String: String] {
        var o: [String: String] = [:]
        var k = i
        while k + 1 < a.count { o[a[k]] = a[k + 1]; k += 2 }
        return o
    }

    private static func url(_ props: String?) -> String {
        guard var p = props, !p.isEmpty else { return "" }
        if p.hasPrefix("url:") { p.removeFirst(4) }
        return p
    }

    static func parse(_ text: String) -> [String: Any] {
        var rules: [String: [[String: Any]]] = [:]
        var stack: [Bool] = []
        var jsExceptions = Set<String>(), cssExceptions = Set<String>()
        var unsupported = Set<String>()
        var scriptlets: [(hosts: [String], name: String, args: [String])] = []
        var css: [(hosts: [String], sel: String)] = []
        let procedural = [":has-text(", ":remove", ":style(", ":upward(", ":matches-", ":xpath(", ":watch-attr", ":min-text-length",
                          ":others(", ":-abp-", ":if(", ":if-not(", ":nth-ancestor("]

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if ") { stack.append(evalIf(String(line.dropFirst(5)))); continue }
            if line == "!#else" { if let l = stack.popLast() { stack.append(!l) }; continue }
            if line == "!#endif" { _ = stack.popLast(); continue }
            if line.isEmpty || line.hasPrefix("!") || stack.contains(false) { continue }

            // Сетевые подмены ответа: ||www.youtube.com/watch?$xhr,1p,replace=/"adSlots"/"no_ads"/
            if line.hasPrefix("|"), let dollar = line.lastIndex(of: "$"), let r = line.range(of: "replace=", range: dollar..<line.endIndex) {
                let pat = String(line[..<dollar])
                let host = pat.drop { $0 == "|" }.prefix { $0 != "/" && $0 != "^" && $0 != "*" }
                guard isYouTube(String(host)), let (find, to, flags) = slashTriple(line[r.upperBound...]) else { continue }
                let rule: [String: Any] = ["h": [String(host)], "on": "both", "find": "/\(find)/\(flags)", "to": to, "url": networkRegex(pat)]
                if !(rules["repl"] ?? []).contains(where: { NSDictionary(dictionary: $0).isEqual(to: rule) }) { rules["repl", default: []].append(rule) }
                continue
            }

            let seps = ["#@#+js(", "##+js(", "#@#", "##"]
            guard let sep = seps.lazy.compactMap({ s in line.range(of: s).map { (s, $0) } }).first else { continue }
            let hosts = line[..<sep.1.lowerBound].split(separator: ",").map(String.init).filter { !$0.hasPrefix("~") && isYouTube($0) }
            guard !hosts.isEmpty else { continue }
            let rest = line[sep.1.upperBound...]
            switch sep.0 {
            case "##+js(", "#@#+js(":
                guard rest.hasSuffix(")") else { continue }
                let a = args(rest.dropLast())
                guard var name = a.first, !name.isEmpty else { continue }
                if name.hasSuffix(".js") { name.removeLast(3) }
                if sep.0 == "#@#+js(" { jsExceptions.insert(([name] + a.dropFirst()).joined(separator: "\u{1}")); continue }
                scriptlets.append((hosts, name, Array(a.dropFirst())))
            case "#@#":
                cssExceptions.insert(String(rest))
            default:
                let sel = String(rest)
                // ##^ — фильтр HTML, #$# / #?# — не наши; приёмы uBO внутри селектора движок не знает
                if sel.hasPrefix("^") || sel.hasPrefix("+") || procedural.contains(where: { sel.contains($0) }) { continue }
                // Рекламу у плеера не прятать: плеер ждёт, пока она покажется (~25 с)
                if sel.contains("player-ads") || sel.contains(".ytp-ad-") { continue }
                css.append((hosts, sel))
            }
        }

        var seen = Set<String>()       // filters.txt и quick-fixes.txt повторяют друг друга
        for s in scriptlets where !jsExceptions.contains(([s.name] + s.args).joined(separator: "\u{1}")) {
            guard seen.insert((s.hosts + [s.name] + s.args).joined(separator: "\u{1}")).inserted else { continue }
            guard let kind = kinds[s.name] else { unsupported.insert(s.name); continue }
            let a = s.args
            let arg = { (i: Int) in i < a.count ? a[i] : "" }
            var r: [String: Any] = ["h": s.hosts]
            switch kind {
            case "prune", "prune-fetch", "prune-xhr":
                r["paths"] = arg(0).split(separator: " ").map(String.init)
                r["needle"] = arg(1).split(separator: " ").map(String.init)
                r["url"] = url(options(a, from: 2)["propsToMatch"])
                r["on"] = kind == "prune" ? "parse" : kind == "prune-fetch" ? "fetch" : "xhr"
                rules["prune", default: []].append(r)
            case "repl-fetch", "repl-xhr":
                r["find"] = arg(0); r["to"] = arg(1); r["url"] = url(arg(2))
                r["on"] = kind == "repl-fetch" ? "fetch" : "xhr"
                rules["repl", default: []].append(r)
            case "set":
                r["path"] = arg(0); r["value"] = arg(1)
                rules["set", default: []].append(r)
            case "stb":
                r["needle"] = arg(0); r["delay"] = arg(1); r["boost"] = arg(2)
                rules["stb", default: []].append(r)
            case "rpnt":
                guard arg(0).lowercased() == "script" else { unsupported.insert(s.name + " " + arg(0)); continue }
                r["find"] = arg(1); r["to"] = arg(2); r["opt"] = options(a, from: 3)
                rules["rpnt", default: []].append(r)
            case "rmnt":
                guard arg(0).lowercased() == "script" else { unsupported.insert(s.name + " " + arg(0)); continue }
                r["needle"] = arg(1)
                rules["rmnt", default: []].append(r)
            case "edit":
                r["fn"] = arg(0); r["arg"] = Int(arg(1)) ?? 0; r["expr"] = arg(2)
                rules["edit", default: []].append(r)
            case "out":
                r["fn"] = arg(0); r["find"] = arg(1); r["to"] = arg(2); r["opt"] = options(a, from: 3)
                rules["out", default: []].append(r)
            case "bypass":
                r["fn"] = arg(0); r["prop"] = arg(1)
                rules["bypass", default: []].append(r)
            default: break
            }
        }
        rules["css"] = css.filter { !cssExceptions.contains($0.sel) }.map { ["h": $0.hosts, "sel": $0.sel] }
        if !unsupported.isEmpty { NSLog("Sapfire: YouTube rules — skipped uBO scriptlets: %@", unsupported.sorted().joined(separator: ", ")) }
        return rules
    }

    /// /find/to/flags (косые внутри экранированы)
    private static func slashTriple(_ s: Substring) -> (String, String, String)? {
        guard s.first == "/" else { return nil }
        var parts: [String] = [], cur = "", prev: Character = " "
        for ch in s.dropFirst() {
            if parts.count == 2 { if ch == "," || ch == "$" { break }; cur.append(ch); continue }
            if ch == "/" && prev != "\\" { parts.append(cur); cur = "" } else { cur.append(ch) }
            prev = ch
        }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1].replacingOccurrences(of: "\\/", with: "/"), cur)
    }

    /// Адрес сетевого правила ABP → регулярка /…/ (|| — любой поддомен, * — что угодно, ^ — разделитель)
    private static func networkRegex(_ p: String) -> String {
        var s = Substring(p), head = ""
        if s.hasPrefix("||") { s = s.dropFirst(2); head = "^https?://(?:[^/]*\\.)?" } else if s.hasPrefix("|") { s = s.dropFirst(); head = "^" }
        var body = ""
        for ch in s {
            switch ch {
            case "*": body += ".*"
            case "^": body += "(?:[/?&:]|$)"
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "|", "\\", "$", "/": body += "\\" + String(ch)
            default: body.append(ch)
            }
        }
        return "/" + head + body + "/"
    }

    private static func encode(_ rules: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        // В JS-тексте эти два знака — конец строки
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
