import AppKit
import SceneKit
import SwiftUI

// MARK: - Камень на пустом экране (из «Sapfire Gem»)

/// Восьмигранный сапфир: крутится вокруг своей оси, грани в цвет значка, по ним пробегает блик.
/// Тянешь мышью — поворачивается (с инерцией), отпустил — через пару секунд возвращается в позу значка.
/// Клик без перетаскивания — `onTap`. Всё нативно (SceneKit + Metal), без сети.
struct GemView: NSViewRepresentable {
    var onTap: () -> Void = {}
    /// Камень сделал полный оборот или его крутанули мышью
    var onTurn: () -> Void = {}

    func makeNSView(context: Context) -> GemSCNView {
        let v = GemSCNView(frame: .zero, options: nil)
        v.onTap = onTap; v.onTurn = onTurn
        return v
    }
    func updateNSView(_ v: GemSCNView, context: Context) { v.onTap = onTap; v.onTurn = onTurn }
}

final class GemSCNView: SCNView, SCNSceneRendererDelegate {
    var onTap: () -> Void = {}
    var onTurn: () -> Void = {}
    private let gem = GemScene()
    private var last: TimeInterval?

    // Вращение вокруг своей оси: крутится, пока двигается курсор; нет движения — затухает
    // и докручивается до позы значка (угол кратен полному обороту)
    private static let cruise: CGFloat = 0.9          // рад/с
    private var angle: CGFloat = 0, speed: CGFloat = 0
    private var turned: CGFloat = 0                   // с прошлого полного оборота (для подсказок)
    private var mouse = CGPoint(x: -1, y: -1)
    private var stillFor: CGFloat = 0                 // сколько курсор не двигался
    /// Докрутка: от угла a0 со скоростью v0 до цели за время T (плавно, скорость к концу — ноль)
    private var settle: (a0: CGFloat, v0: CGFloat, target: CGFloat, t: CGFloat, T: CGFloat)?

    // Мышь: скорость поворота (pt/с), тянут ли, сколько протащили
    private var dragging = false, lastPoint = CGPoint.zero, lastMove: TimeInterval = 0
    private var vx: CGFloat = 0, vy: CGFloat = 0, idle: CGFloat = 0, travel: CGFloat = 0
    private var tiltSpeed: CGFloat = 0                 // скорость возврата наклона (рад/с)
    private var wake: Timer?

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        scene = gem.scene
        pointOfView = gem.camera
        backgroundColor = .clear
        wantsLayer = true
        layer?.isOpaque = false
        antialiasingMode = .multisampling4X
        rendersContinuously = true
        preferredFramesPerSecond = 60
        delegate = self
        // Появился — стоит в позе значка, пока курсор не двинется
        mouse = NSEvent.mouseLocation
        stillFor = 10
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { wake?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { wake?.invalidate(); wake = nil }
    }

