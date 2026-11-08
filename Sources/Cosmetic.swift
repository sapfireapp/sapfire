import Foundation
import WebKit

// MARK: - Скрытие элементов (косметические правила) — по способу uBlock Origin

/// Правила «##селектор» из списков фильтров. Раньше они шли в движок как css-display-none: он держал
/// на каждой странице (и в каждой рамке) таблицу из ~20 тысяч правил и сверял её при каждом изменении —
/// Speedometer терял 4–6 очков даже там, где ни одно правило не подходит. Теперь правила лежат здесь,
/// а страница спрашивает только своё: для сайта — селекторы его домена (один запрос на рамку),
/// общие — только те, чьи id и классы на странице действительно есть (как в uBO: страница присылает
/// встреченные id/классы, в ответ получает подходящие селекторы). В движке остаются только сетевые правила.
final class CosmeticFilter: NSObject, WKScriptMessageHandler {
    static let shared = CosmeticFilter()

    /// Разобранные правила одного списка
    struct Rules: Codable {
        /// домен → селекторы (example.com##sel и example.com,~sub.example.com##sel — исключения ниже)
        var byDomain: [String: [String]] = [:]
        /// Общие правила с ключом: id или класс → селекторы (##.ad-box → "ad-box")
        var byToken: [String: [String]] = [:]
        /// Общие без ключа (##[data-ad], ##AD-SLOT) — проверяются на странице одним querySelectorAll
        var rest: [String] = []
        /// Исключения: домен → селекторы, которые на нём не прятать (example.com#@#sel и ~example.com##sel)
        var exceptDomain: [String: [String]] = [:]
    }

    private(set) var lists: [String: Rules] = [:]

    private static var dir: URL { FilterLists.dir }

    /// При запуске — разобранные правила с диска (перевод делается при обновлении списков)
    func load() {
        for id in FilterLists.sources.map(\.id) + ["custom"] {
            guard let d = try? Data(contentsOf: Self.dir.appendingPathComponent(id + ".cos.json")),
                  let r = try? JSONDecoder().decode(Rules.self, from: d) else { continue }
            lists[id] = r
        }
    }

    /// Список перевели заново — запомнить и записать
    func set(_ id: String, _ rules: Rules?) {
        lists[id] = rules
        let f = Self.dir.appendingPathComponent(id + ".cos.json")
        if let rules, let d = try? JSONEncoder().encode(rules) { try? d.write(to: f, options: .atomic) }
        else { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: Разбор

    /// Строки «##», «#@#» из списка — в правила. Остальные строки пропускаем
    static func parse(_ text: String) -> Rules {
        var r = Rules()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            let exception = line.contains("#@#")
            guard let range = line.range(of: exception ? "#@#" : "##") else { continue }
            let sel = String(line[range.upperBound...])
            guard ABPConverter.selectorOK(sel) else { continue }
            let domains = line[..<range.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) && !$0.contains("*") }
            let incl = domains.filter { !$0.hasPrefix("~") }, excl = domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
            if exception {
                for d in incl { r.exceptDomain[d, default: []].append(sel) }
                continue
            }
            if incl.isEmpty {
                // Общее правило (возможно, кроме некоторых доменов)
                if let t = token(sel) { r.byToken[t, default: []].append(sel) } else { r.rest.append(sel) }
                for d in excl { r.exceptDomain[d, default: []].append(sel) }
            } else {
                for d in incl { r.byDomain[d, default: []].append(sel) }
                for d in excl { r.exceptDomain[d, default: []].append(sel) }
            }
        }
        return r
    }

