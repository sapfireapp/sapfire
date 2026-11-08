import AppKit
import SwiftUI

// MARK: - Значок и цвет пространства или папки — сеткой во всплывающем окне

enum Symbols {
    /// Значки на выбор — только те, что есть в системе
    static let all: [String] = [
        "person", "person.2", "house", "building.2", "briefcase", "graduationcap", "book", "books.vertical",
        "bookmark", "star", "heart", "bolt", "flame", "leaf", "tree", "drop",
        "sun.max", "moon", "cloud", "snowflake", "globe.americas", "map", "airplane", "car",
        "bicycle", "tram", "cart", "bag", "creditcard", "gift", "gamecontroller", "puzzlepiece",
        "paintbrush", "paintpalette", "pencil", "camera", "film", "hifispeaker", "headphones", "mic",
        "tv", "display", "macbook", "keyboard", "curlybraces.square", "terminal", "cube", "hammer",
        "wrench.and.screwdriver", "flask", "chart.bar", "brain", "stethoscope", "cross.case", "pawprint", "fork.knife",
        "cup.and.saucer", "birthday.cake", "trophy", "flag", "bell", "lightbulb", "bubble.left", "envelope",
        "phone", "calendar", "newspaper", "doc.text", "folder", "tray", "archivebox", "lock",
        "key", "shield", "sparkles", "crown", "eye", "hand.raised", "figure.run", "dumbbell",
    ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil && Symbols.hasStates($0) }

    private static func exists(_ n: String) -> Bool { NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil }

    /// У значка есть пара «открыто / закрыто» (контур и заливка — сам или в кружке)
    static func hasStates(_ name: String) -> Bool { exists(name + ".fill") || exists(name + ".circle.fill") }

    /// Контурный вариант — раскрытая папка, другое пространство. Без своей заливки — в кружке (пара к залитому кружку)
    static func open(_ name: String) -> String {
        exists(name + ".fill") || !exists(name + ".circle.fill") ? name : name + ".circle"
    }

    /// Залитый вариант — свёрнутая папка, текущее пространство. Без своей заливки — залитый кружок
    static func filled(_ name: String) -> String {
        if exists(name + ".fill") { return name + ".fill" }
        if exists(name + ".circle.fill") { return name + ".circle.fill" }
        return name
    }

}

struct IconColorPicker: View {
    @Binding var icon: String
    @Binding var hue: Double
    @Binding var sat: Double
    @Binding var bri: Double
    /// Перед первой правкой (одна точка отмены ⌘Z на всё окно)
    var willChange: () -> Void = {}
    /// Градиент панели (только у пространства; у папки — nil)
    var glow: Binding<SpaceGlow?>? = nil
    /// Прозрачность панели 0…1 (только у пространства)
    var glass: Binding<Double>? = nil
    @State private var touched = false
    private func change(_ f: () -> Void) {
        if !touched { touched = true; willChange() }
        f()
    }

    /// Ячейка значка: сетка значков ровно по ширине цветового блока (8 ячеек + промежутки + поля 4)
    static let icon: CGFloat = (SpaceColorEditor.width - 8 - 7 * 4) / 8

    private var current: Color { hue < 0 ? Color(white: 0.6) : Color(hue: hue, saturation: sat, brightness: bri) }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.icon), spacing: 4), count: 8), spacing: 4) {
                    ForEach(Symbols.all, id: \.self) { s in
                        let on = s == icon
                        Button { change { icon = s } } label: {
                            Image(systemName: Symbols.filled(s))
                                .font(.system(size: 15))
                                // Значок — насыщенным вариантом цвета: на светлой пастели он был бы почти не виден
                                .foregroundStyle(on ? (hue < 0 ? Color.primary : Color(hue: hue, saturation: max(sat, 0.65), brightness: min(bri, 0.8))) : Color.secondary)
                                .frame(width: Self.icon, height: Self.icon)
                                .background(on ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .circular))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .circular).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(s)
                    }
                }
                .padding(4)
            }
            .frame(height: Self.icon * 5 + 4 * 4 + 8)

            Divider()
            if let glow, let glass {
                // Пространство: пресеты, градиент из пятен, размытие и прозрачность панели
                SpaceColorEditor(hue: $hue, sat: $sat, bri: $bri, glow: glow, glass: glass,
                                 willChange: { if !touched { touched = true; willChange() } })
            } else {
                HSVColorBlock(hue: $hue, sat: $sat, bri: $bri, willChange: willChange)
            }
        }
        .padding(16)
        .frame(width: SpaceColorEditor.width + 32)
        .onAppear { BrowserModel.shared.popovers += 1 }
        .onDisappear { BrowserModel.shared.popovers = max(0, BrowserModel.shared.popovers - 1) }
    }

}

/// Цвет: своя палитра из 15 ячеек и ползунки H, S, V (окно значка пространства/папки, цвета режима чтения)
/// Градиент для палитры: что сохранить в ячейку и как применить ячейку (только у пространства)
struct GradientSlot {
    let current: () -> ColorSlots.HSV?
    let apply: (ColorSlots.HSV) -> Void
}

struct HSVColorBlock: View {
    @Binding var hue: Double
    @Binding var sat: Double
    @Binding var bri: Double
    var allowNone = true
    var willChange: () -> Void = {}
    var gradient: GradientSlot? = nil
    /// Что положить в ячейку: с градиентом — панель и пятна, иначе — текущий цвет
    private var snapshot: ColorSlots.HSV? {
        if let g = gradient, let c = g.current() { return c }
        return hue >= 0 ? .init(h: hue, s: sat, v: bri) : nil
    }
    @State private var touched = false
    @State private var slots = ColorSlots.load()
    /// Выбранная ячейка палитры: одна; пока выбрана, ползунки правят и её цвет
    @State private var selectedSlot: Int?

