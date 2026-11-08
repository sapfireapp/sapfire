import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

// MARK: - Перевод страницы (⌥⌘T)

/// Переводит текст страницы на язык системы встроенным переводчиком macOS — на самом Mac, без отправки
/// текста в интернет. Разметка сайта не трогается: меняются только тексты, повторно — возвращаются.
@Observable
final class PageTranslator {
    static let shared = PageTranslator()

    /// Запрос на перевод для скрытого «хоста» в окне (Translation работает только из SwiftUI)
    var request: Int = 0
    @ObservationIgnored private(set) weak var tab: Tab?
    @ObservationIgnored var busy = false

    /// На какой язык переводить: из настроек, иначе — родной из языков системы (если первым стоит английский,
    /// а дальше есть другой — берём его: английский такой человек и так читает)
    static var targetCode: String {
        if let s = UserDefaults.standard.string(forKey: Prefs.translateTarget), !s.isEmpty { return s }
        let langs = Locale.preferredLanguages.map { Locale.Language(identifier: $0).languageCode?.identifier ?? "en" }
        if langs.first == "en", let other = langs.first(where: { $0 != "en" }) { return other }
        return langs.first ?? "en"
    }
    static var target: Locale.Language { Locale.Language(identifier: targetCode) }

    /// Тексты страницы, разложенные по языкам (переводим каждый язык отдельно: на странице их бывает несколько)
    @ObservationIgnored var groups: [(lang: String, items: [(Int, String)])] = []
    @ObservationIgnored var translatedAny = false

    /// Язык каждого текста; короткие и непонятные — к основному языку страницы; уже на нужном языке — пропускаем
    static func group(_ texts: [(Int, String)], target: String) -> [(lang: String, items: [(Int, String)])] {
        let rec = NLLanguageRecognizer()
        var byLang: [String: [(Int, String)]] = [:], unknown: [(Int, String)] = []
        var weight: [String: Int] = [:]
        for (i, t) in texts {
            rec.reset()
            rec.processString(t)
            if t.count >= 12, let (lang, p) = rec.languageHypotheses(withMaximum: 1).first, p > 0.6 {
                let code = Locale.Language(identifier: lang.rawValue).languageCode?.identifier ?? lang.rawValue
                byLang[code, default: []].append((i, t))
                weight[code, default: 0] += t.count
            } else {
                unknown.append((i, t))
            }
        }
        // Короткие подписи (кнопки, меню) — на основном языке страницы
        if let main = weight.max(by: { $0.value < $1.value })?.key { byLang[main, default: []] += unknown }
        byLang[target] = nil
        return byLang.sorted { $0.value.count > $1.value.count }.map { ($0.key, $0.value) }
    }

    func toggle(_ tab: Tab?) {
        guard let tab, let wv = tab.webView else { return }
        wv.evaluateJavaScript(Self.script + "window.__sfTr.isOn()") { r, _ in
            if (r as? Bool) == true {
                wv.evaluateJavaScript("window.__sfTr.restore()")
                tab.translated = false
                BrowserModel.shared.showToast("Original")
            } else {
                self.translate(tab)
            }
        }
    }

    func translate(_ tab: Tab) {
        guard #available(macOS 15.0, *) else {
            BrowserModel.shared.showToast("Translation needs macOS 15 or later")
            return
        }
        guard !busy else { return }
        self.tab = tab
        incremental = false
        request += 1
    }

    /// Перевод включён, а на странице появился новый текст (подгрузились комментарии) — перевести и его
    @ObservationIgnored private(set) var incremental = false
    @ObservationIgnored private var pendingMore = false
    func more(_ wv: WKWebView) {
        guard let t = BrowserModel.shared.tab(for: wv) else { return }
        if busy { pendingMore = true; return }
        tab = t
        incremental = true
        request += 1
    }
    /// Перевод закончился — если за это время подгрузилось ещё, перевести и это
    func finished() {
        busy = false
        if pendingMore, let wv = tab?.webView { pendingMore = false; more(wv) }
    }

    /// Тексты страницы (номер и текст), которые надо перевести: все или только новые
    func collect(_ done: @escaping ([(Int, String)]) -> Void) {
        guard let wv = tab?.webView else { done([]); return }
        wv.evaluateJavaScript(Self.script + (incremental ? "window.__sfTr.collectNew()" : "window.__sfTr.collect()")) { r, _ in
            let pairs = (r as? [[Any]] ?? []).compactMap { a -> (Int, String)? in
                guard a.count == 2, let i = (a[0] as? NSNumber)?.intValue, let t = a[1] as? String else { return nil }
                return (i, t)
            }
            done(pairs)
        }
    }

    func apply(_ texts: [Int: String]) {
        guard let wv = tab?.webView, !texts.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: texts.map { (String($0.key), $0.value) })),
              let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.__sfTr && window.__sfTr.apply(\(json))")
        if tab?.translated == false { tab?.translated = true }
    }

    fileprivate static let script = """
    if (!window.__sfTr) window.__sfTr = (function(){
      var nodes = [], orig = [], shown = [], seen = new WeakMap(), on = false, mo = null, timer = null;
      function ok(n){
        var p = n.parentElement; if (!p) return false;
        if (/^(SCRIPT|STYLE|NOSCRIPT|CODE|PRE|TEXTAREA|KBD|SAMP|SVG|MATH)$/.test(p.tagName)) return false;
        // Всеядно: метки сайта «не переводить» (translate=no, .notranslate — их ставят и на всю страницу) не слушаем,
        // пропускаем только код и то, что пользователь сам редактирует
        if (p.closest('code,pre,[contenteditable=true],[contenteditable=""]')) return false;
        var t = n.nodeValue.trim(); return t.length > 1 && /[^\\s\\d\\p{P}\\p{S}]/u.test(t);
      }
      // Новые тексты (и старые узлы, куда сайт вписал другой текст — так YouTube переиспользует комментарии)
      // Тексты страницы — и внутри открытых теневых деревьев (встроенные виджеты, веб-компоненты)
      function walk(onlyNew){
        var out = [], roots = [document.body || document.documentElement];
        function take(n){
          var i = seen.get(n);
          if (i === undefined) { i = nodes.length; seen.set(n, i); nodes.push(n); orig.push(n.nodeValue); shown.push(null); out.push([i, n.nodeValue.trim()]); }
          else if (onlyNew && n.nodeValue !== shown[i] && n.nodeValue !== orig[i]) { orig[i] = n.nodeValue; shown[i] = null; out.push([i, n.nodeValue.trim()]); }
        }
        while (roots.length && out.length < 8000) {
          var w = document.createTreeWalker(roots.shift(), NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT), n;
          while ((n = w.nextNode()) && out.length < 8000) {
            if (n.nodeType === 1) { if (n.shadowRoot) roots.push(n.shadowRoot); continue; }
            if (ok(n)) take(n);
          }
        }
        return out;
      }
      // Пока перевод включён — следим за страницей; новое подгрузилось — просим перевести
      function watch(){
        if (mo) return;
        mo = new MutationObserver(function(){
          if (!on) return;
          clearTimeout(timer);
          timer = setTimeout(function(){ try { window.webkit.messageHandlers.sfTranslate.postMessage('more'); } catch(e){} }, 700);
        });
        mo.observe(document.body, {childList: true, subtree: true, characterData: true});
      }
      return {
        isOn: function(){ return on; },
        collect: function(){ nodes = []; orig = []; shown = []; seen = new WeakMap(); return walk(false); },
        collectNew: function(){ return on ? walk(true) : []; },
        apply: function(m){
          for (var k in m) { var i = +k, n = nodes[i]; if (!n) continue;
            var s = orig[i], lead = s.match(/^\\s*/)[0], tail = s.match(/\\s*$/)[0];
            n.nodeValue = lead + m[k] + tail; shown[i] = n.nodeValue; }
          on = true; watch();
        },
        restore: function(){
          on = false; if (mo) { mo.disconnect(); mo = null; }
          for (var i = 0; i < nodes.length; i++) if (nodes[i] && shown[i] !== null && nodes[i].nodeValue === shown[i]) nodes[i].nodeValue = orig[i];
        }
      };
    })();
    """
}

