import AppKit
import SwiftUI
import WebKit

// MARK: - SwiftUI-обёртка для WKWebView вкладки

struct WebViewHost: NSViewRepresentable {
    let tab: Tab

    /// Рамка страницы. Страница одна, а рамок при перестройке (сплит 2 → 3 панели) на миг бывает две:
    /// забирает страницу только рамка, которая на экране, — уходящая её больше не перехватит
    final class Container: NSView {
        var tab: Tab?
        private static let all = NSHashTable<Container>.weakObjects()
        override init(frame: NSRect) { super.init(frame: frame); Self.all.add(self) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { take(); return }
            // Ушла с экрана вместе со страницей — её забирает другая рамка этой вкладки, что на экране
            guard let tab, let wv = tab.webView, wv.superview === self || wv.superview == nil else { return }
            for c in Self.all.allObjects where c !== self && c.tab === tab && c.window != nil { c.take(); break }
        }
        /// Вкладке сделали новую страницу (Reopen As, смена профиля или туннеля) — рамки на экране забирают её сразу,
        /// не дожидаясь, пока SwiftUI сам перерисует панель (иначе до перезапуска оставалась пустая рамка)
        static func refresh(_ tab: Tab) {
            for c in all.allObjects where c.tab === tab && c.window != nil { c.take() }
        }
        func take() {
            guard window != nil, let tab else { return }
            let wv = tab.ensureWebView()
            guard wv.superview !== self else { return }
            // Сменилась вкладка: прежняя страница не пропадает сразу, а растворяется поверх новой
            let old = subviews.last { $0 is WKWebView && $0 !== wv }
            subviews.forEach { if $0 !== old { $0.removeFromSuperview() } }
            wv.removeFromSuperview()
            wv.alphaValue = 1
            wv.frame = bounds
            wv.autoresizingMask = [.width, .height]
            if let old {
                addSubview(wv, positioned: .below, relativeTo: old)
                // Новая страница, только что вернувшаяся на экран, рисуется не сразу — растворяем прежнюю,
                // когда новая уже нарисована (иначе прежняя растворялась бы в пустоту)
                var started = false
                let fade = { [weak self, weak old] in
                    guard !started, let self, let old else { return }
                    started = true
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.12
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        old.animator().alphaValue = 0
                    }, completionHandler: {
                        // Страницу могли уже забрать в другую рамку — тогда её не трогаем
                        if old.superview === self { old.removeFromSuperview() }
                        old.alphaValue = 1
                    })
                }
                let cfg = WKSnapshotConfiguration()
                cfg.afterScreenUpdates = true
                cfg.snapshotWidth = 1
                wv.takeSnapshot(with: cfg) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: fade) }
                // Запасной выход: страница с холстом (игра, WebGL) отдаёт снимок долго — прежняя не должна висеть поверх
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: fade)
            } else {
                addSubview(wv)
            }
        }
    }

    func makeNSView(context: Context) -> Container {
        let v = Container()
        // Страница обрезается по своей рамке: при жесте «назад / вперёд» она чуть увеличивается и сдвигается
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        v.tab = tab
        v.take()
        return v
    }

    func updateNSView(_ v: Container, context: Context) {
        v.tab = tab
        v.take()
    }
}

// MARK: - Делегат: новые окна, диалоги, загрузки

