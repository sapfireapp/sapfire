import AppKit
import SwiftUI

// MARK: - История посещений (⌘Y и подсказки в командной строке)

/// Посещённые страницы: адрес, заголовок, когда была последний раз и сколько раз.
/// Хранится в ~/Library/Application Support/Sapfire/history.json. Инкогнито не записывается.
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    struct Entry: Codable, Identifiable, Hashable {
        var url: URL
        var title: String
        var lastVisit: Date
        var visits: Int
        var id: String { url.absoluteString }
    }

    /// Свежие сверху
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    private static let limit = 20000

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.file),
           let e = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = e
            reindex()
        }
        prune()
    }

    /// Старше, чем велит настройка «Remove history items», — забыть
    func prune() {
        let keep = WebEngine.historyKeep
        guard keep > 0 else { return }
        let cut = Date().addingTimeInterval(-keep)
        let before = entries.count
        entries.removeAll { $0.lastVisit < cut }
        if entries.count != before { reindex(); saveSoon() }
    }

    /// Названия страниц сайта из истории (свежие, до 200) — по ним узнаётся название сайта в заголовках
    func titles(host: String?) -> [String] {
        guard let host else { return [] }
        var out: [String] = []
        for e in entries where e.url.host == host && !e.title.isEmpty {
            out.append(e.title)
            if out.count >= 200 { break }
        }
        return out
    }

    /// Название страницы из истории (если её посещали)
    func title(for url: URL) -> String? {
        if let t = index[url.absoluteString].map({ entries[$0].title }), !t.isEmpty { return t }
        // Тот же адрес другой записью (http/https, «www.», «/» в конце, #якорь)
        let n = Tab.norm(url)
        return entries.first { !$0.title.isEmpty && Tab.norm($0.url) == n }?.title
    }

    private func reindex() {
        index = [:]
        for (i, e) in entries.enumerated() { index[e.id] = i }
    }

    /// Страница догрузилась
    func visit(_ url: URL?, title: String) {
        guard let url, let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        var e = Entry(url: url, title: title, lastVisit: Date(), visits: 1)
        if let i = index[key] {
            e.visits = entries[i].visits + 1
            if title.isEmpty { e.title = entries[i].title }
            entries.remove(at: i)
        }
        entries.insert(e, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        reindex()
        saveSoon()
    }

    /// Заголовок пришёл позже загрузки
    func retitle(_ url: URL?, _ title: String) {
        guard let url, !title.isEmpty, let i = index[url.absoluteString], entries[i].title != title else { return }
        entries[i].title = title
        saveSoon()
    }

    /// Импорт (из другого браузера): добавить, чего нет; сколько добавлено
    func importEntries(_ list: [(URL, String, Date, Int)]) -> Int {
        var added = 0
        for (u, title, date, visits) in list {
            let key = u.absoluteString
            if let i = index[key] {
                if entries[i].lastVisit < date { entries[i].lastVisit = date }
                entries[i].visits = max(entries[i].visits, visits)
            } else {
                entries.append(Entry(url: u, title: title, lastVisit: date, visits: max(1, visits)))
                index[key] = entries.count - 1
                added += 1
            }
        }
        entries.sort { $0.lastVisit > $1.lastVisit }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        reindex()
        saveSoon()
        return added
    }

    func remove(_ e: Entry) {
        guard let i = index[e.id] else { return }
        entries.remove(at: i)
        reindex()
        saveSoon()
    }

    func clear() {
        entries = []
        index = [:]
        saveSoon()
    }

    /// Поиск по заголовку и адресу: сначала совпадения в начале слова, потом частые и свежие
    func search(_ text: String, limit: Int) -> [Entry] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(entries.prefix(limit)) }
        var hits: [(Entry, Int)] = []
        for e in entries {
            let t = e.title.lowercased(), u = e.url.absoluteString.lowercased()
            let host = e.url.host?.lowercased() ?? ""
            var score = 0
            if host.hasPrefix(q) || host.hasPrefix("www." + q) { score = 3 }
            else if t.hasPrefix(q) || t.contains(" " + q) { score = 2 }
            else if t.contains(q) || u.contains(q) { score = 1 }
            if score > 0 { hits.append((e, score * 1000 + min(e.visits, 999))) }
            if hits.count > 400 { break }
        }
        return hits.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private func saveSoon() {
        saveWork?.cancel()
        let snapshot = entries
        let w = DispatchWorkItem {
            DispatchQueue.global(qos: .utility).async {
                if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: Self.file, options: .atomic) }
            }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
}

