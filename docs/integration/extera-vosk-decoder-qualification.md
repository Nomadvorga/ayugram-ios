# Media decoder EOF/drain qualification

2026-11-26. Follow-up to the Vosk implementation checkpoint. The authorized root Vosk integration is applied in the dirty workspace, and the targeted decoder drain change is now applied to the production MediaPlayer/FFMpegBinding sources. No commit or push. The full iOS build and native decoder fixtures remain unavailable on this Windows host.

## Finding and scope of evidence

The Vosk adapter reaches the actual Telegram FFmpeg decoder, not AVAssetReader or Apple's speech decoder. The former `SoftwareAudioSource.readSampleBuffer()` could not distinguish clean EOF, demux error, codec error or resampler failure, and did not drain codec or SWResample at EOF. It could also strand multiple converted frames in a Swift queue. The applied targeted route addresses those lifecycle gaps for Vosk; fixture execution is still required before claiming complete decoded PCM delivery.

These are exact source control-flow findings. No claim is made that a normal one-frame-per-packet, 48 kHz Opus message loses its last frame: that requires a fixture run. Packet/frame multiplicity, codec delay, resampler delay and a decoder accepting corrupt/truncated input depend on the actual stream. A readable stream can legitimately end without a detectable corruption error; neither the old nor proposed API can prove that an untrusted file is semantically complete.

## Actual callees

Line numbers below refer to the pre-integration source used to generate the proposal; current source locations moved after application. SHA-256 identities for the proposal inputs are in `extera-vosk-drain-source-identities.json`.

| Boundary | Actual source/callee and behavior |
| --- | --- |
| Recognition pull | `VoskSpeechAudio/Sources/VoskSoftwareAudioSource.swift:35–88`: `next()` calls `AVAudioConverter.convert`; its input block at line 46 calls `SoftwareAudioSource.readSampleBuffer()`. A nil sample immediately becomes `.endOfStream`. A nonempty last AVAudioConverter output is returned before `ended` causes later nil. |
| Demux initialization | `MediaPlayer/Sources/SoftwareVideoSource.swift:458–533`: public mono constructor opens a POSIX file, custom 64 KiB AVIO, FFmpeg input/stream info, first usable audio stream, then seeks to zero. It creates `FFMpegAudioFrameDecoder(... sampleRate: 48000, channelCount: 1)`. This is an additional resampling stage before AVAudioConverter. |
| POSIX I/O | Same file, lines 418–440: read callback calls `read`; zero maps to `FFMPEG_CONSTANT_AVERROR_EOF`, negative is returned as-is. Seek callback handles `AVSEEK_SIZE`; otherwise always seeks with `SEEK_SET` and returns the requested offset rather than the syscall result. These callbacks are not a general error-qualified AVIO interface. |
| AVIO bridge | `FFMpegBinding/Sources/FFMpegAVIOContext.m:15–24` passes those exact callback pointers and the unmanaged Swift context directly to `avio_alloc_context`; there is no intermediate error/drain adapter. The context is buffered (`direct = 0`). The exported EOF constant is `AVERROR_EOF` at line 5. |
| Packet read | Same file, `readSampleBuffer:598`, `readDecodableFrame:555`, `readPacketInternal:542` → `FFMpegAVFormatContext.readFrame(into:)` → `FFMpegBinding/Sources/FFMpegAVFormatContext.m:118` → `av_read_frame`. The binding returns Bool (`result >= 0`), erasing EOF versus other negative errors. `readDecodableFrame` filters to the chosen audio stream. |
| Packet submission | `SoftwareVideoSource.swift:605` → `FFMpegAudioFrameDecoder.send(frame:):74` → `FFMpegPacket.send(toDecoder:)` → `FFMpegBinding/Sources/FFMpegPacket.m:64` → `avcodec_send_packet`. The packet wrapper preserves raw Int32, but the Swift decoder reduces it to `status == 0`. On false the source continues to the next packet, with no retry or error delivery. |
| Codec output | `FFMpegAudioFrameDecoder.decode():80` repeatedly calls `FFMpegAVCodecContext.receive(into:)` → `FFMpegBinding/Sources/FFMpegAVCodecContext.m:81` → `avcodec_receive_frame`. Success converts/appends each available frame. Non-success stops the loop. The binding maps literal Darwin `-35` to notEnoughData and **all** other negatives, including `AVERROR_EOF`, to error. |
| First PCM conversion | `FFMpegAudioFrameDecoder.convertAudioFrame:143` → `FFMpegSWResample.resample:98` → `swr_convert:142`, with non-null frame input. This resamples original decoder format/rate/channels to S16/48 kHz/mono. Input is `frameImpl->data`; output capacity uses an integer ratio, not a delay-aware bound. `numFrames <= 0` maps both valid buffering (zero) and error (negative) to nil; failed conversion is silently omitted by `decode()`. No flush method exists. |
| Swift queue | `decode:96–105` returns only the minimum-PTS member of `delayedFrames`. `takeQueuedFrame:111` / `takeRemainingFrame:127` exist, but `SoftwareAudioSource.readSampleBuffer` calls neither. |
| Demux termination | `SoftwareVideoSource.swift:610–611` immediately returns nil once no packet is returned. `hasReadToEnd` is never set by this audio path. `FFMpegAudioFrameDecoder.sendEndToDecoder:176` returns true without calling C. The binding's real `sendEnd:63` calls `avcodec_send_packet(ctx, NULL)`, but this source never reaches it. |
| Final PCM conversion | AVAudioConverter sees input `.endOfStream`, drains its **own** 48→16 kHz state and eventually reports output `.endOfStream`. It cannot recover PCM never provided by the upstream codec/SWResample. |