final class WebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    /// Окно, в котором сейчас работают (страницы общие; действия — в активном окне)
    var browser: BrowserModel? { BrowserModel.current }
    private var downloadPaths: [ObjectIdentifier: URL] = [:]
    private var downloadIDs: [ObjectIdentifier: UUID] = [:]      // строка в списке загрузок (⌘⇧J)
    /// Идущие загрузки держим сами: иначе при закрытии вкладки движок их отпускает молча — строка «висит» и не отменяется
    private var running: [ObjectIdentifier: WKDownload] = [:]

    // Ссылки target=_blank и window.open → новая вкладка (Cmd+клик — в фоне)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let b = browser else { return nil }
        // Всплывающие окна запрещены для сайта — открываем только по клику на ссылку
        if SiteSettings.shared.prefs(webView.url, incognito: BrowserModel.isIncognito(webView)).popups == "block", navigationAction.navigationType != .linkActivated {
            b.showToast("Pop-up blocked")
            return nil
        }
        let f = navigationAction.modifierFlags
        // ⌥⌘-клик — в маленьком окне
        // (из инкогнито — новой вкладкой инкогнито: маленькое окно живёт в обычном хранилище)
        if f.contains(.command), f.contains(.option), webView.configuration.websiteDataStore.isPersistent {
            LittleWindow.open(navigationAction.request.url)
            return nil
        }
        // ⌘-клик — в фоне (или сразу открыть — в настройках); с ⇧ — наоборот
        let background = f.contains(.command) && !f.contains(.option) && f.contains(.shift) == WebEngine.newTabActive
        let opener = b.tab(for: webView)
        // Из закреплённой вкладки на другой сайт — карточкой Peek
        if !background, let o = opener, let url = navigationAction.request.url, b.shouldPeek(from: o, to: url) {
            return b.openPeek(url, configuration: configuration).webView
        }
        let sp = opener.flatMap { b.space(of: $0) }
        let t = b.newTab(url: navigationAction.request.url, in: sp, select: !background, configuration: configuration, opener: opener)
        if background { b.openedInBackground(t) }
        return t.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let t = browser?.tab(for: webView) { browser?.close(t) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // Профилю включили туннель, а его хранилище уже ходило напрямую — до перезапуска ничего не грузим
        if let id = BrowserModel.profileID(of: webView.configuration.websiteDataStore), Tunnel.needsRestart.contains(id) {
            decisionHandler(.cancel, preferences)
            Tunnel.askRestart(navigationAction.request.url)
            return
        }
        // Ссылка открывает другую программу (zoommtg:, tg:, mailto:, macappstore: …)
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file", "javascript", "sapfire"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            openExternal(url, from: webView)
            return
        }
        // ⌘-клик по обычной ссылке → новая вкладка (в фоне или сразу, как в настройках; с ⇧ — наоборот),
        // ⌥⌘-клик → маленькое окно. Раньше проверки загрузки: ⌥-клик движок считает загрузкой
        // ⌥-клик (без ⌘) — новая вкладка, и сразу на неё. Раньше проверки загрузки: движок считает ⌥-клик загрузкой
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.option), !navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url, let b = browser {
            let opener = b.tab(for: webView)
            b.newTab(url: url, in: opener.flatMap { b.space(of: $0) }, select: true, opener: opener)
            decisionHandler(.cancel, preferences); return
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url, let b = browser {
            let f = navigationAction.modifierFlags
            if f.contains(.option), webView.configuration.websiteDataStore.isPersistent {
                LittleWindow.open(url)
            } else {
                let opener = b.tab(for: webView)
                let sp = opener.flatMap { b.space(of: $0) }
                let fg = f.contains(.shift) != WebEngine.newTabActive
                let t = b.newTab(url: url, in: sp, select: fg, opener: opener)
                if !fg { b.openedInBackground(t) }
            }
            decisionHandler(.cancel, preferences); return
        }
        if navigationAction.shouldPerformDownload {
            if SiteSettings.shared.prefs(webView.url, incognito: BrowserModel.isIncognito(webView)).downloads == "deny" {
                browser?.showToast("Downloads are blocked on this site")
                decisionHandler(.cancel, preferences); return
            }
            decisionHandler(.download, preferences); return
        }
        // Сайт с правилом «всегда открывать как профиль» — открыть нужным профилем
        if navigationAction.targetFrame?.isMainFrame ?? true, [.linkActivated, .other].contains(navigationAction.navigationType),
           (navigationAction.request.httpMethod ?? "GET") == "GET", let b = browser, let t = b.tab(for: webView),
           b.applyRule(navigationAction.request.url, in: t) {
            decisionHandler(.cancel, preferences); return
        }
        // Следящие метки в ссылке (utm_, fbclid, gclid…) — идём по чистой
        if PrivacyGuard.cleanNavigation(navigationAction, in: webView) {
            decisionHandler(.cancel, preferences); return
        }
        // Сайт без защищённого соединения — спросить (Settings → Privacy)
        if navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url, WebEngine.shouldWarn(url) {
            decisionHandler(.cancel, preferences)
            WebEngine.warnHTTP(url, in: webView)
            return
        }
        // Уходим со страницы — запомнить, как она выглядела (для жеста «назад / вперёд»)
        if navigationAction.targetFrame?.isMainFrame ?? true, webView.url != nil, webView.url != navigationAction.request.url {
            PageSwipe.shared.remember(webView)
        }
        // Настройки сайта, куда идём (для основной страницы): JavaScript, как представляться, блокировка
        if navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url {
            let incognito = BrowserModel.isIncognito(webView)
            let p = SiteSettings.shared.prefs(url, incognito: incognito)
            // Правила — по сайту, куда идём (сверяем каждый раз: вкладка после запуска сразу открывается с адресом сайта)
            ContentBlocker.shared.update(webView.configuration.userContentController, for: url, incognito: incognito)
            preferences.allowsContentJavaScript = p.javaScript && WebEngine.javaScript
            // Защита от отпечатка (как в приватных окнах Safari)
            PrivacyGuard.apply(to: preferences, store: webView.configuration.websiteDataStore, fingerprint: p.fingerprint)
            let ua = p.userAgent == "mobile" ? SiteSettings.mobileUA : nil
            if webView.customUserAgent != (ua ?? "") { webView.customUserAgent = ua }
        }
        // Ссылка из закреплённой вкладки на другой сайт → карточка Peek поверх страницы
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true,
           !navigationAction.modifierFlags.contains(.command), !navigationAction.modifierFlags.contains(.shift),
           let url = navigationAction.request.url, let b = browser, let t = b.tab(for: webView), b.shouldPeek(from: t, to: url) {
            b.openPeek(url)
            decisionHandler(.cancel, preferences); return
        }
        if navigationAction.targetFrame?.isMainFrame ?? true { StallWatch.allowed(webView, navigationAction.request) }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Файл, который сервер отдаёт «вложением» (Content-Disposition: attachment — так скачиваются вложения Gmail,
        // Google Drive и т. п.), — скачать, даже если движок умеет его показать (html, txt, картинки, pdf)
        // Не только основная страница: Gmail скачивает вложение через невидимую рамку (iframe)
        if let r = navigationResponse.response as? HTTPURLResponse,
           let cd = r.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           cd.hasPrefix("attachment") {
            if SiteSettings.shared.prefs(webView.url ?? r.url, incognito: BrowserModel.isIncognito(webView)).downloads == "deny" {
                browser?.showToast("Downloads are blocked on this site")
                decisionHandler(.cancel); return
            }
            decisionHandler(.download); return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        closeIfEmpty(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        closeIfEmpty(webView)
    }

    /// Ссылка на файл открылась новой вкладкой (target=_blank, как у Gmail) и стала загрузкой —
    /// пустая вкладка не нужна: закрываем её, загрузка идёт дальше
    private func closeIfEmpty(_ webView: WKWebView) {
        guard webView.backForwardList.currentItem == nil, let b = browser, let t = b.tab(for: webView),
              t.openerID != nil, !t.isPinned, !t.isSaved else { return }      // только свежая вкладка, открытая страницей
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak b, weak t] in
            guard let b, let t, t.webView?.backForwardList.currentItem == nil else { return }
            b.close(t)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: Загрузки

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // «Спрашивать для каждой загрузки»
        guard let dir = WebEngine.downloadFolder else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
                guard r == .OK, let dest = panel.url, let self else { completionHandler(nil); return }
                try? FileManager.default.removeItem(at: dest)          // заменить — уже подтвердили в окне
                self.begin(download, dest)
                completionHandler(dest)
            }
            if let w = browser?.mainWindow { panel.beginSheetModal(for: w, completionHandler: finish) } else { finish(panel.runModal()) }
            return
        }
        var dest = dir.appendingPathComponent(suggestedFilename)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        begin(download, dest)
        completionHandler(dest)
    }

    private func begin(_ download: WKDownload, _ dest: URL) {
        downloadPaths[ObjectIdentifier(download)] = dest
        running[ObjectIdentifier(download)] = download
        let priv = download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
        let id = DownloadStore.shared.started(dest, private: priv)
        downloadIDs[ObjectIdentifier(download)] = id
        DownloadStore.shared.track(id, download.progress)
        DownloadStore.shared.cancellers[id] = { [weak self, weak download] in
            guard let download else { return }
            // Отменённой движок об ошибке уже не сообщает — её записи убираем здесь
            let oid = ObjectIdentifier(download)
            self?.running[oid] = nil; self?.downloadPaths[oid] = nil; self?.downloadIDs[oid] = nil
            download.cancel { _ in }
        }
        browser?.showToast("Downloading: \(dest.lastPathComponent)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        running[ObjectIdentifier(download)] = nil
        if let id = downloadIDs.removeValue(forKey: ObjectIdentifier(download)) { DownloadStore.shared.finished(id) }
        guard let dest = downloadPaths.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Пометка «скачано из интернета» с адресом — как у Safari: Gatekeeper проверит перед первым запуском
        var q: [String: Any] = [kLSQuarantineAgentNameKey as String: "Sapfire", kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload]
        if let u = download.originalRequest?.url { q[kLSQuarantineDataURLKey as String] = u }
        if let u = download.webView?.url { q[kLSQuarantineOriginURLKey as String] = u }
        var values = URLResourceValues(); values.quarantineProperties = q
        var marked = dest; try? marked.setResourceValues(values)
        browser?.showToast("Downloaded: \(dest.lastPathComponent)")
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"),
                                                     object: dest.path)
        // «Открывать безопасные файлы после загрузки»
        if WebEngine.openSafeFiles, WebEngine.isSafe(dest) { NSWorkspace.shared.open(dest) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let oid = ObjectIdentifier(download)
        running[oid] = nil
        downloadPaths.removeValue(forKey: oid)
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if let id = downloadIDs.removeValue(forKey: oid) {
            // Отменённую список уже закрыл сам — второй раз не трогаем
            if DownloadStore.shared.items.first(where: { $0.id == id })?.cancelled != true {
                DownloadStore.shared.finished(id, failed: true)
                browser?.showToast(cancelled ? "Download cancelled" : "Download failed")
            }
        } else if !cancelled {        // не началась и отменена (закрыли окно сохранения) — не ошибка
            browser?.showToast("Download failed")
        }
    }

    // MARK: JS-диалоги и выбор файлов

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? ""
        a.informativeText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? ""
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(promptText(prompt, initial: defaultText ?? ""))
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        p.begin { r in completionHandler(r == .OK ? p.urls : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Настройка — того сайта, который просит (рамка другого сайта внутри страницы — не сама страница):
        // «разрешено» для страницы чужой рамке не достаётся, ей — вопрос
        let originURL = URL(string: "\(origin.protocol)://\(origin.host)")
        let foreign = !frame.isMainFrame && BrowserModel.baseDomain(origin.host) != BrowserModel.baseDomain(webView.url?.host)
        let p = SiteSettings.shared.prefs(foreign ? originURL : webView.url, incognito: BrowserModel.isIncognito(webView))
        var v: String
        switch type {
        case .camera: v = p.camera
        case .microphone: v = p.microphone
        default: v = p.camera == p.microphone ? p.camera : "ask"
        }
        if foreign && v == "allow" { v = "ask" }
        decisionHandler(v == "allow" ? .grant : v == "deny" ? .deny : .prompt)
    }

    /// Внешнее приложение — по настройке сайта: спросить / открыть / запретить
    private func openExternal(_ url: URL, from wv: WKWebView) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            browser?.showToast("No app can open this link"); return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        switch SiteSettings.shared.prefs(wv.url, incognito: BrowserModel.isIncognito(wv)).externalApps {
        case "allow": NSWorkspace.shared.open(url)
        case "deny": browser?.showToast("Opening \(name) is blocked on this site")
        default:
            let a = NSAlert()
            a.messageText = "Open “\(name)”?"
            a.informativeText = "\(SiteSettings.site(wv.url) ?? "This site") wants to open another app."
            a.addButton(withTitle: "Open")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Always for this site"
            let r = a.runModal()
            if a.suppressionButton?.state == .on {
                SiteSettings.shared.update(wv.url, incognito: BrowserModel.isIncognito(wv)) { $0.externalApps = r == .alertFirstButtonReturn ? "allow" : "deny" }
            }
            if r == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    // Новая страница — список заблокированного начинается заново; масштаб — как для этого сайта
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        browser?.tab(for: webView)?.blocked = []
        LocalBridge.shared.closeAll(for: webView)       // уходим со страницы — её подключения к программам на Mac закрыть
        EditingFocus.shared.forget(webView)             // поля старой страницы больше не в фокусе
        StallWatch.started(webView)                     // первый ответ не придёт за 15 с — повторить
    }

    // Сайт «всегда в режиме чтения» / «всегда переводить»
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PageSwipe.shared.navigated(webView)
        AutoReload.finished(webView)
        // Снимок страницы для листания назад / вперёд — сразу, как догрузилась и нарисовалась
        // (не только когда с неё уходят: иначе при листании к ней под карточкой пусто)
        let url = webView.url
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak webView] in
            if let wv = webView, wv.url == url, !wv.isLoading, wv.window != nil { PageSwipe.shared.remember(wv) }
        }
        let incognito = BrowserModel.isIncognito(webView)
        let p = SiteSettings.shared.prefs(webView.url, incognito: incognito)
        if Module.boosts.isOn, PageTweaks.shared.site(webView.url, incognito: incognito) != PageTweaks.Site() { PageTweaks.shared.apply(webView) }
        if p.reader { Reader.show(webView) }
        if p.translate, let t = browser?.tab(for: webView) { PageTranslator.shared.translate(t) }

        FaviconStore.probe(webView)
        if !incognito { Tips.pageLoaded(webView, browser) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        StallWatch.settled(webView)
        PageSwipe.shared.navigated(webView)
        browser?.tab(for: webView)?.translated = false       // новая страница — снова оригинал
        PagePixels.reset(webView)
        let incognito = BrowserModel.isIncognito(webView)
        let z = SiteSettings.shared.prefs(webView.url, incognito: incognito).zoom
        if webView.pageZoom != z { webView.pageZoom = z }
        // Стёртое и тёмная страница — как можно раньше, чтобы не мелькало
        if Module.boosts.isOn, PageTweaks.shared.site(webView.url, incognito: incognito) != PageTweaks.Site() { PageTweaks.shared.apply(webView) }
    }

    /// Блокировщик сработал на запросе этой страницы (закрытый, но стабильный вызов WebKit)
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func _webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard (action.value(forKey: "blockedLoad") as? Bool) == true, let t = browser?.tab(for: webView) else { return }
        t.blocked.append(.init(url: url, list: identifier))
    }
}

