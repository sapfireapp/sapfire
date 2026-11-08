import AppKit
import SwiftUI

// MARK: - Мягкий градиент панели (пространство)

/// Два размытых цветных пятна поверх цвета панели — как мягкая «аура»:
/// первое — внизу слева, второе — вверху слева, справа остаётся светлый цвет самой панели
struct SpaceGlow: Codable, Equatable {
    var h1 = 0.6, s1 = 0.9, b1 = 0.95       // нижнее пятно (по умолчанию синее)
    var h2 = 0.07, s2 = 0.75, b2 = 0.98     // верхнее пятно (по умолчанию оранжевое)
    /// Третье пятно (h, s, b) — справа вверху, по умолчанию бледная мята; nil — по умолчанию
    var t3: [Double]?
    var h3: Double { get { t3?[0] ?? 0.42 } set { t3 = [newValue, s3, b3] } }
    var s3: Double { get { t3?[1] ?? 0.14 } set { t3 = [h3, newValue, b3] } }
    var b3: Double { get { t3?[2] ?? 0.98 } set { t3 = [h3, s3, newValue] } }
    var c3: Color { Color(hue: h3, saturation: s3, brightness: b3) }
    /// Расклад пятен: nil / 0 — как на эталоне (оба слева), иначе — случайный, но всегда один и тот же для числа
    var seed: Int?
    /// Сколько пятен (1…3, nil — три): по порядку верхнее, нижнее, угловое
    var count: Int?
    var spots: Int { get { count ?? 3 } set { count = newValue == 3 ? nil : max(1, min(3, newValue)) } }
    /// Размытие 0…1 (nil — по умолчанию)
    var blur: Double?
    var blurAmount: Double { blur ?? 0.55 }

    var c1: Color { Color(hue: h1, saturation: s1, brightness: b1) }
    var c2: Color { Color(hue: h2, saturation: s2, brightness: b2) }
}

/// Положение и размер пятна в долях панели (x — от ширины, y — от высоты, размер — от r)
struct GlowBlob { var x, y, w, h: Double }

/// Простой генератор случайных чисел от зерна (одинаковый на любом Mac)
struct SplitMix {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> Double {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

struct SpaceGlowView: View {
    let glow: SpaceGlow

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            // Пятно — от ширины панели, но не меньше трети высоты: в высокой панели оно не мельчает
            let r = max(w * 0.95, h * 0.32)
            let spot = glow.spot
            let n = glow.spots
            let d = glow.direction
            ZStack {
                // Как в Mus3: первые два цвета — линейный градиент на всю панель, без просветов;
                // один цвет — переход от цвета панели к нему
                LinearGradient(colors: n >= 2 ? [glow.c2, glow.c1] : [glow.c2, glow.c2.opacity(0)],
                               startPoint: d.from, endPoint: d.to)
                // Третий — мягкое пятно в месте от зерна; размытие — только его
                if n >= 3 {
                    Ellipse().fill(glow.c3)
                        .frame(width: r * spot.w, height: r * spot.h)
                        .position(x: w * spot.x, y: h * spot.y)
                        .blur(radius: r * (0.04 + glow.blurAmount * 0.5))
                }
            }
            .animation(.easeInOut(duration: 0.5), value: glow.seed)
            .frame(width: w, height: h)
            .clipped()
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

extension SpaceGlow {
    /// Направление линейного градиента — одно из восьми через 45°; кубик поворачивает его (как в Mus3).
    /// Без зерна — как на эталоне: верхний цвет сверху, нижний снизу
    var direction: (from: UnitPoint, to: UnitPoint) {
        let dirs: [(UnitPoint, UnitPoint)] = [
            (.top, .bottom), (.topTrailing, .bottomLeading), (.trailing, .leading), (.bottomTrailing, .topLeading),
            (.bottom, .top), (.bottomLeading, .topTrailing), (.leading, .trailing), (.topLeading, .bottomTrailing),
        ]
        guard let s = seed, s != 0 else { return dirs[0] }
        var rng = SplitMix(UInt64(bitPattern: Int64(s)) ^ 0xD1B54A32D192ED03)
        return dirs[min(7, Int(rng.next() * 8))]
    }