    /// Ключ общего правила: первый id или класс в селекторе (без него — в rest)
    private static func token(_ sel: String) -> String? {
        var i = sel.startIndex
        while i < sel.endIndex {
            let c = sel[i]
            if c == "#" || c == "." {
                var j = sel.index(after: i), out = ""
                while j < sel.endIndex, sel[j].isLetter || sel[j].isNumber || sel[j] == "-" || sel[j] == "_" { out.append(sel[j]); j = sel.index(after: j) }
                if j < sel.endIndex, sel[j] == "\\" { return nil }     // экранированные имена — в rest
                if !out.isEmpty { return (c == "#" ? "#" : ".") + out }
                return nil
            }
            if c == "[" || c == ":" { return nil }                   // сначала атрибут или псевдокласс — ключа нет
            i = sel.index(after: i)
        }
        return nil
    }

    // MARK: Ответ странице

    /// Селекторы для хоста (его домен и родители) из включённых списков; минус исключения
    func forHost(_ host: String) -> (selectors: [String], rest: [String]) {
        var out = Set<String>(), rest = Set<String>(), except = Set<String>()
        let prefs = BlockerPrefs.shared
        let suffixes = Self.suffixes(host)
        for (id, r) in lists where prefs.isOn(id) {
            for d in suffixes { out.formUnion(r.byDomain[d] ?? []); except.formUnion(r.exceptDomain[d] ?? []) }
            if prefs.genericHiding { rest.formUnion(r.rest) }
        }
        return (Array(out.subtracting(except)), Array(rest.subtracting(except)))
    }

    /// Общие селекторы для id и классов, которые страница встретила
    func forTokens(_ tokens: [String], host: String) -> [String] {
        let prefs = BlockerPrefs.shared
        guard prefs.genericHiding else { return [] }
        var out = Set<String>(), except = Set<String>()
        let suffixes = Self.suffixes(host)
        for (id, r) in lists where prefs.isOn(id) {
            for t in tokens { out.formUnion(r.byToken[t] ?? []) }
            for d in suffixes { except.formUnion(r.exceptDomain[d] ?? []) }
        }
        return Array(out.subtracting(except))
    }

    private static func suffixes(_ host: String) -> [String] {
        let parts = host.lowercased().split(separator: ".")
        return (0..<max(parts.count - 1, 1)).map { parts[$0...].joined(separator: ".") }
    }

    // MARK: Страница

