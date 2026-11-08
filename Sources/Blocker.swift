import AppKit
import WebKit

// MARK: - Блокировщик: общественные списки фильтров (как в Orion / Safari-блокировщиках)

/// Скачивает списки фильтров в формате Adblock Plus, переводит их в правила движка Safari
/// (WKContentRuleList) и держит скомпилированными. Движок применяет правила сам, внутри себя —
/// это быстро и почти не стоит памяти. Списки обновляются раз в несколько дней.
final class FilterLists {
    static let shared = FilterLists()

    struct Source { let id: String; let name: String; let url: String }
    static let sources: [Source] = [
        Source(id: "easylist", name: "EasyList", url: "https://easylist.to/easylist/easylist.txt"),
        Source(id: "easyprivacy", name: "EasyPrivacy", url: "https://easylist.to/easylist/easyprivacy.txt"),
        Source(id: "ruadlist", name: "RU AdList", url: "https://easylist-downloads.adblockplus.org/ruadlist.txt"),
        // Cookie-баннеры (EasyList Cookie / Fanboy’s Cookie Monster): почти целиком правила скрытия — CosmeticFilter
        Source(id: "cookies", name: "Cookie Banners", url: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"),
    ]
    private static let maxAge: TimeInterval = 4 * 24 * 3600
    private static let maxRules = 149_000          // предел движка на один список
    /// Версия перевода правил: поменялась — списки пересобираются из скачанных файлов при запуске
    private static let converterVersion = 4

    /// Скомпилированные списки (по id)
    private(set) var lists: [String: WKContentRuleList] = [:]
    /// Perf: списки без скрытия элементов — под другим именем в хранилище движка
    private static var suffix: String { Perf.off("blk-cos") ? "-nocos" : "" }
    var onChange: (() -> Void)?

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire/filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// При запуске: взять готовые из движка, затем докачать устаревшие
    func start() {
        let store = WKContentRuleListStore.default()!
        let group = DispatchGroup()
        for s in Self.sources + [Source(id: "custom", name: "Your Rules", url: "")] {
            group.enter()
            store.lookUpContentRuleList(forIdentifier: "sapfire-f-" + s.id + Self.suffix) { list, _ in
                DispatchQueue.main.async {
                    if let list { self.lists[s.id] = list }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            self.onChange?()
            self.rebuildIfConverterChanged()
            // При запуске — только из файлов и вложенных списков, без сети; устаревшие докачиваются через 10 минут
            // и дальше раз в 6 часов (при старте Sapfire молчит в сети)
            self.updateIfNeeded(download: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { self.updateIfNeeded() }
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in self.updateIfNeeded() }
        }
    }
    private var refreshTimer: Timer?

    /// Список, вложенный в программу (Filters/*.txt → Resources/filters/<id>.txt.lzfse, см. build.command)
    static func bundled(_ id: String) -> (text: String, date: Date)? {
        guard let u = Bundle.main.url(forResource: id + ".txt", withExtension: "lzfse", subdirectory: "filters"),
              let d = try? Data(contentsOf: u), let raw = try? (d as NSData).decompressed(using: .lzfse) as Data,
              let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) else { return nil }
        let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return (text, date)
    }

    /// Перевод правил исправили — пересобрать списки из уже скачанных файлов (не дожидаясь обновления)
    private func rebuildIfConverterChanged() {
        let key = "filters.converter"
        guard UserDefaults.standard.integer(forKey: key) != Self.converterVersion else { return }
        UserDefaults.standard.set(Self.converterVersion, forKey: key)
        rebuildAll()
    }

    /// Раз в несколько дней — свежие списки. Выключенные списки не качаются и не собираются (включат — соберутся).
    /// `download: false` — только из файла или вложенного списка, в сеть не ходить
    func updateIfNeeded(force: Bool = false, download: Bool = true) {
        let prefs = BlockerPrefs.shared
        UBOYouTube.updateIfNeeded(force: force, download: download)    // правила uBlock Origin для YouTube
        for s in Self.sources where force || prefs.isOn(s.id) {
            let key = "filters.updated." + s.id
            let last = UserDefaults.standard.double(forKey: key)
            let file = Self.dir.appendingPathComponent(s.id + ".txt")
            if lists[s.id] == nil, !force {
                // Списка нет в движке, но файл скачан (другой вариант перевода) — собрать из файла, не качать
                if let data = try? Data(contentsOf: file),
                   let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    compile(s, text) {}
                    continue
                }
                // Первый запуск: список из программы — блокировка работает сразу, без сети; свежий докачается по сроку
                if let b = Self.bundled(s.id) {
                    try? b.text.data(using: .utf8)?.write(to: file)
                    compile(s, b.text) { UserDefaults.standard.set(b.date.timeIntervalSince1970, forKey: key) }
                    continue
                }
            }
            let missing = lists[s.id] == nil && !FileManager.default.fileExists(atPath: file.path)
            guard force || missing || (download && Date().timeIntervalSince1970 - last > Self.maxAge),
                  let url = URL(string: s.url) else { continue }
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
                try? data.write(to: Self.dir.appendingPathComponent(s.id + ".txt"))
                self.compile(s, text) {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
                }
            }.resume()
        }
    }

