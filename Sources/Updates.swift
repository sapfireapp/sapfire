import AppKit

/// Проверка новой версии: раз в сутки (первая — через 10 минут после запуска) — последний выпуск на GitHub.
/// Новее установленной — уведомление «Sapfire X is available» с кнопкой Download (страница выпуска).
/// Ничего не скачивает и не ставит само; выключается в Settings → General → Updates.
enum Updates {
    static let repo = "sapfireapp/sapfire"                         // github.com/<repo>/releases
    private static let lastKey = "updates.lastCheck", skipKey = "updates.skip"
    private static var timer: Timer?

    static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.checkUpdates) as? Bool ?? true }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Первая проверка — через 10 минут после запуска, не сразу: при старте Sapfire молчит в сети
    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { check() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in check() }
    }

    /// manual — из меню: без суточной паузы и с ответом «у вас последняя»
    static func check(manual: Bool = false) {
        guard manual || enabled else { return }
        let d = UserDefaults.standard
        if !manual, Date().timeIntervalSince1970 - d.double(forKey: lastKey) < 86400 { return }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String else {
                if manual { DispatchQueue.main.async { BrowserModel.current.showToast("Couldn’t check for updates") } }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (j["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repo)/releases/latest")!
            DispatchQueue.main.async {
                d.set(Date().timeIntervalSince1970, forKey: lastKey)
                if newer(latest, than: current), manual || d.string(forKey: skipKey) != latest {
                    BrowserModel.current.notify("Sapfire \(latest) is available", icon: "arrow.down.circle", action: "Download") {
                        d.set(latest, forKey: skipKey)          // один раз на версию: нажал — больше не напоминаем
                        NSWorkspace.shared.open(page)
                    }
                } else if manual {
                    BrowserModel.current.showToast("Sapfire \(current) is the latest version")
                }
            }
        }.resume()
    }

    /// Сравнение версий по числам: 0.10 > 0.9
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
