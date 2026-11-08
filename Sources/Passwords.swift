import AppKit
import CommonCrypto
import CryptoKit
import LocalAuthentication
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Пароли

/// Пароли Sapfire: хранятся зашифрованными (AES-GCM) в ~/Library/Application Support/Sapfire/passwords.sealed,
/// ключ — в Связке ключей. На страницах: подсказка входа у поля (клик — заполнить, по Touch ID),
/// «Сохранить пароль?» после входа, надёжный пароль при регистрации. Импорт — из Arc/Chrome, CSV (приложение
/// «Пароли», Chrome, Arc), просмотр и правка — Settings → Passwords.
@Observable
final class PasswordStore {
    static let shared = PasswordStore()

    struct Login: Codable, Identifiable, Hashable {
        var id = UUID()
        var site: String            // хост без www (для поиска и группировки)
        var url: String             // откуда (для открытия)
        var username: String
        var password: String
        var created = Date()
        var used: Date?
        var insecure: Bool? = nil   // сохранён на http-странице: только туда и подставлять
    }
    private struct Vault: Codable {
        var logins: [Login] = []
        var never: [String] = []    // «никогда не предлагать для этого сайта»
    }

    private(set) var logins: [Login] = []
    @ObservationIgnored private var never: [String] = []
    @ObservationIgnored private var key: SymmetricKey?
    private(set) var loaded = false