    private func change(_ f: () -> Void) {
        if !touched { touched = true; willChange() }
        f()
    }

    /// Правка ползунком: цвет пространства/папки и выбранная ячейка палитры
    private func slide(_ f: () -> Void) {
        change(f)
        if let i = selectedSlot, let c = snapshot { slots[i] = c; ColorSlots.save(slots) }
    }

    private var current: Color { hue < 0 ? Color(white: 0.6) : Color(hue: hue, saturation: sat, brightness: bri) }

    var body: some View {
            HStack(alignment: .top, spacing: 18) {
                // Своя палитра: 15 ячеек. Пустая — сохранить текущий цвет, полная — применить, правый клик — убрать
                VStack(spacing: 6) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 5), spacing: 6) {
                        ForEach(0..<ColorSlots.count, id: \.self) { i in slot(i) }
                    }
                    if allowNone { Button { selectedSlot = nil; change { hue = -1 } } label: {
                        Label("No color", systemImage: "slash.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(hue < 0 ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled() }
                }
                // HSV: оттенок, насыщенность, яркость — ползунки на одной высоте с рядами ячеек (24 + 6)
                VStack(spacing: 6) {
                    let h = max(0, hue)
                    GradientSlider(value: Binding(get: { h }, set: { v in slide { hue = v } }),
                                   colors: stride(from: 0.0, through: 1.0, by: 0.1).map { Color(hue: $0, saturation: max(sat, 0.35), brightness: max(bri, 0.5)) },
                                   knob: current, label: "H")
                    GradientSlider(value: Binding(get: { sat }, set: { v in slide { if hue < 0 { hue = h }; sat = v } }),
                                   colors: [Color(hue: h, saturation: 0, brightness: bri), Color(hue: h, saturation: 1, brightness: bri)],
                                   knob: current, label: "S")
                    GradientSlider(value: Binding(get: { bri }, set: { v in slide { if hue < 0 { hue = h }; bri = v } }),
                                   colors: [.black, Color(hue: h, saturation: sat, brightness: 1)],
                                   knob: current, label: "V")
                }
                .frame(maxWidth: .infinity)
            }
    }

    @ViewBuilder private func slot(_ i: Int) -> some View {
        if let c = slots[i] {
            let on = selectedSlot == i
            Button {
                if on { selectedSlot = nil; return }       // повторный клик — снять выбор
                selectedSlot = i
                if let g = gradient { change { g.apply(c) } } else { change { hue = max(0, c.h); sat = c.s; bri = c.v } }
            } label: {
                Group {
                    let base = c.h < 0 ? Color(nsColor: .windowBackgroundColor) : Color(hue: c.h, saturation: c.s, brightness: c.v)
                    if let gl = c.glow { GlowSwatch(panel: base, glow: gl) } else { Circle().fill(base) }
                }
                    .frame(width: 20, height: 20).padding(2)
                    .overlay(Circle().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .contextMenu {
                Button("Replace with Current Color") { if let c = snapshot { slots[i] = c; ColorSlots.save(slots) } }
                Button("Remove") { slots[i] = nil; ColorSlots.save(slots); if selectedSlot == i { selectedSlot = nil } }
            }
        } else {
            Button {
                guard let c = snapshot else { return }
                slots[i] = c; ColorSlots.save(slots)
                selectedSlot = i
            } label: {
                Circle().strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .overlay(Image(systemName: "plus").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary))
                    .frame(width: 20, height: 20).padding(2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Save the current color here")
        }
    }
}

/// Своя палитра: 15 ячеек, общих для всех пространств и папок
enum ColorSlots {
    static let count = 15
    /// Цвет; у градиента — ещё пятна (glow), h — цвет панели под ними
    struct HSV: Codable, Equatable { var h: Double; var s: Double; var v: Double; var glow: SpaceGlow? = nil; var glass: Double? = nil }
    private static let key = "colorSlots"
    static func load() -> [HSV?] {
        var a = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([HSV?].self, from: $0) } ?? []
        if a.count < count { a += Array(repeating: nil, count: count - a.count) }
        return Array(a.prefix(count))
    }
    static func save(_ a: [HSV?]) {
        if let d = try? JSONEncoder().encode(a) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// Ползунок с цветной дорожкой (для H, S, V): кружок — текущий цвет
struct GradientSlider: View {
    @Binding var value: Double
    let colors: [Color]
    let knob: Color
    var label: String = ""
    var labelWidth: CGFloat = 10
    /// Значок на кружке ползунка (Blur, Glass)
    var icon: AnyView? = nil
    /// Точка «выключено» в начале дорожки: у самого края ползунок защёлкивается в 0
    var offStop = false
    var body: some View {
        HStack(spacing: 8) {
            if !label.isEmpty { Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading) }
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                        .frame(height: 10)
                    if offStop {
                        // Точка «выключено»: стоит в центре кружка при значении 0; рядом с ней — защёлка
                        Circle().fill(Color.primary.opacity(value == 0 ? 0 : 0.45))
                            .frame(width: 5, height: 5)
                            .offset(x: h / 2 - 2.5)
                    }
                    Circle()
                        .fill(knob)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                        .overlay { if let icon { icon.padding(6.5) } }
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: h, height: h)
                        .offset(x: CGFloat(value) * (w - h))
                }
                .frame(height: h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let x = Double(min(max((v.location.x - h / 2) / (w - h), 0), 1))
                    value = offStop && x < 0.06 ? 0 : x
                })
            }
            .frame(height: 24)
        }
    }
}
