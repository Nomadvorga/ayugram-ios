import CoreGraphics
import Foundation
import XCTest
@testable import AyuAtmosphericSnow

final class AtmosphericParticleSystemTests: XCTestCase {
    func testSeedIsDeterministicAndDensityIsBounded() {
        var first = AtmosphericParticleSystem(seed: 42)
        var second = AtmosphericParticleSystem(seed: 42)
        var configuration = AtmosphericSnowConfiguration(snowDensity: .heavy)
        first.prepare(size: CGSize(width: 320, height: 640), displayScale: 2, configuration: configuration)
        second.prepare(size: CGSize(width: 320, height: 640), displayScale: 2, configuration: configuration)
        XCTAssertEqual(first.particles, second.particles)
        XCTAssertEqual(first.particles.count, 82)
        let prefix = Array(first.particles.prefix(26))
        configuration.snowDensity = .light
        first.prepare(size: CGSize(width: 320, height: 640), displayScale: 2, configuration: configuration)
        XCTAssertEqual(first.particles, prefix)
        configuration.snowDensity = .medium
        first.prepare(size: CGSize(width: 320, height: 640), displayScale: 2, configuration: configuration)
        XCTAssertEqual(first.particles.count, 50)
        XCTAssertEqual(Array(first.particles.prefix(26)), prefix)
    }

    func testSourceLayerRangesAndCrystalRules() {
        var system = AtmosphericParticleSystem(seed: 0)
        let configuration = AtmosphericSnowConfiguration(snowDensity: .heavy)
        system.prepare(size: CGSize(width: 320, height: 640), displayScale: 1, configuration: configuration)
        for flake in system.particles {
            XCTAssertTrue((-28...348).contains(flake.x))
            XCTAssertTrue((0...640).contains(flake.y))
            XCTAssertTrue((0...2).contains(flake.variant))
            XCTAssertTrue((-38...38).contains(flake.spin))
            XCTAssertTrue((1.5...3.2).contains(flake.twinkleSpeed))
            switch flake.layer {
            case 0:
                XCTAssertTrue((2.2...4).contains(flake.radius))
                XCTAssertTrue((20...36).contains(flake.downwardSpeed))
                XCTAssertTrue((5...11).contains(flake.swayAmplitude))
                XCTAssertTrue((0.6...1.2).contains(flake.swayFrequency))
                XCTAssertTrue((85...145).contains(flake.alpha))
                XCTAssertFalse(flake.isCrystal)
            case 1:
                XCTAssertTrue((4.2...6.8).contains(flake.radius))
                XCTAssertTrue((40...66).contains(flake.downwardSpeed))
                XCTAssertTrue((10...19).contains(flake.swayAmplitude))
                XCTAssertTrue((0.8...1.55).contains(flake.swayFrequency))
                XCTAssertTrue((135...200).contains(flake.alpha))
            case 2:
                XCTAssertTrue((7.5...12).contains(flake.radius))
                XCTAssertTrue((68...102).contains(flake.downwardSpeed))
                XCTAssertTrue((15...28).contains(flake.swayAmplitude))
                XCTAssertTrue((1...1.8).contains(flake.swayFrequency))
                XCTAssertTrue((170...235).contains(flake.alpha))
                XCTAssertTrue(flake.isCrystal)
            default: XCTFail("Unexpected layer")
            }
        }
    }

    func testDeltaClampPreventsCatchUpAndNegativeTime() {
        let configuration = AtmosphericSnowConfiguration()
        var start = AtmosphericParticleSystem(seed: 99)
        start.prepare(size: CGSize(width: 320, height: 640), displayScale: 1, configuration: configuration)
        var longStep = start
        var clamped = start
        longStep.advance(deltaTime: 10, elapsed: 0.05, configuration: configuration)
        clamped.advance(deltaTime: 0.05, elapsed: 0.05, configuration: configuration)
        XCTAssertEqual(longStep.particles, clamped.particles)
        var negative = start
        var zero = start
        negative.advance(deltaTime: -1, elapsed: 0, configuration: configuration)
        zero.advance(deltaTime: 0, elapsed: 0, configuration: configuration)
        XCTAssertEqual(negative.particles, zero.particles)
        XCTAssertEqual(AtmosphericParticleSystem.clampedDeltaTime(.nan), 0)
        XCTAssertEqual(AtmosphericParticleSystem.clampedDeltaTime(.infinity), 0)
    }

