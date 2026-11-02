//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "Utils.h"

#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>

#define SDL_MAIN_HANDLED
#import <SDL.h>

#include "Limelight.h"
#include "opus_multistream.h"
#include <stdatomic.h>

@implementation Connection {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    CONNECTION_LISTENER_CALLBACKS _clCallbacks;
    DECODER_RENDERER_CALLBACKS _drCallbacks;
    AUDIO_RENDERER_CALLBACKS _arCallbacks;
    char _hostString[256];
    char _appVersionString[32];
    char _gfeVersionString[32];
    char _rtspSessionUrl[128];
}

static NSLock* initLock;
static OpusMSDecoder* opusDecoder;
static id<ConnectionCallbacks> _callbacks;
static int lastFrameNumber;
static int activeVideoFormat;
static video_stats_t currentVideoStats;
static video_stats_t lastVideoStats;
static NSLock* videoStatsLock;

static OPUS_MULTISTREAM_CONFIGURATION audioConfig;
static short *audioBuffer;                  // one decoded Opus frame, interleaved

// Playback (11-02): AVAudioEngine instead of SDL. SDL's output thread pulled irregularly once the
// app was in the background and almost stopped with the phone locked, so the sound went away.
// iOS calls a source node's render block on its real-time audio thread, in the background too.
// The decoder never waits: it drops a frame into the ring below and goes back for the next one.
static AVAudioEngine *audioEngine;
static AVAudioSourceNode *audioSource;
static id audioEngineObserver, audioInterruptionObserver;

// Ring of interleaved 16-bit sample frames. One writer (the decode thread) and one reader (the
// render thread), so two ever-increasing frame counters are all the locking it needs.
#define RING_SECONDS 1
static short *ring;
static uint32_t ringFrames;
static int ringChannels;
static _Atomic uint64_t ringWrite, ringRead;
static atomic_bool ringFlush;               // mute: the render thread throws away what is queued
static atomic_bool ringPrimed;              // play only once enough is buffered (start, after a gap)
static atomic_int ringPrefill, ringCap;     // frames: start playing at / never queue more than

// 10 s statistics
static int audioDropped, audioPlayed;
static double audioStatsLogged, audioLimitsSet;
static atomic_int audioUnderruns, audioMinBuffered, audioMaxBuffered, audioCallbacks;
static atomic_int audioCallMax;             // largest render call this second (frames)
static atomic_int audioSecondMin;           // emptiest the ring got this second (frames)
static int audioCallFrames;                 // largest render call over the last couple of seconds
static double audioCallSeen;
static int audioTrimFrames;                 // frames still to drop to bring the delay back down
static int audioTrimmed;                    // packets dropped for that in the 10 s window

static NSString *AudioRouteText(void) {
    NSMutableArray *outs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].currentRoute.outputs) {
        [outs addObject:p.portType];
    }
    return [outs componentsJoinedByString:@"+"];
}

/// What iOS does to the audio session while streaming, as it happens (11-02: the sound stopped
/// when the phone was locked and nothing said why)
static void WatchAudioSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
            NSNumber *reason = n.userInfo[@"AVAudioSessionInterruptionReasonKey"];
            NSNumber *options = n.userInfo[AVAudioSessionInterruptionOptionKey];
            Log(LOG_I, @"Audio session: interruption %@ (reason %@, options %@), route %@",
                type == AVAudioSessionInterruptionTypeBegan ? @"began" : @"ended", reason, options, AudioRouteText());
        }];
        [nc addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            Log(LOG_I, @"Audio session: route change (reason %@), now %@, category %@",
                n.userInfo[AVAudioSessionRouteChangeReasonKey], AudioRouteText(), [AVAudioSession sharedInstance].category);
        }];
        [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            Log(LOG_W, @"Audio session: media services were reset");
        }];
        [nc addObserverForName:AVAudioSessionSilenceSecondaryAudioHintNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            Log(LOG_I, @"Audio session: silence-secondary-audio hint %@", n.userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey]);
        }];
    });
}