For comparison, `MediaPlayer/Sources/FFMpegFileReader.swift:513–557` receives before reading/submitting the next packet, attempts `sendEnd` after demux end and loops back through `decode()`. It does not call `takeRemainingFrame` in this loop. This is a different caller. Its structure does not prove that `SoftwareAudioSource` has the same lifecycle; its audio `sendEnd` still resolves to the audio decoder's no-op.

The local source tree for `submodules/ffmpeg` is absent on this Windows checkout, but the repository's Git objects contain `Sources/FFMpeg/ffmpeg-8.1.2`. `git show HEAD:.../libavcodec/avcodec.h:138–146,2330–2364` explicitly requires sending NULL then receiving until `AVERROR_EOF`; lines 2340–2357 cover multiple audio frames and resending after EAGAIN. `libswresample/swresample.h:80–86,477–488` explicitly requires NULL/zero-input flush and describes `swr_get_out_samples`. These statements were checked against the actual tracked headers, not inferred from the separately consulted FFmpeg n7.1 documentation. They do not establish which external library a full app build will link; root must confirm the resolved FFmpeg build artifact.

## Event timelines

1. **Ordinary single-output packet**: converter requests input → demux P1 → send P1 succeeds → receive F1 → SWR outputs D1 → receive EAGAIN → queue yields D1 → converter consumes it. Next request repeats. On demux EOF the source returns nil immediately; only AVAudioConverter drains. This can be correct when the codec and SWR have no delayed output.
2. **Last packet emits two frames**: send Pn → receive Fn.a, Fn.b → SWR converts both → receive EAGAIN → `decode()` queues both but returns only Fn.a. Next converter input request → source attempts another demux read first → EOF → nil. Fn.b remains in `delayedFrames` until destruction. This is a concrete reachable loss whenever that packet/frame pattern occurs.
3. **Delayed codec frame**: send Pn → receive EAGAIN with no output → source tries another packet → demux EOF → nil. No NULL packet is sent; a frame that requires codec drain is never requested. Even if an earlier packet left the Swift queue nonempty, EOF prevents its delivery.
4. **SWR delay or output-capacity buffering**: last successful `swr_convert(input)` retains T samples. Demux/codec termination never invokes `swr_convert(NULL, 0)`; T cannot reach the later AVAudioConverter. `swr_free` in deinit discards state; it is not a flush.
5. **Packet send fails**: EAGAIN or a real error becomes false → while loop reads the next packet. The failed packet is released; the current API reports neither rejection nor failure. A caller can receive a plausible partial transcript.
6. **Read/decode/convert fails**: demux failure becomes EOF-like nil; receive failure stops the receive loop (possibly delivering an earlier queued frame); SWR negative return is indistinguishable from zero buffering and its frame is omitted. AVAudioConverter may still finish successfully on the partial input.