/// Невидимый помощник в окне браузера: получает от системы сеанс перевода и переводит тексты пачками
struct TranslatorHost: View {
    @State private var tr = PageTranslator.shared
    var body: some View {
        if #available(macOS 15.0, *) {
            TranslatorHost15(request: tr.request)
        } else {
            Color.clear
        }
    }
}

@available(macOS 15.0, *)
private struct TranslatorHost15: View {
    let request: Int
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: request) {
                let tr = PageTranslator.shared
                tr.busy = true
                let quiet = tr.incremental          // догружаем новое — без сообщений
                tr.collect { texts in
                    let target = PageTranslator.targetCode
                    tr.groups = PageTranslator.group(texts, target: target)
                    tr.translatedAny = quiet
                    guard !texts.isEmpty else { tr.finished(); if !quiet { BrowserModel.shared.showToast("Nothing to translate") }; return }
                    guard !tr.groups.isEmpty else {
                        tr.finished()
                        if !quiet {
                            let name = Locale.current.localizedString(forLanguageCode: target) ?? target
                            BrowserModel.shared.showToast("The page is already in \(name)")
                        }
                        return
                    }
                    if !quiet { BrowserModel.shared.showToast("Translating…") }
                    next()
                }
            }
            .translationTask(config) { session in
                let tr = PageTranslator.shared
                guard !tr.groups.isEmpty else { return }
                let group = tr.groups.removeFirst()
                do {
                    try await session.prepareTranslation()
                    var i = 0
                    while i < group.items.count {
                        let chunk = group.items[i..<min(i + 80, group.items.count)]
                        let reqs = chunk.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: String($0.0)) }
                        let res = try await session.translations(from: reqs)
                        var out: [Int: String] = [:]
                        for r in res { if let id = r.clientIdentifier, let k = Int(id) { out[k] = r.targetText } }
                        await MainActor.run { tr.apply(out) }
                        tr.translatedAny = true
                        i += 80
                    }
                } catch {
                    // Этот язык перевести нельзя (не поддерживается или не скачан) — идём к следующему
                    NSLog("Sapfire translate \(group.lang): \(error)")
                }
                await MainActor.run { next() }
            }
    }

    /// Следующий язык страницы — новый сеанс перевода
    @MainActor private func next() {
        let tr = PageTranslator.shared
        guard let g = tr.groups.first else {
            tr.finished()
            if !tr.translatedAny { BrowserModel.shared.showToast("Can’t translate this page") }
            return
        }
        let src = Locale.Language(identifier: g.lang), dst = PageTranslator.target
        // Тот же язык, что в прошлый раз, — сеанс надо перезапустить явно (иначе переводчик не сработает)
        if config?.source == src && config?.target == dst { config?.invalidate() } else { config = .init(source: src, target: dst) }
    }
}

/// Сообщения страницы: «подгрузился новый текст» (перевод включён)
final class TranslateNotifier: NSObject, WKScriptMessageHandler {
    static let shared = TranslateNotifier()
    func install(in c: WKUserContentController) { c.add(self, name: "sfTranslate") }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let wv = message.webView { PageTranslator.shared.more(wv) }
    }
}
