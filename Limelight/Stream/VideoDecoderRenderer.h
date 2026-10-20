//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;

#import "ConnectionCallbacks.h"

#include "Limelight.h"

@interface VideoDecoderRenderer : NSObject

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)start;
- (void)stop;
- (void)setHdrMode:(BOOL)enabled;

- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du;

/// Picture in Picture for the stream being shown. Leaving the app (Home, another app) shrinks the
/// picture into a floating window and keeps the connection, instead of ending the stream; coming
/// back puts it full screen again. Needs iOS 15 (a PiP source can be a sample buffer layer from 15).
+ (BOOL)pictureInPicturePossible;
+ (BOOL)pictureInPictureActive;
+ (void)stopPictureInPicture;

@end

/// Posted when the user closes the Picture in Picture window while the app is in the background:
/// they are done with the stream, so the stream view ends it.
extern NSString *const VideoDecoderRendererPictureInPictureClosedNotification;