    func testSourceVerticalWindSwayAndSpinEquations() {
        let configuration = AtmosphericSnowConfiguration(snowDensity: .heavy, snowSpeed: .fast, snowWind: .blizzard)
        var system = AtmosphericParticleSystem(seed: 31)
        system.prepare(size: CGSize(width: 320, height: 640), displayScale: 2, configuration: configuration)
        let before = system.particles
        let elapsed = 1.25
        let dt = 0.05
        system.advance(deltaTime: dt, elapsed: elapsed, configuration: configuration)
        let gust = 48 * (0.65 + 0.35 * sin(elapsed * 0.45) + 0.15 * sin(elapsed * 1.15))
        for (original, updated) in zip(before, system.particles) where original.x > 10 && original.x < 310 {
            let wind = gust * (0.42 + 0.34 * Double(original.layer))
            let sway = (sourceSine(elapsed * original.swayFrequency + original.phase)
                        + 0.42 * sourceSine(elapsed * original.swayFrequency * 1.7 + original.secondPhase))
                * original.swayAmplitude
            XCTAssertEqual(updated.y, original.y + original.downwardSpeed * 1.55 * dt, accuracy: 0.000_001)
            XCTAssertEqual(updated.x, original.x + (wind + sway * 0.45) * dt, accuracy: 0.000_001)
            let angle = (original.angle + original.spin * dt).truncatingRemainder(dividingBy: 60)
            XCTAssertEqual(updated.angle, angle < 0 ? angle + 60 : angle, accuracy: 0.000_001)
        }
    }

    func testStyleSelectionFadeBucketsAndPixelSnapping() throws {
        var system = AtmosphericParticleSystem(seed: 12)
        var configuration = AtmosphericSnowConfiguration(snowDensity: .heavy)
        system.prepare(size: CGSize(width: 320, height: 200), displayScale: 2, configuration: configuration)
        for original in system.particles {
            var flake = original
            flake.y = 100
            for style in AtmosphericSnowStyle.allCases {
                configuration.snowStyle = style
                let presentation = try XCTUnwrap(system.presentation(of: flake, elapsed: 1, configuration: configuration))
                XCTAssertTrue([32, 64, 96, 128, 160, 192, 224, 255].contains(presentation.bucketAlpha))
                switch style {
                case .bokeh: XCTAssertEqual(presentation.sprite, flake.layer == 0 ? .grain : .bokeh)
                case .crystals:
                    if flake.layer == 0 { XCTAssertEqual(presentation.sprite, .grain) }
                    else { assertCrystal(presentation.sprite, variant: flake.variant) }
                case .mixed:
                    if flake.isCrystal { assertCrystal(presentation.sprite, variant: flake.variant) }
                    else { XCTAssertEqual(presentation.sprite, .grain) }
                }
            }
            flake.y = -1
            XCTAssertNil(system.presentation(of: flake, elapsed: 1, configuration: configuration))
            flake.y = 200
            XCTAssertNil(system.presentation(of: flake, elapsed: 1, configuration: configuration))
        }
        let presentation = AtmosphericParticlePresentation(center: .zero, radius: 7.2, bucketAlpha: 128, sprite: .grain)
        XCTAssertEqual(presentation.snappedDiameter(displayScale: 2), 14)
        let large = AtmosphericParticlePresentation(center: .zero, radius: 100, bucketAlpha: 255, sprite: .bokeh)
        XCTAssertEqual(large.snappedDiameter(displayScale: 2), 32)
    }

    func testResizeThresholdAndLongSimulationStayBounded() {
        let configuration = AtmosphericSnowConfiguration(snowDensity: .heavy)
        var system = AtmosphericParticleSystem(seed: 7)
        system.prepare(size: CGSize(width: 250, height: 40), displayScale: 2, configuration: configuration)
        let initial = system.particles
        system.prepare(size: CGSize(width: 280, height: 40), displayScale: 2, configuration: configuration)
        XCTAssertEqual(system.particles, initial, "30 points is below the 80-pixel resize threshold at 2x")
        system.prepare(size: CGSize(width: 330, height: 40), displayScale: 2, configuration: configuration)
        XCTAssertNotEqual(system.particles, initial)
        for frame in 0..<1000 {
            system.advance(deltaTime: 0.05, elapsed: Double(frame) * 0.05, configuration: configuration)
            XCTAssertEqual(system.particles.count, AtmosphericParticleSystem.maximumParticleCount)
        }
        for flake in system.particles {
            XCTAssertTrue((-30...360).contains(flake.x))
            XCTAssertTrue((-32...70).contains(flake.y))
        }
    }

    private func assertCrystal(_ sprite: AtmosphericSnowSprite, variant: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case let .crystal(actualVariant, rotation) = sprite else {
            XCTFail("Expected crystal", file: file, line: line)
            return
        }
        XCTAssertEqual(actualVariant, variant, file: file, line: line)
        XCTAssertTrue((0..<6).contains(rotation), file: file, line: line)
    }

    private func sourceSine(_ angle: Double) -> Double {
        let index = Int(angle * (128 / (2 * .pi))) & 127
        return sin(Double(index) * 2 * .pi / 128)
    }
}
