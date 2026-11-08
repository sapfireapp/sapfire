import AppKit
import SwiftUI
import WebKit

// MARK: - Маленькое окно для ссылок (как Little Arc)

/// Ссылки из других программ (и ⌥⌘N) открываются в небольшом окне поверх всего: посмотрел и закрыл —
/// основное окно не засоряется. Понравилась страница — «Open in Sapfire» переносит её вкладкой как есть.
final class LittleWindow: NSWindow {
    private(set) var page: LittlePage!

    static func open(_ url: URL?) {
        let w = LittleWindow(url: url)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Уже открытая страница (вынесли из сплита) — в маленькое окно, как есть; `at` — где отпустили (верх окна у курсора)
    static func open(webView: WKWebView, at p: NSPoint? = nil) {
        let w = LittleWindow(url: nil, webView: webView)
        if let p { w.setFrameTopLeftPoint(NSPoint(x: p.x - 120, y: p.y + 16)) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL?, webView: WKWebView? = nil) {
        let size = NSSize(width: 900, height: 640)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Чуть выше центра экрана, каждое следующее — со сдвигом
        let shift = CGFloat(LittleWindow.count % 6) * 24
        let origin = NSPoint(x: screen.midX - size.width / 2 + shift, y: screen.midY - size.height / 2 + 60 - shift)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        LittleWindow.count += 1
        title = "Little Sapfire"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 420, height: 300)
        tabbingMode = .disallowed
        page = LittlePage(window: self, url: url, webView: webView)
        contentView = NSHostingView(rootView: LittleWindowView(page: page))
    }

    private static var count = 0

    override func close() {
        // Страницу могли уже забрать во вкладку («Open in Sapfire») — её загрузку не обрывать
        if !page.adopted { page.webView.stopLoading() }
        super.close()
    }
}

@Observable
final class LittlePage {
    let webView: WKWebView
    var title = ""
    var url: URL?
    var isLoading = false
    var address = ""
    var editing: Bool
    /// Окно поверх всех (⌃⌘P или кнопка-булавка)
    var onTop = false
    /// Страница ушла во вкладку основного окна — окно закрывается, но страницу не трогает
    @ObservationIgnored var adopted = false
    @ObservationIgnored weak var window: LittleWindow?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    init(window: LittleWindow, url: URL?, webView: WKWebView? = nil) {
        self.window = window
        let m = BrowserModel.shared
        let store = m.currentSpace.isIncognito ? WKWebsiteDataStore.default() : m.currentSpace.dataStore
        let wv = webView ?? WKWebView(frame: .zero, configuration: BrowserModel.makeConfiguration(store: store))
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.isInspectable = true
        wv.navigationDelegate = m.delegate
        wv.uiDelegate = m.delegate
        self.webView = wv
        editing = url == nil && webView == nil
        title = wv.title ?? ""
        self.url = wv.url
        isLoading = wv.isLoading
        observers = [
            wv.observe(\.title, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.title = w.title ?? "" }
            },
            wv.observe(\.url, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.url = w.url }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async {
                    self?.isLoading = w.isLoading
                    if !w.isLoading { HistoryStore.shared.visit(w.url, title: w.title ?? "") }
                }
            },
        ]
        if let url { wv.load(URLRequest(url: url)) }
    }

    func go() {
        guard let u = Omnibox.url(for: address) else { return }
        editing = false
        webView.load(URLRequest(url: u))
        webView.window?.makeFirstResponder(webView)
    }

    /// Перенести страницу вкладкой в основное окно — со всем состоянием (прокрутка, входы, видео)
    func moveToMain() {
        guard url != nil else { return }
        observers = []
        let m = BrowserModel.shared
        webView.removeFromSuperview()
        m.adopt(webView, title: title)
        adopted = true
        window?.close()
        m.mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Перенести в выбранное пространство. У него те же входы — страница переезжает как есть;
    /// другой профиль — открывается там заново, уже с его входами (живую страницу в чужое хранилище не пересадить)
    func move(to sp: Space) {
        guard let u = url else { return }
        let m = BrowserModel.window(showing: sp) ?? BrowserModel.shared
        if m.currentSpaceID != sp.id, let i = m.spaces.firstIndex(where: { $0 === sp }) { m.switchSpace(i) }
        observers = []
        webView.removeFromSuperview()
        if webView.configuration.websiteDataStore === sp.dataStore {
            m.adopt(webView, title: title, in: sp)
            adopted = true
        } else {
            webView.stopLoading()
            m.newTab(url: u, in: sp)
        }
        window?.close()
        m.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

struct LittleWindowView: View {
    @Bindable var page: LittlePage
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 64, height: 1)            // место под «светофор»
                if page.editing {
                    TextField("Search or enter address", text: $page.address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { page.go() }
                        .onAppear { DispatchQueue.main.async { focused = true } }
                } else {
                    Favicon(url: page.url).frame(width: 14, height: 14)
                    Text(page.url?.host ?? page.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .onTapGesture {
                            page.address = page.url?.absoluteString ?? ""
                            page.editing = true
                        }
                    if page.isLoading { ProgressView().controlSize(.mini) }
                }
                Spacer(minLength: 8)
                Button { if let w = page.window { BrowserModel.shared.toggleFloatOnTop(w) } } label: {
                    Image(systemName: page.onTop ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(page.onTop ? Color.accentColor : Color.secondary)
                .help(page.onTop ? "Stop floating on top — ⌃⌘P" : "Float on top — ⌃⌘P")
                // Клик — в текущее пространство; стрелка — выбрать пространство
                Menu {
                    let spaces = BrowserModel.shared.spaces.filter { !$0.isIncognito }
                    let current = BrowserModel.shared.currentSpaceID
                    ForEach(spaces) { sp in
                        Button { page.move(to: sp) } label: {
                            Label(sp.id == current ? "\(sp.name) (current)" : sp.name, systemImage: Symbols.open(sp.icon))
                        }
                    }
                } label: {
                    Label("Open in Sapfire", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .medium))
                } primaryAction: {
                    page.moveToMain()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(page.url == nil)
                .help("Move this page to a tab in Sapfire — the arrow picks the space")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)          // середина — на уровне «светофора»
            .background(WindowDragArea())
            LittleWebHost(webView: page.webView)
        }
        .ignoresSafeArea()
        .frame(minWidth: 420, minHeight: 300)
    }
}

private struct LittleWebHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        webView.frame = v.bounds
        webView.autoresizingMask = [.width, .height]
        v.addSubview(webView)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
