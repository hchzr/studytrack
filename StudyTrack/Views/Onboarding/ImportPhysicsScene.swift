import SwiftUI
import SpriteKit
import CoreMotion
import UIKit

/// La scène de l'import : ce que l'app trouve **tombe**.
///
/// Chaque page Moodle lue est un petit caillou ; chaque vidéo, série ou
/// échéance rangée, un objet à l'icône et à la couleur de son cours. Ils
/// tombent, rebondissent, roulent selon l'inclinaison du téléphone (gyroscope)
/// et se poussent du doigt — on peut les lancer. Le sol est la carte du moment
/// (on trie ses cours, on règle son objectif) : les objets s'y posent, et
/// retombent quand elle s'en va. Quand un cours est fini, ses objets s'envolent
/// dans le compteur ; à la fin, tout s'effondre au centre en une onde, d'où naît
/// la grille du semestre.
///
/// Pourquoi SpriteKit : une centaine de corps en collision à 60 images par
/// seconde, avec gravité variable, n'est pas raisonnable en SwiftUI.
final class ImportPhysicsScene: SKScene, SKPhysicsContactDelegate {

    private enum Category {
        static let item: UInt32 = 1 << 0
        static let floor: UInt32 = 1 << 1
        static let wall: UInt32 = 1 << 2
    }

    private let motion = CMMotionManager()
    private var reduceMotion = false
    private var dragged: SKNode?
    private var lastTouch: CGPoint = .zero
    private var lastTouchTime: TimeInterval = 0
    private var dragVelocity: CGVector = .zero
    private var lastHaptic: TimeInterval = 0
    private let haptic = UIImpactFeedbackGenerator(style: .soft)
    private var pending: [OnboardingAutoSetup.Drop] = []
    /// Les cours finis : leurs objets, même arrivés après, rejoignent la grille.
    private var finishedCourses: Set<String> = []
    private var lastSpawn: TimeInterval = 0
    /// La hauteur visée du sol (le haut de la carte du moment), depuis le bas.
    var floorTarget: CGFloat = 0
    /// Là où s'envolent les objets d'un cours fini : le compteur.
    var collectPoint: CGPoint?
    private var imploding = false
    private static var textures: [String: SKTexture] = [:]

    static func make(reduceMotion: Bool) -> ImportPhysicsScene {
        let scene = ImportPhysicsScene(size: CGSize(width: 390, height: 260))
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        scene.reduceMotion = reduceMotion
        return scene
    }

