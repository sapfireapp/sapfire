import AppKit
import SQLite3
import UniformTypeIdentifiers

// MARK: - Импорт из других браузеров

/// Переезд не из Arc: Chromium-семейство (Chrome, Brave, Edge, Vivaldi, Opera, Chromium, Яндекс) — закладки, история, пароли;
/// Firefox — закладки и история (пароли у него под NSS — только через CSV); Safari — из файла «Export Browsing Data»
/// (свои файлы Safari закрыты системой, полный доступ к диску не просим); закладки из HTML-файла (любой браузер).
/// Закладки — сохранённой папкой «<Браузер> Bookmarks» в текущем пространстве, история — в общую, пароли — в свои.
enum BrowserImport {
    enum Kind {
        case chromium(userData: URL, safeStorage: String?)
        case firefox(profiles: URL)
        case safari
        case html
    }
    struct Source {
        let name: String
        let kind: Kind
        var bookmarks: Bool { true }
        var history: Bool { if case .html = kind { false } else { true } }
        var passwords: Bool {
            switch kind {
            case .chromium(_, let s): s != nil
            case .safari: true
            default: false
            }
        }
    }

    private static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support") }

    /// Chromium-браузеры: папка данных и запись в Связке ключей, которой зашифрованы пароли
    /// (у Яндекса пароли шифруются по-своему — только закладки и история)
    private static let chromiumList: [(String, String, String?)] = [
        ("Chrome", "Google/Chrome", "Chrome Safe Storage"),
        ("Dia", "Dia/User Data", "Dia Safe Storage"),          // Dia (The Browser Company): обычный профиль Chromium, закладок у него нет — история и пароли
        ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage"),
        ("Microsoft Edge", "Microsoft Edge", "Microsoft Edge Safe Storage"),
        ("Vivaldi", "Vivaldi", "Vivaldi Safe Storage"),
        ("Opera", "com.operasoftware.Opera", "Opera Safe Storage"),
        ("Chromium", "Chromium", "Chromium Safe Storage"),
        ("Yandex Browser", "Yandex/YandexBrowser", nil),
    ]

    /// Что есть на этом Mac (Safari и HTML-файл — всегда)
    static var sources: [Source] {
        var out: [Source] = []
        for (name, dir, key) in chromiumList {
            let u = support.appendingPathComponent(dir)
            if !chromiumProfiles(u).isEmpty { out.append(Source(name: name, kind: .chromium(userData: u, safeStorage: key))) }
        }
        let ff = support.appendingPathComponent("Firefox/Profiles")
        if !firefoxProfiles(ff).isEmpty { out.append(Source(name: "Firefox", kind: .firefox(profiles: ff))) }
        out.append(Source(name: "Safari", kind: .safari))
        out.append(Source(name: "Bookmarks File (HTML)", kind: .html))
        return out
    }

    // MARK: Окно выбора

    static func run(preferring name: String? = nil) {
        let list = sources
        let a = NSAlert()
        a.messageText = "Import from Another Browser"
        a.informativeText = "Bookmarks become a folder in the current space, history joins Sapfire’s history, passwords go to Sapfire Passwords. For Arc — File → Import from Arc."
        let panel = ImportPanel(list)
        if let name, let i = list.firstIndex(where: { $0.name == name }) { panel.popup.selectItem(at: i); panel.changed() }
        a.accessoryView = panel.view
        a.addButton(withTitle: "Import")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let src = list[panel.popup.indexOfSelectedItem]
        let want = (bookmarks: panel.bookmarks.state == .on, history: panel.history.state == .on && src.history,
                    passwords: panel.passwords.state == .on && src.passwords)
        guard want.bookmarks || want.history || want.passwords else { return }
        switch src.kind {
        case .chromium(let dir, let key): importChromium(src.name, dir, key, want)
        case .firefox(let dir): importFirefox(dir, want)
        case .safari: importSafari(want)
        case .html: importHTMLFile()
        }
    }

    /// Флажки «что переносить» меняются от выбранного браузера
    private final class ImportPanel: NSObject {
        let list: [Source]
        let view = NSStackView()
        let popup = NSPopUpButton()
        let bookmarks = NSButton(checkboxWithTitle: "Bookmarks", target: nil, action: nil)
        let history = NSButton(checkboxWithTitle: "History", target: nil, action: nil)
        let passwords = NSButton(checkboxWithTitle: "Passwords", target: nil, action: nil)
        let hint = NSTextField(wrappingLabelWithString: "")

