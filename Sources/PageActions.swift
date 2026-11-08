import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Действия со страницей и вкладками (меню File / Edit / Tab / Spaces, «⋯», правый клик)

extension BrowserModel {
    /// ⌘P — печать страницы (там же «Сохранить как PDF» постранично)
    func printPage() {
        guard let wv = activeTab?.webView, let w = wv.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let op = wv.printOperation(with: info)
        op.view?.frame = wv.bounds                // без размера движок печатает пустые листы
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// ⇧⌘S — сохранить страницу: веб-архивом (как есть, со всем содержимым) или одним PDF
    func savePage() {
        guard let t = activeTab, let wv = t.webView, let w = wv.window else { return }
        let panel = NSSavePanel()
        let name = t.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = String(name.prefix(120))
        panel.canCreateDirectories = true
        let format = SaveFormat(panel)
        panel.accessoryView = format.view
        panel.allowedContentTypes = [.webArchive]
        panel.beginSheetModal(for: w) { r in
            withExtendedLifetime(format) {}
            guard r == .OK, let url = panel.url else { return }
            let done: (Result<Data, Error>) -> Void = { res in
                if case .success(let d) = res, (try? d.write(to: url, options: .atomic)) != nil {
                    self.showToast("Saved: \(url.lastPathComponent)")
                } else {
                    self.showToast("Couldn’t save the page")
                }
            }
            if format.pdf { wv.createPDF(configuration: WKPDFConfiguration(), completionHandler: done) }
            else { wv.createWebArchiveData(completionHandler: done) }
        }
    }

    /// Поделиться ссылкой: AirDrop, Сообщения, Заметки… — меню у курсора (или над страницей)
    func share(_ tab: Tab? = nil) {
        guard let t = tab ?? activeTab, let u = t.url,
              let w = NSApp.keyWindow ?? mainWindow, let v = w.contentView else { return }
        var p = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
        if !v.bounds.contains(p) {
            p = NSPoint(x: v.bounds.midX, y: v.isFlipped ? 60 : v.bounds.maxY - 60)
        }
        NSSharingServicePicker(items: [u]).show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: v, preferredEdge: .minY)
    }