/// Whether to drop the stream's sound on the floor.
///
/// Written from the main thread when someone taps the control, read on the audio thread for every
/// packet, so it is atomic. Nothing else about it needs ordering: a packet either side of the tap
/// may go whichever way, and half a frame of sound is not worth a lock on the hot path.
static atomic_bool audioMuted;

NSString * const kAudioMuteChangedNotification = @"AudioMuteChanged";

static VideoDecoderRenderer* renderer;

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    [renderer setupWithVideoFormat:videoFormat width:width height:height frameRate:redrawRate];
    lastFrameNumber = 0;
    activeVideoFormat = videoFormat;
    memset(&currentVideoStats, 0, sizeof(currentVideoStats));
    memset(&lastVideoStats, 0, sizeof(lastVideoStats));
    return 0;
}

void DrStart(void)
{
    [renderer start];
}

void DrStop(void)
{
    [renderer stop];
}

-(BOOL) getVideoStats:(video_stats_t*)stats
{
    // We return lastVideoStats because it is a complete 1 second window
    [videoStatsLock lock];
    if (lastVideoStats.endTime != 0) {
        memcpy(stats, &lastVideoStats, sizeof(*stats));
        [videoStatsLock unlock];
        return YES;
    }
    
    // No stats yet
    [videoStatsLock unlock];
    return NO;
}

