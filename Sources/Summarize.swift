import AppKit
import Security
import SwiftUI
import WebKit

// MARK: - Пересказ страницы (модуль Summarize, Gemini)

/// Пересказ страницы и вопросы по ней — Gemini (Google), бесплатный ключ из Google AI Studio.
/// Ключ — в Связке ключей. Запрос может идти через туннель VPN (из некоторых стран Gemini напрямую недоступен).
/// В инкогнито выключено: текст страницы ушёл бы в Google.
@Observable
final class Summarizer {
    static let shared = Summarizer()

    enum Style: String { case summary, points }
    struct Message: Identifiable { let id = UUID(); let user: Bool; var text: String }

    var visible = false
    var tabID: UUID?
    var title = ""
    var style: Style = .summary
    /// Разговор: первое — пересказ, дальше — вопросы и ответы
    var messages: [Message] = []
    var busy = false
    var error: String?
    var question = ""
    @ObservationIgnored private var page = ""          // текст страницы (для вопросов вдогонку)
    @ObservationIgnored private var pageURL = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    // MARK: Настройки

    static var key: String? { Keychain.get("Gemini API key") }
    /// Ключ сохранён (проверка без чтения — Связка не спрашивает пароль)
    static var hasKey: Bool { Keychain.has("Gemini API key") }
    static func setKey(_ k: String?) { Keychain.set("Gemini API key", k?.trimmingCharacters(in: .whitespacesAndNewlines)) }
    static var model: String {
        let m = UserDefaults.standard.string(forKey: Prefs.summaryModel) ?? ""
        return m.isEmpty ? "gemini-2.5-flash" : m
    }
    /// Язык пересказа: код языка или «page» — как у страницы
    static var language: String { UserDefaults.standard.string(forKey: Prefs.summaryLanguage) ?? "ru" }
    static var viaProxy: Bool { UserDefaults.standard.object(forKey: Prefs.summaryViaProxy) as? Bool ?? true }

    static let languages: [(code: String, name: String)] = [
        ("page", "Same as the page"), ("ru", "Русский"), ("en", "English"), ("uk", "Українська"), ("be", "Беларуская"),
        ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
    ]

    // MARK: Открыть / закрыть

    func toggle(_ m: BrowserModel) {
        if visible, tabID == m.activeTab?.id { close() } else { start(m) }
    }

    func close() {
        task?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { visible = false }
    }

    func start(_ m: BrowserModel, style: Style? = nil) {
        guard let t = m.activeTab, let wv = t.webView else { return }
        task?.cancel()
        if let style { self.style = style }
        tabID = t.id
        title = t.title.isEmpty ? t.displayTitle : t.title     // название страницы, не своё
        messages = []
        error = nil
        question = ""
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { visible = true }
        if m.currentSpace.isIncognito {
            error = "Summaries are off in incognito: the page would be sent to Google."
            return
        }
        guard Self.hasKey else { return }        // карточка покажет, как получить ключ
        busy = true
        wv.evaluateJavaScript(Self.extractJS) { [weak self] r, _ in
            guard let self else { return }
            let d = r as? [String: Any] ?? [:]
            self.page = (d["text"] as? String) ?? ""
            self.pageURL = t.url?.absoluteString ?? ""
            let selected = (d["selected"] as? Bool) ?? false
            guard self.page.count > 80 else {
                self.busy = false
                self.error = "There’s almost no text on this page to summarize."
                return
            }
            self.run(first: selected ? "the selected text" : "this page")
        }
    }

