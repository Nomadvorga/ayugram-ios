#import <FFMpegBinding/FFMpegSWResample.h>

#import <FFMpegBinding/FFMpegAVFrame.h>

#import "libavformat/avformat.h"
#import "libavcodec/avcodec.h"
#import "libswresample/swresample.h"

@interface FFMpegSWResample () {
    int _sourceSampleRate;
    FFMpegAVSampleFormat _sourceSampleFormat;
    int _destinationChannelCount;
    int _destinationSampleRate;
    FFMpegAVSampleFormat _destinationSampleFormat;

    int _currentSourceChannelCount;

    SwrContext *_context;
    NSUInteger _ratio;
    void *_buffer;
    int _bufferSize;

    SwrContext *_transcriptionContext;
    int _transcriptionRate;
    int _transcriptionFormat;
#if LIBAVFORMAT_VERSION_MAJOR >= 59
    AVChannelLayout _transcriptionLayout;
#else
    uint64_t _transcriptionLayout;
#endif
    bool _transcriptionDraining;
}

@end

@implementation FFMpegSWResample

- (instancetype)initWithSourceChannelCount:(NSInteger)sourceChannelCount sourceSampleRate:(NSInteger)sourceSampleRate sourceSampleFormat:(enum FFMpegAVSampleFormat)sourceSampleFormat destinationChannelCount:(NSInteger)destinationChannelCount destinationSampleRate:(NSInteger)destinationSampleRate destinationSampleFormat:(enum FFMpegAVSampleFormat)destinationSampleFormat {
    self = [super init];
    if (self != nil) {
        _sourceSampleRate = (int)sourceSampleRate;
        _sourceSampleFormat = sourceSampleFormat;
        _destinationChannelCount = (int)destinationChannelCount;
        _destinationSampleRate = (int)destinationSampleRate;
        _destinationSampleFormat = destinationSampleFormat;

        _currentSourceChannelCount = -1;
    }
    return self;
}

- (void)dealloc {
    swr_free(&_transcriptionContext);
#if LIBAVFORMAT_VERSION_MAJOR >= 59
    av_channel_layout_uninit(&_transcriptionLayout);
#endif
    if (_context) {
        swr_free(&_context);
    }
    if (_buffer) {
        free(_buffer);
    }
}

- (void)resetContextForChannelCount:(int)channelCount {
    if (_context) {
        swr_free(&_context);
        _context = NULL;
    }
    
    #if LIBAVFORMAT_VERSION_MAJOR >= 59
    AVChannelLayout channelLayoutIn;
    av_channel_layout_default(&channelLayoutIn, channelCount);
    
    AVChannelLayout channelLayoutOut;
    av_channel_layout_default(&channelLayoutOut, _destinationChannelCount);
    
    if (swr_alloc_set_opts2(
        &_context,
        &channelLayoutOut,
        (enum AVSampleFormat)_destinationSampleFormat,
        (int)_destinationSampleRate,
        &channelLayoutIn,
        (enum AVSampleFormat)_sourceSampleFormat,
        (int)_sourceSampleRate,
        0,
        NULL
    ) != 0) {
        return;
    }
    #else
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _context = swr_alloc_set_opts(NULL,
                                  av_get_default_channel_layout((int)_destinationChannelCount),
                                  (enum AVSampleFormat)_destinationSampleFormat,
                                  (int)_destinationSampleRate,
                                  av_get_default_channel_layout(channelCount),
                                  (enum AVSampleFormat)_sourceSampleFormat,
                                  (int)_sourceSampleRate,
                                  0,
                                  NULL);
    #pragma clang diagnostic pop
    #endif
    _currentSourceChannelCount = channelCount;
    _ratio = MAX(1, _destinationSampleRate / MAX(_sourceSampleRate, 1)) * MAX(1, _destinationChannelCount / channelCount) * 2;
    if (_context) {
        swr_init(_context);
    }
}

- (NSData * _Nullable)resample:(FFMpegAVFrame *)frame {
    AVFrame *frameImpl = (AVFrame *)[frame impl];

#if LIBAVFORMAT_VERSION_MAJOR >= 59
    int numChannels = frameImpl->ch_layout.nb_channels;
#else
    int numChannels = frameImpl->channels;
#endif
    if (numChannels != _currentSourceChannelCount) {
        [self resetContextForChannelCount:numChannels];
    }

    if (!_context) {
        return nil;
    }

    int64_t outSamples = (int64_t)frameImpl->nb_samples * (int64_t)_ratio;
    // Cap at 8M samples per frame: ~10× larger than any legitimate codec
    // frame × resample ratio, bounds the per-frame buffer to ~32 MB (s16 stereo),
    // and rejects pathological inputs (e.g. 1 Hz source with a 65 KB FLAC block).
    if (outSamples <= 0 || outSamples > 8 * 1024 * 1024) {
        return nil;
    }

    int bufSize = av_samples_get_buffer_size(NULL,
                                             (int)_destinationChannelCount,
                                             (int)outSamples,
                                             (enum AVSampleFormat)_destinationSampleFormat,
                                             1);
    if (bufSize <= 0) {
        return nil;
    }

    if (!_buffer || _bufferSize < bufSize) {
        void *newBuffer = realloc(_buffer, bufSize);
        if (!newBuffer) {
            return nil;
        }
        _buffer = newBuffer;
        _bufferSize = bufSize;
    }

    Byte *outbuf[2] = { _buffer, 0 };

    int numFrames = swr_convert(_context,
                                outbuf,
                                (int)outSamples,
                                (const uint8_t **)frameImpl->data,
                                frameImpl->nb_samples);
    if (numFrames <= 0) {
        return nil;
    }
    
    return [[NSData alloc] initWithBytes:_buffer length:numFrames * _destinationChannelCount * 2];
}

