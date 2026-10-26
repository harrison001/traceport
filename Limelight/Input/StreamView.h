//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "Moonlight-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void) userInteractionBegan;
- (void) userInteractionEnded;

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
#endif

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig;
- (void) showOnScreenControls;
- (OnScreenControlsLevel) getCurrentOscState;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;

/// Brings this device's keyboard up for typing into the host, or puts it away. What three
/// fingers do, for hosts that have a key for it.
- (void) toggleTextInput;
/// Brings it up if it is not already: something on the host is now waiting for text.
- (void) showTextInput;

/// Phone host, real touch: when set, one-finger touches go here instead of steering the host's
/// pointer. Taken up at the start of the next gesture, never in the middle of one.
@property (nonatomic, strong) UIResponder *realTouchHandler;

/// A point in this view as a fraction (0–1) of the picture, clamped to it.
- (CGPoint) normalizedVideoPoint:(CGPoint)viewPoint;
#endif

@end