    override func didMove(to view: SKView) {
        view.allowsTransparency = true
        physicsWorld.gravity = CGVector(dx: 0, dy: -7.5)
        physicsWorld.contactDelegate = self
        buildBounds()
        haptic.prepare()
        if !reduceMotion, motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1 / 30
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let self, let g = data?.gravity else { return }
                // L'inclinaison du téléphone devient la gravité de la scène.
                self.physicsWorld.gravity = CGVector(dx: g.x * 9, dy: min(-2.5, g.y * 9))
            }
        }
    }

    override func willMove(from view: SKView) {
        motion.stopDeviceMotionUpdates()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        buildBounds()
    }

    private func buildBounds() {
        childNode(withName: "floor")?.removeFromParent()
        childNode(withName: "walls")?.removeFromParent()
        guard size.width > 0, size.height > 0 else { return }
        let floor = SKNode()
        floor.name = "floor"
        floor.physicsBody = SKPhysicsBody(edgeFrom: CGPoint(x: -40, y: 0), to: CGPoint(x: size.width + 40, y: 0))
        floor.physicsBody?.categoryBitMask = Category.floor
        floor.physicsBody?.friction = 0.6
        floor.physicsBody?.isDynamic = false
        floor.position.y = floorTarget
        addChild(floor)
        let walls = SKNode()
        walls.name = "walls"
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: size.height * 3))
        path.move(to: CGPoint(x: size.width, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: size.height * 3))
        walls.physicsBody = SKPhysicsBody(edgeChainFrom: path)
        walls.physicsBody?.categoryBitMask = Category.wall
        addChild(walls)
    }

    // MARK: Apparitions

    /// Un élément trouvé : il entre dans la file, la scène le fait tomber à son
    /// rythme (une vingtaine par seconde au plus — une averse, pas un mur).
    func enqueue(_ drop: OnboardingAutoSetup.Drop) {
        pending.append(drop)
    }

    override func update(_ currentTime: TimeInterval) {
        if !pending.isEmpty, !imploding, currentTime - lastSpawn > 0.05 {
            lastSpawn = currentTime
            spawn(pending.removeFirst())
        }
        moveFloor()
        trimIfCrowded()
    }

    /// Le sol suit la carte, par petits pas : un bond d'un coup ferait passer
    /// les cailloux au travers. Ce qui s'est retrouvé dessous remonte dessus.
    private func moveFloor() {
        guard let floor = childNode(withName: "floor") else { return }
        let delta = floorTarget - floor.position.y
        guard abs(delta) > 0.5 else { return }
        let step = delta > 0 ? min(delta, 6) : max(delta, -24)
        floor.position.y += step
        guard step > 0 else { return }
        for node in children where node.name == "item" && node.position.y < floor.position.y - 4 {
            node.position.y = floor.position.y + 8
        }
    }

    private func spawn(_ drop: OnboardingAutoSetup.Drop) {
        guard size.width > 40 else { return }
        let tint = UIColor(Carnet.tint(drop.colorHex))
        let node: SKNode
        let radius: CGFloat
        switch drop.kind {
        case .page:
            radius = CGFloat.random(in: 4...6.5)
            let pebble = SKShapeNode(circleOfRadius: radius)
            pebble.fillColor = tint.withAlphaComponent(0.35)
            pebble.strokeColor = .clear
            node = pebble
        case .video, .theory, .series, .deadline:
            radius = drop.kind == .series ? 17 : (drop.kind == .deadline ? 14 : 15)
            let shape: SKShapeNode = drop.kind == .series
                ? SKShapeNode(rectOf: CGSize(width: radius * 2, height: radius * 2), cornerRadius: radius * 0.42)
                : SKShapeNode(circleOfRadius: radius)
            shape.fillColor = drop.kind == .deadline ? UIColor(Carnet.wrong) : tint
            shape.strokeColor = UIColor.white.withAlphaComponent(0.35)
            shape.lineWidth = 1
            let icon = SKSpriteNode(texture: Self.texture(for: drop.kind))
            let aspect = icon.texture.map { $0.size().width / max($0.size().height, 1) } ?? 1
            icon.size = CGSize(width: radius * 1.05 * min(aspect, 1.2), height: radius * 1.05 / max(aspect, 1))
            shape.addChild(icon)
            node = shape
        }
        node.name = "item"
        node.userData = ["course": drop.courseID, "kind": drop.kind.rawValue]
        node.position = CGPoint(x: CGFloat.random(in: radius + 6...(size.width - radius - 6)),
                                y: size.height + radius + CGFloat.random(in: 0...30))
        let body: SKPhysicsBody = drop.kind == .series
            ? SKPhysicsBody(rectangleOf: CGSize(width: radius * 2, height: radius * 2))
            : SKPhysicsBody(circleOfRadius: radius)
        body.categoryBitMask = Category.item
        body.collisionBitMask = Category.item | Category.floor | Category.wall
        body.contactTestBitMask = Category.floor | Category.item
        body.restitution = drop.kind == .page ? 0.25 : 0.45
        body.friction = 0.4
        body.density = drop.kind == .page ? 0.4 : 1.2
        body.angularDamping = 0.6
        body.linearDamping = 0.15
        node.physicsBody = body
        node.setScale(0.4)
        addChild(node)
        node.run(.scale(to: 1, duration: 0.25))
        body.velocity = CGVector(dx: CGFloat.random(in: -60...60), dy: CGFloat.random(in: -80 ... -20))
        body.angularVelocity = CGFloat.random(in: -3...3)
        // Un objet d'un cours déjà rangé : on le voit tomber, rebondir, puis
        // rejoindre la grille — au lieu de rester sur le sol.
        if finishedCourses.contains(drop.courseID) { collect(node, after: 1.4 + Double.random(in: 0...0.8)) }
    }

    /// L'objet s'envole dans le compteur — un cours rangé, c'est autant de gagné.
    /// Les cailloux, eux, restent : ils font le sol du semestre.
    private func collect(_ node: SKNode, after delay: TimeInterval) {
        guard (node.userData?["kind"] as? String) != "page" else { return }
        let target = collectPoint ?? CGPoint(x: size.width / 2, y: size.height - 120)
        node.run(.sequence([
            .wait(forDuration: delay),
            .run { [weak node] in
                node?.name = "leaving"
                node?.physicsBody = nil
            },
            .group([
                .scale(to: 1.25, duration: 0.12),
                .rotate(toAngle: 0, duration: 0.3, shortestUnitArc: true),
            ]),
            .group([
                .move(to: target, duration: 0.55).withTiming(.easeIn),
                .scale(to: 0.15, duration: 0.55).withTiming(.easeIn),
                .sequence([.wait(forDuration: 0.35), .fadeOut(withDuration: 0.2)]),
            ]),
            .removeFromParent(),
        ]))
    }

    /// Jamais plus de 140 objets : les cailloux les plus anciens s'effacent.
    private func trimIfCrowded() {
        let items = children.filter { $0.name == "item" }
        guard items.count > 140 else { return }
        let pebbles = items.filter { ($0.userData?["kind"] as? String) == "page" }
        for node in pebbles.prefix(items.count - 140) where node.action(forKey: "fade") == nil {
            node.name = "leaving"
            node.run(.sequence([.fadeOut(withDuration: 0.4), .removeFromParent()]), withKey: "fade")
        }
    }

    /// Un cours est rangé : ses objets s'envolent dans le compteur, en cascade.
    func courseFinished(_ courseID: String) {
        finishedCourses.insert(courseID)
        let mine = children.filter { $0.name == "item" && ($0.userData?["course"] as? String) == courseID }
        for (index, node) in mine.enumerated() {
            collect(node, after: 0.4 + Double(index % 40) * 0.035)
        }
    }

    /// La fin : tout ce qui reste est aspiré au centre, s'y écrase, et repart
    /// en onde de choc — la grille du semestre naît de là. Appelle `completion`
    /// à l'instant du choc.
    func implode(at center: CGPoint? = nil, completion: @escaping () -> Void) {
        imploding = true
        pending.removeAll()
        dragged = nil
        let point = center ?? CGPoint(x: size.width / 2, y: size.height * 0.5)
        let items = children.filter { $0.name == "item" || $0.name == "leaving" }
        // Un temps suspendu : la gravité s'inverse doucement, tout flotte.
        physicsWorld.gravity = CGVector(dx: 0, dy: 1.5)
        motion.stopDeviceMotionUpdates()
        let gather: TimeInterval = 0.75
        for node in items {
            node.removeAllActions()
            let distance = node.position.distance(to: point)
            let lag = 0.25 + Double(min(distance, 600) / 600) * 0.35
            node.run(.sequence([
                .wait(forDuration: lag),
                .run { [weak node] in node?.physicsBody = nil },
                .group([
                    .move(to: point, duration: gather).withTiming(.easeIn),
                    .scale(to: 0.05, duration: gather).withTiming(.easeIn),
                    .rotate(byAngle: .pi * 2, duration: gather),
                ]),
                .removeFromParent(),
            ]))
        }
        let impact: TimeInterval = 0.6 + gather + 0.05
        // Le cœur : un point qui grossit à mesure qu'il avale.
        let core = SKShapeNode(circleOfRadius: 10)
        core.fillColor = UIColor(Carnet.ink)
        core.strokeColor = .clear
        core.position = point
        core.setScale(0.01)
        core.zPosition = 10
        addChild(core)
        core.run(.sequence([
            .scale(to: 1.6, duration: impact - 0.1).withTiming(.easeIn),
            .scale(to: 0.6, duration: 0.1),
            .run { [weak self] in self?.shockwave(at: point) },
            .group([.scale(to: 0, duration: 0.18), .fadeOut(withDuration: 0.18)]),
            .removeFromParent(),
        ]))
        run(.sequence([.wait(forDuration: impact), .run(completion)]))
    }

    private func shockwave(at point: CGPoint) {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        let reach = max(size.width, size.height) * 1.2
        for (index, width) in [CGFloat(10), 4, 2].enumerated() {
            let ring = SKShapeNode(circleOfRadius: 10)
            ring.strokeColor = UIColor(Carnet.ink).withAlphaComponent(0.5 - CGFloat(index) * 0.12)
            ring.lineWidth = width
            ring.fillColor = .clear
            ring.position = point
            ring.zPosition = 9
            addChild(ring)
            ring.run(.sequence([
                .wait(forDuration: Double(index) * 0.07),
                .group([
                    .scale(to: reach / 10, duration: 0.7).withTiming(.easeOut),
                    .fadeOut(withDuration: 0.7),
                ]),
                .removeFromParent(),
            ]))
        }
    }

    // MARK: Toucher

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, !imploding else { return }
        let point = touch.location(in: self)
        // Le plus proche dans un rayon généreux : un caillou de 5 pt se rate au doigt.
        let candidate = children
            .filter { $0.name == "item" }
            .min { $0.position.distance(to: point) < $1.position.distance(to: point) }
        if let candidate, candidate.position.distance(to: point) < 44 {
            dragged = candidate
            candidate.physicsBody?.affectedByGravity = false
            candidate.run(.scale(to: 1.18, duration: 0.12))
            haptic.impactOccurred(intensity: 0.6)
        } else {
            // Un toucher dans le vide : une onde qui repousse les objets proches.
            for node in children where node.name == "item" {
                let delta = CGVector(dx: node.position.x - point.x, dy: node.position.y - point.y)
                let distance = max(12, hypot(delta.dx, delta.dy))
                guard distance < 140 else { continue }
                let strength = (140 - distance) / 140 * ((node.physicsBody?.mass ?? 0.1) * 380)
                node.physicsBody?.applyImpulse(CGVector(dx: delta.dx / distance * strength,
                                                        dy: delta.dy / distance * strength + strength * 0.4))
            }
            haptic.impactOccurred(intensity: 0.4)
        }
        lastTouch = point
        lastTouchTime = touch.timestamp
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let dragged else { return }
        let point = touch.location(in: self)
        let dt = max(touch.timestamp - lastTouchTime, 1 / 120)
        dragVelocity = CGVector(dx: (point.x - lastTouch.x) / dt, dy: (point.y - lastTouch.y) / dt)
        dragged.position = point
        dragged.physicsBody?.velocity = .zero
        lastTouch = point
        lastTouchTime = touch.timestamp
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    /// Lâché : l'objet garde la vitesse du doigt — on peut le lancer.
    private func release() {
        guard let dragged else { return }
        dragged.physicsBody?.affectedByGravity = true
        let cap: CGFloat = 1800
        dragged.physicsBody?.velocity = CGVector(dx: max(-cap, min(cap, dragVelocity.dx)),
                                                 dy: max(-cap, min(cap, dragVelocity.dy)))
        dragged.run(.scale(to: 1, duration: 0.2))
        self.dragged = nil
        dragVelocity = .zero
    }

    // MARK: Contacts

    func didBegin(_ contact: SKPhysicsContact) {
        // Un objet (pas un caillou) qui tombe fort : un petit choc sous le doigt,
        // dix fois par seconde au plus.
        guard contact.collisionImpulse > 18, CACurrentMediaTime() - lastHaptic > 0.1 else { return }
        let isItem = [contact.bodyA.node, contact.bodyB.node].contains { ($0?.userData?["kind"] as? String).map { $0 != "page" } ?? false }
        guard isItem else { return }
        lastHaptic = CACurrentMediaTime()
        haptic.impactOccurred(intensity: min(1, contact.collisionImpulse / 80))
    }

    // MARK: Icônes

    private static func texture(for kind: OnboardingAutoSetup.Drop.Kind) -> SKTexture {
        let name: String
        switch kind {
        case .video: name = "play.fill"
        case .theory: name = "book.fill"
        case .series: name = "doc.text.fill"
        case .deadline: name = "flag.fill"
        case .page: name = "circle.fill"
        }
        if let cached = textures[name] { return cached }
        // Dessinée en blanc dans une image : un symbole teinté gardait son
        // gabarit noir une fois devenu texture.
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        let symbol = UIImage(systemName: name, withConfiguration: config) ?? UIImage()
        let image = UIGraphicsImageRenderer(size: symbol.size).image { _ in
            symbol.withTintColor(.white).draw(in: CGRect(origin: .zero, size: symbol.size))
        }
        let texture = SKTexture(image: image)
        textures[name] = texture
        return texture
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

private extension SKAction {
    func withTiming(_ mode: SKActionTimingMode) -> SKAction {
        timingMode = mode
        return self
    }
}

/// La scène, dans SwiftUI, reliée à l'import. Elle couvre tout l'écran.
struct ImportPhysicsStage: View {
    let setup: OnboardingAutoSetup
    /// La hauteur du sol depuis le bas de la scène (le haut de la carte du moment).
    var floor: CGFloat
    /// Le centre du compteur, depuis le haut de la scène.
    var collectPoint: CGPoint?
    /// Passe à vrai : tout s'effondre au centre ; `onImploded` à l'instant du choc.
    var implode: Bool
    var onImploded: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene: ImportPhysicsScene?
    @State private var height: CGFloat = 0

    var body: some View {
        Group {
            if let scene {
                SpriteView(scene: scene, options: [.allowsTransparency])
            } else {
                Color.clear
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0; sync() }
        .onAppear {
            let made = ImportPhysicsScene.make(reduceMotion: reduceMotion)
            scene = made
            sync()
            setup.onDrop = { [weak made] drop in made?.enqueue(drop) }
            setup.onCourseFinished = { [weak made] id in made?.courseFinished(id) }
        }
        .onDisappear {
            setup.onDrop = nil
            setup.onCourseFinished = nil
        }
        .onChange(of: floor) { _, _ in sync() }
        .onChange(of: collectPoint) { _, _ in sync() }
        .onChange(of: implode) { _, now in
            guard now else { return }
            guard let scene, !reduceMotion else { onImploded(); return }
            scene.implode(completion: onImploded)
        }
        .accessibilityElement()
        .accessibilityLabel("Ce que l'app trouve sur Moodle tombe à l'écran. Touche-le pour le lancer.")
    }

    private func sync() {
        scene?.floorTarget = max(0, floor)
        if let collectPoint, height > 0 {
            scene?.collectPoint = CGPoint(x: collectPoint.x, y: height - collectPoint.y)
        }
    }
}