    private static var file: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sapfire", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("passwords.sealed")
    }
    private static let keyName = "Sapfire passwords key"

    /// Открыть хранилище (ключ из Связки ключей; первый раз — создать)
    @discardableResult
    func load() -> Bool {
        if loaded { return true }
        if let b64 = Keychain.get(Self.keyName), let d = Data(base64Encoded: b64) {
            key = SymmetricKey(data: d)
        } else if !FileManager.default.fileExists(atPath: Self.file.path) {
            let k = SymmetricKey(size: .bits256)
            Keychain.set(Self.keyName, k.withUnsafeBytes { Data($0) }.base64EncodedString())
            key = k
        } else {
            return false                      // файл есть, а ключа нет — открыть нельзя
        }
        guard let key else { return false }
        if let sealed = try? Data(contentsOf: Self.file) {
            guard let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: key),
                  let v = try? JSONDecoder().decode(Vault.self, from: plain) else { return false }
            logins = v.logins
            never = v.never
        }
        loaded = true
        return true
    }

    private func save() {
        guard let key, let data = try? JSONEncoder().encode(Vault(logins: logins, never: never)),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? sealed.write(to: Self.file, options: [.atomic, .completeFileProtection])
    }

    static func site(_ url: URL?) -> String? { SiteSettings.site(url) }

    /// Входы для сайта: тот же сайт или его поддомены / родитель (login.x.com ↔ x.com); на общих хостингах
    /// (user.github.io) — только тот же хост. На http-страницу — только входы, сохранённые на http
    func logins(for url: URL?) -> [Login] {
        guard load(), let host = Self.site(url) else { return [] }
        let base = BrowserModel.baseDomain(host) ?? host
        let http = url?.scheme?.lowercased() == "http"
        return logins.filter { ($0.site == host || (BrowserModel.baseDomain($0.site) ?? $0.site) == base) && (!http || $0.insecure == true) }
            .sorted { ($0.site == host ? 0 : 1, -($0.used ?? $0.created).timeIntervalSince1970) < ($1.site == host ? 0 : 1, -($1.used ?? $1.created).timeIntervalSince1970) }
    }

    func isNever(_ url: URL?) -> Bool { Self.site(url).map { never.contains($0) } ?? false }
    func setNever(_ url: URL?) { guard load(), let s = Self.site(url), !never.contains(s) else { return }; never.append(s); save() }

    /// Сохранить (новый или обновить пароль у того же имени на том же сайте)
    func upsert(url: URL?, username: String, password: String) {
        guard load(), let site = Self.site(url), !password.isEmpty else { return }
        let http = url?.scheme?.lowercased() == "http"
        if let i = logins.firstIndex(where: { $0.site == site && $0.username == username }) {
            logins[i].password = password
            logins[i].used = Date()
            if http { logins[i].insecure = true }
        } else {
            logins.append(Login(site: site, url: url?.absoluteString ?? "https://\(site)", username: username, password: password, insecure: http ? true : nil))
        }
        save()
    }

    func update(_ l: Login) { guard load(), let i = logins.firstIndex(where: { $0.id == l.id }) else { return }; logins[i] = l; save() }
    func delete(_ l: Login) { guard load() else { return }; logins.removeAll { $0.id == l.id }; save() }
    func markUsed(_ id: UUID) { guard let i = logins.firstIndex(where: { $0.id == id }) else { return }; logins[i].used = Date(); save() }

    /// Что сохранено для этого входа (сравнить, нужно ли предлагать сохранение)
    func known(url: URL?, username: String, password: String) -> Bool {
        logins(for: url).contains { $0.username == username && $0.password == password }
    }

    /// Добавить много сразу (импорт): тот же сайт и имя — обновить пароль. Сколько добавлено / обновлено
    func importLogins(_ list: [(url: String, username: String, password: String)]) -> (added: Int, updated: Int) {
        guard load() else { return (0, 0) }
        var added = 0, updated = 0
        for e in list where !e.password.isEmpty {
            guard let u = URL(string: e.url), let site = Self.site(u) else { continue }
            if let i = logins.firstIndex(where: { $0.site == site && $0.username == e.username }) {
                if logins[i].password != e.password { logins[i].password = e.password; updated += 1 }
            } else {
                logins.append(Login(site: site, url: e.url, username: e.username, password: e.password)); added += 1
            }
        }
        save()
        return (added, updated)
    }

    // MARK: Touch ID

    /// Спросить Touch ID (или пароль Mac); без них на Mac — сразу да
    static func authenticate(_ reason: String, _ done: @escaping (Bool) -> Void) {
        // Только что подтверждали — не спрашивать снова (иначе каждая подстановка на той же странице — новый запрос)
        if Date().timeIntervalSince(lastAuth) < authGrace { done(true); return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { done(true); return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { if ok { lastAuth = Date() }; done(ok) }
        }
    }
    private static var lastAuth = Date.distantPast
    private static let authGrace: TimeInterval = 60
    static var requireAuthToFill: Bool { UserDefaults.standard.object(forKey: Prefs.passwordFillAuth) as? Bool ?? true }

    // MARK: Надёжный пароль (как в Safari: abcDef-ghijk3-lmnopq)

    static func strongPassword() -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyz"), digits = Array("23456789")
        func chunk() -> String { String((0..<6).map { _ in letters.randomElement()! }) }
        var parts = [chunk(), chunk(), chunk()]
        // Одна заглавная и одна цифра — в случайных местах
        let p = Int.random(in: 0..<3), q = Int.random(in: 0..<6)
        var c = Array(parts[p]); c[q] = Character(c[q].uppercased()); parts[p] = String(c)
        let r = Int.random(in: 0..<3), t = Int.random(in: 0..<6)
        var d = Array(parts[r]); if r == p && t == q { d[(t + 1) % 6] = digits.randomElement()! } else { d[t] = digits.randomElement()! }; parts[r] = String(d)
        return parts.joined(separator: "-")
    }

    // MARK: CSV (приложение «Пароли», Chrome, Arc, Firefox)

    static func parseCSV(_ text: String) -> [(url: String, username: String, password: String)] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return it.next() }
        while let ch = next() {
            if quoted {
                if ch == "\"" { if let n = next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false } }
                else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r\n" || ch == "\r" { row.append(field); field = ""; if !row.allSatisfy(\.isEmpty) { rows.append(row) }; row = [] }
            else { field.append(ch) }
        }
        row.append(field); if !row.allSatisfy(\.isEmpty) { rows.append(row) }
        guard let head = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return [] }
        func col(_ names: [String]) -> Int? { head.firstIndex { names.contains($0) } }
        guard let cu = col(["url", "website", "login_uri", "origin"]), let cn = col(["username", "login", "login_username", "user name"]),
              let cp = col(["password", "login_password"]) else { return [] }
        return rows.dropFirst().compactMap { r in
            guard r.count > max(cu, cn, cp) else { return nil }
            var u = r[cu].trimmingCharacters(in: .whitespaces)
            if !u.contains("://") { u = "https://" + u }
            return (u, r[cn], r[cp])
        }
    }

    static func importCSV() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText, .plainText]
        p.message = "Choose a CSV with passwords (exported from the Passwords app, Chrome, Arc or Firefox)"
        p.prompt = "Import"
        guard p.runModal() == .OK, let u = p.url, let text = try? String(contentsOf: u, encoding: .utf8) else { return }
        let list = parseCSV(text)
        let r = shared.importLogins(list)
        let a = NSAlert()
        a.messageText = list.isEmpty ? "No passwords found in this file" : "Imported \(r.added) passwords" + (r.updated > 0 ? ", updated \(r.updated)" : "")
        a.informativeText = "Delete the CSV file now — passwords in it are not encrypted."
        a.addButton(withTitle: "Move File to Trash")
        a.addButton(withTitle: "Keep")
        if a.runModal() == .alertFirstButtonReturn { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
    }
}