    private func compile(_ s: Source, _ text: String, done: @escaping () -> Void) {
        let allow = BlockerPrefs.shared.exceptionText
        DispatchQueue.global(qos: .utility).async {
            // В движок — только сетевые правила; скрытие элементов — CosmeticFilter (страница берёт только своё)
            let net = ABPConverter.convert(text).network
            let cosmetic = Perf.off("blk-cos") ? nil : CosmeticFilter.parse(text)
            DispatchQueue.main.async { CosmeticFilter.shared.set(s.id, cosmetic) }
            // Разрешённое пользователем — в каждый список: исключение действует только внутри своего списка
            let extra = ABPConverter.convert(allow).network
            self.tryCompile(s.id, Array((extra + net).prefix(Self.maxRules))) { ok in if ok { done() } }
        }
    }

    /// Свои правила или разрешения поменялись — пересобрать все списки из скачанных файлов
    func rebuildAll() {
        for s in Self.sources {
            let f = Self.dir.appendingPathComponent(s.id + ".txt")
            guard let data = try? Data(contentsOf: f),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            compile(s, text) {}
        }
        compileCustom()
        ContentBlocker.shared.compile()
    }

    /// Свой список: правила, которые пользователь дописал сам (Settings → Privacy → Your Rules)
    func compileCustom() {
        let text = BlockerPrefs.shared.blockText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lists["custom"] = nil
            CosmeticFilter.shared.set("custom", nil)
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "sapfire-f-custom") { _ in }
            onChange?()
            return
        }
        compile(Source(id: "custom", name: "Your Rules", url: ""), text) {}
    }

    private func tryCompile(_ id: String, _ rules: [[String: Any]], _ done: @escaping (Bool) -> Void) {
        // Исключения (ignore-previous-rules) должны идти после блокировок
        let sorted = rules.filter { ($0["action"] as? [String: String])?["type"] != "ignore-previous-rules" }
            + rules.filter { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" }
        guard let data = try? JSONSerialization.data(withJSONObject: sorted),
              let json = String(data: data, encoding: .utf8) else { done(false); return }
        DispatchQueue.main.async {
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "sapfire-f-" + id + Self.suffix,
                                                                    encodedContentRuleList: json) { list, error in
                if let error { NSLog("Sapfire filters \(id): \(error.localizedDescription)") }
                if let list { self.lists[id] = list; self.onChange?() }
                done(list != nil)
            }
        }
    }
}