    /// Третье пятно: без зерна — в правом верхнем углу (как было), с зерном — в случайном месте панели
    var spot: GlowBlob {
        guard let s = seed, s != 0 else { return GlowBlob(x: 1.1, y: 0.06, w: 1.2, h: 0.9) }
        var rng = SplitMix(UInt64(bitPattern: Int64(s)) ^ 0x9E3779B97F4A7C15)
        func r(_ a: Double, _ b: Double) -> Double { a + (b - a) * rng.next() }
        return GlowBlob(x: r(-0.1, 1.1), y: r(0.0, 1.0), w: r(0.9, 1.4), h: r(0.6, 1.1))
    }
}

/// Цвет пространства:
/// верхний ряд — «без цвета» и пресеты (цвет или градиент; выбранный пресет запоминает все правки);
/// слева — включатель градиента, его пятна (до трёх), кубик, размытие и прозрачность; справа — H / S / V
/// для цвета панели или выбранного пятна (повторный клик по пятну — снова цвет панели)
struct SpaceColorEditor: View {
    @Binding var hue: Double
    @Binding var sat: Double
    @Binding var bri: Double
    @Binding var glow: SpaceGlow?
    @Binding var glass: Double
    var willChange: () -> Void = {}

    @State private var slots = ColorSlots.load()
    @State private var selectedSlot: Int?
    /// 0 — панель, иначе номер пятна (1 — нижнее, 2 — верхнее, 3 — угловое)
    @State private var editing = 0
    /// Выключенный градиент — чтобы галочка вернула его таким же
    @State private var lastGlow: SpaceGlow?

    static let shown = 10
    /// Ширина редактора: 11 кружков верхнего ряда стоят равномерно от края до края,
    /// и всё остальное (пятна, кубик, ползунки, промежутки, строки) ложится на тот же шаг
    static let cell: CGFloat = 24, gap: CGFloat = 6
    static let width: CGFloat = 11 * cell + 10 * gap
    private let cell = SpaceColorEditor.cell
    private let gap = SpaceColorEditor.gap

    /// Значок на кружке — тёмный на светлом цвете панели, светлый на тёмном
    private var knobInk: Color { hue >= 0 && bri < 0.55 ? .white.opacity(0.8) : .black.opacity(0.6) }

    private var panel: Color { hue < 0 ? Color(nsColor: .windowBackgroundColor) : Color(hue: hue, saturation: sat, brightness: bri) }