// This converter is isolated from the playback resampler's legacy nil contract.
- (NSData * _Nullable)resampleForTranscription:(FFMpegAVFrame * _Nullable)frame {
    AVFrame *input = frame == nil ? NULL : (AVFrame *)[frame impl];
    if ((enum AVSampleFormat)_destinationSampleFormat != AV_SAMPLE_FMT_S16 ||
        _destinationSampleRate <= 0 || _destinationSampleRate > 192000 ||
        _destinationChannelCount < 1 || _destinationChannelCount > 2) {
        return nil;
    }
    if (input != NULL) {
        if (_transcriptionDraining || input->sample_rate <= 0 ||
            input->sample_rate > 192000 || input->nb_samples <= 0 ||
            (int64_t)input->nb_samples > (int64_t)input->sample_rate * 10 ||
            input->extended_data == NULL) {
            return nil;
        }
#if LIBAVFORMAT_VERSION_MAJOR >= 59
        int channels = input->ch_layout.nb_channels;
#else
        int channels = input->channels;
        uint64_t layout = input->channel_layout != 0 ? input->channel_layout : av_get_default_channel_layout(channels);
#endif
        if (channels < 1 || channels > 64) { return nil; }
        if (_transcriptionContext == NULL) {
#if LIBAVFORMAT_VERSION_MAJOR >= 59
            if (!av_channel_layout_check(&input->ch_layout) ||
                av_channel_layout_copy(&_transcriptionLayout, &input->ch_layout) < 0) {
                return nil;
            }
            AVChannelLayout outputLayout;
            av_channel_layout_default(&outputLayout, _destinationChannelCount);
            int status = swr_alloc_set_opts2(&_transcriptionContext,
                &outputLayout, AV_SAMPLE_FMT_S16, _destinationSampleRate,
                &_transcriptionLayout, (enum AVSampleFormat)input->format,
                input->sample_rate, 0, NULL);
            av_channel_layout_uninit(&outputLayout);
            if (status < 0) { return nil; }
#else
            _transcriptionLayout = layout;
            _transcriptionContext = swr_alloc_set_opts(NULL,
                av_get_default_channel_layout(_destinationChannelCount),
                AV_SAMPLE_FMT_S16, _destinationSampleRate,
                layout, (enum AVSampleFormat)input->format,
                input->sample_rate, 0, NULL);
#endif
            if (_transcriptionContext == NULL || swr_init(_transcriptionContext) < 0) {
                return nil;
            }
            _transcriptionRate = input->sample_rate;
            _transcriptionFormat = input->format;
        } else {
            // A format change requires draining/reconfiguration; fail explicitly
            // rather than silently discarding the previous converter's tail.
            if (!swr_is_initialized(_transcriptionContext) ||
                input->sample_rate != _transcriptionRate ||
                input->format != _transcriptionFormat) { return nil; }
#if LIBAVFORMAT_VERSION_MAJOR >= 59
            if (av_channel_layout_compare(&_transcriptionLayout, &input->ch_layout) != 0) { return nil; }
#else
            if (layout != _transcriptionLayout) { return nil; }
#endif
        }
    } else {
        _transcriptionDraining = true;
        if (_transcriptionContext == NULL) { return [NSData data]; }
        if (!swr_is_initialized(_transcriptionContext)) { return nil; }
    }

    // Ask SWR for its delay-aware bound for both input and NULL-input flushes.
    // Repeated flush calls stop only when zero output is produced.
    int capacity = swr_get_out_samples(_transcriptionContext, input == NULL ? 0 : input->nb_samples);
    if (capacity < 0 || capacity > (int64_t)_destinationSampleRate * 10) { return nil; }
    capacity = MAX(1, capacity);
    size_t bytes = (size_t)capacity * (size_t)_destinationChannelCount * 2;
    uint8_t *output = malloc(bytes);
    if (output == NULL) { return nil; }
    int frames = swr_convert(_transcriptionContext, &output, capacity,
        input == NULL ? NULL : (const uint8_t **)input->extended_data,
        input == NULL ? 0 : input->nb_samples);
    if (frames < 0 || frames > capacity) { free(output); return nil; }
    return [[NSData alloc] initWithBytesNoCopy:output
        length:(NSUInteger)frames * (NSUInteger)_destinationChannelCount * 2
        freeWhenDone:YES];
}

@end