-(NSString*) getActiveCodecName
{
    switch (activeVideoFormat)
    {
        case VIDEO_FORMAT_H264:
            return @"H.264";
        case VIDEO_FORMAT_H265:
            return @"HEVC";
        case VIDEO_FORMAT_H265_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"HEVC Main 10 HDR";
            }
            else {
                return @"HEVC Main 10 SDR";
            }
        case VIDEO_FORMAT_AV1_MAIN8:
            return @"AV1";
        case VIDEO_FORMAT_AV1_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"AV1 10-bit HDR";
            }
            else {
                return @"AV1 10-bit SDR";
            }
        default:
            return @"UNKNOWN";
    }
}

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit)
{
    int offset = 0;
    int ret;
    unsigned char* data = (unsigned char*) malloc(decodeUnit->fullLength);
    if (data == NULL) {
        // A frame was lost due to OOM condition
        return DR_NEED_IDR;
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    if (!lastFrameNumber) {
        currentVideoStats.startTime = now;
        lastFrameNumber = decodeUnit->frameNumber;
    }
    else {
        // Flip stats roughly every second
        if (now - currentVideoStats.startTime >= 1.0f) {
            currentVideoStats.endTime = now;
            
            [videoStatsLock lock];
            lastVideoStats = currentVideoStats;
            [videoStatsLock unlock];
            
            memset(&currentVideoStats, 0, sizeof(currentVideoStats));
            currentVideoStats.startTime = now;
        }
        
        // Any frame number greater than m_LastFrameNumber + 1 represents a dropped frame
        currentVideoStats.networkDroppedFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        currentVideoStats.totalFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        lastFrameNumber = decodeUnit->frameNumber;
    }
    
    if (decodeUnit->frameHostProcessingLatency != 0) {
        if (currentVideoStats.minHostProcessingLatency == 0 || decodeUnit->frameHostProcessingLatency < currentVideoStats.minHostProcessingLatency) {
            currentVideoStats.minHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        if (decodeUnit->frameHostProcessingLatency > currentVideoStats.maxHostProcessingLatency) {
            currentVideoStats.maxHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        currentVideoStats.framesWithHostProcessingLatency++;
        currentVideoStats.totalHostProcessingLatency += decodeUnit->frameHostProcessingLatency;
    }
    
    currentVideoStats.receivedFrames++;
    currentVideoStats.totalFrames++;

    PLENTRY entry = decodeUnit->bufferList;
    while (entry != NULL) {
        // Submit parameter set NALUs directly since no copy is required by the decoder
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            ret = [renderer submitDecodeBuffer:(unsigned char*)entry->data
                                        length:entry->length
                                    bufferType:entry->bufferType
                                     decodeUnit:decodeUnit];
            if (ret != DR_OK) {
                free(data);
                return ret;
            }
        }
        else {
            memcpy(&data[offset], entry->data, entry->length);
            offset += entry->length;
        }

        entry = entry->next;
    }

    // This function will take our picture data buffer
    return [renderer submitDecodeBuffer:data
                                 length:offset
                             bufferType:BUFFER_TYPE_PICDATA
                             decodeUnit:decodeUnit];
}

/// How far ahead to buffer, from how much iOS takes per render call (21 ms in the background,
/// more on some routes): enough that one call never finds the ring empty, little enough to keep
/// the delay low.
static void SetAudioLimits(void) {
    double rate = audioConfig.sampleRate;
    // What iOS really asks for per call: IOBufferDuration says 21 ms with the phone locked while
    // the calls come every 85 ms (11-02), so take the larger of the two.
    double io = MAX([AVAudioSession sharedInstance].IOBufferDuration, audioCallFrames / rate);
    int prefill = (int)(MAX(0.030, io * 1.5) * rate);
    int cap = (int)(MAX(0.150, io * 3 + 0.030) * rate);
    if (cap > (int)ringFrames - 1) cap = (int)ringFrames - 1;
    atomic_store(&ringPrefill, prefill);
    atomic_store(&ringCap, cap);
}

static OSStatus RenderAudio(BOOL *isSilence, AVAudioFrameCount frameCount, AudioBufferList *out) {
    uint64_t r = atomic_load_explicit(&ringRead, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ringWrite, memory_order_acquire);
    if (atomic_exchange(&ringFlush, false)) {
        r = w;
        atomic_store(&ringPrimed, false);
    }
    uint64_t avail = w - r;
    atomic_fetch_add(&audioCallbacks, 1);
    if ((int)frameCount > atomic_load(&audioCallMax)) atomic_store(&audioCallMax, (int)frameCount);
    if ((int)avail < atomic_load(&audioSecondMin)) atomic_store(&audioSecondMin, (int)avail);
    if ((int)avail < atomic_load(&audioMinBuffered)) atomic_store(&audioMinBuffered, (int)avail);
    if ((int)avail > atomic_load(&audioMaxBuffered)) atomic_store(&audioMaxBuffered, (int)avail);

    bool primed = atomic_load(&ringPrimed);
    if (!primed && (int)avail >= atomic_load(&ringPrefill)) {
        primed = true;
        atomic_store(&ringPrimed, true);
    }
    uint32_t n = primed ? (uint32_t)MIN(avail, (uint64_t)frameCount) : 0;
    if (primed && n < frameCount) {
        // ran dry: fill the rest with silence and build the cushion up again before going on
        atomic_fetch_add(&audioUnderruns, 1);
        atomic_store(&ringPrimed, false);
    }

    int ch = ringChannels;
    if (out->mNumberBuffers == (UInt32)ch) {
        for (int c = 0; c < ch; c++) {
            float *dst = (float *)out->mBuffers[c].mData;
            for (uint32_t i = 0; i < n; i++) {
                dst[i] = ring[((r + i) % ringFrames) * ch + c] * (1.0f / 32768.0f);
            }
            memset(dst + n, 0, (frameCount - n) * sizeof(float));
        }
    } else if (out->mNumberBuffers == 1) {
        float *dst = (float *)out->mBuffers[0].mData;   // interleaved
        for (uint32_t i = 0; i < n; i++) {
            for (int c = 0; c < ch; c++) {
                dst[i * ch + c] = ring[((r + i) % ringFrames) * ch + c] * (1.0f / 32768.0f);
            }
        }
        memset(dst + n * ch, 0, (frameCount - n) * ch * sizeof(float));
    }
    atomic_store_explicit(&ringRead, r + n, memory_order_release);
    *isSilence = (n == 0);
    return noErr;
}

static void StartAudioEngine(const char *why) {
    if (audioEngine == nil || audioEngine.isRunning) return;
    NSError *err = nil;
    if ([audioEngine startAndReturnError:&err]) {
        Log(LOG_I, @"Audio: output started (%s), route %@", why, AudioRouteText());
    } else {
        Log(LOG_W, @"Audio: output could not start (%s): %@", why, err.localizedDescription);
    }
}

int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION opusConfig, void* context, int flags)
{
    int err;

    // Carry the choice across sessions. Someone who muted because they are in an office is still
    // in that office the next time they connect, and having to find the control again every time
    // is how a setting earns its reputation for not working.
    atomic_store(&audioMuted, [[NSUserDefaults standardUserDefaults] boolForKey:@"audioMuted"]);

    audioConfig = *opusConfig;
    audioBuffer = malloc(opusConfig->samplesPerFrame * sizeof(short) * opusConfig->channelCount);
    ringChannels = opusConfig->channelCount;
    ringFrames = opusConfig->sampleRate * RING_SECONDS;
    ring = calloc((size_t)ringFrames * ringChannels, sizeof(short));
    if (audioBuffer == NULL || ring == NULL) {
        Log(LOG_E, @"Failed to allocate audio buffers");
        ArCleanup();
        return -1;
    }
    atomic_store(&ringWrite, 0);
    atomic_store(&ringRead, 0);
    atomic_store(&ringFlush, false);
    atomic_store(&ringPrimed, false);
    atomic_store(&audioMinBuffered, INT_MAX);
    atomic_store(&audioMaxBuffered, 0);
    atomic_store(&audioUnderruns, 0);
    atomic_store(&audioCallMax, 0);
    atomic_store(&audioSecondMin, INT_MAX);
    audioCallFrames = 0;
    audioCallSeen = CACurrentMediaTime();
    audioTrimFrames = audioTrimmed = 0;
    audioDropped = audioPlayed = 0;
    audioStatsLogged = CACurrentMediaTime();

    opusDecoder = opus_multistream_decoder_create(opusConfig->sampleRate,
                                                  opusConfig->channelCount,
                                                  opusConfig->streams,
                                                  opusConfig->coupledStreams,
                                                  opusConfig->mapping,
                                                  &err);
    if (opusDecoder == NULL) {
        Log(LOG_E, @"Failed to create Opus decoder");
        ArCleanup();
        return -1;
    }

    WatchAudioSession();
    // Mixed with other apps' sound rather than ducking it, as before
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [session setActive:YES error:nil];
    SetAudioLimits();
    audioLimitsSet = CACurrentMediaTime();

    AVAudioFormat *format;
    if (ringChannels <= 2) {
        format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:opusConfig->sampleRate channels:ringChannels];
    } else {
        // the stream's surround order is the MPEG one: L R C LFE, then the rears (and sides)
        AudioChannelLayoutTag tag = ringChannels >= 8 ? kAudioChannelLayoutTag_MPEG_7_1_C
                                  : ringChannels >= 6 ? kAudioChannelLayoutTag_MPEG_5_1_A
                                  : (kAudioChannelLayoutTag_DiscreteInOrder | (UInt32)ringChannels);
        format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:opusConfig->sampleRate
                                                           channelLayout:[AVAudioChannelLayout layoutWithLayoutTag:tag]];
    }
    if (format == nil) {
        Log(LOG_E, @"Audio: no output format for %d channels at %d Hz", ringChannels, opusConfig->sampleRate);
        ArCleanup();
        return -1;
    }
    audioEngine = [[AVAudioEngine alloc] init];
    audioSource = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
                   ^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *outputData) {
        return RenderAudio(isSilence, frameCount, outputData);
    }];
    [audioEngine attachNode:audioSource];
    [audioEngine connect:audioSource to:audioEngine.mainMixerNode format:format];

    // The engine stops when the audio session changes under it (the mic turning on or off switches
    // the category, a route change, an interruption): start it again each time.
    AVAudioEngine *engine = audioEngine;
    audioEngineObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification
                                                                            object:engine queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (engine == audioEngine) StartAudioEngine("configuration changed");
    }];
    audioInterruptionObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
                                                                                  object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if ([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded && engine == audioEngine) {
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            StartAudioEngine("interruption ended");
        }
    }];

    StartAudioEngine("stream start");
    if (!audioEngine.isRunning) {
        ArCleanup();
        return -1;
    }
    Log(LOG_I, @"Audio: %d channel(s) at %d Hz, start after %d ms, at most %d ms queued",
        ringChannels, opusConfig->sampleRate,
        atomic_load(&ringPrefill) * 1000 / opusConfig->sampleRate, atomic_load(&ringCap) * 1000 / opusConfig->sampleRate);
    return 0;
}