// MARK: - Загрузки (⌘⇧J)

@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    struct Item: Identifiable, Codable {
        var id = UUID()
        var file: URL
        var done = false
        var failed = false
        var started = Date()
        var isPrivate: Bool? = nil     // из инкогнито — не сохраняется, стирается при закрытии
        var cancelled: Bool? = nil     // остановлена пользователем
        var status: String { cancelled == true ? "Cancelled" : failed ? "Failed" : done ? "Done" : "Downloading…" }
    }

    private(set) var items: [Item] = []
    /// Ход идущих загрузок: 0…1, -1 — размер неизвестен
    private(set) var progress: [UUID: Double] = [:]
    /// Когда закончилась последняя загрузка (кружок загрузок ещё немного виден)
    private(set) var lastFinished: Date?
    @ObservationIgnored private var watches: [UUID: NSKeyValueObservation] = [:]
    /// Как остановить идущую загрузку (ставит Web.swift при начале)
    @ObservationIgnored var cancellers: [UUID: () -> Void] = [:]

    /// Остановить загрузку (недокачанный файл движок убирает сам). Строка закрывается сразу,
    /// не дожидаясь ответа движка: если загрузка уже умерла молча, ответа не будет
    func cancel(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].done, !items[i].failed else { return }
        items[i].cancelled = true
        cancellers.removeValue(forKey: id)?()
        finished(id, failed: true)
    }

    /// Идущие сейчас
    var active: [Item] { items.filter { !$0.done && !$0.failed } }

    /// Следить за ходом загрузки
    func track(_ id: UUID, _ p: Progress) {
        progress[id] = p.totalUnitCount > 0 ? p.fractionCompleted : -1
        watches[id] = p.observe(\.fractionCompleted) { [weak self] p, _ in
            let v = p.totalUnitCount > 0 ? p.fractionCompleted : -1
            DispatchQueue.main.async { self?.progress[id] = v }
        }
    }

    /// Список хранится между запусками, только если его чистят через день или вручную (Settings → General)
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }
    private static var kept: Bool { ["day", "manual"].contains(WebEngine.downloadListRemoval) }

    init() {
        if Self.kept, let d = try? Data(contentsOf: Self.file), let list = try? JSONDecoder().decode([Item].self, from: d) {
            items = list.filter { $0.done || $0.failed }
        }
        prune()
    }

    func started(_ file: URL, private priv: Bool = false) -> UUID {
        let it = Item(file: file, isPrivate: priv ? true : nil)
        items.insert(it, at: 0)
        return it.id
    }

    func finished(_ id: UUID, failed: Bool = false) {
        cancellers[id] = nil
        watches[id] = nil
        progress[id] = nil
        lastFinished = Date()
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done = !failed
        items[i].failed = failed
        // Скачали картинку — подсказать Capture Image (полный размер)
        if !failed, items[i].isPrivate != true, ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic"].contains(items[i].file.pathExtension.lowercased()) {
            Tips.show(.capture)
        }
        // «Убирать из списка после успешной загрузки»
        if !failed, WebEngine.downloadListRemoval == "success" { items.remove(at: i) }
        save()
    }

    /// Убрать то, чему пора уйти (настройка поменялась или прошёл день)
    func prune() {
        let before = items.count
        defer { if items.count != before { save() } }
        if WebEngine.downloadListRemoval == "day" {
            items.removeAll { ($0.done || $0.failed) && Date().timeIntervalSince($0.started) > 86400 }
        } else if WebEngine.downloadListRemoval == "success" {
            items.removeAll(where: \.done)
        }
    }

    /// Настройку поменяли — список начать или перестать хранить
    func removalChanged() { prune(); save() }

    func clear() {
        items.removeAll { $0.done || $0.failed }
        save()
    }

    /// Убрать из списка (идущие не трогаем — они ещё качаются)
    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) && ($0.done || $0.failed) }
        save()
    }

    /// Закрыли инкогнито — его загрузки из списка убираем (сами файлы остаются там, куда сохранены)
    func forgetPrivate() { items.removeAll { $0.isPrivate == true } }

    private func save() {
        guard Self.kept else { try? FileManager.default.removeItem(at: Self.file); return }
        if let d = try? JSONEncoder().encode(items.filter { ($0.done || $0.failed) && $0.isPrivate != true }) { try? d.write(to: Self.file, options: .atomic) }
    }
}

// MARK: - Подсказки поисковика в командной строке

