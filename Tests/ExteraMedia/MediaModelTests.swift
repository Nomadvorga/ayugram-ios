import Foundation

// Compiled with the exact production CameraZoom.swift and the extracted production
// shouldUnmuteVideo method by run_model_tests.py. No camera, audio session or settings store.
@main
struct MediaModelTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func near(_ actual: CGFloat?, _ expected: CGFloat, _ message: String) {
        expect(actual.map { abs($0 - expected) <= max(1.0, abs(expected)) * 0.00000001 } ?? false, message)
    }

    static func main() {
        invalidBounds()
        actualBoundsAndReset()
        sliderMapping()
        deltaBounds()
        volumeSamples()
        print("PASS: \(checks) production media model assertions")
    }

    static func invalidBounds() {
        for minimum: CGFloat in [0.0, -1.0, .nan, .infinity, -.infinity] {
            expect(CameraZoomState(minimum: minimum, maximum: 8.0, neutral: 1.0, value: 1.0) == nil, "Invalid minimum accepted")
        }
        for maximum: CGFloat in [0.5, .nan, .infinity, -.infinity] {
            expect(CameraZoomState(minimum: 1.0, maximum: maximum, neutral: 1.0, value: 1.0) == nil, "Invalid maximum accepted")
        }
        for neutral: CGFloat in [.nan, .infinity, -.infinity] {
            expect(CameraZoomState(minimum: 1.0, maximum: 8.0, neutral: neutral, value: 1.0) == nil, "Nonfinite neutral accepted")
        }
        for value: CGFloat in [.nan, .infinity, -.infinity] {
            let state = CameraZoomState(minimum: 1.0, maximum: 8.0, neutral: 2.0, value: value)!
            near(state.value, 2.0, "Invalid current value must recover to neutral")
        }
    }

    static func actualBoundsAndReset() {
        let back = CameraZoomState(minimum: 1.0, maximum: 12.0, neutral: 2.0, value: 9.0)!
        near(back.target(for: .reset), 2.0, "Virtual back lens resets to its neutral factor")
        let front = CameraZoomState(minimum: 1.0, maximum: 3.0, neutral: 1.0, value: 9.0)!
        near(front.value, 3.0, "Front device clamps a larger back-lens value")
        near(front.target(for: .reset), 1.0, "Front reset uses its own neutral")
        let bounded = CameraZoomState(minimum: 2.0, maximum: 7.0, neutral: 1.0, value: -4.0)!
        near(bounded.neutral, 2.0, "Neutral respects actual minimum")
        near(bounded.value, 2.0, "Current factor respects actual minimum")
        near(bounded.target(for: .fraction(1.0)), 7.0, "No fabricated upper zoom bound")
        let fixed = CameraZoomState(minimum: 2.0, maximum: 2.0, neutral: 8.0, value: 4.0)!
        near(fixed.fraction, 0.0, "Fixed-range fraction")
        for update in [CameraZoomUpdate.fraction(0.5), .delta(10.0), .reset] {
            near(fixed.target(for: update), 2.0, "Fixed-range update")
        }
        expect(fixed.target(for: .read) == nil, "Reading must not write or cancel a ramp")
    }

    static func sliderMapping() {
        // A range below 1 is intentional: the model must preserve device-reported bounds.
        for (minimum, maximum): (CGFloat, CGFloat) in [(0.5, 8.0), (1.0, 64.0), (2.0, 7.0)] {
            let state = CameraZoomState(minimum: minimum, maximum: maximum, neutral: 2.0, value: minimum)!
            var previous = minimum
            for step in 0 ... 100 {
                let fraction = CGFloat(step) / 100.0
                let value = state.target(for: .fraction(fraction))!
                expect(value >= minimum && value <= maximum && value >= previous, "Slider monotonicity and bounds")
                let readback = CameraZoomState(minimum: minimum, maximum: maximum, neutral: 2.0, value: value)!
                near(readback.fraction, fraction, "Logarithmic round trip")
                previous = value
            }
            near(state.target(for: .fraction(-100.0)), minimum, "Negative fraction clamps")
            near(state.target(for: .fraction(100.0)), maximum, "Oversized fraction clamps")
            for invalid: CGFloat in [.nan, .infinity, -.infinity] {
                near(state.target(for: .fraction(invalid)), state.value, "Nonfinite fraction is ignored")
            }
        }
        let logarithmic = CameraZoomState(minimum: 1.0, maximum: 64.0, neutral: 1.0, value: 1.0)!
        near(logarithmic.target(for: .fraction(0.5)), 8.0, "Slider midpoint is geometric")
        let extreme = CameraZoomState(minimum: .leastNormalMagnitude, maximum: .greatestFiniteMagnitude, neutral: 1.0, value: 1.0)!
        expect(extreme.fraction.isFinite, "Finite bounds with an overflowing ratio still have a valid fraction")
        let midpoint = extreme.target(for: .fraction(0.5))!
        expect(midpoint.isFinite && midpoint > 0.0, "Extreme slider midpoint remains finite")
    }

    static func deltaBounds() {
        let state = CameraZoomState(minimum: 1.0, maximum: 12.0, neutral: 2.0, value: 4.0)!
        near(state.target(for: .delta(1.5)), 6.0, "Pinch delta multiplies current factor")
        near(state.target(for: .delta(0.1)), 1.0, "Pinch lower clamp")
        near(state.target(for: .delta(1000.0)), 12.0, "Pinch upper clamp")
        near(state.target(for: .delta(.greatestFiniteMagnitude)), 12.0, "Overflowing product clamps to device maximum")
        near(state.target(for: .delta(.leastNonzeroMagnitude)), 1.0, "Tiny positive delta clamps to device minimum")
        for invalid: CGFloat in [0.0, -1.0, .nan, .infinity, -.infinity] {
            near(state.target(for: .delta(invalid)), 4.0, "Invalid pinch delta is ignored")
        }
    }

    static func volumeSamples() {
        expect(ExteraMediaSettings.shouldUnmuteVideo(previousVolume: 0.0, volume: 0.0625), "Volume up from zero")
        expect(ExteraMediaSettings.shouldUnmuteVideo(previousVolume: 0.5, volume: 0.4375), "Volume down with audible result")
        expect(ExteraMediaSettings.shouldUnmuteVideo(previousVolume: 0.9375, volume: 1.0), "Volume up to maximum")
        expect(!ExteraMediaSettings.shouldUnmuteVideo(previousVolume: 0.0625, volume: 0.0), "Zero result must stay muted")
        for volume: Float in [0.0, 0.5, 1.0] {
            expect(!ExteraMediaSettings.shouldUnmuteVideo(previousVolume: volume, volume: volume), "No-op/endpoint sample")
        }
        expect(!ExteraMediaSettings.shouldUnmuteVideo(previousVolume: 0.5, volume: 0.50001), "Ignore observation noise")
        for invalid: Float in [-0.1, 1.1, .nan, .infinity, -.infinity] {
            expect(!ExteraMediaSettings.shouldUnmuteVideo(previousVolume: invalid, volume: 0.5), "Invalid previous volume")
            expect(!ExteraMediaSettings.shouldUnmuteVideo(previousVolume: 0.5, volume: invalid), "Invalid new volume")
        }
    }
}