/// Whether the stream's sound is being dropped.
+ (BOOL)isAudioMuted {
    return atomic_load(&audioMuted);
}

/// Turn the stream's sound off or on, mid-session or before one starts.
+ (void)setAudioMuted:(BOOL)muted {
    atomic_store(&audioMuted, muted);
    [[NSUserDefaults standardUserDefaults] setBool:muted forKey:@"audioMuted"];

    // Throw away what is already queued. Without this, unmuting starts by playing whatever was
    // buffered at the moment of the mute — a stale burst from seconds ago, arriving as a jolt
    // exactly when the user asked for sound back.
    if (muted) {
        atomic_store(&ringFlush, true);
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:kAudioMuteChangedNotification
                                                        object:nil];
}

void ArCleanup(void)
{
    if (audioEngineObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:audioEngineObserver];
        audioEngineObserver = nil;
    }
    if (audioInterruptionObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:audioInterruptionObserver];
        audioInterruptionObserver = nil;
    }
    if (audioEngine != nil) {
        [audioEngine stop];   // after this the render block is no longer called
        if (audioSource != nil) {
            [audioEngine detachNode:audioSource];
        }
        audioEngine = nil;
        audioSource = nil;
    }

    if (opusDecoder != NULL) {
        opus_multistream_decoder_destroy(opusDecoder);
        opusDecoder = NULL;
    }

    free(audioBuffer);
    audioBuffer = NULL;
    free(ring);
    ring = NULL;
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    // Muted: drop it here, before the decode. The host keeps sending — there is no way to ask it
    // to stop that does not risk the session (Sunshine's audio thread waits on one ping at setup
    // and takes the whole session down if it never comes) — but nothing past this point costs
    // anything, and Opus is the expensive part.
    if (atomic_load(&audioMuted)) {
        return;
    }
    if (opusDecoder == NULL || ring == NULL) {
        return;
    }

    double now = CACurrentMediaTime();
    if (now - audioLimitsSet >= 1) {
        // iOS calls for more at a time in the background: follow it up, and back down two seconds
        // after it stops
        int call = atomic_exchange(&audioCallMax, 0);
        if (call >= audioCallFrames) {
            audioCallFrames = call;
            audioCallSeen = now;
        } else if (now - audioCallSeen >= 2) {
            audioCallFrames = call;
            audioCallSeen = now;
        }
        SetAudioLimits();
        // A queue that never got below the cushion plus a margin for a whole second is delay
        // nobody needs (it builds up while locked and stays after unlocking, putting the sound
        // behind the picture): drop that much, a packet at a time
        int secondMin = atomic_exchange(&audioSecondMin, INT_MAX);
        int keep = atomic_load(&ringPrefill) + audioConfig.sampleRate / 50;   // cushion + 20 ms
        if (secondMin != INT_MAX && secondMin > keep && atomic_load(&ringPrimed)) {
            audioTrimFrames = secondMin - keep;
        }
        audioLimitsSet = now;
    }
    if (now - audioStatsLogged >= 10) {
        int underruns = atomic_exchange(&audioUnderruns, 0);
        int minBuf = atomic_exchange(&audioMinBuffered, INT_MAX);
        int maxBuf = atomic_exchange(&audioMaxBuffered, 0);
        int calls = atomic_exchange(&audioCallbacks, 0);
        if (audioDropped > 0 || underruns > 0 || audioTrimmed > 0) {
            double rate = audioConfig.sampleRate;
            Log(LOG_I, @"Audio: %d packets played, %d dropped (over %d ms queued), %d trimmed, %d run-dry in %d output calls "
                "(largest %d ms); queued %d-%d ms, cushion %d ms; iOS buffer %.1f ms; engine %s, route %@",
                audioPlayed, audioDropped, (int)(atomic_load(&ringCap) * 1000 / rate), audioTrimmed, underruns, calls,
                (int)(audioCallFrames * 1000 / rate),
                minBuf == INT_MAX ? -1 : (int)(minBuf * 1000 / rate), (int)(maxBuf * 1000 / rate),
                (int)(atomic_load(&ringPrefill) * 1000 / rate),
                [AVAudioSession sharedInstance].IOBufferDuration * 1000,
                audioEngine.isRunning ? "running" : "stopped", AudioRouteText());
        }
        audioDropped = audioPlayed = audioTrimmed = 0;
        audioStatsLogged = now;
    }

    int decodeLen = opus_multistream_decode(opusDecoder, (unsigned char *)sampleData, sampleLength,
                                            audioBuffer, audioConfig.samplesPerFrame, 0);
    if (decodeLen <= 0) {
        return;
    }

    if (audioTrimFrames > 0) {
        audioTrimFrames -= decodeLen;
        audioTrimmed++;
        return;
    }
    uint64_t w = atomic_load_explicit(&ringWrite, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ringRead, memory_order_acquire);
    if ((int)(w - r) + decodeLen > atomic_load(&ringCap)) {
        // Already as far behind as we allow: keep the delay bounded rather than let it grow
        audioDropped++;
        return;
    }
    uint32_t at = (uint32_t)(w % ringFrames);
    uint32_t first = MIN((uint32_t)decodeLen, ringFrames - at);
    memcpy(ring + (size_t)at * ringChannels, audioBuffer, (size_t)first * ringChannels * sizeof(short));
    if (first < (uint32_t)decodeLen) {
        memcpy(ring, audioBuffer + (size_t)first * ringChannels, (size_t)(decodeLen - first) * ringChannels * sizeof(short));
    }
    atomic_store_explicit(&ringWrite, w + decodeLen, memory_order_release);
    audioPlayed++;
}

