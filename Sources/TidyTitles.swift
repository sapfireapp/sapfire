import Foundation

// MARK: - Tidy Tab Titles (как в Arc)

/// Короткие чистые названия вкладок. Закрепил вкладку — название само становится коротким (если модуль включён).
/// Через Gemini, если у Summarize есть ключ и модуль Summarize включён; иначе — правилами: убрать счётчики
/// «(3)» и название сайта из «Статья — Сайт». Своё название — Tab.customTitle (Rename… / Restore Original Title).
enum TidyTitles {
    /// Вкладку только что закрепили: само — только правилами; в Gemini заголовки (в них бывает почта
    /// и темы писем) уходят лишь по прямой команде Tidy Title
    static func pinned(_ t: Tab) {
        guard Module.tidyTitles.isOn, t.customTitle == nil, !t.title.isEmpty else { return }
        tidy(t, nil, ai: false)
    }

    /// Сделать название коротким (правый клик → Tidy Title)
    static func tidy(_ t: Tab, _ model: BrowserModel?, ai: Bool = true) {
        let original = t.title
        guard !original.isEmpty else { return }
        let m = model ?? t.browser
        m?.checkpoint("Tidy Title")
        let before = t.customTitle                    // к этому возвращает «Undo» — и после ответа Gemini тоже
        let quick = trimmed(original, host: t.url?.host)
        let first = apply(quick, to: t, before: before, original: original, model: m)
        // Инкогнито и временные контейнеры наружу не отдаём
        guard ai, Module.summarize.isOn, Summarizer.hasKey, !t.isIncognito, !t.temporary else { return }
        // Адреса почты наружу не отдаём
        let clean = original.replacingOccurrences(of: #"[\w.+-]+@[\w-]+(\.[\w-]+)+"#, with: "", options: .regularExpression)
        ask(clean, host: t.url?.host, session: session(for: t)) { [weak t, weak m] name in
            // Страница сменилась или название уже поменяли вручную — ответ устарел
            guard let t, let name, t.title == original, t.customTitle == first.custom else { return }
            if let n = first.notice { m?.dismiss(n) }
            apply(name, to: t, before: before, original: original, model: m)
        }
    }

    /// Поставить название; возвращает, что поставлено, и уведомление с «Undo»
    @discardableResult
    private static func apply(_ name: String, to t: Tab, before: String?, original: String, model m: BrowserModel?) -> (custom: String?, notice: Notice?) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let was = t.customTitle
        t.customTitle = n.isEmpty || n == original ? nil : n
        m?.save()
        guard let c = t.customTitle, c != was else { return (t.customTitle, nil) }
        let notice = m?.notify("Renamed to “\(c)”", icon: "textformat.abc", action: "Undo") { [weak t, weak m] in
            t?.customTitle = before
            m?.save()
        }
        return (c, notice)
    }

    /// Вкладка профиля через туннель — и запрос через туннель, не напрямую (Privacy.md)
    private static func session(for t: Tab) -> URLSession {
        if let p = t.effectiveProfileID ?? t.browser?.space(of: t)?.profileID, Tunnel.isOn(p),
           let s = Incognito.proxySession(Incognito.endpoint) { return s }
        return Summarizer.session
    }

    // MARK: Правила

    private static let separators = [" | ", " – ", " — ", " - ", " · ", " • ", " :: ", " / "]