// MARK: - Блокировщик рекламы и трекеров

final class ContentBlocker {
    static let shared = ContentBlocker()

    var enabled: Bool = UserDefaults.standard.object(forKey: "adblock") as? Bool ?? true
    private var list: WKContentRuleList?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    private let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "amazon-adsystem.com",
        "adnxs.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "scorecardresearch.com",
        "quantserve.com", "moatads.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com", "openx.net",
        "casalemedia.com", "advertising.com", "smartadserver.com", "adform.net", "teads.tv",
        "an.yandex.ru", "yandexadexchange.net", "adfox.ru", "ad.mail.ru", "top-fwz1.mail.ru",
        "hotjar.com", "adroll.com", "bidswitch.net", "3lift.com", "sharethrough.com", "media.net",
        "popads.net", "propellerads.com", "exoclick.com", "mgid.com", "trafficjunky.net",
        "doubleverify.com", "adsafeprotected.com", "ads-twitter.com", "analytics.tiktok.com",
        "bat.bing.com", "clarity.ms", "mc.yandex.ru",
    ]

    func compile() {
        var rules: [[String: Any]] = domains.map { d in
            let escaped = d.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[/:]", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        // Разрешённое пользователем (исключения — в конце списка)
        rules += ABPConverter.convert(BlockerPrefs.shared.exceptionText).network
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "sapfire-ads",
                                                                encodedContentRuleList: json) { list, error in
            DispatchQueue.main.async {
                if let error { NSLog("Sapfire: blocker compile error \(error)") }
                self.list = list
                self.refreshAll()
            }
        }
    }

    func apply(to controller: WKUserContentController) {
        controllers.add(controller)
        refresh(controller)
        CosmeticFilter.shared.install(in: controller)     // скрытие элементов — скриптом, не правилами движка
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "adblock")
        refreshAll()
    }

    func refreshAll() {
        controllers.allObjects.forEach { refresh($0) }
        compileExceptions()      // вкладки сайтов, где блокировка выключена, — снова без правил
    }

    /// Правила на странице: встроенный список + общественные списки. Для сайтов, где блокировка
    /// выключена, у вкладки правил нет вовсе (решается при переходе — см. decidePolicy).
    /// Нужны ли правила странице этого сайта: блокировка включена, не выключена для сайта, не YouTube
    func wantsRules(_ url: URL?, incognito: Bool = false) -> Bool {
        enabled && !Perf.off("blocker") && (url.map { SiteSettings.shared.prefs($0, incognito: incognito).blocker } ?? true) && !YouTubeAds.covers(url)
    }
    /// Какие правила сейчас стоят у страницы (true — стоят)
    private let applied = NSMapTable<WKUserContentController, NSNumber>.weakToStrongObjects()

    /// Переход: поставить или снять правила, если для этого сайта нужно иначе, чем сейчас
    func update(_ c: WKUserContentController, for url: URL?, incognito: Bool = false) {
        if applied.object(forKey: c)?.boolValue != wantsRules(url, incognito: incognito) { refresh(c, site: url, incognito: incognito) }
        // YouTube: скрипт против рекламы — только если блокировка для сайта не выключена (знак для него — обработчик sfYTOff)
        if YouTubeAds.covers(url) {
            let off = !enabled || !BlockerPrefs.shared.isOn(UBOYouTube.id) || !SiteSettings.shared.prefs(url, incognito: incognito).blocker
            let has = ytOff.object(forKey: c)?.boolValue ?? false
            if off && !has { c.add(YouTubeAds.OffMarker.shared, name: "sfYTOff"); ytOff.setObject(true, forKey: c) }
            if !off && has { c.removeScriptMessageHandler(forName: "sfYTOff"); ytOff.setObject(false, forKey: c) }
        }
    }
    private let ytOff = NSMapTable<WKUserContentController, NSNumber>.weakToStrongObjects()

    func refresh(_ c: WKUserContentController, site url: URL? = nil, incognito: Bool = false) {
        c.removeAllContentRuleLists()
        applied.setObject(NSNumber(value: false), forKey: c)
        guard enabled, !Perf.off("blocker") else { return }
        if let url, !SiteSettings.shared.prefs(url, incognito: incognito).blocker { return }
        // YouTube: сетевые правила ломают плеер (ждёт рекламную паузу, которую они не пропускают) —
        // там рекламу убирает скрипт (YouTubeAds)
        if YouTubeAds.covers(url) { return }
        let prefs = BlockerPrefs.shared
        if let list, prefs.isOn(BlockerPrefs.builtinID), !Perf.off("blk-builtin") { c.add(list) }
        for (id, l) in FilterLists.shared.lists where prefs.isOn(id) && !Perf.off("blk-" + id) { c.add(l) }
        applied.setObject(NSNumber(value: true), forKey: c)
    }

    func compileExceptions() {
        // Сайт включили / выключили — обновить открытые вкладки этого сайта
        for t in BrowserModel.shared.allTabs {
            if let wv = t.webView { refresh(wv.configuration.userContentController, site: wv.url) }
        }
    }
}

// MARK: - Реклама на YouTube

/// На YouTube сетевые правила не годятся: плеер зависает, ожидая рекламу. Вместо них — скрипт:
/// вырезает рекламные вставки из данных плеера, прячет рекламу в ленте, жмёт «Пропустить».
enum YouTubeAds {
    /// Пустой обработчик: само его наличие говорит скрипту «блокировка для YouTube выключена»
    final class OffMarker: NSObject, WKScriptMessageHandler {
        static let shared = OffMarker()
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {}
    }

