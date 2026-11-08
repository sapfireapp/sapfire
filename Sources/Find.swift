import AppKit
import SwiftUI
import WebKit

// MARK: - Поиск по странице (⌘F)

@Observable
final class FindController {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: FindController { BrowserModel.current.find }

    var visible = false
    var query = ""
    var total = 0
    var current = 0            // с нуля
    var marks: [Double] = []   // положение совпадений в долях высоты страницы
    var focusToken = 0         // меняется, когда поле надо сфокусировать заново
    @ObservationIgnored private(set) weak var tab: Tab?
    @ObservationIgnored weak var model: BrowserModel?
    init(model: BrowserModel) { self.model = model }
    @ObservationIgnored private var work: DispatchWorkItem?

    func show() {
        if !visible { visible = true }
        focusToken += 1
        search()
    }

    func hide() {
        visible = false
        clear(on: tab)
        tab = nil
        total = 0; current = 0; marks = []
        if let wv = model?.activeTab?.webView { wv.window?.makeFirstResponder(wv) }
    }

    /// Поиск с небольшой задержкой — пока печатаешь.
    func queryChanged() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.search() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    /// Вкладка сменилась или страница перезагрузилась — ищем заново.
    func retarget() {
        guard visible else { return }
        search()
    }

    func search() {
        guard visible else { return }
        let target = model?.activeTab
        if tab !== target { clear(on: tab); tab = target }
        guard let wv = target?.webView else { total = 0; marks = []; return }
        let q = query
        wv.callAsyncJavaScript(Self.script + "return window.__sfFind.run(q);",
                               arguments: ["q": q], in: nil, in: .page) { [weak self] result in
            guard let self, self.query == q else { return }
            let d = (try? result.get()) as? [String: Any]
            self.total = (d?["n"] as? NSNumber)?.intValue ?? 0
            self.marks = (d?["m"] as? [NSNumber])?.map(\.doubleValue) ?? []
            self.current = 0
            if self.total > 0 { self.go(0) }
        }
    }

    func next() { guard total > 0 else { return }; go((current + 1) % total) }
    func prev() { guard total > 0 else { return }; go((current - 1 + total) % total) }

    private func go(_ i: Int) {
        current = i
        tab?.webView?.callAsyncJavaScript("window.__sfFind && window.__sfFind.go(i);",
                                          arguments: ["i": i], in: nil, in: .page, completionHandler: nil)
    }

    private func clear(on t: Tab?) {
        t?.webView?.evaluateJavaScript("window.__sfFind && window.__sfFind.clear();")
    }

    // Подсветка через CSS Highlight API — страница не изменяется.
    private static let script = """
    if (!window.__sfFind) {
      window.__sfFind = {
        ranges: [],
        style() {
          if (document.getElementById('sf-find-style')) return;
          const s = document.createElement('style');
          s.id = 'sf-find-style';
          s.textContent = '::highlight(sf-all){background-color:rgba(255,214,0,.55);color:inherit}' +
                          '::highlight(sf-cur){background-color:#ff9500;color:#000}';
          (document.head || document.documentElement).appendChild(s);
        },
        clear() {
          this.ranges = [];
          if (window.CSS && CSS.highlights) { CSS.highlights.delete('sf-all'); CSS.highlights.delete('sf-cur'); }
        },
        run(q) {
          this.clear();
          if (!q || !document.body) return {n: 0, m: []};
          this.style();
          const ql = q.toLocaleLowerCase();
          const skip = {SCRIPT:1, STYLE:1, NOSCRIPT:1, TEXTAREA:1, TEMPLATE:1};
          const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
            acceptNode(n) { const p = n.parentElement; return (!p || skip[p.tagName]) ? 2 : 1; }
          });
          const H = Math.max(document.documentElement.scrollHeight, document.body.scrollHeight, 1);
          const m = [];
          let n;
          while ((n = w.nextNode()) && this.ranges.length < 3000) {
            const s = n.data.toLocaleLowerCase();
            let i = s.indexOf(ql);
            while (i >= 0) {
              const r = new Range();
              r.setStart(n, i); r.setEnd(n, Math.min(i + q.length, n.data.length));
              const b = r.getBoundingClientRect();
              if (b.width || b.height) { this.ranges.push(r); m.push(Math.min(1, Math.max(0, (b.top + scrollY) / H))); }
              i = s.indexOf(ql, i + ql.length);
            }
          }
          if (window.CSS && CSS.highlights) CSS.highlights.set('sf-all', new Highlight(...this.ranges));
          return {n: this.ranges.length, m};
        },
        go(i) {
          const r = this.ranges[i];
          if (!r) return;
          if (window.CSS && CSS.highlights) CSS.highlights.set('sf-cur', new Highlight(r));
          const b = r.getBoundingClientRect();
          if (b.top < 60 || b.bottom > innerHeight - 60 || b.left < 0 || b.right > innerWidth) {
            const el = r.startContainer.parentElement;
            if (el) el.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'smooth'});
          }
        }
      };
    }
    """
}

// MARK: - Плашка поиска (справа сверху)

struct FindBar: View {
    @Environment(BrowserModel.self) private var model
    private var find: FindController { model.find }
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var find = find
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Find on Page", text: $find.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .frame(width: 170)
                .onChange(of: find.query) { find.queryChanged() }
                .onSubmit {
                    if (NSApp.currentEvent?.modifierFlags ?? []).contains(.shift) { find.prev() } else { find.next() }
                    focused = true
                }
            Text(find.query.isEmpty ? "" : find.total == 0 ? "none" : "\(find.current + 1)/\(find.total)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(find.total == 0 && !find.query.isEmpty ? Color.red.opacity(0.8) : .secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Divider().frame(height: 16)
            FindButton(icon: "chevron.up") { find.prev() }
            FindButton(icon: "chevron.down") { find.next() }
            FindButton(icon: "xmark") { find.hide() }
        }
        .padding(.leading, 12).padding(.trailing, 6)   // (36 − 24) / 2 = 6 — как сверху и снизу у кнопок
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: find.focusToken) { focused = true }
    }
}

private struct FindButton: View {
    let icon: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(hover ? Color.primary.opacity(0.08) : .clear,
                            in: Circle())   // концентрично полукруглому торцу плашки
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Точки совпадений у полосы прокрутки

struct FindMarks: View {
    let tab: Tab
    @Environment(BrowserModel.self) private var model
    private var find: FindController { model.find }

    var body: some View {
        if find.visible, find.tab === tab, !find.marks.isEmpty {
            GeometryReader { g in
                ForEach(Array(find.marks.enumerated()), id: \.offset) { i, f in
                    let cur = i == find.current
                    Circle()
                        .fill(cur ? Color.orange : Color.yellow)
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: cur ? 7 : 5, height: cur ? 7 : 5)
                        .position(x: g.size.width - 6, y: 6 + f * (g.size.height - 12))
                }
            }
            .allowsHitTesting(false)
        }
    }
}