void ClStageStarting(int stage)
{
    [_callbacks stageStarting:LiGetStageName(stage)];
}

void ClStageComplete(int stage)
{
    [_callbacks stageComplete:LiGetStageName(stage)];
}

void ClStageFailed(int stage, int errorCode)
{
    [_callbacks stageFailed:LiGetStageName(stage) withError:errorCode portTestFlags:LiGetPortFlagsFromStage(stage)];
}

void ClConnectionStarted(void)
{
    [_callbacks connectionStarted];
}

void ClConnectionTerminated(int errorCode)
{
    [_callbacks connectionTerminated: errorCode];
}

void ClLogMessage(const char* format, ...)
{
    va_list va;
    va_start(va, format);
    vfprintf(stderr, format, va);
    va_end(va);
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    [_callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

void ClConnectionStatusUpdate(int status)
{
    [_callbacks connectionStatusUpdate:status];
}

void ClSetHdrMode(bool enabled)
{
    [renderer setHdrMode:enabled];
    [_callbacks setHdrMode:enabled];
}

void ClRumbleTriggers(uint16_t controllerNumber, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor)
{
    [_callbacks rumbleTriggers:controllerNumber leftTrigger:leftTriggerMotor rightTrigger:rightTriggerMotor];
}

void ClSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz)
{
    [_callbacks setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

void ClSetControllerLED(uint16_t controllerNumber, uint8_t r, uint8_t g, uint8_t b)
{
    [_callbacks setControllerLed:controllerNumber r:r g:g b:b];
}

-(void) terminate
{
    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnection();
    
    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [initLock lock];
        LiStopConnection();
        [initLock unlock];
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (initLock == nil) {
        initLock = [[NSLock alloc] init];
    }
    
    if (videoStatsLock == nil) {
        videoStatsLock = [[NSLock alloc] init];
    }
    
    NSString *rawAddress = [Utils addressPortStringToAddress:config.host];
    strncpy(_hostString,
            [rawAddress cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_hostString) - 1);
    strncpy(_appVersionString,
            [config.appVersion cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_appVersionString) - 1);
    if (config.gfeVersion != nil) {
        strncpy(_gfeVersionString,
                [config.gfeVersion cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_gfeVersionString) - 1);
    }
    if (config.rtspSessionUrl != nil) {
        strncpy(_rtspSessionUrl,
                [config.rtspSessionUrl cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_rtspSessionUrl) - 1);
    }

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _hostString;
    _serverInfo.serverInfoAppVersion = _appVersionString;
    if (config.gfeVersion != nil) {
        _serverInfo.serverInfoGfeVersion = _gfeVersionString;
    }
    if (config.rtspSessionUrl != nil) {
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }
    _serverInfo.serverCodecModeSupport = config.serverCodecModeSupport;

    renderer = myRenderer;
    _callbacks = callbacks;

    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = config.width;
    _streamConfig.height = config.height;
    _streamConfig.fps = config.frameRate;
    _streamConfig.bitrate = config.bitRate;
    _streamConfig.supportedVideoFormats = config.supportedVideoFormats;
    _streamConfig.audioConfiguration = config.audioConfiguration;
    
    // Since we require iOS 12 or above, we're guaranteed to be running
    // on a 64-bit device with ARMv8 crypto instructions, so we don't
    // need to check for that here.
    _streamConfig.encryptionFlags = ENCFLG_ALL;
    
    if ([Utils isActiveNetworkVPN]) {
        // Force remote streaming mode when a VPN is connected
        _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
        _streamConfig.packetSize = 1024;
    }
    else {
        // Detect remote streaming automatically based on the IP address of the target
        _streamConfig.streamingRemotely = STREAM_CFG_AUTO;
        _streamConfig.packetSize = 1392;
    }

    memcpy(_streamConfig.remoteInputAesKey, [config.riKey bytes], [config.riKey length]);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    int riKeyId = htonl(config.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &riKeyId, sizeof(riKeyId));

    LiInitializeVideoCallbacks(&_drCallbacks);
    _drCallbacks.setup = DrDecoderSetup;
    _drCallbacks.start = DrStart;
    _drCallbacks.stop = DrStop;
    _drCallbacks.capabilities = CAPABILITY_PULL_RENDERER |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;

    LiInitializeAudioCallbacks(&_arCallbacks);
    _arCallbacks.init = ArInit;
    _arCallbacks.cleanup = ArCleanup;
    _arCallbacks.decodeAndPlaySample = ArDecodeAndPlaySample;
    _arCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    LiInitializeConnectionCallbacks(&_clCallbacks);
    _clCallbacks.stageStarting = ClStageStarting;
    _clCallbacks.stageComplete = ClStageComplete;
    _clCallbacks.stageFailed = ClStageFailed;
    _clCallbacks.connectionStarted = ClConnectionStarted;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;
    _clCallbacks.setHdrMode = ClSetHdrMode;
    _clCallbacks.rumbleTriggers = ClRumbleTriggers;
    _clCallbacks.setMotionEventState = ClSetMotionEventState;
    _clCallbacks.setControllerLED = ClSetControllerLED;

    return self;
}

-(void) main
{
    [initLock lock];
    LiStartConnection(&_serverInfo,
                      &_streamConfig,
                      &_clCallbacks,
                      &_drCallbacks,
                      &_arCallbacks,
                      NULL, 0,
                      NULL, 0);
    [initLock unlock];
}

@end