    func install(in c: WKUserContentController) {
        if Perf.off("cos") { return }
        // Perf: части скрипта по одной (cos-obs — без наблюдателя, cos-survey — без опроса общих правил)
        var src = Self.js
        if Perf.off("cos-obs") { src = src.replacingOccurrences(of: "/*obs*/", with: "return;") }
        if Perf.off("cos-survey") { src = src.replacingOccurrences(of: "/*survey*/", with: "return;") }
        if Perf.off("cos-flush") { src = src.replacingOccurrences(of: "/*flush*/", with: "if (dirty) { timer = null; dirty = false; return; }") }
        c.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        c.add(self, contentWorld: .defaultClient, name: "sfCosmetic")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let wv = m.webView, let body = m.body as? [String: Any] else { return }
        let frame = m.frameInfo
        let host = frame.securityOrigin.host.lowercased()
        guard !host.isEmpty else { return }
        // Для сайта блокировка выключена (или YouTube — там свой скрипт) — ничего не прячем
        guard ContentBlocker.shared.wantsRules(wv.url, incognito: BrowserModel.isIncognito(wv)) else { return }
        let selectors: [String], rest: [String]
        if let tokens = body["tokens"] as? [String] {
            guard tokens.count <= 5000 else { return }
            selectors = forTokens(tokens, host: host); rest = []
        } else {
            (selectors, rest) = forHost(host)
        }
        guard !selectors.isEmpty || !rest.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["s": selectors, "r": rest]),
              let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.__sfCos && window.__sfCos.add(\(json))", in: frame, in: .defaultClient) { _ in }
    }

    /// Страница: просит правила для своего сайта, присылает встреченные id и классы (новые — по мере появления).
    /// Наблюдатель за DOM — только childList и только «что-то добавилось»: сбор id/классов идёт одним проходом
    /// по документу по таймеру, а не на каждый узел в обратном вызове (так Speedometer терял 5 очков).
    /// Изменения class не ловим (как uBO): правило по классу, появившемуся позже, сработает при следующем добавлении узлов
    static let js = """
    (function(){
      if (window.__sfCos || !(document instanceof HTMLDocument)) return;
      var post = function(m){ try { window.webkit.messageHandlers.sfCosmetic.postMessage(m); } catch(e){} };
      var style = null, seen = {}, timer = null, dirty = false, rest = [], restSel = null, applied = {};
      var surveyed = 0, misses = 0;
      function sheet(){
        if (style && style.isConnected) return style;
        style = document.createElement('style'); style.id = 'sf-cos';
        (document.head || document.documentElement).appendChild(style);
        return style;
      }
      function hide(list){
        var add = [];
        for (var i = 0; i < list.length; i++) if (!applied[list[i]]) { applied[list[i]] = 1; add.push(list[i]); }
        if (!add.length) return;
        var s = sheet();
        // По одному правилу на селектор: один неверный не ломает остальные
        s.appendChild(document.createTextNode(add.map(function(x){ return x + '{display:none!important}'; }).join('\\n')));
      }
      // Общие правила без id/класса (##[data-ad], ##AD-SLOT) — одним querySelectorAll по склеенному селектору,
      // не чаще раза в секунду, а после десяти промахов подряд — раз в пять секунд; найденное прячется прямо
      // у элемента. Неверные селекторы отсеиваются один раз
      function survey(){ /*survey*/
        if (!rest.length || Date.now() - surveyed < (misses >= 10 ? 5000 : 1000)) return;
        surveyed = Date.now();
        if (restSel === null) {
          var ok = [];
          for (var i = 0; i < rest.length; i++) { try { document.querySelector(rest[i]); ok.push(rest[i]); } catch(e){} }
          restSel = ok.join(',');
        }
        if (!restSel) return;
        var hit; try { hit = document.querySelectorAll(restSel); } catch(e) { restSel = ''; return; }
        misses = hit.length ? 0 : misses + 1;
        for (var j = 0; j < hit.length; j++) hit[j].style.setProperty('display', 'none', 'important');
      }
      // Новые id и классы во всём документе — одним проходом
      function collect(){
        var out = [], all = document.querySelectorAll('[id],[class]');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el.id && !seen['#' + el.id]) { seen['#' + el.id] = 1; out.push('#' + el.id); }
          var cl = el.classList;
          for (var k = 0; k < cl.length; k++) if (!seen['.' + cl[k]]) { seen['.' + cl[k]] = 1; out.push('.' + cl[k]); }
        }
        return out;
      }
      // Вкладка не на экране — проход по документу откладывается до показа (фоновые вкладки с живой лентой
      // иначе сканировали бы себя на каждое изменение); первый проход при старте — всегда
      function flush(force){ /*flush*/
        timer = null;
        if (document.hidden && !force) { dirty = true; return; }
        dirty = false;
        var t = collect();
        if (t.length) post({tokens: t});
        survey();
      }
      document.addEventListener('visibilitychange', function(){ if (!document.hidden && dirty && !timer) timer = setTimeout(flush, 250); });
      window.__sfCos = { add: function(d){
        if (d.r && d.r.length) rest = d.r;
        if (d.s && d.s.length) hide(d.s);
        if (d.r && d.r.length) survey();
      }};
      post({host: 1});
      function start(){
        flush(true); /*obs*/
        // Подрамки (виджеты, встраивания) — без наблюдателя: сам наблюдатель стоит движку по записи на каждое
        // изменение DOM; там хватает проходов по load и чуть позже
        if (window !== window.top) {
          window.addEventListener('load', function(){ flush(); setTimeout(function(){ flush(); }, 2000); });
          return;
        }
        // В обратном вызове — ничего, кроме пометки: он идёт микрозадачей после каждого изменения DOM
        new MutationObserver(function(){
          if (dirty) return;
          dirty = true;
          if (!timer) timer = setTimeout(flush, 250);
        }).observe(document.documentElement, {childList: true, subtree: true});
      }
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
    })();
    """
}