    static func covers(_ url: URL?) -> Bool {
        guard let h = url?.host?.lowercased() else { return false }
        return h == "youtube.com" || h.hasSuffix(".youtube.com")
    }

    /// Скрипт страницы: исполнитель (`engine`) + таблица правил uBlock Origin (UBOYouTube.json).
    /// Пересобирается, когда пришли свежие правила; открытые вкладки получают их при следующем создании страницы
    private static var cached: WKUserScript?
    static var script: WKUserScript {
        if let c = cached { return c }
        let s = WKUserScript(source: engine + "(" + UBOYouTube.json + ");", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        cached = s
        return s
    }
    static func rulesChanged() { cached = nil }

    /// Исполнитель правил uBO на странице (сырая строка: регулярки без экранирования). Свои правила — только
    /// лента, шапка и кнопка «Пропустить»; всё про плеер и заглушку — из таблицы R
    static let engine = #"""
(function(R){
  if (!/(^|\.)youtube\.com$/.test(location.hostname) || window.__sfYT) return;
  // Блокировщик для YouTube выключен (шестерёнка в адресе) — ничего не трогаем, реклама как есть
  try { if (window.webkit.messageHandlers.sfYTOff) return; } catch(e){}
  var stat = window.__sfYT = {rpnt: 0, rmnt: 0};      // для проверки пробой (tools/probe.swift)
  var host = location.hostname;
  var mine = function(r){ return !r.h || r.h.some(function(d){ return host === d || host.slice(-d.length - 1) === '.' + d; }); };
  var pick = function(k){ return (R[k] || []).filter(mine); };
  var parse = JSON.parse, stringify = JSON.stringify;

  // Свои правила ленты и шапки. Рекламу рядом с плеером не прячем — иначе плеер ждёт, пока она покажется (~25 с)
  var css = document.createElement('style');
  css.textContent = '#masthead-ad,ytd-in-feed-ad-layout-renderer,ytd-promoted-sparkles-web-renderer,' +
    'ytd-banner-promo-renderer,ytd-statement-banner-renderer,ytd-promoted-video-renderer,' +
    'ytd-rich-item-renderer:has(ytd-ad-slot-renderer),ytd-rich-section-renderer:has(ytd-statement-banner-renderer){display:none!important}\n' +
    pick('css').map(function(r){ return r.sel + '{display:none!important}'; }).join('\n');
  (document.head || document.documentElement).appendChild(css);

  // Все подмены — через Proxy, а текст функции (toString) — от исходной: YouTube не отличает их от родных.
  // В движке Safari и Proxy выдаёт себя («ProxyObject»), поэтому toString смотрит в таблицу real.
  // Сам Proxy тоже подменён: прокси, которые делает код uBO на странице, попадают в ту же таблицу
  var real = new WeakMap();
  var origin = function(f){ var n = 0; while (real.has(f) && n++ < 20) f = real.get(f); return f; };
  var NativeProxy = Proxy;
  var wrap = function(fn, apply){ var p = new NativeProxy(fn, {apply: apply}); real.set(p, fn); return p; };
  Function.prototype.toString = wrap(Function.prototype.toString, function(t, self, args){ return Reflect.apply(t, origin(self), args); });
  try {
    var P = new NativeProxy(NativeProxy, {construct: function(t, args, nt){
      var p = Reflect.construct(t, args, nt === P ? t : nt);
      if (typeof args[0] === 'function') real.set(p, args[0]);
      return p;
    }});
    real.set(P, NativeProxy);
    window.Proxy = P;
  } catch(e){}
  var resolve = function(path){
    var parts = path.split('.'), o = window;
    for (var i = 0; i < parts.length - 1; i++) { o = o && o[parts[i]]; }
    return o ? {owner: o, name: parts[parts.length - 1]} : null;
  };
  var hook = function(path, apply){
    var r = typeof path === 'string' ? resolve(path) : path;
    try { if (r && typeof r.owner[r.name] === 'function') r.owner[r.name] = wrap(r.owner[r.name], apply); } catch(e){}
  };

  // Образец uBO: /рег/флаги — регулярка, иначе обычный текст; пусто — подходит всё
  var pattern = function(s, flags){
    if (!s) return null;
    var m = /^\/(.+)\/([a-z]*)$/.exec(s);
    try { if (m) return new RegExp(m[1], flags === undefined ? m[2] : (m[2] + flags).replace(/(.)(?=.*\1)/g, '')); } catch(e){ return /$^/; }
    return new RegExp(s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flags || '');
  };
  var test = function(re, s){ if (!re) return true; re.lastIndex = 0; return re.test(s); };

  // Пути вида a.b, [].a, a.[-].b, * (как у json-prune uBO)
  function has(o, segs){
    if (!segs.length) return true;
    if (o === null || typeof o !== 'object') return false;
    var s = segs[0], rest = segs.slice(1);
    if (s === '[]' || s === '[-]' || s === '*') return Object.keys(o).some(function(k){ return has(o[k], rest); });
    return s in o && has(o[s], rest);
  }
  function prunePath(o, segs){
    if (o === null || typeof o !== 'object' || !segs.length) return;
    var s = segs[0], rest = segs.slice(1);
    if (s === '[-]') { if (Array.isArray(o)) for (var i = o.length - 1; i >= 0; i--) if (has(o[i], rest)) o.splice(i, 1); return; }
    if (s === '[]' || s === '*') { Object.keys(o).forEach(function(k){ if (rest.length) prunePath(o[k], rest); else delete o[k]; }); return; }
    if (!rest.length) { if (s in o) delete o[s]; return; }
    prunePath(o[s], rest);
  }
  var pruneWith = function(rules){
    return function(o){
      if (!o || typeof o !== 'object') return o;
      rules.forEach(function(r){
        try {
          if (r.needle.length && !r.needle.every(function(n){ return has(o, n.split('.')); })) return;
          r.paths.forEach(function(p){ prunePath(o, p.split('.')); });
        } catch(e){}
      });
      return o;
    };
  };

  // Правила uBO пропали (не скачались, не разобрались) — хотя бы вырезать рекламу из данных плеера
  var prune = pick('prune');
  if (!prune.length && !pick('repl').length) prune = [{on: 'parse', needle: [], url: '', paths: ['adPlacements', 'playerAds', 'adSlots', 'playerResponse.adPlacements', 'playerResponse.playerAds', 'playerResponse.adSlots']}];

  // json-prune: всё, что страница разбирает из JSON
  var onParse = pruneWith(prune.filter(function(r){ return r.on === 'parse'; }));
  if (prune.some(function(r){ return r.on === 'parse'; })) {
    hook('JSON.parse', function(t, self, args){ return onParse(Reflect.apply(t, self, args)); });
    hook('Response.prototype.json', function(t, self, args){ return Reflect.apply(t, self, args).then(onParse); });
  }

  // Ответы сервера (fetch / XHR): подмена текста и вырезание из JSON — по адресу запроса
  var net = function(on){
    var rp = prune.filter(function(r){ return r.on === on; }).map(function(r){ return {url: pattern(r.url), fn: pruneWith([r])}; });
    var rr = pick('repl').filter(function(r){ return r.on === on || r.on === 'both'; }).map(function(r){
      return {url: pattern(r.url), find: pattern(r.find, 'gms'), to: r.to};
    });
    if (!rp.length && !rr.length) return null;
    return function(url, text){
      var out = text;
      rr.forEach(function(r){ if (test(r.url, url)) { r.find.lastIndex = 0; out = out.replace(r.find, r.to); } });
      var ps = rp.filter(function(r){ return test(r.url, url); });
      if (ps.length) {
        try { var o = parse(out); ps.forEach(function(r){ r.fn(o); }); out = stringify(o); } catch(e){}
      }
      return out;
    };
  };
  var fetchEdit = net('fetch');
  if (fetchEdit) hook('fetch', function(t, self, args){
    var a = args[0], url = typeof a === 'string' ? a : (a && a.url) || String(a || '');
    var p = Reflect.apply(t, self, args);
    return p.then(function(r){
      if (!r || !r.ok) return r;
      return r.clone().text().then(function(text){
        var after = fetchEdit(url, text);
        if (after === text) return r;
        var n = new Response(after, {status: r.status, statusText: r.statusText, headers: r.headers});
        try { Object.defineProperties(n, {ok: {value: r.ok}, redirected: {value: r.redirected}, type: {value: r.type}, url: {value: r.url}}); } catch(e){}
        return n;
      }, function(){ return r; });
    });
  });
  var xhrEdit = net('xhr');
  if (xhrEdit) {
    var xurl = new WeakMap(), xdone = new WeakMap();
    hook('XMLHttpRequest.prototype.open', function(t, self, args){ try { xurl.set(self, String(args[1] || '')); xdone.delete(self); } catch(e){} return Reflect.apply(t, self, args); });
    ['responseText', 'response'].forEach(function(prop){
      var d = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, prop);
      if (!d || !d.get) return;
      var get = wrap(d.get, function(t, self, args){
        var v = Reflect.apply(t, self, args);
        if (typeof v !== 'string' || self.readyState !== 4) return v;
        var c = xdone.get(self);
        if (c && c.raw === v) return c.out;
        var out = xhrEdit(xurl.get(self) || '', v);
        xdone.set(self, {raw: v, out: out});
        return out;
      });
      try { Object.defineProperty(XMLHttpRequest.prototype, prop, {configurable: true, enumerable: d.enumerable, get: get}); } catch(e){}
    });
  }

  // set: свойство-константа по пути от window (ловушки на каждом звене, как set-constant у uBO)
  var value = function(v){
    var map = {'undefined': undefined, 'false': false, 'true': true, 'null': null, '': '', 'emptyStr': '', "''": '',
      'noopFunc': function(){}, 'trueFunc': function(){ return true; }, 'falseFunc': function(){ return false; }};
    if (v in map) return map[v];
    if (v === '{}') return {};
    if (v === '[]') return [];
    if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
    return v;
  };
  var tree = {};
  pick('set').forEach(function(r){
    var segs = r.path.split('.'), node = tree;
    segs.forEach(function(s, i){
      if (i === segs.length - 1) node[s] = {leaf: true, v: value(r.value)};
      else node = node[s] = (node[s] && !node[s].leaf) ? node[s] : {};
    });
  });
  function trap(owner, t){
    Object.keys(t).forEach(function(k){
      var sub = t[k];
      if (sub.leaf) { try { Object.defineProperty(owner, k, {configurable: true, enumerable: true, get: function(){ return sub.v; }, set: function(){}}); } catch(e){} return; }
      var v = owner[k];
      var apply = function(o){ if (o && (typeof o === 'object' || typeof o === 'function')) trap(o, sub); };
      apply(v);
      try { Object.defineProperty(owner, k, {configurable: true, enumerable: true, get: function(){ return v; }, set: function(n){ v = n; apply(n); }}); } catch(e){}
    });
  }
  if (Object.keys(tree).length) trap(window, tree);

  // nano-stb: ускорить таймеры ожидания (проверку блокировщика)
  var stb = pick('stb');
  if (stb.length) hook('setTimeout', function(t, self, args){
    try {
      var f = String(args[0]);
      stb.forEach(function(r){
        if (r.needle && r.needle !== '*' && !test(pattern(r.needle), f)) return;
        var d = r.delay === '' || r.delay === '*' ? null : Number(r.delay || 1000);
        if (d !== null && Number(args[1]) !== d) return;
        var b = Number(r.boost || 0.05);
        args[1] = Number(args[1]) * Math.min(50, Math.max(0.001, b));
      });
    } catch(e){}
    return Reflect.apply(t, self, args);
  });

  // trusted-edit-inbound-object: правка аргумента перед вызовом. Подмножество JSONPath uBO:
  // [?.путь], [?!.путь], [?.путь*="x"], ==, ^=, $=, =/рег/, .ключ, а в конце += {…}, = значение, =repl({…})
  function readValue(s, i){
    if (s[i] === '"') { for (var j = i + 1; j < s.length; j++) { if (s[j] === '\\') { j++; continue; } if (s[j] === '"') return {v: parse(s.slice(i, j + 1)), end: j + 1}; } return null; }
    if (s[i] === '/') { for (var k = i + 1; k < s.length; k++) { if (s[k] === '\\') { k++; continue; } if (s[k] === '/') { var f = /^[a-z]*/.exec(s.slice(k + 1))[0]; return {v: new RegExp(s.slice(i + 1, k), f), end: k + 1 + f.length}; } } return null; }
    var e = s.indexOf(']', i);
    if (e < 0) return null;
    try { return {v: parse(s.slice(i, e)), end: e}; } catch(x){ return null; }
  }
  var looseJSON = function(t){
    try { return parse(t.replace(/(^|[^\\])((?:\\\\)*)\\([bBdDsSwW])/g, '$1$2\\\\$3')); } catch(e){ return null; }
  };
  function compileExpr(s){
    var steps = [], i = 0;
    while (i < s.length) {
      if (s.substr(i, 2) === '..') return null;
      if (s[i] === '.') { var m = /^\.([\w$-]+)/.exec(s.slice(i)); if (!m) return null; steps.push({k: m[1]}); i += m[0].length; continue; }
      if (s.substr(i, 2) === '[?') {
        i += 2;
        var neg = s[i] === '!'; if (neg) i++;
        if (s[i] !== '.' || s[i + 1] === '.') return null;
        var pm = /^\.([\w$.-]+)/.exec(s.slice(i)); if (!pm) return null;
        i += pm[0].length;
        var c = {p: pm[1].split('.'), neg: neg, op: null};
        var op = /^(\*=|\^=|\$=|==|!=|=)/.exec(s.slice(i));
        if (op) { c.op = op[1]; i += op[1].length; var v = readValue(s, i); if (!v) return null; c.v = v.v; i = v.end; }
        if (s[i] !== ']') return null;
        i++; steps.push({c: c}); continue;
      }
      if (s.substr(i, 2) === '+=') { try { return {steps: steps, op: '+=', v: parse(s.slice(i + 2))}; } catch(e){ return null; } }
      if (s[i] === '=') {
        var rest = s.slice(i + 1), rm = /^repl\((.*)\)$/.exec(rest);
        if (rm) { var o = looseJSON(rm[1]); if (!o || typeof o.regex !== 'string') return null; return {steps: steps, op: 'repl', re: pattern(o.regex) || /$^/, to: o.replacement || ''}; }
        try { return {steps: steps, op: '=', v: parse(rest)}; } catch(e){ return null; }
      }
      return null;
    }
    return null;
  }
  var get = function(o, segs){ for (var i = 0; i < segs.length; i++) { if (o === null || typeof o !== 'object' || !(segs[i] in o)) return {ok: false}; o = o[segs[i]]; } return {ok: true, v: o}; };
  var cond = function(node, c){
    var g = get(node, c.p), r;
    if (!c.op) r = g.ok;
    else if (!g.ok) r = false;
    else if (c.op === '=') r = c.v instanceof RegExp ? c.v.test(String(g.v)) : g.v === c.v;
    else if (c.op === '==') r = g.v === c.v;
    else if (c.op === '!=') r = g.v !== c.v;
    else { var sv = String(g.v), cv = String(c.v); r = c.op === '*=' ? sv.indexOf(cv) >= 0 : c.op === '^=' ? sv.indexOf(cv) === 0 : sv.slice(-cv.length) === cv; }
    return c.neg ? !r : r;
  };
  var now = function(v){
    if (typeof v === 'string') return v.split('${now}').join(String(Date.now()));
    if (v && typeof v === 'object') { var o = Array.isArray(v) ? [] : {}; Object.keys(v).forEach(function(k){ o[k] = now(v[k]); }); return o; }
    return v;
  };
  var runEdit = function(root, e){
    var node = root, parent = null, key = null;
    for (var i = 0; i < e.steps.length; i++) {
      var st = e.steps[i];
      if (st.c) { if (!cond(node, st.c)) return; continue; }
      if (node === null || typeof node !== 'object') return;
      parent = node; key = st.k; node = node[st.k];
    }
    if (e.op === '+=') { if (node && typeof node === 'object') Object.assign(node, now(e.v)); return; }
    if (!parent) return;
    if (e.op === '=') parent[key] = now(e.v);
    else if (e.op === 'repl' && typeof node === 'string') { e.re.lastIndex = 0; parent[key] = node.replace(e.re, e.to); }
  };
  // Правка входа и подмена текста на выходе — одной подменой на функцию
  var fns = {};
  pick('edit').forEach(function(r){ var e = compileExpr(r.expr); if (e) (fns[r.fn] = fns[r.fn] || {edit: [], out: []}).edit.push({arg: r.arg, e: e}); });
  pick('out').forEach(function(r){
    var o = r.opt || {};
    (fns[r.fn] = fns[r.fn] || {edit: [], out: []}).out.push({find: pattern(r.find), to: r.to, cond: pattern(o.condition)});
  });
  Object.keys(fns).forEach(function(fn){
    var h = fns[fn];
    hook(fn, function(t, self, args){
      h.edit.forEach(function(x){ try { var a = args[x.arg]; if (a && typeof a === 'object') runEdit(a, x.e); } catch(e){} });
      var res = Reflect.apply(t, self, args);
      if (typeof res === 'string') h.out.forEach(function(x){ try { if (x.find && test(x.cond, res)) { x.find.lastIndex = 0; res = res.replace(x.find, x.to); } } catch(e){} });
      return res;
    });
  });

  // trusted-prevent-dom-bypass: рамка, вставленная в страницу, получает те же (подменённые) функции
  var byp = {};
  pick('bypass').forEach(function(r){ (byp[r.fn] = byp[r.fn] || []).push(r.prop); });
  Object.keys(byp).forEach(function(fn){
    hook(fn, function(t, self, args){
      var res = Reflect.apply(t, self, args);
      try {
        var n = args[0], frames = n && n.tagName === 'IFRAME' ? [n] : (n && n.querySelectorAll ? n.querySelectorAll('iframe') : []);
        Array.prototype.forEach.call(frames, function(f){
          var w = f.contentWindow; if (!w) return;
          byp[fn].forEach(function(p){ try { var r = resolve(p); var o = w; p.split('.').slice(0, -1).forEach(function(k){ o = o && o[k]; }); if (r && o) o[r.name] = r.owner[r.name]; } catch(e){} });
        });
      } catch(e){}
      return res;
    });
  });

  // rpnt / rmnt: правка и вырезание встроенных скриптов страницы до их запуска (движок даёт поправить текст
  // вставленного скрипта, пока он не выполнился). Так приходит обход заглушки «Блокировщики рекламы нарушают Условия»
  var rp = pick('rpnt').map(function(r){
    var o = r.opt || {};
    return {find: pattern(r.find, 'g'), to: r.to, cond: pattern(o.condition), excl: pattern(o.excludes),
      count: Number(o.sedCount) || 0, quit: Number(o.quitAfter) || 0, done: 0};
  });
  var rm = pick('rmnt').map(function(r){ return pattern(r.needle); });
  if (rp.length || rm.length) {
    // YouTube требует Trusted Types для текста скриптов: свой пропуск (CSP не ограничивает имена политик)
    var tt = null;
    try { tt = window.trustedTypes && window.trustedTypes.createPolicy('sapfire-yt', {createScript: function(s){ return s; }}); } catch(e){}
    var setText = function(n, t){ n.textContent = tt ? tt.createScript(t) : t; };
    var patchScript = function(n){
      var text = n.textContent;
      if (!text) return;
      if (rm.some(function(re){ return test(re, text); })) { setText(n, ''); stat.rmnt++; return; }
      rp.forEach(function(r){
        if (!r.find || (r.quit && r.done >= r.quit) || !test(r.cond, text) || (r.excl && test(r.excl, text))) return;
        var k = 0, single = new RegExp(r.find.source, r.find.flags.replace('g', ''));
        r.find.lastIndex = 0;
        var after = text.replace(r.find, function(m){ return r.count && k++ >= r.count ? m : m.replace(single, r.to); });
        if (after !== text) { text = after; setText(n, after); r.done++; stat.rpnt++; }
      });
    };
    var mo = new MutationObserver(function(ms){
      ms.forEach(function(m){ m.addedNodes.forEach(function(n){ if (n.nodeName === 'SCRIPT' && !n.src) try { patchScript(n); } catch(e){ stat.err = String(e); } }); });
    });
    mo.observe(document, {childList: true, subtree: true});
    window.addEventListener('load', function(){ mo.disconnect(); }, {once: true});
  }

  // Если реклама всё же пришла — только нажать «Пропустить», когда YouTube его покажет
  setInterval(function(){
    if (document.hidden) return;      // в фоне нечего пропускать — не тратить процессор
    var b = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-slot button');
    if (b) b.click();
  }, 500);
})
"""#
}

// MARK: - Значки сайтов

@Observable
final class FaviconStore {
    static let shared = FaviconStore()
    var images: [String: NSImage] = [:]
    /// Значок «во весь квадрат» (без прозрачных/белых полей) — его можно растянуть на весь круг
    var fullBleed: [String: Bool] = [:]
    @ObservationIgnored private var loading = Set<String>()
    /// Значок взят со страницы (он лучше запасных — не заменяем)
    @ObservationIgnored private var fromPage = Set<String>()
    /// Сайты из инкогнито: их значки — только через прокси и только в памяти
    @ObservationIgnored private var privateHosts = Set<String>()

    /// Сайты профилей с туннелем: значки — через прокси (на диск можно)
    @ObservationIgnored private var tunnelHosts = Set<String>()
    func markTunneled(_ host: String) { tunnelHosts.insert(host) }
    /// Сайт с правилом «Through VPN» (Settings → Websites): его значки тоже через туннель, не напрямую
    private static func vpnRule(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return BrowserModel.profileRules[h] == Profile.vpnID
    }

    func markPrivate(_ host: String) {
        // Значок уже есть на диске (сайт бывал в обычных вкладках) — ничего нового не узнаём
        if FileManager.default.fileExists(atPath: Self.file(host).path) { return }
        privateHosts.insert(host)
    }

    /// Закрыли инкогнито: значки его сайтов забываем
    func forgetPrivate() {
        for h in privateHosts { images[h] = nil; fullBleed[h] = nil; loading.remove(h); fromPage.remove(h) }
        privateHosts = []
    }

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ host: String) -> URL { dir.appendingPathComponent(host) }

    func image(for host: String) -> NSImage? {
        if let i = images[host] { return i }
        if !loading.contains(host) {
            loading.insert(host)
            // Открыто инкогнито, а значка на диске нет (подсказки строки команд и т. п.) — тоже как сайт инкогнито
            if BrowserModel.current.currentSpace.isIncognito { markPrivate(host) }
            else if Tunnel.currentOn || Self.vpnRule(host) { tunnelHosts.insert(host) }
            let tunnel = tunnelHosts.contains(host) ? Incognito.proxySession(Incognito.endpoint) : nil
            // Сайт из инкогнито: только с самого сайта, через прокси, без записи на диск (прокси нет — без значка)
            if privateHosts.contains(host) {
                if let s = Incognito.session(), let u = URL(string: "https://\(host)/favicon.ico") {
                    fetch([u], host: host, session: s, save: false)
                }
                return nil
            }
            // Сначала — сохранённый на диске, потом сам сайт, потом запасные сервисы
            DispatchQueue.global(qos: .utility).async {
                if let data = try? Data(contentsOf: Self.file(host)), self.accept(data, host: host, save: false) { return }
                let sources = ["https://\(host)/favicon.ico",
                               "https://icons.duckduckgo.com/ip3/\(host).ico",
                               "https://www.google.com/s2/favicons?domain=\(host)&sz=128"].compactMap(URL.init(string:))
                self.fetch(sources, host: host, session: tunnel ?? .shared)
            }
        }
        return nil
    }

    /// Страница сама назвала свой значок (link rel=icon / apple-touch-icon) — берём его
    func pageIcon(_ url: URL, host: String) {
        guard !fromPage.contains(host) else { return }
        let priv = privateHosts.contains(host)
        let session: URLSession? = priv ? Incognito.session()
            : tunnelHosts.contains(host) || Self.vpnRule(host) ? Incognito.proxySession(Incognito.endpoint) : .shared
        guard let session else { return }
        fromPage.insert(host)
        loading.insert(host)
        fetch([url], host: host, fromPage: true, session: session, save: !priv)
    }

    private func fetch(_ urls: [URL], host: String, fromPage: Bool = false, session: URLSession = .shared, save: Bool = true) {
        guard let u = urls.first else { return }
        session.dataTask(with: u) { data, resp, _ in
            let ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 400
            if ok, let data, self.accept(data, host: host, save: save) { return }
            if fromPage { DispatchQueue.main.async { self.fromPage.remove(host) } }
            else { self.fetch(Array(urls.dropFirst()), host: host, session: session, save: save) }
        }.resume()
    }

    @discardableResult
    private func accept(_ data: Data, host: String, save: Bool) -> Bool {
        guard let img = NSImage(data: data), img.size.width >= 8 else { return false }
        if save { try? data.write(to: Self.file(host)) }
        let full = Self.isFullBleed(data)
        DispatchQueue.main.async { self.fullBleed[host] = full; self.images[host] = img }
        return true
    }
}

extension FaviconStore {
    /// Спросить у страницы её значок: крупный apple-touch-icon или самый большой rel=icon
    static func probe(_ wv: WKWebView) {
        guard let host = wv.url?.host, !shared.fromPage.contains(host) else { return }
        let js = """
        (() => { let best = null, bs = -1;
          for (const l of document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')) {
            if (!l.href || /\\.svg($|\\?)/i.test(l.href) || l.type === 'image/svg+xml') continue;
            let s = parseInt((l.sizes && l.sizes.value || '').split('x')[0]) || (l.rel.includes('apple') ? 180 : 32);
            if (s > 256) s = 100;
            if (s > bs) { bs = s; best = l.href; }
          }
          return best; })()
        """
        wv.evaluateJavaScript(js) { r, _ in
            if let s = r as? String, let u = URL(string: s) { shared.pageIcon(u, host: host) }
        }
    }

    /// Смотрим на пиксели у края: если почти все непрозрачные и не белые — значок во весь квадрат.
    static func isFullBleed(_ data: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 4, rep.pixelsHigh > 4 else { return false }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let inset = max(1, w / 16)
        var solid = 0, total = 0
        for i in stride(from: inset, to: w - inset, by: max(1, w / 16)) {
            for (x, y) in [(i, inset), (i, h - 1 - inset), (inset, i * h / w), (w - 1 - inset, i * h / w)] {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                let white = c.redComponent > 0.94 && c.greenComponent > 0.94 && c.blueComponent > 0.94
                if c.alphaComponent > 0.9 && !white { solid += 1 }
            }
        }
        return total > 0 && Double(solid) / Double(total) > 0.85
    }
}

struct Favicon: View {
    let url: URL?
    var body: some View {
        if let host = url?.host, let img = FaviconStore.shared.image(for: host) {
            Image(nsImage: img).resizable().interpolation(.high)
        } else {
            Image(systemName: "globe").resizable().foregroundStyle(.secondary)
        }
    }
}

// MARK: - Размытый фон окна

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Невидимая зона, за которую можно тащить окно (двойной клик — развернуть).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with e: NSEvent) {
            guard let w = window else { return }
            if e.clickCount == 2 { w.performZoom(nil); return }
            // Главное окно для системы неподвижно (см. applyWindowButtons): разрешаем движение
            // только на время этого перетаскивания
            let locked = !w.isMovable
            w.isMovable = true
            w.performDrag(with: e)
            if locked { WindowDragArea.relock(w) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}

    /// Отпустили кнопку мыши — окно снова неподвижно для системы
    private static var upMonitor: Any?
    static func relock(_ w: NSWindow) {
        let finish = {
            if let m = upMonitor { NSEvent.removeMonitor(m); upMonitor = nil }
            w.isMovable = false
        }
        // Перетаскивание могло уже закончиться (система ведёт его сама — отпускание сюда может не дойти)
        if NSEvent.pressedMouseButtons & 1 == 0 { finish(); return }
        if let m = upMonitor { NSEvent.removeMonitor(m) }
        upMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .mouseMoved, .leftMouseDown]) { e in
            if NSEvent.pressedMouseButtons & 1 == 0 || e.type == .leftMouseDown { finish() }
            return e
        }
    }
}

// MARK: - Страница: свои пункты в меню правого клика

/// WKWebView со своими пунктами в контекстном меню страницы: перевод, режим чтения.
final class SapfireWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard url?.host != nil else { return }
        let translate = NSMenuItem(title: "Translate Page", action: #selector(translatePage), keyEquivalent: "")
        translate.target = self
        let reader = NSMenuItem(title: "Reader", action: #selector(toggleReader), keyEquivalent: "")
        reader.target = self
        translate.showShortcut(.translate)
        reader.showShortcut(.reader)
        // Выделен текст — пункты в начале меню мешают; ставим в конец, отделив чертой
        menu.addItem(.separator())
        menu.addItem(translate)
        menu.addItem(reader)
        if Module.summarize.isOn {
            let sum = NSMenuItem(title: "Summarize Page", action: #selector(summarizePage), keyEquivalent: "")
            sum.target = self
            sum.showShortcut(.summarize)
            menu.addItem(sum)
        }
        // Картинка — взять в полном размере; иначе — выбрать картинку на странице
        if Module.capture.isOn {
            let onImage = menu.items.contains { ["WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierDownloadImage"].contains($0.identifier?.rawValue ?? "") }
            let cap = NSMenuItem(title: onImage ? "Capture Image at Full Size" : "Capture Image…",
                                 action: onImage ? #selector(captureHere) : #selector(capturePick), keyEquivalent: "")
            cap.target = self
            if !onImage { cap.showShortcut(.captureImage) }
            if onImage, let i = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyImage" }) {
                menu.insertItem(cap, at: i + 1)
            } else {
                menu.addItem(cap)
            }
        }
        // Ссылка — «Open Link As ▸ профиль / одноразовый контейнер» (не в инкогнито)
        let isLink = menu.items.contains { ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink"].contains($0.identifier?.rawValue ?? "") }
        let m = BrowserModel.windows.first { $0.window === window } ?? BrowserModel.current
        if isLink { addLinkItems(menu, model: m) }
        if isLink, !m.currentSpace.isIncognito {
            let sub = NSMenu()
            for p in m.profiles {
                sub.addItem(ClosureMenuItem(p.name) { [weak self] in self?.openLastLink(profile: p.id, temporary: false) })
            }
            sub.addItem(.separator())
            sub.addItem(ClosureMenuItem("Temporary Container") { [weak self] in self?.openLastLink(profile: nil, temporary: true) })
            let item = NSMenuItem(title: "Open Link As", action: nil, keyEquivalent: "")
            item.submenu = sub
            // Над «Download Linked File» — после своих «Open Link …» (просьба пользователя)
            let at = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierDownloadLinkedFile" }
                ?? menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" } ?? 0
            menu.insertItem(item, at: at)
        }
        // Пункты расширений
        let ext = Ext.menuItems(for: self)
        if !ext.isEmpty { menu.addItem(.separator()); ext.forEach(menu.addItem) }
        // Поделиться страницей (у выделенного текста своё «Поделиться» уже есть)
        if !menu.items.contains(where: { $0.identifier?.rawValue.contains("Share") == true || $0.title.hasPrefix("Share") }) {
            let share = NSMenuItem(title: "Share Page…", action: #selector(sharePage), keyEquivalent: "")
            share.target = self
            share.showShortcut(.share)
            menu.addItem(share)
        }
        // Пункты движка — с теми сочетаниями, что у этих действий в Sapfire
        let engine: [String: ShortcutID] = ["WKMenuItemIdentifierGoBack": .back, "WKMenuItemIdentifierGoForward": .forward,
                                            "WKMenuItemIdentifierReload": .reload, "WKMenuItemIdentifierInspectElement": .inspector]
        for item in menu.items where !item.isAlternate && item.keyEquivalent.isEmpty {
            if let raw = item.identifier?.rawValue, let id = engine[raw] { item.showShortcut(id) }
        }
    }

    /// Пункты ссылки вместо «Открыть в новом окне» движка (оно открывало вкладку). С зажатым ⌥ пункты меняются
    /// на альтернативные — как в меню macOS: вкладка в фоне ↔ сразу на неё, маленькое окно ↔ сплит, ссылка ↔ Markdown
    private func addLinkItems(_ menu: NSMenu, model m: BrowserModel) {
        let webNew = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }
        if let i = webNew { menu.removeItem(at: i) }
        var at = webNew ?? (menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }.map { $0 + 1 } ?? 0)
        func pair(_ title: String, _ action: @escaping (URL) -> Void, alt altTitle: String, _ alt: @escaping (URL) -> Void) {
            let a = ClosureMenuItem(title) { [weak self] in self?.withLastLink(action) }
            let b = ClosureMenuItem(altTitle) { [weak self] in self?.withLastLink(alt) }
            b.isAlternate = true
            b.keyEquivalentModifierMask = .option
            menu.insertItem(a, at: at); menu.insertItem(b, at: at + 1)
            at += 2
        }
        let opener = m.tab(for: self)
        let sp = opener.flatMap { m.space(of: $0) }
        pair("Open Link in New Tab", { m.openedInBackground(m.newTab(url: $0, in: sp, select: false, opener: opener)) },
             alt: "Open Link in New Tab and Switch", { _ = m.newTab(url: $0, in: sp, select: true, opener: opener) })
        if configuration.websiteDataStore.isPersistent {
            pair("Open Link in Little Window", { LittleWindow.open($0) },
                 alt: "Open Link in Split View", { u in
                     let t = m.newTab(url: u, in: sp, select: false, opener: opener)
                     m.openInSplit(t)
                 })
        }
        // Копировать: обычная ссылка ↔ Markdown [текст](адрес)
        if let i = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }) {
            let md = ClosureMenuItem("Copy Link as Markdown") { [weak self] in
                guard let self, let l = LastLink.shared.link(for: self) else { return }
                let href = l.url.absoluteString
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(l.text.isEmpty ? href : l.text)](\(href))", forType: .string)
            }
            md.isAlternate = true
            md.keyEquivalentModifierMask = .option
            menu.insertItem(md, at: i + 1)
        }
    }

    private func withLastLink(_ f: @escaping (URL) -> Void) {
        if let l = LastLink.shared.link(for: self) { f(l.url) }
    }

    private func openLastLink(profile: UUID?, temporary: Bool) {
        let m = BrowserModel.windows.first { $0.window === window } ?? BrowserModel.current
        let opener = m.tab(for: self)
        guard let l = LastLink.shared.link(for: self) else { return }
        m.openAs(l.url, profile: profile, temporary: temporary, opener: opener)
    }

    @objc private func captureHere() {
        let m = BrowserModel.windows.first { $0.window === window } ?? BrowserModel.current
        ImageCapture.shared.captureContextTarget(self, model: m)
    }

    @objc private func capturePick() {
        let m = BrowserModel.windows.first { $0.window === window } ?? BrowserModel.current
        ImageCapture.shared.pick(m)
    }

    @objc private func summarizePage() {
        let m = BrowserModel.windows.first { $0.window === window } ?? BrowserModel.current
        Summarizer.shared.start(m)
    }

    @objc private func sharePage() {
        let m = BrowserModel.windows.first { $0.window === window } ?? BrowserModel.current
        m.share(m.tab(for: self))
    }

    @objc private func translatePage() {
        PageTranslator.shared.toggle(BrowserModel.shared.tab(for: self))
    }

    @objc private func toggleReader() {
        Reader.toggle(BrowserModel.shared.tab(for: self))
    }
}

/// ⌥-клик и ⌘-клик по ссылке — новая вкладка (⌥ — сразу на неё, ⌘ — в фоне или по настройке, ⇧ — наоборот).
/// Перехват в странице: сайты, которые сами водят по ссылкам скриптом (Flaticon и т.п.), иначе переходят в той же
/// вкладке — до движка клик не доходит. ⌥⌘ (маленькое окно) и ⌃ — движку
final class OptionClick: NSObject, WKScriptMessageHandler {
    static let shared = OptionClick()

    static let script = WKUserScript(source: """
    window.addEventListener('click', function(e){
      if (!e.isTrusted) return;                                   // только настоящий клик, не событие от скрипта сайта
      if (!(e.altKey || e.metaKey) || (e.altKey && e.metaKey) || e.ctrlKey || e.button !== 0) return;
      if (window.__sfCap || window.__sfPick) return;            // выбор картинки / стирание элементов — клик их
      var a = null, p = e.composedPath ? e.composedPath() : [];  // и ссылки внутри shadow DOM
      for (var i = 0; i < p.length; i++) { var n = p[i]; if (n && n.tagName === 'A' && n.href) { a = n; break; } }
      if (!a && e.target && e.target.closest) a = e.target.closest('a[href]');
      if (!a || !/^https?:/i.test(a.href)) return;
      e.preventDefault(); e.stopImmediatePropagation();
      window.webkit.messageHandlers.sfOptionClick.postMessage({href: a.href, meta: e.metaKey, shift: e.shiftKey});
    }, true);
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    /// В своём мире скриптов: сайт обработчик не видит и вкладки через него не откроет
    func install(in c: WKUserContentController) {
        c.addUserScript(Self.script)
        c.add(self, contentWorld: .defaultClient, name: "sfOptionClick")
    }