/// Как в Arc: пока набираешь, поисковик подсказывает продолжения запроса.
/// Запрос уходит только для обычного текста (не для адресов и !-команд) и не из инкогнито.
@Observable
final class SearchSuggest {
    static let shared = SearchSuggest()

    /// Подсказки для текста `query`
    private(set) var query = ""
    private(set) var items: [String] = []
    @ObservationIgnored private var task: URLSessionDataTask?
    @ObservationIgnored private var work: DispatchWorkItem?

    static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.searchSuggestions) as? Bool ?? true }

    func update(_ raw: String, incognito: Bool) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        work?.cancel(); task?.cancel()
        guard Self.enabled, !incognito, !text.isEmpty, !text.hasPrefix("!"),
              Omnibox.parseBang(text) == nil, Omnibox.directURL(text) == nil else {
            if !items.isEmpty { items = [] }
            query = text
            return
        }
        let w = DispatchWorkItem { [weak self] in self?.fetch(text) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    private func fetch(_ text: String) {
        // Подсказки — от того поисковика, что выбран (у некоторых их нет)
        guard let tpl = SearchEngine.main.suggest else { return }
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        guard let url = Omnibox.fill(tpl.replacingOccurrences(of: "%l", with: lang), text) else { return }
        // Пространство с туннелем — и подсказки через него
        guard let session = Tunnel.currentSession else { return }
        let t = session.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  arr.count > 1, let list = arr[1] as? [String] else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.query = text
                self.items = list.filter { $0.lowercased() != text.lowercased() }
            }
        }
        task = t
        t.resume()
    }

    func reset() {
        work?.cancel(); task?.cancel()
        items = []; query = ""
    }
}

// MARK: - Архив закрытых вкладок (⇧⌘A)

/// Закрытые вкладки — вручную (⌘W, ⌘⇧K) и авто-архивом. Можно найти и открыть снова.
/// Хранится в ~/Library/Application Support/Sapfire/archive.json. Инкогнито не попадает.
@Observable
final class ArchiveStore {
    static let shared = ArchiveStore()

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var url: URL
        var title: String
        var closed: Date
        var space: String
        var auto: Bool          // закрыта авто-архивом
        var folder: String? = nil   // была во временной папке — возвращается папкой целиком
        var group: UUID? = nil
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    private static let limit = 1000

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("archive.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.file), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    func add(url: URL?, title: String, space: String, auto: Bool, folder: String? = nil, group: UUID? = nil) {
        guard let url, let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        entries.removeAll { $0.url == url }
        entries.insert(Entry(url: url, title: title, closed: Date(), space: space, auto: auto, folder: folder, group: group), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        saveSoon()
    }

    func remove(_ e: Entry) {
        entries.removeAll { $0.id == e.id }
        saveSoon()
    }

    func search(_ text: String, limit: Int) -> [Entry] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        let all = q.isEmpty ? entries : entries.filter {
            $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q) || $0.space.lowercased().contains(q)
                || ($0.folder?.lowercased().contains(q) ?? false)
        }
        return Array(all.prefix(limit))
    }

    private func saveSoon() {
        saveWork?.cancel()
        let snapshot = entries
        let w = DispatchWorkItem {
            DispatchQueue.global(qos: .utility).async {
                if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: Self.file, options: .atomic) }
            }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
}

// MARK: - Часы присутствия

/// Считает только время, когда ты за Mac: он не спит, экран не заблокирован и за последние 5 минут
/// были мышь или клавиатура. По этим часам — авто-архив и красные точки (Settings → Tabs → Archive → Count time).
final class ActiveClock {
    static let shared = ActiveClock()
    static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.archiveClock) as? Bool ?? true }

    private static let key = "activeClock"
    private static let away: Double = 5 * 60
    /// Секунды присутствия с первого запуска
    private(set) var now: Double
    private var lastTick = Date()
    private var locked = false
    private var timer: Timer?

    private init() {
        now = UserDefaults.standard.double(forKey: Self.key)
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.tick(); self?.locked = true }
        dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.lastTick = Date() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastTick = Date()     // сон не считается
        }
    }

    private func tick() {
        let d = Date()
        // Промежуток — не больше минуты (таймер мог стоять, пока Mac спал)
        let dt = min(max(d.timeIntervalSince(lastTick), 0), 60)
        lastTick = d
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard !locked, idle < Self.away else { return }
        now += dt
        UserDefaults.standard.set(now, forKey: Self.key)
    }
}