    func renderer(_ r: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = CGFloat(min(time - (last ?? time), 0.05))
        last = time
        guard dt > 0 else { return }

        // Курсор двигается?
        let m = NSEvent.mouseLocation
        if m != mouse { mouse = m; stillFor = 0 } else { stillFor += dt }
        let active = stillFor < 1.2 || dragging

        // Своя ось
        var step: CGFloat
        if active {
            // Докрутку прервали — доворот плавно уходит
            gem.wobble.eulerAngles.x *= pow(0.05, dt)
            settle = nil
            speed += (Self.cruise - speed) * (1 - pow(0.25, dt))       // разгон ~0,5 с
            step = speed * dt
        } else {
            if settle == nil {
                // Докрутить вперёд до ближайшей позы значка; время — чтобы скорость только убывала
                let full = 2 * CGFloat.pi
                var target = (angle / full).rounded(.up) * full
                if target - angle < 0.02 { target += speed > 0.05 ? full : 0 }
                // Едва отошёл от позы и почти стоит — назад, а не целый оборот
                let past = angle - (angle / full).rounded(.down) * full
                if past < 0.5 && speed < 0.4 { target = angle - past }
                let d = target - angle
                let T = abs(d) < 0.001 ? 0 : d < 0 ? 1.2 : min(max(1.5 * d / max(speed, 0.1), 1.2), 12)
                settle = (angle, speed, target, 0, T)
            }
            if var st = settle, st.T > 0, st.t < st.T {
                st.t = min(st.t + dt, st.T)
                settle = st
                // Кубическая кривая Эрмита: старт со скоростью v0, финиш в цели с нулевой скоростью
                let u = st.t / st.T, d = st.target - st.a0
                let h = (3 * u * u - 2 * u * u * u) * d + (u - 2 * u * u + u * u * u) * st.v0 * st.T
                let next = st.a0 + h
                step = next - angle
                speed = step / dt
                // По пути чуть качнётся по второй оси и выпрямится к концу (sin² — мягко в начале и в конце)
                let amp = 0.22 * min(1, abs(d) / .pi)
                let b = sin(.pi * u)
                gem.wobble.eulerAngles.x = amp * b * b
            } else {
                step = 0; speed = 0
                gem.wobble.eulerAngles.x = 0
            }
        }
        angle += step
        gem.spin.eulerAngles.y = angle
        turned += step
        if turned >= 2 * .pi {
            turned -= 2 * .pi
            DispatchQueue.main.async { self.onTurn() }
        }

        // Наклон: инерция после броска, потом плавный возврат к позе значка
        guard !dragging else { return }
        if hypot(vx, vy) > 4 {
            gem.turn(dx: vx * dt, dy: vy * dt)
            let k = pow(0.46, dt); vx *= k; vy *= k; idle = 0; tiltSpeed = 0
        } else {
            vx = 0; vy = 0; idle += dt
            if idle > 1 { tiltSpeed = gem.springHome(speed: tiltSpeed, dt: dt) }
        }

        // Всё на месте и курсор стоит — перестаём рисовать (экономия); проснёмся от движения
        if !active, settle.map({ $0.t >= $0.T }) ?? true, speed == 0, idle > 1, gem.atHome {
            DispatchQueue.main.async { self.sleep() }
        }
    }

