//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import "StreamConfiguration.h"

#define CONN_TEST_SERVER "ios.conntest.moonlight-stream.org"

typedef struct {
    CFTimeInterval startTime;
    CFTimeInterval endTime;
    int totalFrames;
    int receivedFrames;
    int networkDroppedFrames;
    int totalHostProcessingLatency;
    int framesWithHostProcessingLatency;
    int maxHostProcessingLatency;
    int minHostProcessingLatency;
} video_stats_t;

@interface Connection : NSOperation <NSStreamDelegate>

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
-(void) terminate;
-(void) main;
-(BOOL) getVideoStats:(video_stats_t*)stats;
-(NSString*) getActiveCodecName;

/// Posted whenever the mute state changes, so anything showing it can catch up.
///
/// The state is one process-wide flag but it is displayed in more than one place — the keyboard
/// bar and the pad are separate views, each holding a menu built when it was created. Toggling in
/// one used to leave the other showing what it said a moment ago. A broadcast keeps every display
/// right without any of them knowing the others exist, and stays right if a third appears.
extern NSString * const kAudioMuteChangedNotification;

/// The stream's sound, on or off.
///
/// A client-side drop, not a request to the host: it stops the packets at the decoder and leaves
/// the host streaming. That is the only shape available — Sunshine sends audio unconditionally,
/// and its audio thread takes the session down if the client never completes the audio setup — so
/// this buys quiet, not bandwidth. Quiet is what was asked for.
///
/// Class methods because the audio path is process-wide: one decoder, one device, set up by the
/// C callbacks rather than by any instance.
+ (BOOL)isAudioMuted;
+ (void)setAudioMuted:(BOOL)muted;

@end