    /// Что лежит в выбранном пресете
    private var snapshot: ColorSlots.HSV? {
        guard hue >= 0 || glow != nil else { return nil }
        return .init(h: hue, s: sat, v: bri, glow: glow, glass: glass > 0 ? glass : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // Пресеты — на той же сетке, что и кружки градиента под ними
            HStack(spacing: gap) {
                Button { willChange(); selectedSlot = nil; hue = -1 } label: {
                    // Тот же кружок, что у пресетов, с крестиком; выбран — синее кольцо
                    Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.2)
                        .overlay(Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary))
                        .frame(width: cell - 4, height: cell - 4).padding(2)
                        .overlay(Circle().strokeBorder(hue < 0 ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .help("No color")
                ForEach(0..<Self.shown, id: \.self) { slot($0) }
            }
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    // Включатель и пятна — бусинами на одной нити: О-О-О-О
                    HStack(spacing: 0) {
                        toggle
                        ForEach(0..<3, id: \.self) { i in
                            link
                            spotCell(i)
                        }
                        link
                        dice
                    }
                    .frame(height: cell)
                    GradientSlider(value: Binding(get: { glow?.blurAmount ?? 0.55 }, set: { v in willChange(); glow?.blur = v }),
                                   colors: [Color.primary.opacity(0.5), Color.primary.opacity(0.05)],
                                   knob: panel, icon: AnyView(BlurIcon().fill(knobInk)))
                        .disabled(glow == nil).opacity(glow == nil ? 0.4 : 1)
                        .help("Blur — from crisp spots to soft haze")
                    GradientSlider(value: Binding(get: { glass }, set: { v in willChange(); glass = v }),
                                   colors: [panel, panel.opacity(0.15)],
                                   knob: panel, icon: AnyView(GlassIcon().foregroundStyle(knobInk).opacity(glass == 0 ? 0.35 : 1)),
                                   offStop: true)
                        .help(glass == 0 ? "Glass is off — drag right to see the page through the sidebar when it slides out"
                                         : "Glass — the page shows through the sidebar when it slides out over it. Far left — off")
                }
                .frame(width: 5 * cell + 4 * gap)
                VStack(spacing: gap) {
                    let h = max(0, value(\.h1, hue))
                    GradientSlider(value: binding(\.h1, \.h2, \.h3, $hue),
                                   colors: stride(from: 0.0, through: 1.0, by: 0.1).map { Color(hue: $0, saturation: 0.6, brightness: 0.95) },
                                   knob: editingColor)
                        .help("Hue")
                    GradientSlider(value: binding(\.s1, \.s2, \.s3, $sat),
                                   colors: [Color(hue: h, saturation: 0, brightness: 0.95), Color(hue: h, saturation: 1, brightness: 0.95)],
                                   knob: editingColor)
                        .help("Saturation")
                    GradientSlider(value: binding(\.b1, \.b2, \.b3, $bri),
                                   colors: [.black, Color(hue: h, saturation: value(\.s1, sat), brightness: 1)],
                                   knob: editingColor)
                        .help("Brightness")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: Self.width)
        // Выбранный пресет запоминает каждую правку: цвет, пятна, разброс, размытие, прозрачность
        .onChange(of: snapshot) { _, c in
            if let i = selectedSlot, let c { slots[i] = c; ColorSlots.save(slots) }
        }
    }

    // MARK: Пятна

    /// Порядок кружков: верхнее, нижнее, угловое
    private static let order = [2, 1, 3]
    private var spotCount: Int { glow?.spots ?? 0 }

    private func spotColor(_ k: Int) -> Color {
        guard let g = glow else { return .clear }
        return k == 1 ? g.c1 : k == 2 ? g.c2 : g.c3
    }

    private var editingColor: Color { editing == 0 ? panel : spotColor(editing) }

    /// Значение под ползунком: у пятна — его, иначе — панели
    private func value(_ kp1: WritableKeyPath<SpaceGlow, Double>, _ base: Double) -> Double {
        guard editing != 0, let g = glow else { return base }
        let kp = spotPath(kp1)
        return g[keyPath: kp]
    }

    private func spotPath(_ kp1: WritableKeyPath<SpaceGlow, Double>) -> WritableKeyPath<SpaceGlow, Double> {
        let all: [[WritableKeyPath<SpaceGlow, Double>]] = [[\.h1, \.s1, \.b1], [\.h2, \.s2, \.b2], [\.h3, \.s3, \.b3]]
        let col = all[0].firstIndex(of: kp1) ?? 0
        return all[max(0, min(2, editing - 1))][col]
    }

    private func binding(_ k1: WritableKeyPath<SpaceGlow, Double>, _ k2: WritableKeyPath<SpaceGlow, Double>,
                         _ k3: WritableKeyPath<SpaceGlow, Double>, _ base: Binding<Double>) -> Binding<Double> {
        guard editing != 0, glow != nil else {
            return Binding(get: { max(0, base.wrappedValue) },
                           set: { v in willChange(); if base.wrappedValue < 0 || hue < 0 { hue = max(0, hue) }; base.wrappedValue = v })
        }
        let kp = editing == 1 ? k1 : editing == 2 ? k2 : k3
        return Binding(get: { glow?[keyPath: kp] ?? 0 }, set: { v in willChange(); glow?[keyPath: kp] = v })
    }

    private var toggle: some View {
        let on = glow != nil
        return Button {
            willChange()
            withAnimation(.easeInOut(duration: 0.3)) {
                if on { lastGlow = glow; glow = nil; editing = 0 }
                else { glow = lastGlow ?? SpaceGlow() }
            }
        } label: {
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .opacity(on ? 1 : 0.35)
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black.opacity(0.85)) }
            }
            .frame(width: cell - 2, height: cell - 2)
            .frame(width: cell, height: cell)
            .contentShape(Circle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .help(on ? "Turn off the gradient" : "Gradient")
    }