// MARK: - Пароли Chromium (Arc, Chrome): расшифровка «Login Data»

enum ChromiumPasswords {
    /// Все входы профилей браузера. `service` — запись в Связке ключей («Arc Safe Storage», «Chrome Safe Storage»);
    /// macOS спросит разрешение Sapfire прочитать её
    static func read(profiles: [URL], service: String) -> [(url: String, username: String, password: String)]? {
        guard let pw = keychainPassword(service: service), let key = deriveKey(pw) else { return nil }
        var out: [(String, String, String)] = []
        for dir in profiles {
            let db = dir.appendingPathComponent("Login Data")
            guard FileManager.default.fileExists(atPath: db.path) else { continue }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard (try? FileManager.default.copyItem(at: db, to: tmp)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: tmp) }
            SQLite.rows(tmp, "SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0") { st in
                let url = SQLite.text(st, 0), user = SQLite.text(st, 1)
                guard let blob = SQLite.blob(st, 2), let pass = decrypt(blob, key: key), !pass.isEmpty else { return }
                out.append((url, user, pass))
            }
        }
        return out
    }

    private static func keychainPassword(service: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func deriveKey(_ password: String) -> Data? {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let ok = key.withUnsafeMutableBytes { k in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, k.bindMemory(to: UInt8.self).baseAddress, 16)
        }
        return ok == kCCSuccess ? key : nil
    }

    /// «v10» + AES-128-CBC (IV — 16 пробелов)
    private static func decrypt(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return String(data: blob, encoding: .utf8) }
        let enc = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: enc.count + kCCBlockSizeAES128)
        var n = 0
        let outCount = out.count
        let st = out.withUnsafeMutableBytes { o in enc.withUnsafeBytes { e in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, key.count, v.baseAddress, e.baseAddress, enc.count, o.baseAddress, outCount, &n)
        } } } }
        guard st == kCCSuccess else { return nil }
        return String(data: out.prefix(n), encoding: .utf8)
    }
}

/// Мелкий помощник SQLite (история и пароли Chromium)
enum SQLite {
    /// `writable` — для копии базы в режиме WAL (Firefox): только чтение не может создать её файл -shm
    static func rows(_ file: URL, _ sql: String, writable: Bool = false, _ each: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { each(st) }
    }
    static func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    static func int(_ st: OpaquePointer, _ i: Int32) -> Int64 { sqlite3_column_int64(st, i) }
    static func blob(_ st: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(st, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
    }
}

// MARK: - На страницах: подсказка входа, сохранение, надёжный пароль

/// Скрипт в отдельном «мире» (сайт его не видит и не может им пользоваться): находит поля входа,
/// у поля — просит Sapfire показать подсказку; после входа — предлагает сохранить.
final class PasswordAgent: NSObject, WKScriptMessageHandler {
    static let shared = PasswordAgent()

