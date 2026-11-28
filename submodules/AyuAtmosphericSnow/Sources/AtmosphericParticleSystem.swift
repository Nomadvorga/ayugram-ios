import CoreGraphics
import Foundation

// Pure, bounded simulation. No UIKit, settings dictionaries, image creation, or wall clock.
// Constants and ordering follow source Snowflake.reset (66–130) and render (1210–1370).
struct AtmosphericParticle: Equatable, Sendable {
    var x: Double
    var y: Double
    let layer: Int
    let radius: Double
    let downwardSpeed: Double
    let swayAmplitude: Double
    let swayFrequency: Double
    let phase: Double
    let secondPhase: Double
    let alpha: Int
    var angle: Double
    let spin: Double
    let twinklePhase: Double
    let twinkleSpeed: Double
    let variant: Int
    let isCrystal: Bool

    init(size: CGSize, randomY: Bool, random: inout AtmosphericRandom) {
        let roll = random.unit()
        if roll < 0.48 {
            layer = 0
            radius = random.uniform(2.2, 4.0)
            downwardSpeed = random.uniform(20, 36)
            swayAmplitude = random.uniform(5, 11)
            swayFrequency = random.uniform(0.6, 1.2)
            alpha = random.integer(85, 145)
            isCrystal = false
        } else if roll < 0.82 {
            layer = 1
            radius = random.uniform(4.2, 6.8)
            downwardSpeed = random.uniform(40, 66)
            swayAmplitude = random.uniform(10, 19)
            swayFrequency = random.uniform(0.8, 1.55)
            alpha = random.integer(135, 200)
            isCrystal = random.unit() < 0.50
        } else {
            layer = 2
            radius = random.uniform(7.5, 12)
            downwardSpeed = random.uniform(68, 102)
            swayAmplitude = random.uniform(15, 28)
            swayFrequency = random.uniform(1.0, 1.8)
            alpha = random.integer(170, 235)
            isCrystal = true
        }
        x = random.uniform(-28, Double(size.width) + 28)
        y = randomY ? random.uniform(0, Double(size.height)) : random.uniform(-32, -6)
        phase = random.uniform(0, 2 * .pi)
        secondPhase = random.uniform(0, 2 * .pi)
        angle = random.uniform(0, 360)
        spin = random.uniform(-38, 38)
        twinklePhase = random.uniform(0, 2 * .pi)
        twinkleSpeed = random.uniform(1.5, 3.2)
        variant = random.integer(0, 2)
    }
}

enum AtmosphericSnowSprite: Equatable, Sendable {
    case grain
    case bokeh
    case crystal(variant: Int, rotation: Int)
}

struct AtmosphericParticlePresentation: Equatable, Sendable {
    let center: CGPoint
    let radius: CGFloat
    let bucketAlpha: Int
    let sprite: AtmosphericSnowSprite

    // Matches the Android scaled-cache diameter (4-pixel multiples, capped at 64).
    // Images themselves are NOT resized or allocated on the frame path on iOS.
    func snappedDiameter(displayScale: CGFloat) -> CGFloat {
        let scale = displayScale > 0 && displayScale.isFinite ? displayScale : 1
        let raw = radius * 2 * scale + 2
        // Clamp before Int conversion as well: unsupported/extreme platform scales cannot trap.
        let bounded = raw.isFinite ? min(64, max(4, raw)) : (raw > 0 ? 64 : 4)
        let pixels = (Int(bounded) >> 2) << 2
        return CGFloat(pixels) / scale
    }
}

struct AtmosphericParticleSystem: Sendable {
    static let maximumParticleCount = 82
    private(set) var particles: [AtmosphericParticle] = []
    private(set) var size: CGSize = .zero
    private var random: AtmosphericRandom

    init(seed: UInt64) {
        random = AtmosphericRandom(seed: seed)
        particles.reserveCapacity(Self.maximumParticleCount)
    }

    mutating func reset(seed: UInt64, keepingCapacity: Bool = true) {
        random = AtmosphericRandom(seed: seed)
        particles.removeAll(keepingCapacity: keepingCapacity)
        size = .zero
    }

    mutating func prepare(size newSize: CGSize, displayScale: CGFloat, configuration: AtmosphericSnowConfiguration) {
        guard newSize.width.isFinite, newSize.height.isFinite, newSize.width > 10, newSize.height > 10 else {
            particles.removeAll(keepingCapacity: true)
            size = .zero
            return
        }
        let scale = displayScale > 0 && displayScale.isFinite ? displayScale : 1
        let resizeThreshold = 80 / scale
        let count = configuration.snowDensity.particleCount
        if particles.isEmpty || abs(newSize.width - size.width) > resizeThreshold
            || abs(newSize.height - size.height) > resizeThreshold {
            particles.removeAll(keepingCapacity: true)
        }
        size = newSize
        while particles.count < count {
            particles.append(AtmosphericParticle(size: size, randomY: true, random: &random))
        }
        if particles.count > count { particles.removeLast(particles.count - count) }
    }