/// Перевод правил Adblock Plus в правила движка Safari. Берём то, что движок умеет:
/// блокировку адресов (с типами загрузок, своими/чужими и сайтами), исключения и скрытие элементов.
/// Сложное (скриптлеты, перенаправления, :has и т. п.) пропускаем.
enum ABPConverter {
    /// Сетевые правила списка. Скрытие элементов («##») здесь пропускается — его разбирает CosmeticFilter
    static func convert(_ text: String) -> (network: [[String: Any]], cosmetic: [[String: Any]]) {
        var net: [[String: Any]] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if line.contains("##") || line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#") || line.contains("$$") { continue }
            if let rule = network(line) { net.append(rule) }
        }
        return (net, [])
    }

    static func selectorOK(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 400, s.allSatisfy({ $0.isASCII }) else { return false }
        for bad in [":has", ":-abp", ":xpath", ":contains", ":upward", ":style", ":remove", ":matches-", ":min-text", ":watch-attr", ":nth-ancestor", "+js", ":not(:", "{", "}"] where s.contains(bad) { return false }
        return true
    }

    private static let types: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
        "xmlhttprequest": "raw", "xhr": "raw", "subdocument": "document", "frame": "document", "media": "media",
        "font": "font", "ping": "ping", "websocket": "websocket", "other": "other", "object": "media", "popup": "popup",
    ]
    // «ping» (маячки), «websocket», «other» — свои типы движка. Раньше ping переводился в «raw» (любой fetch/XHR),
    // и общее правило «*$ping,third-party» из EasyPrivacy глушило все запросы данных к чужим адресам —
    // ломались загрузки файлов, 3D-модели, облака
    private static let allTypes = ["image", "style-sheet", "script", "font", "raw", "media", "document", "svg-document", "popup", "ping", "websocket", "other"]

    private static func network(_ line: String) -> [String: Any]? {
        var l = line, exception = false
        if l.hasPrefix("@@") { exception = true; l.removeFirst(2) }
        var opts: [String] = []
        // Опции после последнего «$» (если за ним не часть адреса)
        if let i = l.lastIndex(of: "$"), !l[l.index(after: i)...].contains("/") {
            opts = l[l.index(after: i)...].split(separator: ",").map { $0.lowercased() }
            l = String(l[..<i])
        }
        if l.hasPrefix("/") && l.hasSuffix("/") && l.count > 2 { return nil }     // регулярки — пропускаем
        guard !l.isEmpty, l.allSatisfy({ $0.isASCII }) else { return nil }

        var trig: [String: Any] = [:], act = exception ? "ignore-previous-rules" : "block"
        var incl: [String] = [], excl: [String] = [], wholePage = false
        for o in opts {
            switch o {
            case "third-party", "3p": trig["load-type"] = ["third-party"]
            case "~third-party", "1p", "first-party": trig["load-type"] = ["first-party"]
            case "match-case": trig["url-filter-is-case-sensitive"] = true
            case "important", "all": break
            case "document", "doc": if exception { wholePage = true } else { incl.append("document") }
            case _ where o.hasPrefix("domain="):
                let ds = o.dropFirst(7).split(separator: "|").map(String.init)
                guard let t = domainTrigger(ds) else { return nil }
                trig.merge(t) { a, _ in a }
            case _ where types[o] != nil: incl.append(types[o]!)
            case _ where o.hasPrefix("~") && types[String(o.dropFirst())] != nil: excl.append(types[String(o.dropFirst())]!)
            default: return nil       // redirect, csp, removeparam, generichide и прочее — движок не умеет
            }
        }
        if wholePage {
            // Сайт целиком в белом списке
            guard let host = hostOnly(l) else { return nil }
            return ["trigger": ["url-filter": ".*", "if-domain": ["*" + host]], "action": ["type": "ignore-previous-rules"]]
        }
        if !incl.isEmpty { trig["resource-type"] = Array(Set(incl)) }
        else if !excl.isEmpty { trig["resource-type"] = allTypes.filter { !excl.contains($0) } }
        guard let re = regex(l) else { return nil }
        trig["url-filter"] = re
        return ["trigger": trig, "action": ["type": act]]
    }

    private static func hostOnly(_ p: String) -> String? {
        guard p.hasPrefix("||") else { return nil }
        let h = p.dropFirst(2).prefix { $0 != "^" && $0 != "/" && $0 != "*" }
        return h.isEmpty ? nil : String(h).lowercased()
    }

    /// Шаблон ABP → регулярка движка (без «|» — движок не понимает альтернативы)
    private static func regex(_ p: String) -> String? {
        var s = Substring(p), out = ""
        if s.hasPrefix("||") { out = "^[^:]+://+([^:/]+\\.)?"; s = s.dropFirst(2) }
        else if s.hasPrefix("|") { out = "^"; s = s.dropFirst() }
        var tail = ""
        if s.hasSuffix("|") { tail = "$"; s = s.dropLast() }
        if s.isEmpty || s == "*" { return out.isEmpty ? ".*" : out + ".*" }
        for c in s {
            switch c {
            case "*": out += ".*"
            case "^": out += "[/:?=&]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|": out += "\\" + String(c)
            default: out.append(c)
            }
        }
        // Очень короткие шаблоны без привязки ловят слишком много
        if out.count < 4 { return nil }
        return out + tail
    }

    /// domain=a.com|~b.com → if-domain / unless-domain (оба сразу движок не умеет)
    private static func domainTrigger(_ ds: [String]) -> [String: Any]? {
        let clean = ds.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) && !$0.contains("*") }
        let inc = clean.filter { !$0.hasPrefix("~") }.map { "*" + $0 }
        let exc = clean.filter { $0.hasPrefix("~") }.map { "*" + $0.dropFirst() }
        if !inc.isEmpty { return ["if-domain": inc] }
        if !exc.isEmpty { return ["unless-domain": exc] }
        return nil
    }
}


// MARK: - Настройки блокировщика