        init(_ list: [Source]) {
            self.list = list
            super.init()
            popup.addItems(withTitles: list.map(\.name))
            popup.target = self
            popup.action = #selector(changed)
            [bookmarks, history, passwords].forEach { $0.state = .on }
            hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            hint.textColor = .secondaryLabelColor
            hint.preferredMaxLayoutWidth = 360
            view.orientation = .vertical
            view.alignment = .leading
            view.spacing = 6
            [popup, bookmarks, history, passwords, hint].forEach(view.addArrangedSubview)
            view.setCustomSpacing(10, after: popup)
            changed()
            view.frame = NSRect(x: 0, y: 0, width: 370, height: view.fittingSize.height + 30)
        }

        @objc func changed() {
            let s = list[max(0, popup.indexOfSelectedItem)]
            history.isEnabled = s.history
            passwords.isEnabled = s.passwords
            hint.stringValue = switch s.kind {
            case .chromium(_, let key):
                key == nil ? "\(s.name) encrypts passwords its own way — export them there as a CSV file and use File → Import Passwords from CSV."
                           : "macOS will ask to allow access to “\(key!)” for passwords."
            case .firefox: "Firefox passwords: in Firefox open Passwords → ⋯ → Export Passwords, then File → Import Passwords from CSV."
            case .safari: "Safari keeps its data private. In Safari choose File → Export Browsing Data to File…, then pick that file here."
            case .html: "A bookmarks file exported from any browser."
            }
        }
    }

    /// Только пароли (Settings → Passwords → Import)
    static func importPasswords(_ s: Source) {
        guard case .chromium(let dir, let key?) = s.kind else { return }
        let a = NSAlert()
        if let list = ChromiumPasswords.read(profiles: chromiumProfiles(dir), service: key) {
            let r = PasswordStore.shared.importLogins(list)
            a.messageText = "Imported \(r.added) passwords from \(s.name)" + (r.updated > 0 ? ", updated \(r.updated)" : "")
        } else {
            a.messageText = "Couldn’t read \(s.name) passwords"
            a.informativeText = "Allow Sapfire to use “\(key)” when macOS asks. Or export passwords from \(s.name) as a CSV file and import that."
        }
        a.runModal()
    }

    // MARK: Chromium