    private func sleep() {
        guard rendersContinuously, window != nil else { return }
        rendersContinuously = false
        wake?.invalidate()
        wake = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NSEvent.mouseLocation != self.mouse { self.resume() }
        }
    }

    private func resume() {
        wake?.invalidate(); wake = nil
        last = nil
        rendersContinuously = true
    }

    override func mouseDown(with e: NSEvent) {
        resume()
        dragging = true; travel = 0; vx = 0; vy = 0; tiltSpeed = 0
        lastPoint = convert(e.locationInWindow, from: nil); lastMove = e.timestamp
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let dx = p.x - lastPoint.x, dy = -(p.y - lastPoint.y)       // вниз — положительно, как в браузере
        let mdt = max(CGFloat(e.timestamp - lastMove), 0.008)
        lastPoint = p; lastMove = e.timestamp; idle = 0
        travel += hypot(dx, dy)
        vx = vx * 0.6 + dx / mdt * 0.4; vy = vy * 0.6 + dy / mdt * 0.4
        gem.turn(dx: dx, dy: dy)
    }

    override func mouseUp(with e: NSEvent) {
        NSCursor.pop()
        dragging = false
        if travel < 3 { vx = 0; vy = 0; onTap(); return }
        if e.timestamp - lastMove > 0.09 { vx = 0; vy = 0 }     // держал на месте перед тем, как отпустить
        let sp = hypot(vx, vy), cap: CGFloat = 4000
        if sp > cap { vx *= cap / sp; vy *= cap / sp }
        // Крутанул — следующая подсказка (и отсчёт оборота заново)
        if hypot(vx, vy) > 150 { turned = 0; onTurn() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// Сцена камня: огранка, шейдер граней, светлые рёбра
final class GemScene {
    let scene = SCNScene()
    let camera = SCNNode()
    /// Расстояние до камеры (угол обзора считается от него, размер камня в кадре не меняется)
    static let distance = 40.0
    let tilt = SCNNode()        // поза как на значке
    let spin = SCNNode()        // вращение вокруг своей оси
    let wobble = SCNNode()      // лёгкий доворот по второй оси, пока камень докручивается
    private let home: simd_quatf
    private static let start = CACurrentMediaTime()

    init() {
        let cam = SCNCamera()
        // Камера далеко и с узким углом — почти без перспективы, как на иконке (с 7.2 ближние грани раздувались)
        cam.fieldOfView = CGFloat(2 * atan(2.0 / 0.83 / Self.distance) * 180 / .pi)      // камень — на 83% кадра
        cam.zNear = 0.1; cam.zFar = 100
        camera.camera = cam
        camera.position = SCNVector3(0, 0, Self.distance)
        scene.rootNode.addChildNode(camera)

        let (tris, edges) = Self.shape()
        let body = SCNNode(geometry: Self.facets(tris))
        body.addChildNode(SCNNode(geometry: Self.lines(edges)))
        spin.addChildNode(body)
        wobble.addChildNode(spin)
        tilt.addChildNode(wobble)
        // Поза как на значке Sapfire (подобрана по углам камня на AppIcon)
        home = simd_normalize(simd_quatf(ix: -0.5765, iy: -0.0120, iz: 0.3472, r: -0.7395))
        tilt.simdOrientation = home
        scene.rootNode.addChildNode(tilt)
    }

    /// Повернуть весь камень (перетаскивание)
    func turn(dx: CGFloat, dy: CGFloat) {
        let a = Float(hypot(dx, dy) * 0.008)
        guard a > 0 else { return }
        // Как в оригинале: ось (dy, dx, 0); dy — вниз положительно
        let axis = simd_normalize(simd_float3(Float(dy), Float(dx), 0))
        tilt.simdOrientation = simd_quatf(angle: a, axis: axis) * tilt.simdOrientation
    }

    /// Возврат к позе значка «пружиной» без отскока: плавно разгоняется и мягко докручивается.
    /// Возвращает новую скорость (рад/с).
    func springHome(speed: CGFloat, dt: CGFloat) -> CGFloat {
        let delta = home * tilt.simdOrientation.inverse
        var q = delta
        if q.real < 0 { q = simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: -q.real) }   // короткий путь
        let theta = CGFloat(q.angle)
        guard theta > 0.0005 else { tilt.simdOrientation = home; return 0 }
        let w: CGFloat = 2.2                                   // ~2 с до места
        var v = speed + (w * w * theta - 2 * w * speed) * dt
        v = max(v, 0)
        let step = min(v * dt, theta)
        tilt.simdOrientation = simd_normalize(simd_quatf(angle: Float(step), axis: q.axis) * tilt.simdOrientation)
        return v
    }

    /// Стоит в позе значка
    var atHome: Bool {
        let d = home * tilt.simdOrientation.inverse
        return abs(d.real) > 0.99999
    }

    // MARK: Огранка

    private static func ring(_ h: Float, _ c: Float, _ y: Float) -> [simd_float3] {
        [(h - c, h), (-h + c, h), (-h, h - c), (-h, -h + c), (-h + c, -h), (h - c, -h), (h, -h + c), (h, h - c)]
            .map { simd_float3($0.0, y, $0.1) }
    }

    /// Треугольники граней и рёбра (без диагоналей плоских граней)
    private static func shape() -> ([simd_float3], [(simd_float3, simd_float3)]) {
        // Площадка, верх и низ пояса; от пояса грани идут прямо к острию (без ступеньки посередине)
        let rings = [ring(0.46, 0.07, 0.52), ring(1.00, 0.15, 0.10), ring(1.00, 0.15, -0.02)]
        var t: [simd_float3] = []
        var e: [(simd_float3, simd_float3)] = []
        let top = rings[0], tc = simd_float3(0, top[0].y, 0)
        for i in 0..<8 { t += [tc, top[(i + 1) % 8], top[i]] }
        for r in 0..<(rings.count - 1) {
            let a = rings[r], b = rings[r + 1]
            for i in 0..<8 {
                let j = (i + 1) % 8
                t += [a[i], a[j], b[j], a[i], b[j], b[i]]
                e.append((a[i], b[i]))
            }
        }
        let low = rings[rings.count - 1], culet = simd_float3(0, -1.15, 0)
        for i in 0..<8 { t += [low[i], low[(i + 1) % 8], culet]; e.append((low[i], culet)) }
        for r in rings { for i in 0..<8 { e.append((r[i], r[(i + 1) % 8])) } }
        return (t, e)
    }

    /// Грани: у каждой свои вершины и нормаль (плоские грани)
    private static func facets(_ t: [simd_float3]) -> SCNGeometry {
        var pos: [SCNVector3] = [], nrm: [SCNVector3] = []
        for i in stride(from: 0, to: t.count, by: 3) {
            let n = simd_normalize(simd_cross(t[i + 1] - t[i], t[i + 2] - t[i]))
            for k in 0..<3 { pos.append(SCNVector3(t[i + k])); nrm.append(SCNVector3(n)) }
        }
        let idx = (0..<Int32(pos.count)).map { $0 }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nrm)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.isDoubleSided = true
        if let p = program() {
            m.program = p
        } else {
            // Нет Metal-шейдера — просто синий камень
            m.lightingModel = .constant
            m.diffuse.contents = NSColor(calibratedRed: 0.1, green: 0.3, blue: 1, alpha: 1)
        }
        g.materials = [m]
        return g
    }

    /// Тонкие светлые рёбра
    private static func lines(_ e: [(simd_float3, simd_float3)]) -> SCNGeometry {
        let pos = e.flatMap { [SCNVector3($0.0), SCNVector3($0.1)] }
        let idx = (0..<Int32(pos.count)).map { $0 }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(srgbRed: 0x9f / 255, green: 0xe8 / 255, blue: 1, alpha: 1)
        m.transparency = 0.22
        m.writesToDepthBuffer = false
        g.materials = [m]
        return g
    }

    // MARK: Шейдер граней (перенос из «Sapfire Gem»)

    private static func program() -> SCNProgram? {
        guard let dev = MTLCreateSystemDefaultDevice(), let lib = try? dev.makeLibrary(source: metal, options: nil) else { return nil }
        let p = SCNProgram()
        p.library = lib
        p.vertexFunctionName = "gemVertex"
        p.fragmentFunctionName = "gemFragment"
        p.handleBinding(ofBufferNamed: "gem", frequency: .perFrame) { stream, _, _, _ in
            var t = Float(CACurrentMediaTime() - start)
            stream.writeBytes(&t, count: MemoryLayout<Float>.size)
        }
        return p
    }

    private static let metal = """
    #include <metal_stdlib>
    using namespace metal;
    struct NodeBuffer { float4x4 modelViewTransform; float4x4 normalTransform; float4x4 modelViewProjectionTransform; };
    struct GemU { float time; };
    struct VIn { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; };
    struct VOut { float4 pos [[position]]; float3 n; float3 v; float3 p; float3 on; float3 edge; };

    vertex VOut gemVertex(VIn in [[stage_in]], constant NodeBuffer& scn_node [[buffer(1)]]) {
        VOut o;
        float4 mv = scn_node.modelViewTransform * float4(in.position, 1.0);
        o.pos = scn_node.modelViewProjectionTransform * float4(in.position, 1.0);
        o.n = normalize((scn_node.normalTransform * float4(in.normal, 0.0)).xyz);
        o.v = normalize(-mv.xyz);
        o.p = in.position;
        o.on = in.normal;
        o.edge = normalize((scn_node.normalTransform * float4(-1.0, 0.0, 0.0, 0.0)).xyz);   // куда смотрит левый край бирюзовой грани
        return o;
    }

    fragment half4 gemFragment(VOut i [[stage_in]], bool front [[front_facing]], constant GemU& gem [[buffer(2)]]) {
        float3 n = normalize(i.n);
        if (!front) n = -n;
        float3 vV = normalize(i.v), vP = i.p;
        float3 deep = float3(0.16, 0.06, 0.95), blue = float3(0.05, 0.36, 1.00), cyan = float3(0.22, 0.98, 1.00);
        float3 L1 = normalize(float3(-0.6, 0.8, 0.9)), L2 = normalize(float3(0.9, -0.2, 0.6));
        float d1 = max(dot(n, L1), 0.0), d2 = max(dot(n, L2), 0.0);
        float3 col = mix(deep, blue, smoothstep(0.15, 0.85, d1 * 0.9 + d2 * 0.35));
        float sweep = clamp(dot(vP, float3(-0.5, 0.3, 0.5)) * 0.6 + 0.5, 0.0, 1.0);
        col = mix(col, mix(col, float3(0.35, 0.7, 1.0), 0.45), sweep * d1);
        float table = smoothstep(0.97, 0.995, normalize(i.on).y) * step(0.4, vP.y);
        float3 tcol = mix(float3(0.0, 0.62, 1.0), cyan, clamp(0.5 - vP.x * 0.9 + vP.z * 0.5, 0.0, 1.0));
        col = mix(col, tcol, table * (0.55 + 0.45 * d1));
        // Блик бирюзовой грани, как на значке: сама грань у левого края — яркая бирюза, к правому уходит в синий;
        // вдоль левого края — чёткий белый клин (широкий сверху, сходит на нет книзу).
        // Видно в позе значка: камень повернулся вокруг оси — край ушёл с места, и блик гаснет
        float pose = smoothstep(0.80, 0.93, dot(normalize(i.edge), normalize(float3(-0.7586, 0.4997, 0.4181))));
        float lit = table * pose;
        col = mix(col, mix(float3(0.0, 0.55, 1.0), mix(cyan, float3(1.0), 0.12), smoothstep(0.40, -0.46, vP.x)), lit * 0.85);
        float wedge = 0.17 * clamp((0.39 - vP.z) / 0.78, 0.0, 1.0);
        float sliver = 1.0 - smoothstep(-0.46 + wedge - 0.006, -0.46 + wedge + 0.006, vP.x);
        col = mix(col, float3(1.0), lit * sliver * step(0.001, wedge));
        col = mix(col, deep, clamp(-vP.y * 0.35 + vP.x * 0.12, 0.0, 0.35));
        float3 R = reflect(-vV, n);
        float g1 = pow(max(dot(R, L1), 0.0), 10.0), g2 = pow(max(dot(R, L2), 0.0), 18.0);
        col = mix(col, cyan, clamp(g1 * 1.1 + g2 * 0.8, 0.0, 1.0));
        col = mix(col, float3(1.0), pow(clamp(g1, 0.0, 1.0), 4.0) * 0.8);
        float cyc = fmod(gem.time, 3.0);
        float off = mix(-1.5, 1.5, cyc);
        float along = dot(vP, normalize(float3(1.0, 0.45, -0.8)));
        float band = (1.0 - smoothstep(0.17, 0.185, abs(along - off))) * step(cyc, 1.0);
        float litMask = smoothstep(0.4, 0.44, dot(R, L1)) * smoothstep(0.2, 0.25, dot(n, vV));
        col = mix(col, float3(1.0), band * litMask);
        float fr = pow(1.0 - max(dot(n, vV), 0.0), 3.0);
        col += float3(0.25, 0.3, 1.0) * fr * 0.35;
        // Цвета из оригинала заданы «как на экране»; SceneKit сам переводит в sRGB — возвращаем в линейные
        col = pow(clamp(col, 0.0, 1.0), float3(2.2));
        return half4(half3(col), 1.0h);
    }
    """
}