    @ViewBuilder private func spotCell(_ i: Int) -> some View {
        let k = Self.order[i]
        if glow != nil && i < spotCount {
            Button { editing = editing == k ? 0 : k } label: {
                Circle().fill(spotColor(k))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .frame(width: cell - 4, height: cell - 4).padding(2)
                    .overlay(Circle().strokeBorder(editing == k ? Color.accentColor : .clear, lineWidth: 2))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .help(editing == k ? "Back to the panel color" : "Edit this spot")
            .contextMenu {
                Button("Remove Spot") {
                    willChange()
                    glow?.spots = max(1, spotCount - 1)
                    if editing == k { editing = 0 }
                }
                .disabled(spotCount <= 1)
            }
        } else {
            Button {
                willChange()
                if glow == nil { glow = lastGlow ?? SpaceGlow(); glow?.spots = 1 } else { glow?.spots = min(3, spotCount + 1) }
                editing = Self.order[max(0, (glow?.spots ?? 1) - 1)]
            } label: {
                Circle().strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .overlay(Image(systemName: "plus").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary))
                    .frame(width: cell - 4, height: cell - 4).padding(2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .help("Add a gradient spot")
        }
    }

    /// Нить между кружками градиента (заходит под края кружков)
    private var link: some View {
        Capsule().fill(Color.primary.opacity(0.22))
            .frame(width: gap + 6, height: 1.5)
            .padding(.horizontal, -3)
            .zIndex(-1)
    }

    private var dice: some View {
        // Разброс пятен; правый клик — исходный расклад, копировать / вставить seed
        Button {
            willChange()
            glow?.seed = Int.random(in: 1...999_999)
        } label: {
            // Кубик в кружке — бусина на той же нити, что и пятна
            DiceIcon().fill(Color.primary.opacity(0.7), style: FillStyle(eoFill: true))
                .frame(width: 11, height: 11)
                .frame(width: cell - 4, height: cell - 4)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.2))
                .padding(2)
                .frame(width: cell, height: cell).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(glow == nil).opacity(glow == nil ? 0.4 : 1)
        .help("Shuffle the spots")
        .contextMenu {
            Button("Original Layout") { willChange(); glow?.seed = nil }
            Button("Copy Seed") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(glow?.seed ?? 0), forType: .string)
            }
            Button("Paste Seed") {
                if let s = NSPasteboard.general.string(forType: .string).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                    willChange(); glow?.seed = s
                }
            }
        }
    }

    // MARK: Пресеты

