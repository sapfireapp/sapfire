import AppKit
import SwiftUI
import WebKit

// MARK: - ⌃Z / ⌃⇧Z — отмена действий с вкладками, папками и пространствами

/// Перед каждым действием запоминаем «снимок» устройства панели; отмена возвращает его целиком.
/// Сами вкладки (и их страницы) не копируются — снимок держит ссылки на те же объекты.
final class BrowserUndo {
    static let shared = BrowserUndo()

    private struct TabState { let tab: Tab; let pinned: Bool; let folder: UUID?; let saved: Bool; let branch: Bool; let opener: UUID?; var custom: String? = nil }
    private struct FolderState { let folder: Folder; let name: String; let icon: String; let hue: Double; let sat: Double; let bri: Double; let expanded: Bool; let parent: UUID?; var temp = false }
    private struct SpaceState {
        let space: Space; let name: String; let icon: String; let hue: Double; let sat: Double; let bri: Double
        let tabs: [TabState]; let folders: [FolderState]; let layout: [UUID]; let selected: UUID?; let split: [[UUID]]
        let pinnedFrom: UUID?
    }
    private struct Snapshot { let label: String; let favorites: [Tab]; let spaces: [SpaceState]; let current: UUID; var date = Date() }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastCheckpoint = Date.distantPast   // несколько вызовов за одно действие — один шаг отмены
    private var restoring = false

    /// Закрыли инкогнито — в отмене не должно остаться его вкладок
    func clear() { undoStack = []; redoStack = [] }
    private static let limit = 40