    private var lastOpen = Date.distantPast

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView, let d = message.body as? [String: Any], let s = d["href"] as? String, let url = URL(string: s),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),          // не file:// и не чужие схемы
              Date().timeIntervalSince(lastOpen) > 0.15 else { return }             // один клик — одна вкладка
        lastOpen = Date()
        let b = BrowserModel.owner(of: wv)
        let opener = b.tab(for: wv)
        // ⌘ — в фоне (или сразу, по настройке «In a new tab and switches to it»); ⇧ — наоборот. ⌥ — сразу на неё
        let meta = d["meta"] as? Bool == true, shift = d["shift"] as? Bool == true
        let background = meta && shift == WebEngine.newTabActive
        let t = b.newTab(url: url, in: opener.flatMap { b.space(of: $0) }, select: !background, opener: opener)
        if background { b.openedInBackground(t) }
        else if wv.window !== b.window { b.mainWindow?.makeKeyAndOrderFront(nil) }   // из маленького окна — основное вперёд
    }
}

/// Ссылка под правым кликом — для своих пунктов меню («Open Link in New Tab», «Open Link As», Markdown).
/// Страница сообщает её из той рамки, где кликнули (и из iframe), — в window главной рамки её бы не было
final class LastLink: NSObject, WKScriptMessageHandler {
    static let shared = LastLink()
    private var links: [ObjectIdentifier: (url: URL, text: String)] = [:]