    /// Другой вид пересказа (абзац / пункты)
    func restyle(_ s: Style, _ m: BrowserModel) {
        guard s != style else { return }
        style = s
        if !page.isEmpty, messages.count <= 1 { messages = []; error = nil; run(first: "this page") } else { start(m) }
    }

    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy, !page.isEmpty else { return }
        question = ""
        messages.append(Message(user: true, text: q))
        send()
    }

    // MARK: Запрос

    private var languageRule: String {
        let code = Self.language
        if code == "page" { return "Answer in the language of the page." }
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        return "Always answer in \(name), even if the page is in another language."
    }

    private func run(first what: String) {
        let how = style == .summary
            ? "Summarize \(what) in one short paragraph of 4–6 sentences: what it is about and the main takeaway."
            : "Summarize \(what) as 5–8 key points, one line each, most important first. Use \"- \" bullets."
        messages = [Message(user: true, text: how)]
        send()
    }

    private func send() {
        guard let key = Self.key else { return }
        busy = true
        error = nil
        let system = "You summarize web pages for a browser user. Use only the page content; don't invent facts. Be concise. Markdown is fine (bold, bullets). \(languageRule)"
        // Страница не может «закрыть» свой блок и дописать инструкции от нашего имени
        let safePage = page.replacingOccurrences(of: "</page>", with: "", options: .caseInsensitive)
        let pageBlock = "Title: \(title)\nURL: \(pageURL)\n\n<page>\n\(safePage)\n</page>"
        // Страница — в первом сообщении, дальше — разговор
        var contents: [[String: Any]] = []
        for (i, msg) in messages.enumerated() {
            let text = i == 0 ? msg.text + "\n\n" + pageBlock : msg.text
            contents.append(["role": msg.user ? "user" : "model", "parts": [["text": text]]])
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": ["temperature": 0.3],
        ]
        let model = Self.model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = data
        req.timeoutInterval = 90
        let session = Self.session
        messages.append(Message(user: false, text: ""))
        let idx = messages.count - 1
        task = Task { @MainActor [weak self] in
            do {
                let (bytes, resp) = try await session.bytes(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 {
                    var raw = ""
                    for try await line in bytes.lines { raw += line }
                    self?.fail(Self.explain(status, raw))
                    return
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:") else { continue }
                    let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let cands = o["candidates"] as? [[String: Any]], let c = cands.first,
                          let content = c["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { continue }
                    let chunk = parts.compactMap { $0["text"] as? String }.joined()
                    if let self, idx < self.messages.count { self.messages[idx].text += chunk }
                }
                self?.busy = false
                if let self, idx < self.messages.count, self.messages[idx].text.isEmpty { self.fail("Gemini sent an empty answer. Try again.") }
            } catch {
                if Task.isCancelled { return }
                self?.fail(Self.viaProxy && Incognito.endpoint != nil
                           ? "Couldn’t reach Gemini through the VPN proxy — is Happ running? (\(error.localizedDescription))"
                           : "Couldn’t reach Gemini: \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ message: String) {
        busy = false
        if let last = messages.last, !last.user, last.text.isEmpty { messages.removeLast() }
        error = message
    }

    /// Сеть: через туннель VPN (по настройке) или напрямую
    /// Одна сессия на настройку: URLSession без invalidate живёт до конца программы — новая на каждый запрос текла бы
    private static var cached: (key: String, session: URLSession)?
    static var session: URLSession {
        let key = "\(viaProxy) \(Incognito.host):\(Incognito.port) \(Incognito.http)"
        if let c = cached, c.key == key { return c.session }
        cached?.session.finishTasksAndInvalidate()
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        if viaProxy, let p = Incognito.endpoint { c.proxyConfigurations = [p] }
        let s = URLSession(configuration: c)
        cached = (key, s)
        return s
    }

    /// Понятная причина ошибки
    static func explain(_ status: Int, _ raw: String) -> String {
        let msg = ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }?["message"] as? String ?? raw
        if msg.localizedCaseInsensitiveContains("location is not supported") {
            return "Gemini isn’t available in your region. Turn on “Through the VPN proxy” in Settings → Advanced → Summarize and start Happ."
        }
        if status == 400 && msg.localizedCaseInsensitiveContains("api key") || status == 403 {
            return "The Gemini key doesn’t work. Check it in Settings → Advanced → Summarize."
        }
        if status == 429 { return "The free limit is used up for now. Try again in a minute (or later today)." }
        if status == 404 { return "Model “\(model)” isn’t available. Pick another one in Settings → Advanced → Summarize." }
        return "Gemini: \(msg.isEmpty ? "error \(status)" : msg)"
    }

    /// Модели, которые умеют отвечать (для выбора в настройках)
    static func fetchModels(_ done: @escaping ([String]) -> Void) {
        guard let key, let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100") else { done([]); return }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        session.dataTask(with: req) { d, _, _ in
            let list = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["models"] as? [[String: Any]] ?? [])
                .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
                .filter { $0.hasPrefix("gemini") && !$0.contains("tts") && !$0.contains("image") && !$0.contains("embedding") }
            DispatchQueue.main.async { done(list.sorted()) }
        }.resume()
    }

    /// Текст статьи (или выделенного): основной блок страницы без меню, подвалов и рекламы; до ~120 тыс. знаков
    static let extractJS = """
    (function(){
      var sel = String(window.getSelection ? window.getSelection() : '').trim();
      if (sel.length > 200) return {text: sel.slice(0, 120000), selected: true};
      function score(el){
        var ps = el.querySelectorAll('p, li'), n = 0, t = 0;
        for (var i = 0; i < ps.length && i < 3000; i++) { var l = (ps[i].innerText || '').trim().length; if (l > 60) { n++; t += l; } }
        var bad = /comment|footer|sidebar|nav|menu|related|share|promo|ad-|advert/i.test((el.className || '') + ' ' + (el.id || ''));
        return (t + n * 60) * (bad ? 0.2 : 1);
      }
      var c = document.querySelectorAll('article, main, [role=main], .post, .article, .entry-content, .content, #content');
      var best = null, bs = 0;
      for (var i = 0; i < c.length && i < 400; i++) { var s = score(c[i]); if (s > bs) { bs = s; best = c[i]; } }
      var text = ((bs > 800 && best) ? best : document.body).innerText || '';
      text = text.replace(/\\n{3,}/g, '\\n\\n');
      return {text: text.slice(0, 120000), selected: false};
    })()
    """
}

// MARK: - Карточка пересказа

struct SummaryCard: View {
    @Environment(BrowserModel.self) private var model
    @State private var s = Summarizer.shared
    @State private var keyDraft = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !Summarizer.hasKey && !model.currentSpace.isIncognito {
                            setup
                        } else {
                            ForEach(Array(s.messages.enumerated()), id: \.element.id) { i, m in
                                if i > 0 || !m.user { bubble(m, first: i <= 1) }
                            }
                            if s.busy && (s.messages.last?.text.isEmpty ?? true) {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the page…").foregroundStyle(.secondary) }
                                    .font(.system(size: 12))
                            }
                            if let e = s.error {
                                Text(e).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: s.messages.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            if Summarizer.hasKey && !model.currentSpace.isIncognito {
                Divider()
                HStack(spacing: 8) {
                    TextField("Ask about this page…", text: $s.question)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($askFocused)
                        .onSubmit { s.ask() }
                    Button { s.ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(s.question.isEmpty || s.busy ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                        .disabled(s.question.isEmpty || s.busy)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
            }
        }
        .frame(width: 400)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text(s.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { s.style }, set: { s.restyle($0, model) })) {
                Text("Summary").tag(Summarizer.Style.summary)
                Text("Key points").tag(Summarizer.Style.points)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            Button {
                let text = s.messages.filter { !$0.user }.map(\.text).joined(separator: "\n\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                model.showToast("Summary copied")
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy")
                .disabled(s.messages.allSatisfy(\.user))
            Button { s.close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close — Esc")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func bubble(_ m: Summarizer.Message, first: Bool) -> some View {
        let md = (try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text)
        return Group {
            if m.user {
                Text(m.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .circular))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(md)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // Ссылки из ответа модели (её могла подучить сама страница): только http(s), вкладкой,
                    // и с показом адреса — не в системные программы в обход вопроса
                    .environment(\.openURL, OpenURLAction { url in
                        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
                        model.newTab(url: url)
                        model.showToast("Opened \(url.host ?? url.absoluteString)")
                        return .handled
                    })
            }
        }
    }

    /// Ключа ещё нет — как получить
    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summaries use Gemini by Google. The key is free:")
                .font(.system(size: 13))
            Button("Get a Free Key") {
                if let u = URL(string: "https://aistudio.google.com/apikey") { BrowserModel.current.newTab(url: u) }
            }
            Text("Sign in with a Google account, press “Create API key”, copy it and paste here. The key stays in your Keychain.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("With a free key Google may use the pages you summarize to train its models. A key from a billed project keeps them private.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("Paste the key", text: $keyDraft).textFieldStyle(.roundedBorder)
                Button("Save") {
                    Summarizer.setKey(keyDraft); keyDraft = ""
                    s.start(model)
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).count < 20)
            }
            if Incognito.endpoint != nil {
                Text("Gemini isn’t available directly in some countries — requests go through your VPN proxy (Happ).")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Связка ключей

enum Keychain {
    private static let service = "Sapfire"

    /// Прочитанное за этот запуск: каждое чтение данных из Связки — вопрос пароля, если подпись программы сменилась
    /// (после пересборки), поэтому читаем один раз
    private static var cache: [String: String?] = [:]

    /// Есть ли запись — без чтения самих данных (так Связка пароль не спрашивает)
    static func has(_ account: String) -> Bool {
        if let c = cache[account] { return c != nil }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        if let c = cache[account] { return c }
        let v = read(account)
        cache[account] = .some(v)
        return v
    }

    private static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(data: d, encoding: .utf8)
        return s?.isEmpty == false ? s : nil
    }

    static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        cache[account] = .some(value?.isEmpty == false ? value : nil)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
