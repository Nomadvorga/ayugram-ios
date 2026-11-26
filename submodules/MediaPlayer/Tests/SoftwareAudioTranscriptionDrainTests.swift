import CoreMedia
import Foundation
import XCTest
@testable import UniversalMediaPlayer

final class SoftwareAudioTranscriptionDrainTests: XCTestCase {
    private func decode(_ fixture: String) throws -> (samples: Int, timestamps: [CMTime]) {
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: fixture, ofType: "mp4"))
        let source = SoftwareAudioSource(path: path, forTranscription: true)
        XCTAssertTrue(source.hasStream)

        var samples = 0
        var timestamps: [CMTime] = []
        while let sample = try source.readSampleBufferForTranscription(checkCancellation: {}) {
            let count = CMSampleBufferGetNumSamples(sample)
            XCTAssertGreaterThan(count, 0)
            samples += count
            timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        XCTAssertNil(try source.readSampleBufferForTranscription(checkCancellation: {}), "EOF should remain stable after every drain stage completes")
        return (samples, timestamps)
    }

    func testAACDecoderAndResamplerDrainEveryReferenceSample() throws {
        // Independent FFmpeg decode of the checked-in AAC fMP4 fixtures to mono
        // S16/48 kHz yields these exact decoded PCM frame counts.
        for (fixture, expectedSamples) in [("fragment", 145_408), ("fragment720", 49_152)] {
            let decoded = try self.decode(fixture)
            XCTAssertEqual(decoded.samples, expectedSamples, fixture)
            XCTAssertFalse(decoded.timestamps.isEmpty)
            for pair in zip(decoded.timestamps, decoded.timestamps.dropFirst()) {
                XCTAssertGreaterThan(CMTimeCompare(pair.1, pair.0), 0, fixture)
            }
        }
    }

    func testCancellationDuringStrictReadIsAnErrorNotEOF() throws {
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "fragment", ofType: "mp4"))
        let source = SoftwareAudioSource(path: path, forTranscription: true)
        var checks = 0
        XCTAssertThrowsError(try source.readSampleBufferForTranscription {
            checks += 1
            if checks == 2 { throw CancellationError() }
        })
        XCTAssertThrowsError(try source.readSampleBufferForTranscription(checkCancellation: {}))
    }
}