    /// Выделенный на странице текст — цитатой в Markdown со ссылкой на страницу
    func copyQuote() {
        guard let t = activeTab, let wv = t.webView, let u = t.url?.absoluteString else { return }
        wv.evaluateJavaScript("window.getSelection().toString()") { r, _ in
            let sel = ((r as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = t.displayTitle.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            let link = "[\(title)](\(u))"
            let text: String
            if sel.isEmpty {
                text = link
            } else {
                let quote = sel.components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
                text = quote + "\n>\n> — " + link
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.showToast(sel.isEmpty ? "Nothing selected — copied the link" : "Quote copied")
        }
    }

    /// Стереть куки открытого сайта (в его профиле) и обновить — когда сайт глючит или завис вход
    func clearCookiesAndReload() {
        guard let t = activeTab, let wv = t.webView, let site = SiteSettings.site(t.url) else { return }
        let store = wv.configuration.websiteDataStore
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        store.fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter { r in let n = r.displayName.lowercased(); return n == site || site.hasSuffix("." + n) || n.hasSuffix("." + site) }
            store.removeData(ofTypes: types, for: mine) {
                t.reload()
                self.showToast("Cleared cookies for \(site)")
            }
        }
    }

    /// Показать открытую вкладку в сайдбаре: раскрыть её папки и прокрутить к ней
    func revealActiveTab() {
        guard let t = activeTab else { return }
        sidebarVisible = true
        let sp = currentSpace
        var entry = t.id
        if t.isBranch, let opener = sp.tabs.first(where: { $0.id == t.openerID }) {
            opener.branchesExpanded = true
            entry = opener.id
        }
        var f = sp.folders.first { $0.id == (sp.tabs.first { $0.id == entry }?.folderID ?? t.folderID) }
        while let cur = f {
            cur.expanded = true
            entry = cur.id
            f = sp.parent(of: cur)
        }
        revealIDs = [entry, t.id]
        revealCenter = true
        revealTick += 1
    }

    /// Вернуть все закреплённые вкладки пространства на их адреса
    func resetPinned() {
        let away = currentSpace.pinned.filter(\.awayFromPin)
        away.forEach { $0.backToPin() }
        showToast(away.isEmpty ? "Pinned tabs are at their addresses" : away.count == 1 ? "Reset 1 pinned tab" : "Reset \(away.count) pinned tabs")
    }

    /// Значок и цвет пространства — то же окошко, что по правому клику на значке
    func editSpaceLook() {
        sidebarVisible = true
        spacePicker = currentSpace.id
    }
}

/// Выбор формата в окне сохранения: веб-архив или PDF
private final class SaveFormat: NSObject {
    weak var panel: NSSavePanel?
    let view: NSView
    private let popup = NSPopUpButton()
    var pdf: Bool { popup.indexOfSelectedItem == 1 }

    init(_ panel: NSSavePanel) {
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        popup.addItems(withTitles: ["Web Archive", "PDF"])
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        panel?.allowedContentTypes = [pdf ? .pdf : .webArchive]
    }
}

// MARK: - Open As: вкладка с входами другого профиля или одноразовая

extension BrowserModel {
    /// Открыть адрес новой вкладкой — как профиль `profile` (nil и `temporary` — одноразовый контейнер)
    @discardableResult
    func openAs(_ url: URL?, profile: UUID?, temporary: Bool = false, opener: Tab? = nil) -> Tab? {
        guard !currentSpace.isIncognito else { return nil }
        let t = newTab(url: url, select: true, opener: opener)
        if temporary { t.temporary = true } else if profile != currentSpace.profileID { t.profileOverride = profile }
        return t
    }

    /// Открытую вкладку — заново, уже как другой профиль (или одноразовую; nil — как у пространства)
    func reopenAs(_ t: Tab, profile: UUID?, temporary: Bool = false) {
        guard let sp = space(of: t), !sp.isIncognito else { return }
        checkpoint("Reopen As")
        t.temporary = temporary
        t.profileOverride = temporary || profile == sp.profileID ? nil : profile
        t.dropTempStore()
        let visible = BrowserModel.visibleAnywhere(t)
        if t.webView != nil { t.sleep() }
        if visible { t.ensureWebView() }
        save()
        let name = temporary ? "a temporary container" : profile == Profile.vpnID ? "VPN" : profiles.first { $0.id == (profile ?? sp.profileID) }?.name ?? "profile"
        showToast("Reopened as \(name)")
    }

    /// Правило: сайт всегда открывать как этот профиль (nil — убрать правило)
    static var profileRules: [String: UUID] {
        get {
            let d = UserDefaults.standard.dictionary(forKey: "profileRules") as? [String: String] ?? [:]
            return d.compactMapValues(UUID.init(uuidString:))
        }
        set { UserDefaults.standard.set(newValue.mapValues(\.uuidString), forKey: "profileRules") }
    }

    func setRule(for url: URL?, profile: UUID?) {
        guard let site = SiteSettings.site(url) else { return }
        var r = Self.profileRules
        r[site] = profile
        Self.profileRules = r
        if profile == Profile.vpnID { showToast("\(site) — always through the VPN") }
        else if let p = profile, let name = profiles.first(where: { $0.id == p })?.name { showToast("\(site) — always as “\(name)”") }
        else { showToast("\(site) — as the space’s profile") }
    }

    /// Переход на сайт с правилом, а вкладка открыта другим профилем — открыть как нужно (true — перехвачено)
    func applyRule(_ url: URL?, in t: Tab) -> Bool {
        guard let site = SiteSettings.site(url), let want = Self.profileRules[site],
              want == Profile.vpnID || profiles.contains(where: { $0.id == want }),      // профиль правила могли удалить
              let sp = space(of: t), !sp.isIncognito, !t.temporary, t.effectiveProfileID != want else { return false }
        // Пустая новая вкладка — просто она сама становится нужным профилем
        if t.webView?.backForwardList.currentItem == nil {
            t.profileOverride = want == sp.profileID ? nil : want
            t.url = url
            t.sleep()
            t.ensureWebView()
            return true
        }
        openAs(url, profile: want, opener: t)
        notify(want == Profile.vpnID ? "\(site) opened through the VPN" : "\(site) opened as “\(profiles.first { $0.id == want }?.name ?? "profile")”",
               icon: want == Profile.vpnID ? "lock.shield" : "person.crop.circle")
        return true
    }
}

/// Подменю «Open As ▸ …»: профили и одноразовый контейнер
struct OpenAsMenu: View {
    @Environment(BrowserModel.self) private var model
    let title: String
    var current: UUID? = nil
    var currentTemporary = false
    let pick: (UUID?, Bool) -> Void
    var body: some View {
        Menu(title) {
            ForEach(model.profiles) { p in
                Button(p.name) { pick(p.id, false) }.disabled(!currentTemporary && p.id == current)
            }
            Divider()
            Button("Temporary Container") { pick(nil, true) }.disabled(currentTemporary)
        }
    }
}

extension BrowserModel {
    /// ↑ / ↓ над сайдбаром: соседняя вкладка в том порядке, как их видно в панели (закреплённые, потом список)
    func stepTab(_ d: Int) {
        let sp = currentSpace
        let list = sp.pinned + sp.visual
        guard !list.isEmpty else { return }
        let cur = list.firstIndex { $0 === activeTab } ?? (d > 0 ? -1 : list.count)
        let next = cur + d
        guard list.indices.contains(next) else { return }
        select(list[next])
        // Список прокрутить к ней, если ушла за край
        revealIDs = [list[next].id]
        revealCenter = false
        revealTick += 1
    }
}
