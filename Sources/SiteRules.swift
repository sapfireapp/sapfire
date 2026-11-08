import AppKit
import WebKit

// MARK: - Правила сайтов для движка: куки, веб-шрифты, автозапуск, демонстрация экрана

/// Из настроек сайтов собираются:
/// • список правил движка (не принимать куки, не грузить веб-шрифты) — действует независимо от блокировщика;
/// • скрипт в начале каждой страницы с политикой автозапуска и демонстрации экрана для её сайта.
/// Сайты на паузе в правила не попадают.
final class SiteRules {
    static let shared = SiteRules()
    private(set) var list: WKContentRuleList?
    private(set) var script = WKUserScript(source: "", injectionTime: .atDocumentStart, forMainFrameOnly: false)
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    func install(in c: WKUserContentController) {
        controllers.add(c)
        c.addUserScript(script)
        if let list { c.add(list) }
    }

    /// Пересобрать правила и скрипт; открытым страницам — новый скрипт (подхватится при следующей загрузке)
    func rebuild() {
        let all = SiteSettings.shared.all.filter { !$0.value.paused }
        // Скрипт
        var policy: [String: [String: String]] = [:]
        for (site, p) in all where p.autoplay != "allow" || p.screenShare != "ask" {
            policy[site] = ["autoplay": p.autoplay, "screen": p.screenShare]
        }
        let json = (try? JSONSerialization.data(withJSONObject: policy)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        script = WKUserScript(source: "(function(M){" + Self.guardJS + "})(\(json));", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        for c in controllers.allObjects {
            let others = c.userScripts.filter { !$0.source.contains("__sfSitePolicy") }
            c.removeAllUserScripts()
            others.forEach(c.addUserScript)
            c.addUserScript(script)
        }
        // Правила движка
        var rules: [[String: Any]] = []
        for (site, p) in all {
            if !p.cookies { rules.append(["trigger": ["url-filter": ".*", "if-domain": ["*" + site]], "action": ["type": "block-cookies"]]) }
            if !p.webFonts { rules.append(["trigger": ["url-filter": ".*", "resource-type": ["font"], "if-domain": ["*" + site]], "action": ["type": "block"]]) }
        }
        let old = list
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules),
              let rulesJSON = String(data: data, encoding: .utf8) else {
            list = nil
            if let old { controllers.allObjects.forEach { $0.remove(old) } }
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "sapfire-sites", encodedContentRuleList: rulesJSON) { l, err in
            DispatchQueue.main.async {
                if let err { NSLog("Sapfire site rules: \(err.localizedDescription)") }
                if let old { self.controllers.allObjects.forEach { $0.remove(old) } }
                self.list = l
                if let l { self.controllers.allObjects.forEach { $0.add(l) } }
            }
        }
    }

    /// Автозапуск: «nosound» — видео и звук сами стартуют только без звука, «deny» — ничего само не играет.
    /// Демонстрация экрана: «deny» — сайт её не получит. По клику или нажатию клавиши всё играет как обычно.
    private static let guardJS = """
    var host = location.hostname.replace(/^www\\./, ''), pol = null;
    for (var k in M) { if (host === k || host.endsWith('.' + k)) { pol = M[k]; break; } }
    window.__sfSitePolicy = pol;
    if (!pol) return;
    if (pol.screen === 'deny' && navigator.mediaDevices) {
      navigator.mediaDevices.getDisplayMedia = function(){ return Promise.reject(new DOMException('Screen sharing is blocked for this site', 'NotAllowedError')); };
    }
    if (pol.autoplay && pol.autoplay !== 'allow') {
      var gesture = 0;
      ['pointerdown', 'mousedown', 'keydown', 'touchstart'].forEach(function(e){
        addEventListener(e, function(){ gesture = Date.now(); }, true);
      });
      function allowed(m){ if (Date.now() - gesture < 1500) return true;
        return pol.autoplay === 'nosound' && (m.muted || m.volume === 0); }
      var play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function(){
        if (allowed(this)) return play.apply(this, arguments);
        return Promise.reject(new DOMException('Autoplay is blocked for this site', 'NotAllowedError'));
      };
      document.addEventListener('play', function(e){ var m = e.target; if (m instanceof HTMLMediaElement && !allowed(m)) m.pause(); }, true);
      document.addEventListener('volumechange', function(e){ var m = e.target; if (m instanceof HTMLMediaElement && !m.paused && !allowed(m)) m.pause(); }, true);
    }
    """
}