    static let script = WKUserScript(source: """
    // ⇧ + правый клик — меню браузера даже там, где сайт свой правый клик запрещает (как в Firefox):
    // этот обработчик ставится первым, и до страницы событие не доходит
    // Здесь же — ссылка под курсором (одним обработчиком: остановленное событие дальше никому не придёт)
    window.addEventListener('contextmenu', function(e){
      var a = null, p = e.composedPath ? e.composedPath() : [];
      for (var i = 0; i < p.length; i++) { var n = p[i]; if (n && n.tagName === 'A' && n.href) { a = n; break; } }
      if (!a && e.target && e.target.closest) a = e.target.closest('a[href]');
      try { window.webkit.messageHandlers.sfLastLink.postMessage(a ? { href: a.href, text: a.innerText || a.textContent || '' } : {}); } catch (err) {}
      if (e.shiftKey) e.stopImmediatePropagation();
    }, true);
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    func install(in c: WKUserContentController) {
        c.addUserScript(Self.script)
        c.add(self, name: "sfLastLink")
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView else { return }
        let d = message.body as? [String: Any]
        if let href = d?["href"] as? String, let u = URL(string: href) {
            links[ObjectIdentifier(wv)] = (u, (d?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            links[ObjectIdentifier(wv)] = nil
        }
    }

    func link(for wv: WKWebView) -> (url: URL, text: String)? { links[ObjectIdentifier(wv)] }
    func forget(_ wv: WKWebView) { links[ObjectIdentifier(wv)] = nil }
}
