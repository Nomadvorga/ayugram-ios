import AVFoundation
import CoreMedia
import Foundation
import SwiftSignalKit
import UniversalMediaPlayer
import VoskSpeech

/// Pull-based conversion of Telegram's existing Opus decoder to mono Int16/16k.
/// AVAudioConverter maintains resampling state and is drained until endOfStream.
private final class VoskSoftwareAudioSource: VoskPCMSource {
    let sampleRate: Float = 16000
    private let source: SoftwareAudioSource
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var ended = false
    private var pending: AVAudioPCMBuffer?
    private var pendingOffset = 0

    init(path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0,
              bytes.int64Value <= 256 * 1024 * 1024 else { throw VoskSpeechError.recognitionFailed }
        self.source = SoftwareAudioSource(path: path, forTranscription: true)
        guard self.source.hasStream,
              let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { throw VoskSpeechError.recognitionFailed }
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
    }

    func next(checkCancellation: @escaping () throws -> Void) throws -> Data? {
        guard !self.ended else { return nil }
        while true {
            try checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: 4096) else { throw VoskSpeechError.recognitionFailed }
            var conversionError: NSError?
            var inputError = false
            let status = self.converter.convert(to: output, error: &conversionError) { requested, status in
                do { try checkCancellation() }
                catch { inputError = true; status.pointee = .endOfStream; return nil }
                if self.pending == nil {
                    let sample: CMSampleBuffer
                    do {
                        guard let next = try self.source.readSampleBufferForTranscription(checkCancellation: checkCancellation) else {
                            status.pointee = .endOfStream
                            return nil
                        }
                        sample = next
                    } catch {
                        inputError = true
                        status.pointee = .endOfStream
                        return nil
                    }
                    let frames = CMSampleBufferGetNumSamples(sample)
                    guard frames > 0, frames <= 48000 * 10,
                          let description = CMSampleBufferGetFormatDescription(sample),
                          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                          asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                          asbd.pointee.mSampleRate == 48000, asbd.pointee.mChannelsPerFrame == 1,
                          asbd.pointee.mBitsPerChannel == 16,
                          asbd.pointee.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                          asbd.pointee.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0,
                          asbd.pointee.mBytesPerFrame == 2,
                          let buffer = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: UInt32(frames)) else {
                        inputError = true; status.pointee = .endOfStream; return nil
                    }
                    buffer.frameLength = UInt32(frames)
                    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
                        inputError = true; status.pointee = .endOfStream; return nil
                    }
                    self.pending = buffer
                    self.pendingOffset = 0
                }
                guard let pending = self.pending, requested > 0 else { inputError = true; status.pointee = .endOfStream; return nil }
                let count = min(Int(requested), Int(pending.frameLength) - self.pendingOffset)
                guard let slice = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: UInt32(count)),
                      let source = pending.int16ChannelData?[0], let destination = slice.int16ChannelData?[0] else {
                    inputError = true; status.pointee = .endOfStream; return nil
                }
                slice.frameLength = UInt32(count)
                destination.update(from: source.advanced(by: self.pendingOffset), count: count)
                self.pendingOffset += count
                if self.pendingOffset == Int(pending.frameLength) { self.pending = nil }
                status.pointee = .haveData
                return slice
            }
            try checkCancellation()
            guard !inputError, conversionError == nil, status != .error else { throw VoskSpeechError.recognitionFailed }
            if status == .endOfStream { self.ended = true }
            if output.frameLength > 0 {
                guard let bytes = output.int16ChannelData?[0] else { throw VoskSpeechError.recognitionFailed }
                return Data(bytes: bytes, count: Int(output.frameLength) * 2)
            }
            if self.ended { return nil }
        }
    }
}

/// Takes the original Telegram resource path, before the Apple AAC conversion.
public func transcribeVoskAudio(path: String, chatLocale: String?, appLocale: String) -> Signal<VoskTranscript?, NoError> {
    recognizeVoskAudio(chatLocale: chatLocale, appLocale: appLocale, makeSource: { try VoskSoftwareAudioSource(path: path) })
}