    mutating func advance(deltaTime: TimeInterval, elapsed: TimeInterval, configuration: AtmosphericSnowConfiguration) {
        let dt = Self.clampedDeltaTime(deltaTime)
        let time = elapsed.isFinite ? elapsed : 0
        let baseWind = configuration.snowWind.strength
        let gust = baseWind > 0
            ? baseWind * (0.65 + 0.35 * sin(time * 0.45) + 0.15 * sin(time * 1.15)) : 0
        let hasCrystals = configuration.snowStyle != .bokeh
        let width = Double(size.width)
        let height = Double(size.height)
        for index in particles.indices {
            // Mutate array elements in place; there is no per-frame particle array/map.
            let flake = particles[index]
            let layerWind = gust * (0.42 + 0.34 * Double(flake.layer))
            let sway = (
                Self.fastSine(time * flake.swayFrequency + flake.phase)
                + 0.42 * Self.fastSine(time * flake.swayFrequency * 1.7 + flake.secondPhase)
            ) * flake.swayAmplitude
            particles[index].y += flake.downwardSpeed * configuration.snowSpeed.multiplier * dt
            particles[index].x += (layerWind + sway * 0.45) * dt
            if hasCrystals {
                var angle = (flake.angle + flake.spin * dt).truncatingRemainder(dividingBy: 60)
                if angle < 0 { angle += 60 }
                particles[index].angle = angle
            }
            if particles[index].y > height + 30 {
                particles[index] = AtmosphericParticle(size: size, randomY: false, random: &random)
            } else if particles[index].x > width + 30 {
                particles[index].x = -30
            } else if particles[index].x < -30 {
                particles[index].x = width + 30
            }
        }
    }

    func presentation(
        of flake: AtmosphericParticle, elapsed: TimeInterval, configuration: AtmosphericSnowConfiguration
    ) -> AtmosphericParticlePresentation? {
        let height = Double(size.height)
        guard height > 10 else { return nil }
        let time = elapsed.isFinite ? elapsed : 0
        let topFade = height * 0.07
        let bottomStart = height * 0.88
        let bottomLength = max(1, height - bottomStart)
        var edgeFactor = 1.0
        if flake.y < topFade {
            edgeFactor = flake.y > 0 ? flake.y / topFade : 0
        } else if flake.y > bottomStart {
            edgeFactor = max(0, 1 - (flake.y - bottomStart) / bottomLength)
        }
        let shimmer = flake.layer > 0
            ? 0.86 + 0.14 * Self.fastSine(time * flake.twinkleSpeed + flake.twinklePhase) : 1
        let alpha = min(255, Int(Double(flake.alpha) * edgeFactor * shimmer * configuration.snowOpacity.multiplier))
        guard alpha > 3 else { return nil }
        let drawCrystal: Bool
        switch configuration.snowStyle {
        case .bokeh: drawCrystal = false
        case .crystals: drawCrystal = flake.layer >= 1
        case .mixed: drawCrystal = flake.isCrystal
        }
        let sprite: AtmosphericSnowSprite
        let radiusMultiplier: Double
        if drawCrystal {
            let rotation = ((Int(flake.angle * 0.1) % 6) + 6) % 6
            sprite = .crystal(variant: flake.variant, rotation: rotation)
            radiusMultiplier = 1.35
        } else if configuration.snowStyle == .bokeh && flake.layer >= 1 {
            sprite = .bokeh
            radiusMultiplier = 1.25
        } else {
            sprite = .grain
            radiusMultiplier = 0.95
        }
        let bucket = min(7, alpha >> 5)
        let bucketAlpha = bucket == 7 ? 255 : (bucket + 1) * 32
        return AtmosphericParticlePresentation(
            center: CGPoint(x: flake.x, y: flake.y),
            radius: CGFloat(flake.radius * radiusMultiplier * configuration.snowSize.multiplier),
            bucketAlpha: bucketAlpha,
            sprite: sprite
        )
    }

    static func clampedDeltaTime(_ value: TimeInterval) -> TimeInterval {
        return value.isFinite ? min(0.05, max(0, value)) : 0
    }

    private static let sineTable = (0..<128).map { sin(Double($0) * 2 * .pi / 128) }

    private static func fastSine(_ angle: Double) -> Double {
        // Modulo before conversion also keeps arbitrarily long native sessions from overflowing Int.
        let scaled = (angle * (128 / (2 * .pi))).truncatingRemainder(dividingBy: 128)
        guard scaled.isFinite else { return 0 }
        return sineTable[Int(scaled) & 127]
    }
}

// SplitMix64 makes native runs reproducible; it is NOT Python's Mersenne Twister stream.
struct AtmosphericRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> Double { return Double(next() >> 11) / 9_007_199_254_740_992 }
    mutating func uniform(_ lower: Double, _ upper: Double) -> Double { return lower + (upper - lower) * unit() }
    mutating func integer(_ lower: Int, _ upper: Int) -> Int {
        return lower + Int(unit() * Double(upper - lower + 1))
    }
}