    func install(in c: WKUserContentController) {
        c.addUserScript(WKUserScript(source: Self.js, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
        c.add(self, contentWorld: .defaultClient, name: "sfPw")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let wv = m.webView, let d = m.body as? [String: Any], let kind = d["kind"] as? String else { return }
        let frame = m.frameInfo
        let o = frame.securityOrigin
        let url = URL(string: "\(o.protocol)://\(o.host)\(o.port > 0 ? ":\(o.port)" : "")")
        switch kind {
        case "focus":
            // Поле входа в фокусе — показать сохранённые входы (и надёжный пароль при регистрации).
            // Чужая рамка (другой сайт внутри страницы) входы страницы не получает
            guard let rect = d["rect"] as? [Double], rect.count == 4, Self.sameSite(frame, in: wv) else { return }
            showMenu(wv, frame: frame, url: url, at: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
                     newPassword: d["new"] as? Bool ?? false, field: d["field"] as? String ?? "user")
        case "submit":
            let user = d["user"] as? String ?? "", pass = d["pass"] as? String ?? ""
            offerSave(wv, url: url, username: user, password: pass)
        default: break
        }
    }

    /// Рамка — сама страница или её же сайт (login.x.com в x.com); остальные рамки — чужие
    private static func sameSite(_ frame: WKFrameInfo, in wv: WKWebView) -> Bool {
        if frame.isMainFrame { return true }
        guard let top = wv.url?.host else { return false }
        return BrowserModel.baseDomain(frame.securityOrigin.host) == BrowserModel.baseDomain(top)
    }

    private var lastMenu = Date.distantPast
    /// Только что подставили пароль: фокус, который при этом получили поля, меню не вызывает
    private var lastFill = Date.distantPast

    private func showMenu(_ wv: WKWebView, frame: WKFrameInfo, url: URL?, at r: CGRect, newPassword: Bool, field: String) {
        let incognito = !wv.configuration.websiteDataStore.isPersistent
        let list = PasswordStore.shared.logins(for: url)
        guard !list.isEmpty || newPassword, Date().timeIntervalSince(lastMenu) > 0.6, Date().timeIntervalSince(lastFill) > 1.5 else { return }
        lastMenu = Date()
        let menu = NSMenu()
        if !list.isEmpty {
            let head = NSMenuItem(title: "Saved passwords", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for l in list.prefix(8) {
                let item = ClosureMenuItem(l.username.isEmpty ? "(no username)" : l.username) { [weak wv] in
                    guard let wv else { return }
                    let fill = { self.fill(wv, frame: frame, url: url, username: l.username, password: l.password); PasswordStore.shared.markUsed(l.id) }
                    if PasswordStore.requireAuthToFill { PasswordStore.authenticate("fill the password for \(l.site)") { if $0 { fill() } } } else { fill() }
                }
                if l.site != PasswordStore.site(url) { item.title += "  — \(l.site)" }
                item.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        if newPassword && !incognito {
            if !list.isEmpty { menu.addItem(.separator()) }
            let strong = PasswordStore.strongPassword()
            let item = ClosureMenuItem("Use Strong Password: \(strong)") { [weak wv] in
                guard let wv else { return }
                self.fill(wv, frame: frame, url: url, username: nil, password: strong, onlyNew: true)
            }
            item.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Passwords…") { SettingsWindow.show(page: .passwords) })
        // Под полем (координаты страницы → вида; с учётом масштаба)
        let k = wv.pageZoom * wv.magnification
        let p = NSPoint(x: r.minX * k, y: wv.isFlipped ? r.maxY * k + 4 : wv.bounds.height - r.maxY * k - 4)
        menu.popUp(positioning: nil, at: p, in: wv)
    }

    /// Подставить. Рамка за время меню или Touch ID могла уйти на другой сайт — скрипт сверяет свой адрес с `o`
    private func fill(_ wv: WKWebView, frame: WKFrameInfo, url: URL?, username: String?, password: String, onlyNew: Bool = false) {
        lastFill = Date()
        let origin = url.map { "\($0.scheme ?? "https")://\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")" } ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: ["u": username as Any, "p": password, "n": onlyNew, "o": origin]),
              let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.__sfPwFill && window.__sfPwFill(\(json))", in: frame, in: .defaultClient) { _ in }
    }

    /// Вопрос «сохранить пароль?» — один за раз; на тот же вход (сайт, имя, пароль) после ответа в этом сеансе не спрашивать.
    /// Страница сообщает о входе несколько раз (отправка формы, щелчок по кнопке, Enter, уход со страницы, рамки)
    private var offerOpen = false
    private var answered = Set<String>()

    private func offerSave(_ wv: WKWebView, url: URL?, username: String, password: String) {
        guard !password.isEmpty, wv.configuration.websiteDataStore.isPersistent,          // в инкогнито не сохраняем
              UserDefaults.standard.object(forKey: Prefs.passwordOffer) as? Bool ?? true else { return }
        let store = PasswordStore.shared
        guard store.load(), !store.isNever(url), !store.known(url: url, username: username, password: password),
              let site = PasswordStore.site(url) else { return }
        let key = site + "\u{1}" + username + "\u{1}" + password
        guard !offerOpen, !answered.contains(key) else { return }
        offerOpen = true
        let update = store.logins(for: url).contains { $0.username == username }
        let a = NSAlert()
        a.messageText = update ? "Update the saved password for \(username.isEmpty ? site : username)?" : "Save the password for \(site)?"
        a.informativeText = username.isEmpty ? "Sapfire will fill it in next time." : "\(username) — Sapfire will fill it in next time."
        a.icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        a.addButton(withTitle: update ? "Update" : "Save")
        a.addButton(withTitle: "Not Now")
        if !update { a.addButton(withTitle: "Never for This Website") }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            self?.offerOpen = false
            self?.answered.insert(key)
            switch r {
            case .alertFirstButtonReturn:
                store.upsert(url: url, username: username, password: password)
                if !update { Tips.show(.passwords, BrowserModel.owner(of: wv)) }
            case .alertThirdButtonReturn: store.setNever(url)
            default: break
            }
        }
        if let w = wv.window {
            guard w.attachedSheet == nil else { offerOpen = false; return }      // уже что-то спрашиваем в этом окне
            a.beginSheetModal(for: w, completionHandler: done)
        } else { done(a.runModal()) }
    }

    /// Поля входа: пароль и имя перед ним. Фокус — просьба показать подсказку; отправка формы
    /// (кнопка, Enter, уход со страницы) — предложить сохранить.
    /// Обработчики кликов, клавиш и ввода ставятся только после первого фокуса в поле входа: на страницах
    /// без входа они срабатывали на каждый клик и клавишу и стоили Speedometer больше 10%
    static let js = """
    (function(){
      if (window.__sfPwOn) return; window.__sfPwOn = true;
      var post = function(m){ try { window.webkit.messageHandlers.sfPw.postMessage(m); } catch(e){} };
      function visible(e){ var r = e.getBoundingClientRect(); if (!(r.width > 0 && r.height > 0)) return false;
        var cs = getComputedStyle(e); if (cs.visibility === 'hidden' || +cs.opacity < 0.1) return false;
        return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth; }
      function passFields(root){ return Array.prototype.filter.call((root || document).querySelectorAll('input[type=password]'), visible); }
      // Дешёвая проверка «на странице вообще есть пароль» — для обработчиков, которые срабатывают на каждый клик и клавишу
      function hasPass(){ return !!document.querySelector('input[type=password]'); }
      function userField(pass){
        var form = pass.form || document;
        var list = Array.prototype.filter.call(form.querySelectorAll('input:not([type=hidden]):not([type=password]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button])'), visible);
        var before = list.filter(function(i){ return i.compareDocumentPosition(pass) & Node.DOCUMENT_POSITION_FOLLOWING; });
        var named = before.filter(function(i){ return /user|login|mail|phone|name|account/i.test((i.name||'') + (i.id||'') + (i.autocomplete||'') + (i.type||'')); });
        return named.pop() || before.pop() || null;
      }
      function isNew(p){ return /new-password/.test(p.autocomplete || '') || /regist|signup|sign-up|create|new/i.test((p.name||'') + (p.id||'') + ((p.form && p.form.action) || '')); }
      function loginFieldFor(el){
        if (el.type === 'password') return {field: 'pass', pass: el};
        var ps = passFields(el.form || document); if (!ps.length) return null;
        if (userField(ps[0]) === el) return {field: 'user', pass: ps[0]};
        return null;
      }
      var filling = false;   // Sapfire сам ставит курсор в поля при подстановке — это не повод снова показывать меню
      var armed = false;     // слушатели отправки формы — поставлены
      document.addEventListener('focusin', function(e){
        if (filling || !document.hasFocus()) return;
        var el = e.target; if (!el || el.tagName !== 'INPUT' || el.type === 'checkbox' || el.type === 'radio') return;
        if (!armed && !hasPass()) return;               // страница без входа: ничего не ищем
        if (!visible(el)) return;
        var info = loginFieldFor(el); if (!info) return;
        arm();
        var r = el.getBoundingClientRect();
        post({kind: 'focus', field: info.field, 'new': isNew(info.pass), rect: [r.left, r.top, r.width, r.height]});
      }, true);
      // Запомнить, что ввели, — отправить при входе
      var last = null;
      function capture(){
        var ps = passFields(); if (!ps.length) return;
        var p = ps[0], u = userField(p);
        if (p.value) last = {user: u ? u.value : '', pass: p.value};
        else if (last && u && u.value) last.user = u.value;     // пароль сайт уже стёр — имя берём свежее
      }
      function send(){ capture(); if (last && last.pass) { post({kind: 'submit', user: last.user, pass: last.pass}); last = null; } }
      function arm(){
        if (armed) return; armed = true;
        document.addEventListener('input', function(e){ if (e.target && e.target.type === 'password') capture(); }, true);
        document.addEventListener('submit', send, true);
        document.addEventListener('click', function(e){
          var b = e.target && e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
          if (b && hasPass()) setTimeout(send, 0);
        }, true);
        document.addEventListener('keydown', function(e){ if (e.key === 'Enter' && e.target && e.target.tagName === 'INPUT' && hasPass()) setTimeout(send, 0); }, true);
        window.addEventListener('pagehide', send);
      }
      // Заполнить (из Sapfire)
      window.__sfPwFill = function(d){
        if (d.o && location.origin !== d.o) return;   // рамка уже на другом сайте — пароль не для него
        filling = true; setTimeout(function(){ filling = false; }, 400);
        function set(el, v){ if (!el) return; el.focus();
          var proto = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
          proto.set.call(el, v);
          el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true})); }
        var ps = passFields(); if (!ps.length) return;
        if (d.n) { ps.forEach(function(p){ if (isNew(p) || ps.length > 1) set(p, d.p); }); if (ps.length === 1) set(ps[0], d.p); return; }
        var p = ps[0]; if (d.u !== null && d.u !== undefined) set(userField(p), d.u); set(p, d.p);
      };
    })();
    """
}

// MARK: - Settings → Passwords

struct PasswordsPage: View {
    @State private var store = PasswordStore.shared
    @State private var unlocked = false
    @State private var query = ""
    @State private var revealed = Set<UUID>()
    @State private var editing: PasswordStore.Login?
    @AppStorage(Prefs.passwordOffer) private var offer = true
    @AppStorage(Prefs.passwordFillAuth) private var fillAuth = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("Offer to save passwords", isOn: $offer)
                Toggle("Touch ID to fill", isOn: $fillAuth)
            }
            .font(.system(size: 12))
            if !unlocked {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Passwords are locked").font(.system(size: 13, weight: .medium))
                    Button("Unlock") { unlock() }.keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                HStack(spacing: 8) {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Spacer()
                    Menu("Import") {
                        Button("From Arc…") { ArcImport.importPasswords() }
                        ForEach(BrowserImport.sources.filter { if case .chromium = $0.kind { $0.passwords } else { false } }, id: \.name) { s in
                            Button("From \(s.name)…") { BrowserImport.importPasswords(s) }
                        }
                        Button("From Safari…") { BrowserImport.run(preferring: "Safari") }
                        Button("From CSV File…") { PasswordStore.importCSV() }
                    }
                    .fixedSize()
                    Button("Add…") { editing = PasswordStore.Login(site: "", url: "https://", username: "", password: "") }
                }
                let q = query.lowercased()
                let list = store.logins.filter { q.isEmpty || $0.site.contains(q) || $0.username.lowercased().contains(q) }
                    .sorted { $0.site < $1.site }
                if list.isEmpty {
                    Text(store.logins.isEmpty ? "No saved passwords yet. They appear when you sign in on websites, or import them." : "Nothing found.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(list) { l in row(l) }
                Text("Passwords are encrypted on this Mac; the key is in your Keychain.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .sheet(item: $editing) { l in PasswordEditor(login: l) { editing = nil } }
    }

    private func row(_ l: PasswordStore.Login) -> some View {
        HStack(spacing: 10) {
            Favicon(url: URL(string: l.url)).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.site).font(.system(size: 13))
                Text(l.username.isEmpty ? "(no username)" : l.username).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(width: 230, alignment: .leading)
            Text(revealed.contains(l.id) ? l.password : String(repeating: "•", count: 10))
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1)
            Spacer(minLength: 8)
            Button { if revealed.contains(l.id) { revealed.remove(l.id) } else { revealed.insert(l.id) } } label: {
                Image(systemName: revealed.contains(l.id) ? "eye.slash" : "eye")
            }.buttonStyle(.plain).help("Show password")
            Menu {
                Button("Copy Username") { copy(l.username) }
                Button("Copy Password") { copy(l.password) }
                Button("Open Website") { if let u = URL(string: l.url) { BrowserModel.current.newTab(url: u) } }
                Divider()
                Button("Edit…") { editing = l }
                Button("Delete") { store.delete(l) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func unlock() {
        PasswordStore.authenticate("show your saved passwords") { ok in
            guard ok else { return }
            if store.load() { unlocked = true }
        }
    }
}

private struct PasswordEditor: View {
    @State var login: PasswordStore.Login
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(login.site.isEmpty ? "New Password" : "Edit Password").font(.headline)
            TextField("Website (https://example.com)", text: $login.url).textFieldStyle(.roundedBorder)
            TextField("Username", text: $login.username).textFieldStyle(.roundedBorder)
            TextField("Password", text: $login.password).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            HStack {
                Button("Generate") { login.password = PasswordStore.strongPassword() }
                Spacer()
                Button("Cancel", action: close)
                Button("Save") {
                    let u = URL(string: login.url.contains("://") ? login.url : "https://" + login.url)
                    if let site = PasswordStore.site(u) {
                        login.site = site
                        if PasswordStore.shared.logins.contains(where: { $0.id == login.id }) { PasswordStore.shared.update(login) }
                        else { PasswordStore.shared.upsert(url: u, username: login.username, password: login.password) }
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(login.password.isEmpty || PasswordStore.site(URL(string: login.url.contains("://") ? login.url : "https://" + login.url)) == nil)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}