    /// Запомнить состояние перед действием.
    func checkpoint(_ label: String, model: BrowserModel) {
        // Вызовы в пределах доли секунды — части одного действия (например, закрытие группы вкладок)
        guard !restoring, Date().timeIntervalSince(lastCheckpoint) > 0.25 else { return }
        lastCheckpoint = Date()
        undoStack.append(snapshot(label, model))
        if undoStack.count > Self.limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo(model: BrowserModel) {
        guard let s = undoStack.popLast() else { model.showToast("Nothing to undo"); return }
        guard confirm(s, model: model, verb: "Undo") else { undoStack.append(s); return }
        redoStack.append(snapshot(s.label, model))
        restore(s, model: model)
        model.showToast("Undo: \(s.label)")
    }

    func redo(model: BrowserModel) {
        guard let s = redoStack.popLast() else { model.showToast("Nothing to redo"); return }
        guard confirm(s, model: model, verb: "Redo") else { redoStack.append(s); return }
        undoStack.append(snapshot(s.label, model))
        restore(s, model: model)
        model.showToast("Redo: \(s.label)")
    }

    /// Вкладки, которых в снимке нет: восстановление их закроет (в архив)
    private func gone(_ s: Snapshot, _ m: BrowserModel) -> [Tab] {
        let keep = Set(s.favorites.map(ObjectIdentifier.init) + s.spaces.flatMap { $0.tabs.map { ObjectIdentifier($0.tab) } })
        return m.allTabs.filter { !keep.contains(ObjectIdentifier($0)) }
    }

    /// Снимок давний (действие было больше 15 минут назад) или откат закроет больше трёх вкладок — спросить.
    /// 6 ноября 2026 в Work пропало ~40 вкладок без следа в архиве; вероятная причина — ⌘Z, откативший панель
    /// к давнему снимку (вкладки, открытые после него, выбрасывались молча). Теперь — вопрос и архив.
    private func confirm(_ s: Snapshot, model m: BrowserModel, verb: String) -> Bool {
        let lost = gone(s, m).filter { $0.url?.scheme?.hasPrefix("http") ?? false }
        let age = Date().timeIntervalSince(s.date)
        guard age > 15 * 60 || lost.count > 3 else { return true }
        let a = NSAlert()
        a.messageText = "\(verb) “\(s.label)”?"
        var info = age > 15 * 60 ? "This was \(RelativeDateTimeFormatter().localizedString(for: s.date, relativeTo: Date())). The sidebar goes back to how it was then. " : ""
        if !lost.isEmpty { info += "\(lost.count) tab\(lost.count == 1 ? "" : "s") opened since then will close — you’ll find \(lost.count == 1 ? "it" : "them") in Archive (⇧⌘A)." }
        a.informativeText = info
        a.addButton(withTitle: verb)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func snapshot(_ label: String, _ m: BrowserModel) -> Snapshot {
        Snapshot(label: label, favorites: m.favorites, spaces: m.spaces.map { sp in
            SpaceState(space: sp, name: sp.name, icon: sp.icon, hue: sp.hue, sat: sp.sat, bri: sp.bri,
                       tabs: sp.tabs.map { TabState(tab: $0, pinned: $0.isPinned, folder: $0.folderID, saved: $0.isSaved, branch: $0.isBranch, opener: $0.openerID, custom: $0.customTitle) },
                       folders: sp.folders.map { FolderState(folder: $0, name: $0.name, icon: $0.icon, hue: $0.hue, sat: $0.sat, bri: $0.bri, expanded: $0.expanded, parent: $0.parentID, temp: $0.isTemp) },
                       layout: sp.layout,
                       selected: sp.selectedTabID, split: sp.splitGroups, pinnedFrom: sp.pinnedFrom)
        }, current: m.currentSpaceID)
    }

    private func restore(_ s: Snapshot, model m: BrowserModel) {
        restoring = true
        defer { restoring = false }
        let before = m.allTabs
        // Где лежали вкладки до отката — для архива тех, что закроются
        var place: [ObjectIdentifier: (space: String, folder: String?)] = [:]
        for sp in m.spaces where !sp.isIncognito {
            for t in sp.tabs { place[ObjectIdentifier(t)] = (sp.name, t.folderID.flatMap { id in sp.folders.first { $0.id == id }?.name }) }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            m.favorites = s.favorites
            for st in s.spaces {
                let sp = st.space
                sp.name = st.name; sp.icon = st.icon; sp.hue = st.hue; sp.sat = st.sat; sp.bri = st.bri
                for f in st.folders {
                    f.folder.name = f.name; f.folder.icon = f.icon; f.folder.hue = f.hue; f.folder.sat = f.sat; f.folder.bri = f.bri; f.folder.expanded = f.expanded; f.folder.parentID = f.parent; f.folder.isTemp = f.temp
                }
                sp.folders = st.folders.map(\.folder)
                for t in st.tabs {
                    t.tab.isPinned = t.pinned; t.tab.folderID = t.folder; t.tab.customTitle = t.custom; t.tab.browser = m
                    t.tab.isSaved = t.saved; t.tab.isBranch = t.branch; t.tab.openerID = t.opener
                }
                sp.tabs = st.tabs.map(\.tab)
                sp.layout = st.layout
                sp.pinnedFrom = st.pinnedFrom
                sp.selectedTabID = st.selected
                sp.splitGroups = st.split
            }
            m.spaces = s.spaces.map(\.space)
            // Пространство могло с тех пор открыться в другом окне — туда не переключаемся
            if let sp = m.spaces.first(where: { $0.id == s.current }), BrowserModel.window(showing: sp).map({ $0 === m }) ?? true {
                m.currentSpaceID = s.current
            }
            BrowserModel.fixWindows()
        }
        let after = m.allTabs
        // Вкладки, которых в восстановленном состоянии нет, — в архив (⇧⌘A) и выгружаем: молча не пропадает ничего
        for t in before where !after.contains(where: { $0 === t }) {
            if let p = place[ObjectIdentifier(t)] { ArchiveStore.shared.add(url: t.url, title: t.title, space: p.space, auto: false, folder: p.folder) }
            t.sleep()
        }
        m.focusWebView()
        m.selection.clear()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
}

extension BrowserModel {
    /// Короткая запись: запомнить состояние перед действием.
    func checkpoint(_ label: String) { BrowserUndo.shared.checkpoint(label, model: self) }
}

// MARK: - Стоит ли курсор в поле ввода на странице (чтобы ⌘Z отменял там набор текста)

final class EditingFocus: NSObject, WKScriptMessageHandler {
    static let shared = EditingFocus()
    /// По страницам и по рамкам (iframe) внутри: печатают, если хоть в одной рамке курсор в поле
    private var editing: [ObjectIdentifier: [String: Bool]] = [:]

    static let script = WKUserScript(source: """
    (function(){
      var fid = Math.random().toString(36).slice(2);      // своя метка у каждой рамки
      function ed(el){
        if (!el) return false;
        if (el.isContentEditable) return true;
        var t = (el.tagName || '').toLowerCase();
        if (t === 'textarea') return true;
        if (t === 'input') {
          var ty = (el.type || 'text').toLowerCase();
          return ['button','checkbox','radio','submit','reset','file','image','range','color'].indexOf(ty) < 0;
        }
        return false;
      }
      // Фокус внутри shadow DOM: activeElement — хозяин дерева, поле — внутри него
      function active(){ var el = document.activeElement; while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement; return el; }
      function send(){ try { window.webkit.messageHandlers.sfFocus.postMessage({f: fid, e: ed(active())}); } catch(e){} }
      document.addEventListener('focusin', send, true);
      document.addEventListener('focusout', function(){ setTimeout(send, 0); }, true);
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', send); else send();   // поле с autofocus
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    func install(in c: WKUserContentController) {
        c.addUserScript(Self.script)
        c.add(self, name: "sfFocus")
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView, let d = message.body as? [String: Any], let f = d["f"] as? String else { return }
        editing[ObjectIdentifier(wv), default: [:]][f] = d["e"] as? Bool == true
    }

    /// В поле этой страницы сейчас печатают
    func isEditing(_ wv: WKWebView) -> Bool { editing[ObjectIdentifier(wv)]?.values.contains(true) ?? false }
    /// Страница ушла или выгружена — её рамки больше не в счёт
    func forget(_ wv: WKWebView) { editing[ObjectIdentifier(wv)] = nil }

    /// ⌘Z должен уйти в текст, а не в отмену действий браузера?
    func textWantsUndo(in window: NSWindow?) -> Bool {
        guard let r = window?.firstResponder else { return false }
        if r is NSText { return true }                          // поля Sapfire: командная строка, поиск…
        var v = r as? NSView
        while let cur = v, !(cur is WKWebView) { v = cur.superview }
        if let wv = v as? WKWebView { return isEditing(wv) }
        return false
    }
}