/// Что блокировать: какие списки включены, свои правила, адреса, разрешённые на отдельных сайтах.
/// Разрешения работают как правила-исключения «@@» и вписываются в каждый список
/// (в движке Safari исключение действует только внутри своего списка).
@Observable
final class BlockerPrefs {
    static let shared = BlockerPrefs()

    /// Списки: встроенный (builtin), скачиваемые (FilterLists.sources) и свой (custom)
    static let builtinID = "builtin"
    /// Названия списков — для окна сайта («кем заблокировано»)
    static func listName(_ identifier: String) -> String {
        if identifier == "sapfire-ads" { return "Built-in" }
        let id = identifier.replacingOccurrences(of: "sapfire-f-", with: "")
        if id == "custom" { return "Your Rules" }
        return FilterLists.sources.first { $0.id == id }?.name ?? id
    }

    private(set) var off: Set<String>
    /// Свои правила в формате Adblock Plus (по строке)
    private(set) var custom: String
    struct Allow: Codable, Hashable, Identifiable {
        var site: String      // где разрешено
        var host: String      // что разрешено
        var id: String { site + " " + host }
    }
    private(set) var allows: [Allow]

    private init() {
        let d = UserDefaults.standard
        off = Set(d.stringArray(forKey: "blocker.off") ?? [])
        custom = d.string(forKey: "blocker.custom") ?? ""
        allows = (d.data(forKey: "blocker.allows")).flatMap { try? JSONDecoder().decode([Allow].self, from: $0) } ?? []
        // Региональный список (RU AdList) по умолчанию включён только там, где Mac говорит по-русски:
        // чужому пользователю он стоил бы скорости впустую. Решается один раз, дальше — выбор в Settings → Privacy
        if d.object(forKey: "blocker.regional") == nil {
            d.set(true, forKey: "blocker.regional")
            if !Self.russianMac { off.insert("ruadlist"); d.set(Array(off), forKey: "blocker.off") }
        }
    }

    static var russianMac: Bool {
        if Locale.preferredLanguages.contains(where: { let l = $0.lowercased(); return l.hasPrefix("ru") || l.hasPrefix("uk") || l.hasPrefix("be") }) { return true }
        return ["RU", "BY", "KZ", "UA"].contains(Locale.current.region?.identifier ?? "")
    }

    func isOn(_ id: String) -> Bool { !off.contains(id) }

    /// Скрытие элементов «для всех сайтов» (общие селекторы EasyList и RU AdList, ~14 тысяч). Раньше движок держал их
    /// на каждой странице как огромную таблицу стилей (Speedometer 27 вместо 38) и это было выключено; теперь страница
    /// получает только те селекторы, чьи id и классы у неё есть (CosmeticFilter) — включено по умолчанию
    var genericHiding: Bool {
        get { UserDefaults.standard.object(forKey: "blocker.genericHiding") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "blocker.genericHiding") }
    }

    /// Включить / выключить список — без пересборки, просто снять или поставить его на страницах
    func setOn(_ id: String, _ on: Bool) {
        if on { off.remove(id) } else { off.insert(id) }
        UserDefaults.standard.set(Array(off), forKey: "blocker.off")
        ContentBlocker.shared.refreshAll()
        if on { FilterLists.shared.updateIfNeeded() }      // выключенный список не собирался — собрать (или скачать)
    }

    /// Строки-правила блокировки из своих правил
    var blockText: String {
        custom.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("@@") }.joined(separator: "\n")
    }
    /// Все исключения: свои «@@…» и разрешённое на сайтах
    var exceptionText: String {
        let own = custom.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("@@") }
        let sites = allows.map { "@@||\($0.host)^$domain=\($0.site)" }
        return (own + sites).joined(separator: "\n")
    }

    private var rebuildWork: DispatchWorkItem?
    private func rebuildSoon() {
        rebuildWork?.cancel()
        let w = DispatchWorkItem { FilterLists.shared.rebuildAll() }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func setCustom(_ text: String) {
        guard text != custom else { return }
        custom = text
        UserDefaults.standard.set(text, forKey: "blocker.custom")
        rebuildSoon()
    }

    func allow(_ host: String, on site: String) {
        let a = Allow(site: site.lowercased(), host: host.lowercased())
        guard !allows.contains(a) else { return }
        allows.append(a)
        saveAllows()
    }

    func removeAllow(_ a: Allow) {
        allows.removeAll { $0 == a }
        saveAllows()
    }

    private func saveAllows() {
        if let d = try? JSONEncoder().encode(allows) { UserDefaults.standard.set(d, forKey: "blocker.allows") }
        rebuildSoon()
    }
}
