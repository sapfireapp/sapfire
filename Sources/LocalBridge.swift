import AppKit
import WebKit

// MARK: - Подключение страниц к программам на этом Mac

/// Сайты вроде Tripo (DCC Bridge) подключаются к программе на этом же Mac (плагин Blender и т. п.)
/// по ws://127.0.0.1:порт. Движок Safari с защищённой страницы (https) такое не пускает —
/// считает «незащищённым содержимым» (Chrome и Arc для своего компьютера делают исключение).
/// Здесь — то же исключение: для адресов этого Mac страница получает подменный WebSocket,
/// а само подключение держит Sapfire и передаёт сообщения туда и обратно.
/// Только адреса этого Mac (127.0.0.1, localhost, ::1) и только с разрешения для сайта.
final class LocalBridge: NSObject, WKScriptMessageHandler, URLSessionWebSocketDelegate {
    static let shared = LocalBridge()

    private struct Conn {
        let task: URLSessionWebSocketTask
        weak var wv: WKWebView?
        let frame: WKFrameInfo
        let id: String
        /// Откуда открыли (схема://хост:порт): писать и закрывать может только та же рамка-источник —
        /// чужая рамка на той же странице (реклама, виджет) до подключения не дотянется
        let origin: String
    }
    private var conns: [Int: Conn] = [:]            // по taskIdentifier
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]           // только этот Mac — без прокси
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()
    /// Решения инкогнито — только до закрытия (на диск не пишем)
    private var sessionDecisions: [String: Bool] = [:]
    private var asking: [String: [(Bool) -> Void]] = [:]
    private static let key = "localConnect"

    func install(in c: WKUserContentController) {
        c.addUserScript(WKUserScript(source: Self.js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        c.add(self, name: "sfLocalWS")
    }

    static func isLocal(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "ws", let h = url.host?.lowercased() else { return false }
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }

    // MARK: Страница → Sapfire

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView, let body = message.body as? [String: Any],
              let op = body["op"] as? String, let id = body["id"] as? String, id.count <= 64 else { return }
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        let originKey = "\(origin.protocol)://\(origin.host):\(origin.port)"
        switch op {
        case "open":
            // Только с защищённой страницы: для http это проверяет лишь скрипт, а его подменит любой в сети
            guard let s = body["url"] as? String, let url = URL(string: s), Self.isLocal(url), origin.protocol == "https" else {
                event(wv, frame, id, "error"); event(wv, frame, id, "close", 1006); return
            }
            // Ключ сайта — как у остальных настроек (без «www.»), иначе Settings → Websites видел бы другой сайт
            let site = SiteSettings.site(URL(string: "\(origin.protocol)://\(origin.host)")) ?? origin.host
            let persistent = wv.configuration.websiteDataStore.isPersistent
            permission(site: site, port: url.port, persistent: persistent) { [weak self, weak wv] ok in
                guard let self, let wv else { return }
                guard ok else { self.event(wv, frame, id, "error"); self.event(wv, frame, id, "close", 1006); return }
                var req = URLRequest(url: url)
                // Сервер может сверять, откуда подключаются, — как у обычного браузера
                let port = origin.port == 0 ? "" : ":\(origin.port)"
                req.setValue("\(origin.protocol)://\(origin.host)\(port)", forHTTPHeaderField: "Origin")
                if let p = body["protocols"] as? [String], !p.isEmpty {
                    req.setValue(p.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
                }
                let task = self.session.webSocketTask(with: req)
                self.conns[task.taskIdentifier] = Conn(task: task, wv: wv, frame: frame, id: id, origin: originKey)
                task.resume()
                self.receive(task)
            }
        case "send":
            guard let c = conn(wv, id, originKey) else { return }
            if let t = body["text"] as? String {
                c.task.send(.string(t)) { _ in }
            } else if let b = body["b64"] as? String, let d = Data(base64Encoded: b) {
                c.task.send(.data(d)) { _ in }
            }
        case "close":
            guard let c = conn(wv, id, originKey) else { return }
            let code = URLSessionWebSocketTask.CloseCode(rawValue: body["code"] as? Int ?? 1000) ?? .normalClosure
            c.task.cancel(with: code, reason: (body["reason"] as? String)?.data(using: .utf8))
        default: break
        }
    }

    private func conn(_ wv: WKWebView, _ id: String, _ origin: String) -> Conn? {
        conns.values.first { $0.wv === wv && $0.id == id && $0.origin == origin }
    }

    /// Страница ушла — её подключения закрыть
    func closeAll(for wv: WKWebView) {
        for (k, c) in conns where c.wv === wv || c.wv == nil {
            c.task.cancel(with: .goingAway, reason: nil)
            conns[k] = nil
        }
    }

    // MARK: Sapfire → страница

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            DispatchQueue.main.async {
                guard let self, let task, let c = self.conns[task.taskIdentifier] else { return }
                guard let wv = c.wv else { task.cancel(with: .goingAway, reason: nil); self.conns[task.taskIdentifier] = nil; return }
                switch result {
                case .success(.string(let s)): self.event(wv, c.frame, c.id, "text", s)
                case .success(.data(let d)): self.event(wv, c.frame, c.id, "bin", d.base64EncodedString())
                case .success: break
                case .failure: return       // закрытие придёт через делегата
                }
                self.receive(task)
            }
        }
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        guard let c = conns[t.taskIdentifier], let wv = c.wv else { return }
        event(wv, c.frame, c.id, "open", p ?? "")
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask,
                    didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let c = conns.removeValue(forKey: t.taskIdentifier), let wv = c.wv else { return }
        event(wv, c.frame, c.id, "close", code.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = conns.removeValue(forKey: task.taskIdentifier), let wv = c.wv else { return }
        if error != nil { event(wv, c.frame, c.id, "error") }
        event(wv, c.frame, c.id, "close", 1006)
    }

    private func event(_ wv: WKWebView, _ frame: WKFrameInfo, _ id: String, _ type: String, _ a: Any = NSNull(), _ b: Any = NSNull()) {
        guard let data = try? JSONSerialization.data(withJSONObject: [id, type, a, b]),
              let args = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.__sfLWS && window.__sfLWS.ev.apply(null, \(args))", in: frame, in: .page) { _ in }
    }

    // MARK: Разрешение для сайта

    /// Сохранённые ответы «пускать к программам на Mac» (Settings → Websites)
    static var decisions: [String: Bool] {
        get {
            let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
            // Старые записи были с «www.» — под общим ключом сайта (без www — главнее)
            var out: [String: Bool] = [:]
            for (k, v) in d.sorted(by: { $0.key.hasPrefix("www.") && !$1.key.hasPrefix("www.") }) {
                out[k.hasPrefix("www.") ? String(k.dropFirst(4)) : k] = v
            }
            return out
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private func permission(site: String, port: Int?, persistent: Bool, _ done: @escaping (Bool) -> Void) {
        let saved = Self.decisions
        if let v = persistent ? saved[site] : sessionDecisions[site] { done(v); return }
        if asking[site] != nil { asking[site]!.append(done); return }
        asking[site] = [done]
        let a = NSAlert()
        a.messageText = "Allow “\(site)” to connect to an app on this Mac?"
        a.informativeText = "It wants to talk to a program running on your Mac\(port.map { " (port \($0))" } ?? "") — usually a plugin like a Blender bridge. Safari blocks this on secure pages; Sapfire can pass it through. Nothing leaves your Mac."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don’t Allow")
        let ok = a.runModal() == .alertFirstButtonReturn
        if persistent {
            var d = saved; d[site] = ok
            Self.decisions = d
        } else {
            sessionDecisions[site] = ok
        }
        let waiting = asking.removeValue(forKey: site) ?? []
        waiting.forEach { $0(ok) }
    }

    /// Закрыли инкогнито — его решения забыть
    func forgetSession() { sessionDecisions = [:] }

    // MARK: Подменный WebSocket для адресов этого Mac

    static let js = """
    (function(){
      if (window.__sfLWS || location.protocol !== 'https:' || !window.WebSocket) return;
      var Native = window.WebSocket, socks = {};
      // Номер подключения — случайный: соседняя рамка его не угадает
      function newId(){ try { return crypto.randomUUID(); } catch(e) { return String(Date.now()) + Math.random().toString(16).slice(2); } }
      var LOCAL = /^ws:\\/\\/(127\\.0\\.0\\.1|localhost|\\[::1\\])(:\\d+)?(\\/|\\?|$)/i;
      function post(m){ try { window.webkit.messageHandlers.sfLocalWS.postMessage(m); } catch(e){} }
      function toB64(d){
        var blob = d instanceof Blob ? d : new Blob([d]);
        return blob.arrayBuffer().then(function(ab){
          var u = new Uint8Array(ab), s = '';
          for (var i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000));
          return btoa(s);
        });
      }
      function fromB64(b, type){
        var s = atob(b), u = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
        return type === 'arraybuffer' ? u.buffer : new Blob([u]);
      }
      class Shim extends EventTarget {
        constructor(url, protocols){
          super();
          this.url = String(url); this.readyState = 0; this.protocol = ''; this.extensions = '';
          this.binaryType = 'blob'; this.bufferedAmount = 0;
          this.onopen = this.onmessage = this.onerror = this.onclose = null;
          this._id = newId(); socks[this._id] = this;
          var p = protocols == null ? [] : (Array.isArray(protocols) ? protocols : [protocols]);
          post({op: 'open', id: this._id, url: this.url, protocols: p.map(String)});
        }
        send(d){
          if (this.readyState === 0) throw new DOMException('Still in CONNECTING state.', 'InvalidStateError');
          if (this.readyState !== 1) return;
          var id = this._id;
          if (typeof d === 'string') post({op: 'send', id: id, text: d});
          else toB64(d).then(function(b){ post({op: 'send', id: id, b64: b}); });
        }
        close(code, reason){
          if (this.readyState >= 2) return;
          this.readyState = 2;
          post({op: 'close', id: this._id, code: code || 1000, reason: reason || ''});
        }
        _fire(type, init){
          var e = type === 'message' ? new MessageEvent('message', init)
                : type === 'close' ? new CloseEvent('close', init) : new Event(type);
          var h = this['on' + type];
          if (typeof h === 'function') { try { h.call(this, e); } catch(x) { setTimeout(function(){ throw x; }); } }
          this.dispatchEvent(e);
        }
      }
      ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function(k, i){ Shim[k] = i; Shim.prototype[k] = i; });
      window.__sfLWS = { ev: function(id, type, a, b){
        var s = socks[id]; if (!s) return;
        var origin = s.url.replace(/^(ws:\\/\\/[^\\/?]+).*$/i, '$1');
        if (type === 'open') { s.readyState = 1; s.protocol = a || ''; s._fire('open'); }
        else if (type === 'text') s._fire('message', {data: a, origin: origin});
        else if (type === 'bin') s._fire('message', {data: fromB64(a, s.binaryType), origin: origin});
        else if (type === 'error') s._fire('error');
        else if (type === 'close') {
          s.readyState = 3; delete socks[id];
          s._fire('close', {code: a || 1006, reason: b || '', wasClean: a === 1000});
        }
      }};
      // Остальные адреса — настоящий WebSocket без изменений (и для наследников: class X extends WebSocket)
      var WS = new Proxy(Native, {
        construct: function(target, args, newTarget){
          if (args.length && LOCAL.test(String(args[0]))) return new Shim(args[0], args[1]);
          return Reflect.construct(target, args, newTarget);
        }
      });
      window.WebSocket = WS;
    })();
    """
}
