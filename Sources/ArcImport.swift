import AppKit
import SwiftUI
import WebKit

// MARK: - Импорт из Arc

/// Переезд из Arc: пространства (значок, профиль), «Избранное» профиля → закреплённые его пространств,
/// закреплённое пространства (папки любой вложенности, сплиты) → сохранённое над чертой, «Сегодня» → временные,
/// профили Arc → профили Sapfire, история, пароли. Всё добавляется к тому, что уже есть.
enum ArcImport {
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc") }
    static var available: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("StorableSidebar.json").path) }

    // MARK: Что есть в Arc

    struct ArcTab { let url: URL; let title: String }
    indirect enum Node {
        case tab(ArcTab)
        case folder(String, [Node])
        case split([ArcTab])
    }
    struct ArcSpace {
        let title: String
        let icon: String?
        let profileKey: String          // "default" или папка профиля («Profile 1»)
        let pinned: [Node]
        let today: [Node]
    }
    struct Plan {
        var spaces: [ArcSpace] = []
        var favorites: [String: [ArcTab]] = [:]        // профиль → «Избранное»
        var profileNames: [String: String] = [:]      // папка профиля → имя
        var tabCount: Int {
            func n(_ l: [Node]) -> Int { l.reduce(0) { r, x in switch x { case .tab: r + 1; case .folder(_, let k): r + n(k); case .split(let t): r + t.count } } }
            return spaces.reduce(0) { $0 + n($1.pinned) + n($1.today) } + favorites.values.reduce(0) { $0 + $1.count }
        }
    }

    static func read() -> Plan? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("StorableSidebar.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = j["sidebar"] as? [String: Any], let containers = sidebar["containers"] as? [Any] else { return nil }
        // Основной контейнер — тот, где пространства и больше всего элементов
        let main = containers.compactMap { $0 as? [String: Any] }.filter { $0["spaces"] != nil }
            .max { (($0["items"] as? [Any])?.count ?? 0) < (($1["items"] as? [Any])?.count ?? 0) }
        guard let main else { return nil }
        var items: [String: [String: Any]] = [:]
        for case let i as [String: Any] in (main["items"] as? [Any] ?? []) { if let id = i["id"] as? String { items[id] = i } }

        func tab(_ i: [String: Any]) -> ArcTab? {
            guard let d = i["data"] as? [String: Any], let t = d["tab"] as? [String: Any],
                  let s = t["savedURL"] as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { return nil }
            let title = (i["title"] as? String) ?? (t["savedTitle"] as? String) ?? ""
            return ArcTab(url: u, title: title)
        }
        func nodes(_ ids: [String]) -> [Node] {
            ids.compactMap { id -> Node? in
                guard let i = items[id], let d = i["data"] as? [String: Any] else { return nil }
                let kids = i["childrenIds"] as? [String] ?? []
                if d["tab"] != nil { return tab(i).map { .tab($0) } }
                if d["list"] != nil { return .folder((i["title"] as? String) ?? "Folder", nodes(kids)) }
                if d["splitView"] != nil {
                    let t = kids.compactMap { items[$0].flatMap(tab) }
                    return t.count > 1 ? .split(t) : t.first.map { .tab($0) }
                }
                return nil
            }
        }
        func key(_ profile: Any?) -> String {
            if let p = profile as? [String: Any], let c = p["custom"] as? [String: Any], let z = c["_0"] as? [String: Any],
               let dir = z["directoryBasename"] as? String { return dir }
            return "default"
        }

        var plan = Plan()
        for case let s as [String: Any] in (main["spaces"] as? [Any] ?? []) {
            let cids = s["containerIDs"] as? [Any] ?? []
            func container(_ name: String) -> String? {
                guard let i = cids.firstIndex(where: { ($0 as? String) == name }), i + 1 < cids.count else { return nil }
                return cids[i + 1] as? String
            }
            let pinned = container("pinned").flatMap { items[$0]?["childrenIds"] as? [String] } ?? []
            let today = container("unpinned").flatMap { items[$0]?["childrenIds"] as? [String] } ?? []
            let info = s["customInfo"] as? [String: Any]
            let iconType = info?["iconType"] as? [String: Any]
            let icon = (iconType?["icon"] as? String) ?? (iconType?["emoji_v2"] as? String) ?? (iconType?["emoji"] as? String)
            plan.spaces.append(ArcSpace(title: (s["title"] as? String) ?? "Space", icon: icon, profileKey: key(s["profile"]),
                                        pinned: nodes(pinned), today: nodes(today)))
        }
        // «Избранное»: [профиль, контейнер, профиль, контейнер…]
        let top = main["topAppsContainerIDs"] as? [Any] ?? []
        var i = 0
        while i + 1 < top.count {
            if let cid = top[i + 1] as? String, let kids = items[cid]?["childrenIds"] as? [String] {
                plan.favorites[key(top[i]), default: []] += kids.compactMap { items[$0].flatMap(tab) }
            }
            i += 2
        }
        // Имена профилей
        if let d = try? Data(contentsOf: root.appendingPathComponent("User Data/Local State")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let cache = (j["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, v) in cache { plan.profileNames[dir] = (v as? [String: Any])?["name"] as? String ?? dir }
        }
        return plan
    }

    // MARK: Импорт

    static func run() {
        guard let plan = read(), !plan.spaces.isEmpty else {
            let a = NSAlert(); a.messageText = "Arc data not found"; a.informativeText = "Sapfire looks in ~/Library/Application Support/Arc."; a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = "Import from Arc"
        a.informativeText = "Found \(plan.spaces.count) spaces and \(plan.tabCount) tabs. They’re added next to what you already have."
        let what = NSStackView()
        what.orientation = .vertical
        what.alignment = .leading
        let cSpaces = NSButton(checkboxWithTitle: "Spaces, pinned tabs, folders and favorites", target: nil, action: nil); cSpaces.state = .on
        let cToday = NSButton(checkboxWithTitle: "Open tabs (Today)", target: nil, action: nil); cToday.state = .on
        let cHistory = NSButton(checkboxWithTitle: "History", target: nil, action: nil); cHistory.state = .on
        let cPasswords = NSButton(checkboxWithTitle: "Passwords (macOS will ask to allow access to “Arc Safe Storage”)", target: nil, action: nil); cPasswords.state = .on
        [cSpaces, cToday, cHistory, cPasswords].forEach(what.addArrangedSubview)
        what.frame = NSRect(x: 0, y: 0, width: 380, height: 96)
        a.accessoryView = what
        a.addButton(withTitle: "Import")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let m = BrowserModel.current
        var report: [String] = []
        if cSpaces.state == .on || cToday.state == .on {
            let n = importSidebar(plan, into: m, pinned: cSpaces.state == .on, today: cToday.state == .on)
            report.append("\(n.tabs) tabs" + (n.spaces > 0 ? ", \(n.spaces) new spaces" : "") + " (spaces with the same name were filled in)")
        }
        if cHistory.state == .on {
            let n = importHistory()
            report.append("\(n) history items")
        }
        if cPasswords.state == .on {
            if let r = importPasswordsQuiet() { report.append("\(r.added) passwords" + (r.updated > 0 ? " (\(r.updated) updated)" : "")) }
            else { report.append("passwords not imported (access to “Arc Safe Storage” wasn’t allowed)") }
        }
        m.save()
        let done = NSAlert()
        done.messageText = "Imported from Arc"
        done.informativeText = report.joined(separator: "\n") + "\n\nSign-ins (cookies) don’t move between browsers — sign in to websites once in Sapfire; saved passwords will fill in."
        done.runModal()
    }

    /// Пространства и вкладки
    @discardableResult
    static func importSidebar(_ plan: Plan, into m: BrowserModel, pinned: Bool, today: Bool) -> (spaces: Int, tabs: Int) {
        m.checkpoint("Import from Arc")
        var tabs = 0
        // Профили: основной Arc → основной Sapfire; остальные — с тем же именем (есть — берём его)
        var profileFor: [String: Profile] = [:]
        func profile(_ key: String) -> Profile {
            if key == "default" { return m.primaryProfile }
            if let p = profileFor[key] { return p }
            let name = plan.profileNames[key] ?? key
            let p = m.profiles.first { $0.name == name } ?? {
                let p = Profile(name: name, hue: Profile.hues[(m.profiles.count - 1 + Profile.hues.count) % Profile.hues.count])
                m.profiles.append(p)
                return p
            }()
            profileFor[key] = p
            return p
        }
        var firstOfProfile: [String: Space] = [:]
        var created = 0
        for (n, a) in plan.spaces.enumerated() {
            // Пространство с таким же названием уже есть — дополняем его, а не заводим второе
            let existing = m.spaces.first { !$0.isIncognito && $0.name.lowercased() == a.title.lowercased() }
            let sp = existing ?? Space(name: a.title, icon: symbol(a.icon, n), hue: (0.58 + Double(m.spaces.count) * 0.17).truncatingRemainder(dividingBy: 1))
            if existing == nil {
                sp.profileID = profile(a.profileKey).id
                m.spaces.append(sp)
                created += 1
            }
            sp.normalize()
            // Уже открытое в пространстве не дублируем
            var have = Set(sp.tabs.compactMap { $0.url.map(Self.norm) })
            if pinned {
                // «Избранное» профиля — закреплённые первого его пространства, остальные берут их оттуда
                if let owner = firstOfProfile[a.profileKey], existing == nil, sp.pinned.isEmpty {
                    sp.pinnedFrom = owner.id
                } else {
                    if firstOfProfile[a.profileKey] == nil { firstOfProfile[a.profileKey] = sp.pinOwner }
                    let pinnedHave = Set(sp.pinned.compactMap { ($0.pinnedURL ?? $0.url).map(Self.norm) })
                    for f in plan.favorites[a.profileKey] ?? [] where !pinnedHave.contains(Self.norm(f.url)) {
                        let t = Tab(url: f.url, title: f.title, isPinned: true)
                        t.pinnedURL = f.url
                        t.browser = m
                        sp.pinOwner.tabs.append(t); tabs += 1
                    }
                }
                tabs += add(a.pinned, to: sp, in: m, parent: nil, depth: 0, saved: true, have: &have)
            }
            if today { tabs += add(a.today, to: sp, in: m, parent: nil, depth: 0, saved: false, have: &have) }
            sp.normalize()
        }
        return (created, tabs)
    }

    /// Узлы Arc → вкладки, папки (до 3 уровней, глубже — внутрь последней), сплиты
    /// Адрес для сравнения «уже есть»: без www, без / в конце, без #
    static func norm(_ u: URL) -> String {
        var s = (u.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "") + u.path
        while s.hasSuffix("/") { s.removeLast() }
        return s + (u.query.map { "?" + $0 } ?? "")
    }

    static func add(_ nodes: [Node], to sp: Space, in m: BrowserModel, parent: Folder?, depth: Int, saved: Bool, have: inout Set<String>) -> Int {
        var count = 0
        for node in nodes {
            switch node {
            case .tab(let a):
                guard have.insert(norm(a.url)).inserted else { continue }
                let t = Tab(url: a.url, title: a.title)
                t.browser = m
                t.folderID = parent?.id
                t.isSaved = saved && parent == nil
                sp.tabs.append(t)
                if parent == nil { sp.layout.append(t.id) }
                count += 1
            case .folder(let name, let kids):
                if !saved {
                    count += add(kids, to: sp, in: m, parent: nil, depth: depth, saved: false, have: &have)      // во временных папок нет
                    continue
                }
                if depth >= Space.maxFolderDepth + 1, let parent {
                    count += add(kids, to: sp, in: m, parent: parent, depth: depth, saved: saved, have: &have)
                    continue
                }
                // Папка с таким именем на том же месте уже есть — складываем в неё
                let f = sp.folders.first { $0.name == name && $0.parentID == parent?.id } ?? {
                    let f = Folder(name: name, hue: sp.colorless ? -1 : sp.hue)
                    f.parentID = parent?.id
                    f.expanded = false
                    sp.folders.append(f)
                    if parent == nil { sp.layout.append(f.id) }
                    return f
                }()
                count += add(kids, to: sp, in: m, parent: f, depth: depth + 1, saved: saved, have: &have)
            case .split(let list):
                var ids: [UUID] = []
                for a in list.prefix(Space.maxPanes) {
                    guard have.insert(norm(a.url)).inserted else { continue }
                    let t = Tab(url: a.url, title: a.title)
                    t.browser = m
                    t.folderID = parent?.id
                    t.isSaved = saved && parent == nil
                    sp.tabs.append(t)
                    if parent == nil { sp.layout.append(t.id) }
                    ids.append(t.id)
                    count += 1
                }
                if ids.count > 1 { sp.splitGroups.append(ids) }
            }
        }
        return count
    }

    /// Значок Arc → SF Symbol (есть такой — он; эмодзи и неизвестные — из обычного набора)
    private static func symbol(_ arc: String?, _ n: Int) -> String {
        if let a = arc, NSImage(systemSymbolName: a, accessibilityDescription: nil) != nil { return a }
        let map = ["egg": "oval.portrait", "skull": "theatermasks", "house": "house", "briefcase": "briefcase", "star": "star"]
        if let a = arc, let s = map[a], NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil { return s }
        return BrowserModel.spaceIcons[n % BrowserModel.spaceIcons.count]
    }

    /// Профили Chromium в папке браузера
    static func profileDirs(_ userData: URL) -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: userData, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
    }

    /// История всех профилей Arc (последние 10 000)
    static func importHistory() -> Int {
        HistoryStore.shared.importEntries(BrowserImport.chromiumHistory(profileDirs(root.appendingPathComponent("User Data"))))
    }

    // MARK: Пароли

    static func importPasswordsQuiet() -> (added: Int, updated: Int)? {
        guard let list = ChromiumPasswords.read(profiles: profileDirs(root.appendingPathComponent("User Data")), service: "Arc Safe Storage") else { return nil }
        return PasswordStore.shared.importLogins(list)
    }

    static func importPasswords() { report(importPasswordsQuiet(), from: "Arc") }

    private static func report(_ r: (added: Int, updated: Int)?, from: String) {
        let a = NSAlert()
        if let r {
            a.messageText = "Imported \(r.added) passwords from \(from)" + (r.updated > 0 ? ", updated \(r.updated)" : "")
        } else {
            a.messageText = "Couldn’t read \(from) passwords"
            a.informativeText = "Allow Sapfire to use “\(from) Safe Storage” when macOS asks. Or export passwords from \(from) as a CSV file and import that."
        }
        a.runModal()
    }
}
