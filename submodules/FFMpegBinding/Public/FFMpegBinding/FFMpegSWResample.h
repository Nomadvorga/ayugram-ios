#import <Foundation/Foundation.h>

#import <FFMpegBinding/FFMpegAVSampleFormat.h>

NS_ASSUME_NONNULL_BEGIN

@class FFMpegAVFrame;

@interface FFMpegSWResample : NSObject

- (instancetype)initWithSourceChannelCount:(NSInteger)sourceChannelCount sourceSampleRate:(NSInteger)sourceSampleRate sourceSampleFormat:(enum FFMpegAVSampleFormat)sourceSampleFormat destinationChannelCount:(NSInteger)destinationChannelCount destinationSampleRate:(NSInteger)destinationSampleRate destinationSampleFormat:(enum FFMpegAVSampleFormat)destinationSampleFormat;
- (NSData * _Nullable)resample:(FFMpegAVFrame *)frame;
// Dedicated fixed-format S16 transcription converter. nil frame flushes it.
// Empty data is valid buffering/drain completion; nil data is a failure.
- (NSData * _Nullable)resampleForTranscription:(FFMpegAVFrame * _Nullable)frame NS_SWIFT_NAME(resampleForTranscription(_:));

@end

NS_ASSUME_NONNULL_END