    @ViewBuilder private func slot(_ i: Int) -> some View {
        let on = selectedSlot == i
        if let c = slots[i] {
            Button {
                if on { selectedSlot = nil; return }       // повторный клик — снять выбор
                willChange()
                selectedSlot = i
                withAnimation(.easeInOut(duration: 0.3)) {
                    hue = c.h; sat = c.s; bri = c.v
                    glow = c.glow
                    glass = c.glass ?? 0
                }
                editing = 0
            } label: {
                Group {
                    let base = c.h < 0 ? Color(nsColor: .windowBackgroundColor) : Color(hue: c.h, saturation: c.s, brightness: c.v)
                    if let gl = c.glow { GlowSwatch(panel: base, glow: gl) } else { Circle().fill(base) }
                }
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .frame(width: cell - 4, height: cell - 4).padding(2)
                .overlay(Circle().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .contextMenu {
                Button("Replace with Current") { if let s = snapshot { slots[i] = s; ColorSlots.save(slots) } }
                Button("Remove") { slots[i] = nil; ColorSlots.save(slots); if on { selectedSlot = nil } }
            }
        } else {
            // Пустой: сохранить сюда текущий цвет или градиент и дальше запоминать правки
            Button {
                if on { selectedSlot = nil; return }
                selectedSlot = i
                if let s = snapshot { slots[i] = s; ColorSlots.save(slots) }
            } label: {
                Circle().strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.22),
                                      style: StrokeStyle(lineWidth: on ? 2 : 1, dash: on ? [] : [3, 2]))
                    .overlay(Image(systemName: "plus").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary))
                    .frame(width: cell - 4, height: cell - 4).padding(2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .help("Save the current color or gradient here")
        }
    }
}

/// Маленький кружок с градиентом — для ячейки палитры
struct GlowSwatch: View {
    let panel: Color
    let glow: SpaceGlow
    var body: some View {
        ZStack {
            panel
            SpaceGlowView(glow: glow)
        }
        .clipShape(Circle())
    }
}

/// Значок размытия: круг, в нём четыре крупные точки и восемь мелких вокруг
struct BlurIcon: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height), c = CGPoint(x: r.midX, y: r.midY)
        var p = Path(ellipseIn: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
        func dot(_ x: Double, _ y: Double, _ d: Double) {
            p.addEllipse(in: CGRect(x: c.x + x * s - d * s / 2, y: c.y + y * s - d * s / 2, width: d * s, height: d * s))
        }
        // Точки — дырки в круге (чётно-нечётная заливка)
        for (x, y) in [(-0.105, -0.105), (0.105, -0.105), (-0.105, 0.105), (0.105, 0.105)] { dot(x, y, 0.18) }
        for (x, y) in [(-0.105, -0.27), (0.105, -0.27), (-0.105, 0.27), (0.105, 0.27),
                       (-0.27, -0.105), (-0.27, 0.105), (0.27, -0.105), (0.27, 0.105)] { dot(x, y, 0.06) }
        return p
    }
    func fill(_ c: Color) -> some View { self.fill(c, style: FillStyle(eoFill: true)) }
}

/// Значок стекла: сплошной круг и кольцо поверх него, с зазором вокруг кольца
struct GlassIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let d = s * 0.66, lw = s * 0.08, gap = s * 0.07
            let a = CGRect(x: 0, y: 0, width: d, height: d)
            let b = CGRect(x: s - d - lw / 2, y: s - d - lw / 2, width: d, height: d)
            ctx.fill(Path(ellipseIn: a), with: .foreground)
            // Зазор: стереть полосу вдоль кольца, потом нарисовать само кольцо
            var clear = ctx
            clear.blendMode = .clear
            clear.stroke(Path(ellipseIn: b), with: .foreground, lineWidth: lw + gap * 2)
            ctx.stroke(Path(ellipseIn: b), with: .foreground, lineWidth: lw)
        }
    }
}

/// Кубик: скруглённый квадрат с пятью точками-дырками
struct DiceIcon: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height)
        let o = CGPoint(x: r.midX - s / 2, y: r.midY - s / 2)
        var p = Path(roundedRect: CGRect(origin: o, size: CGSize(width: s, height: s)), cornerRadius: s * 0.22)
        let d = s * 0.17
        for (x, y) in [(0.3, 0.3), (0.7, 0.3), (0.5, 0.5), (0.3, 0.7), (0.7, 0.7)] {
            p.addEllipse(in: CGRect(x: o.x + x * s - d / 2, y: o.y + y * s - d / 2, width: d, height: d))
        }
        return p
    }
}