## Applied Vosk-only drain route

The applied implementation adds an opt-in sequential `readSampleBufferForTranscription(checkCancellation:) throws`. Only the Vosk adapter calls it. Existing public `readSampleBuffer`, `readFrame`, playback decoder send/receive methods and Apple callers retain their current contracts. Its Vosk-only constructor also enables strict POSIX read/seek error handling before probing and the initial seek; legacy playback keeps its previous callback behavior.

The new route receives one codec frame per pull, and keeps receiving until EAGAIN **before** reading/submitting the next audio packet. Demux distinguishes exact `AVERROR_EOF` from other failures. Only clean demux EOF submits a single NULL packet; receive then runs through codec EOF, SWR repeatedly flushes NULL input until zero output, and only then does the source return nil to AVAudioConverter. Thus all three stages drain in order: codec → SWResample → AVAudioConverter.

Raw status accessors avoid changing the legacy receive enum (which would affect video switches). The new code compares platform-compiled `AVERROR(EAGAIN)` / `AVERROR_EOF`, without hardcoded Darwin numeric errors. It fails on simultaneous receive/send EAGAIN, which violates the pinned FFmpeg state-machine contract; it does not discard a packet and continue. Non-EOF demux failures, send/receive failures and conversion failures throw. POSIX read/seek failures observed during the new pull are recorded even if demux ultimately reports EOF. Cancellation checks run within packet and codec loops; a failure makes that dedicated source terminal.

The separate transcription SWR state starts from the actual first AVFrame's sample rate, sample format, extended_data and channel layout. It checks configuration/init errors, distinguishes empty valid data from nil failure, uses `swr_get_out_samples` for input capacity, and emits bounded repeated tail buffers. A midstream rate/format/layout change fails explicitly; seamless reconfiguration is outside this patch. Output timestamps count contiguous produced samples; recognition does not use source PTS. The new path does not populate `delayedFrames`.

The change is deliberately additive rather than replacing global playback behavior. It touches the six binding interfaces/implementations, two MediaPlayer sources, the Vosk PCM adapter, and a fixture-backed MediaPlayer test. It needs no new Bazel dependencies. The original unapplied patch remains as a review artifact; the current working-tree diff also includes strict initial-I/O handling and the test.

```sh
git apply --check docs/integration/extera-vosk-drain.patch
```

The patch uses ordinary three-line context and does not require `--unidiff-zero`.

## Qualification still required

Executed here: patch applicability before application; parsing the current Swift production/test files; raw-source identity capture; exact tracked FFmpeg-header inspection; independent FFmpeg reference sample counts for the checked-in AAC fixtures. The actual production Swift/Objective-C decoder was not typechecked or run on Windows. The fixture test is added for Mac/iOS execution, but the drain fix is not claimed as runtime-verified until that test runs.

On Mac, compile with the resolved FFmpeg headers and run original Opus (48 kHz), AAC delay, a packet with multiple audio frames, PCM at 44.1/8/16/48 kHz, planar multichannel, empty/silent input and a file truncated at several boundaries. Compare produced samples and concatenated PCM against an independently drained FFmpeg reference at both 48 and 16 kHz; check SWR tail values, not just duration rounded to milliseconds. Fixture codec/packaging settings must demonstrate the intended multiplicity/delay rather than assume it.

Inject demux EIO, receive errors, send errors, send-EAGAIN-after-receive-EAGAIN, SWR init/conversion errors, valid zero output, repeated flush output and EOF-with-final-output. Verify no final result after any error; no dropped or duplicated packet; cancellation in non-audio packet loops and zero-output loops; one-hour/sample-buffer bounds. Exercise old callers to confirm their contracts remain intact. The old seek callback's general whence/return-value semantics, init stat/open race, codec concealment and successful early EOF from truncated streams remain separate qualifications; this patch does not promise complete malformed-file diagnosis.