    /// Профили: Default, Profile N; у Opera данные прямо в папке браузера
    static func chromiumProfiles(_ userData: URL) -> [URL] {
        let fm = FileManager.default
        var dirs = ArcImport.profileDirs(userData)
        if fm.fileExists(atPath: userData.appendingPathComponent("Bookmarks").path) || fm.fileExists(atPath: userData.appendingPathComponent("History").path) {
            dirs.append(userData)
        }
        return dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("Bookmarks").path) || fm.fileExists(atPath: $0.appendingPathComponent("History").path) }
    }

    /// Имена профилей из Local State («Person 1», «Work»)
    private static func chromiumProfileNames(_ userData: URL) -> [String: String] {
        guard let d = try? Data(contentsOf: userData.appendingPathComponent("Local State")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cache = (j["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }

    private static func importChromium(_ name: String, _ dir: URL, _ key: String?, _ want: (bookmarks: Bool, history: Bool, passwords: Bool)) {
        let profiles = chromiumProfiles(dir)
        let names = chromiumProfileNames(dir)
        let m = BrowserModel.current
        var report: [String] = []
        if want.bookmarks {
            var n = 0
            for p in profiles {
                let roots = chromiumBookmarks(p.appendingPathComponent("Bookmarks"))
                guard !roots.isEmpty else { continue }
                // Несколько профилей с закладками — у каждого своя папка
                let label = profiles.count > 1 ? "\(name) · \(names[p.lastPathComponent] ?? p.lastPathComponent)" : name
                n += addBookmarks(roots, title: "\(label) Bookmarks", into: m)
            }
            report.append("\(n) bookmarks")
        }
        if want.history { report.append("\(HistoryStore.shared.importEntries(chromiumHistory(profiles))) history items") }
        if want.passwords, let key {
            if let list = ChromiumPasswords.read(profiles: profiles, service: key) {
                let r = PasswordStore.shared.importLogins(list)
                report.append("\(r.added) passwords" + (r.updated > 0 ? " (\(r.updated) updated)" : ""))
            } else {
                report.append("passwords not imported (access to “\(key)” wasn’t allowed)")
            }
        }
        finish(name, report, m)
    }

    /// Закладки профиля: панель закладок — сразу в папку, «Другие» и «Мобильные» — вложенными папками
    static func chromiumBookmarks(_ file: URL) -> [ArcImport.Node] {
        guard let d = try? Data(contentsOf: file),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let roots = j["roots"] as? [String: Any] else { return [] }
        func nodes(_ list: Any?) -> [ArcImport.Node] {
            ((list as? [[String: Any]]) ?? []).compactMap { n in
                if n["type"] as? String == "folder" {
                    let kids = nodes(n["children"])
                    let name = (n["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                    return kids.isEmpty ? nil : .folder(name.isEmpty ? "Folder" : name, kids)
                }
                return link(n["url"] as? String, n["name"] as? String)
            }
        }
        var out = nodes((roots["bookmark_bar"] as? [String: Any])?["children"])
        for (k, fallback) in [("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
            guard let r = roots[k] as? [String: Any] else { continue }
            let kids = nodes(r["children"])
            if !kids.isEmpty { out.append(.folder((r["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback, kids)) }
        }
        return out
    }

    /// История профилей Chromium (последние 10 000 на профиль)
    static func chromiumHistory(_ profiles: [URL]) -> [(URL, String, Date, Int)] {
        var list: [(URL, String, Date, Int)] = []
        for dir in profiles {
            withCopy(of: dir.appendingPathComponent("History")) { db in
                SQLite.rows(db, "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 10000") { st in
                    guard let u = URL(string: SQLite.text(st, 0)), u.scheme?.hasPrefix("http") == true else { return }
                    // Время Chromium — микросекунды с 1601 года
                    let t = Date(timeIntervalSince1970: Double(SQLite.int(st, 3)) / 1_000_000 - 11_644_473_600)
                    list.append((u, SQLite.text(st, 1), t, Int(SQLite.int(st, 2))))
                }
            }
        }
        return list
    }

    // MARK: Firefox

    static func firefoxProfiles(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("places.sqlite").path) }
    }

    private static func importFirefox(_ dir: URL, _ want: (bookmarks: Bool, history: Bool, passwords: Bool)) {
        let profiles = firefoxProfiles(dir)
        let m = BrowserModel.current
        var report: [String] = []
        if want.bookmarks {
            var n = 0
            for p in profiles {
                let roots = firefoxBookmarks(p)
                guard !roots.isEmpty else { continue }
                // «xxxx.default-release» → «default-release»
                let pname = p.lastPathComponent.split(separator: ".", maxSplits: 1).last.map(String.init) ?? p.lastPathComponent
                n += addBookmarks(roots, title: profiles.count > 1 ? "Firefox · \(pname) Bookmarks" : "Firefox Bookmarks", into: m)
            }
            report.append("\(n) bookmarks")
        }
        if want.history {
            var list: [(URL, String, Date, Int)] = []
            for p in profiles {
                withCopy(of: p.appendingPathComponent("places.sqlite")) { db in
                    SQLite.rows(db, "SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE hidden = 0 AND last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT 10000", writable: true) { st in
                        guard let u = URL(string: SQLite.text(st, 0)), u.scheme?.hasPrefix("http") == true else { return }
                        list.append((u, SQLite.text(st, 1), Date(timeIntervalSince1970: Double(SQLite.int(st, 3)) / 1_000_000), Int(SQLite.int(st, 2))))
                    }
                }
            }
            report.append("\(HistoryStore.shared.importEntries(list)) history items")
        }
        finish("Firefox", report, m)
    }

    /// Дерево закладок Firefox: панель — сразу в папку, меню, «Другие» и «Мобильные» — вложенными
    static func firefoxBookmarks(_ profile: URL) -> [ArcImport.Node] {
        struct Row { let id: Int64; let parent: Int64; let type: Int64; let title: String; let url: String; let guid: String }
        var rows: [Row] = []
        withCopy(of: profile.appendingPathComponent("places.sqlite")) { db in
            SQLite.rows(db, "SELECT b.id, b.parent, b.type, IFNULL(b.title, ''), IFNULL(p.url, ''), b.guid FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position", writable: true) { st in
                rows.append(Row(id: SQLite.int(st, 0), parent: SQLite.int(st, 1), type: SQLite.int(st, 2),
                                title: SQLite.text(st, 3), url: SQLite.text(st, 4), guid: SQLite.text(st, 5)))
            }
        }
        let kids = Dictionary(grouping: rows, by: \.parent)
        func nodes(_ id: Int64) -> [ArcImport.Node] {
            (kids[id] ?? []).compactMap { r in
                switch r.type {
                case 1: return link(r.url, r.title)
                case 2:
                    let k = nodes(r.id)
                    return k.isEmpty ? nil : .folder(r.title.isEmpty ? "Folder" : r.title, k)
                default: return nil          // разделители
                }
            }
        }
        func root(_ guid: String) -> Row? { rows.first { $0.guid == guid } }
        var out = root("toolbar_____").map { nodes($0.id) } ?? []
        for (guid, name) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")] {
            if let r = root(guid) { let k = nodes(r.id); if !k.isEmpty { out.append(.folder(name, k)) } }
        }
        return out
    }

    // MARK: Safari (из файла экспорта)

    /// Safari 18+: File → Export Browsing Data to File… — zip (или распакованная папка) с Bookmarks.html, History.json, Passwords.csv
    private static func importSafari(_ want: (bookmarks: Bool, history: Bool, passwords: Bool)) {
        let p = NSOpenPanel()
        p.message = "Choose the file exported from Safari (File → Export Browsing Data to File…)"
        p.prompt = "Import"
        p.canChooseDirectories = true
        p.allowedContentTypes = [.zip, .folder, .html, .json, .commaSeparatedText]
        guard p.runModal() == .OK, let picked = p.url else { return }
        let fm = FileManager.default
        var root = picked
        var tmp: URL?
        if picked.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            pr.arguments = ["-x", "-k", picked.path, t.path]
            try? pr.run(); pr.waitUntilExit()
            root = t; tmp = t
        }
        defer { if let tmp { try? fm.removeItem(at: tmp) } }
        // Все файлы экспорта (у каждого профиля Safari — свои)
        var files: [URL] = []
        if (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let e = fm.enumerator(at: root, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL { files.append(u) }
        } else { files = [root] }
        func named(_ ext: String, _ word: String) -> [URL] {
            files.filter { $0.pathExtension.lowercased() == ext && $0.lastPathComponent.lowercased().contains(word) }
        }
        let m = BrowserModel.current
        var report: [String] = []
        if want.bookmarks {
            var n = 0
            for f in named("html", "bookmark") {
                let roots = htmlBookmarks(f)
                if !roots.isEmpty { n += addBookmarks(roots, title: "Safari Bookmarks", into: m) }
            }
            report.append("\(n) bookmarks")
        }
        if want.history {
            var list: [(URL, String, Date, Int)] = []
            for f in named("json", "history") { list += exportedHistory(f) }
            report.append("\(HistoryStore.shared.importEntries(list)) history items")
        }
        var hadPasswords = false
        if want.passwords {
            var r = (added: 0, updated: 0)
            for f in named("csv", "password") {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                hadPasswords = true
                let x = PasswordStore.shared.importLogins(PasswordStore.parseCSV(text))
                r.added += x.added; r.updated += x.updated
            }
            report.append(hadPasswords ? "\(r.added) passwords" + (r.updated > 0 ? " (\(r.updated) updated)" : "")
                                       : "no passwords in this export (tick Passwords when exporting from Safari)")
        }
        if report.allSatisfy({ $0.hasPrefix("0 ") || $0.hasPrefix("no ") }) {
            let a = NSAlert()
            a.messageText = "Nothing to import in this file"
            a.informativeText = "Pick the zip file Safari made with File → Export Browsing Data to File…"
            a.runModal()
            return
        }
        finish("Safari", report, m, trash: hadPasswords ? picked : nil)
    }

    /// History.json формата переноса данных (Safari, Chrome): каждая запись — посещение; время — микросекунды с 1970
    static func exportedHistory(_ file: URL) -> [(URL, String, Date, Int)] {
        guard let d = try? Data(contentsOf: file),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let items = j["history"] as? [[String: Any]] else { return [] }
        var by: [String: (URL, String, Date, Int)] = [:]
        for i in items {
            guard let s = i["url"] as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { continue }
            let usec = (i["time_usec"] as? NSNumber)?.doubleValue ?? 0
            let t = Date(timeIntervalSince1970: usec / 1_000_000)
            let visits = (i["visit_count"] as? Int) ?? 1
            if let old = by[s] {
                by[s] = (u, old.1.isEmpty ? (i["title"] as? String ?? "") : old.1, max(old.2, t), old.3 + visits)
            } else {
                by[s] = (u, i["title"] as? String ?? "", t, visits)
            }
        }
        return Array(by.values)
    }

    // MARK: Закладки из HTML (формат Netscape — экспорт любого браузера)

    static func importHTMLFile() {
        let p = NSOpenPanel()
        p.message = "Choose a bookmarks file exported from a browser"
        p.prompt = "Import"
        p.allowedContentTypes = [.html]
        guard p.runModal() == .OK, let u = p.url else { return }
        let roots = htmlBookmarks(u)
        let m = BrowserModel.current
        guard !roots.isEmpty else {
            let a = NSAlert(); a.messageText = "No bookmarks found in this file"; a.runModal(); return
        }
        let n = addBookmarks(roots, title: "Imported Bookmarks", into: m)
        finish("the file", ["\(n) bookmarks"], m)
    }

    static func htmlBookmarks(_ file: URL) -> [ArcImport.Node] {
        guard let html = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) else { return [] }
        let re = try! NSRegularExpression(pattern: #"<H3[^>]*>(.*?)</H3>|<A\s[^>]*?HREF="([^"]*)"[^>]*>(.*?)</A>|<DL>|</DL>"#,
                                          options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        // Стек папок: имя ждёт своего <DL>
        var stack: [(name: String?, items: [ArcImport.Node])] = []
        var pending: String?
        var top: [ArcImport.Node] = []
        for match in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range).uppercased()
            func group(_ i: Int) -> String? { match.range(at: i).location == NSNotFound ? nil : unescape(ns.substring(with: match.range(at: i))) }
            if token.hasPrefix("<H3") {
                pending = group(1) ?? "Folder"
            } else if token.hasPrefix("<A") {
                if let n = link(group(2), group(3)) {
                    if stack.isEmpty { top.append(n) } else { stack[stack.count - 1].items.append(n) }
                }
            } else if token == "<DL>" {
                stack.append((pending, []))
                pending = nil
            } else if let done = stack.popLast() {
                // Папка без закладок пропадает; корневой список без заголовка — содержимым наверх
                let add: [ArcImport.Node] = done.name.map { done.items.isEmpty ? [] : [.folder($0, done.items)] } ?? done.items
                if stack.isEmpty { top += add } else { stack[stack.count - 1].items += add }
            }
        }
        while let rest = stack.popLast() { top += rest.items }
        // Одна обёртка на всё («Bookmarks», «Favorites») — раскрываем её
        if top.count == 1, case .folder(_, let kids) = top[0] { return kids }
        return top
    }

    private static func unescape(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Общее

    /// Закладка — только обычные адреса (без javascript:, place: и т. п.)
    private static func link(_ url: String?, _ title: String?) -> ArcImport.Node? {
        guard let s = url, let u = URL(string: s), let sc = u.scheme?.lowercased(), sc == "http" || sc == "https" else { return nil }
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        return .tab(ArcImport.ArcTab(url: u, title: t.isEmpty ? (u.host ?? s) : t))
    }

    /// Закладки — свёрнутой сохранённой папкой в текущем пространстве (в инкогнито — в первое обычное);
    /// папка с тем же именем уже есть — дополняем, повторы адресов в пространстве пропускаем
    @discardableResult
    static func addBookmarks(_ roots: [ArcImport.Node], title: String, into m: BrowserModel) -> Int {
        guard let sp = m.currentSpace.isIncognito ? m.spaces.first(where: { !$0.isIncognito }) : m.currentSpace else { return 0 }
        m.checkpoint("Import Bookmarks")
        sp.normalize()
        var have = Set(sp.tabs.compactMap { $0.url.map(ArcImport.norm) })
        let n = ArcImport.add([.folder(title, roots)], to: sp, in: m, parent: nil, depth: 0, saved: true, have: &have)
        sp.normalize()
        return n
    }

    /// Базу открытого браузера читаем из копии (вместе с журналом WAL — иначе нет последних записей)
    private static func withCopy(of db: URL, _ body: (URL) -> Void) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: db.path) else { return }
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return }
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(db.lastPathComponent)
        guard (try? fm.copyItem(at: db, to: copy)) != nil else { return }
        for ext in ["-wal", "-journal"] {
            let side = URL(fileURLWithPath: db.path + ext)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + ext)) }
        }
        body(copy)
    }

    private static func finish(_ from: String, _ report: [String], _ m: BrowserModel, trash: URL? = nil) {
        m.save()
        let a = NSAlert()
        a.messageText = "Imported from \(from)"
        var info = report.joined(separator: "\n")
        if report.contains(where: { $0.hasSuffix("bookmarks") && !$0.hasPrefix("0 ") }) { info += "\n\nBookmarks are in a folder in the sidebar of the current space." }
        info += "\n\nSign-ins (cookies) don’t move between browsers — sign in to websites once in Sapfire; saved passwords will fill in."
        if trash != nil { info += "\n\nThe exported file has your passwords unencrypted — better delete it now." }
        a.informativeText = info
        if let trash {
            a.addButton(withTitle: "Move Export to Trash")
            a.addButton(withTitle: "Keep")
            if a.runModal() == .alertFirstButtonReturn { try? FileManager.default.trashItem(at: trash, resultingItemURL: nil) }
        } else {
            a.runModal()
        }
    }
}