    /// «(3) Inbox — Gmail» → «Inbox»; «Мор, Томас — Википедия» → «Мор, Томас»
    static func trimmed(_ title: String, host: String?, known: [String]? = nil) -> String {
        var s = title.trimmingCharacters(in: .whitespaces)
        // Счётчики уведомлений в начале: «(3) », «(12+) », «• »
        if let r = s.range(of: #"^(\(\d+\+?\)\s*|•\s*)+"#, options: .regularExpression) { s.removeSubrange(r) }
        // Части через разделители: убрать название сайта (совпадает с адресом или короткий хвост)
        let site = siteWords(host)
        let names = siteNames(host, titles: known ?? HistoryStore.shared.titles(host: host))
        for sep in separators where s.contains(sep) {
            var parts = s.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard parts.count > 1 else { continue }
            // Адрес почты и счётчики внутри части («Inbox (12) - me@gmail.com - Gmail»)
            parts = parts.filter { !$0.contains("@") }
                .map { $0.replacingOccurrences(of: #"\s*\(\d+\+?\)"#, with: "", options: .regularExpression) }
            guard !parts.isEmpty else { continue }
            // Название сайта — с краю; нестрогое совпадение (по словам) только там, иначе режет суть
            let kept = parts.enumerated().filter { i, p in
                !matchesSite(p, site, edge: i == 0 || i == parts.count - 1) && !names.contains(p.lowercased())
            }.map(\.element)
            if !kept.isEmpty { parts = kept }
            s = parts.joined(separator: sep)
        }
        return s.isEmpty ? title : s
    }

    /// Название сайта — часть с краю, которая повторяется в названиях разных его страниц
    /// («… — Википедия», «… - YouTube»)
    private static func siteNames(_ host: String?, titles: [String]) -> Set<String> {
        var seen: [String: Set<String>] = [:]
        for t in titles {
            for sep in separators where t.contains(sep) {
                let parts = t.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard parts.count > 1 else { continue }
                for edge in [parts.first!, parts.last!] where edge.count <= 40 { seen[edge, default: []].insert(t) }
            }
        }
        return Set(seen.filter { $0.value.count >= 3 }.keys)
    }

    private static func siteWords(_ host: String?) -> Set<String> {
        guard let h = host?.lowercased() else { return [] }
        let skip: Set<String> = ["www", "m", "com", "org", "net", "ru", "io", "co", "app", "ai", "dev", "uk", "de"]
        return Set(h.split(separator: ".").map(String.init).filter { !skip.contains($0) && $0.count > 1 })
    }

    private static func matchesSite(_ part: String, _ site: Set<String>, edge: Bool) -> Bool {
        let p = part.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !p.isEmpty else { return true }
        if site.contains(where: { $0.filter { $0.isLetter || $0.isNumber } == p || (p.count >= 4 && $0.contains(p))
                                  || ($0.count >= 4 && p.count <= $0.count + 2 && p.contains($0)) }) { return true }     // «Gmail» у mail.google.com
        // Короткая крайняя часть со словом сайта: «Поиск в Google», «YouTube Music»
        guard edge else { return false }
        let words = part.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.count <= 4 && words.contains { site.contains($0) }
    }

    // MARK: Gemini

    private static func ask(_ title: String, host: String?, session: URLSession, _ done: @escaping (String?) -> Void) {
        guard let key = Summarizer.key,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Summarizer.model):generateContent") else { done(nil); return }
        let system = """
        You rename browser tabs. Given a page title and its website, answer with a short, clear tab name: \
        1 to 4 words, in the language of the title. Drop the website name, counters and filler unless they are the point. \
        Answer with the name only — no quotes, no punctuation at the end.
        """
        // Без «размышлений» — быстрее; выключать их умеют только модели 2.5 Flash (у других запрос с этим отвергается)
        var gen: [String: Any] = ["temperature": 0.2, "maxOutputTokens": 40]
        if Summarizer.model.contains("2.5-flash") { gen["thinkingConfig"] = ["thinkingBudget": 0] }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": "Title: \(title)\nWebsite: \(host ?? "")"]]]],
            "generationConfig": gen,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { done(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = data
        req.timeoutInterval = 20
        session.dataTask(with: req) { d, resp, _ in
            var name: String?
            if (resp as? HTTPURLResponse)?.statusCode == 200, let d,
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let c = (o["candidates"] as? [[String: Any]])?.first,
               let parts = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"«»“”.")))
                if !text.isEmpty, text.count <= 60, !text.contains("\n") { name = text }
            }
            DispatchQueue.main.async { done(name) }
        }.resume()
    }
}
