//
//  AbsoluteTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "AbsoluteTouchHandler.h"

#include <Limelight.h>

// How long the fingers must be stationary to start a right click
#define LONG_PRESS_ACTIVATION_DELAY 0.650f

// How far the finger can move before it cancels a right click
#define LONG_PRESS_ACTIVATION_DELTA 0.01f

// How long the double tap deadzone stays in effect between touch up and touch down
#define DOUBLE_TAP_DEAD_ZONE_DELAY 0.250f

// How far the finger can move before it can override the double tap deadzone
#define DOUBLE_TAP_DEAD_ZONE_DELTA 0.025f

// Phone mode: how long a press waits for a second finger (a two-finger scroll must not tap)
#define PHONE_PRESS_DELAY 0.070f

@implementation AbsoluteTouchHandler {
    StreamView* view;
    
    NSTimer* longPressTimer;
    UITouch* lastTouchDown;
    CGPoint lastTouchDownLocation;
    UITouch* lastTouchUp;
    CGPoint lastTouchUpLocation;

    BOOL phoneMode;
    NSTimer* pressTimer;     // phone mode: pending press
    BOOL pressed;            // left button is down for this gesture
    BOOL multiTouch;         // a second finger joined: this gesture never presses
}

- (id)initWithView:(StreamView*)view {
    return [self initWithView:view phoneMode:NO];
}

- (id)initWithView:(StreamView*)view phoneMode:(BOOL)mode {
    self = [self init];
    self->view = view;
    self->phoneMode = mode;
    return self;
}

- (void)pressNow {
    [pressTimer invalidate];
    pressTimer = nil;
    if (!pressed && !multiTouch) {
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
        pressed = YES;
    }
}

- (void)onPressDelayElapsed:(NSTimer*)timer {
    pressTimer = nil;
    [self pressNow];
}

- (void)onLongPressStart:(NSTimer*)timer {
    // Raise the left click and start a right click
    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    // Ignore touch down events with more than one finger
    if ([[event allTouches] count] > 1) {
        if (phoneMode && !pressed) {
            // A second finger before the press went out: a two-finger gesture, not a tap
            multiTouch = YES;
            [pressTimer invalidate];
            pressTimer = nil;
        }
        return;
    }
    multiTouch = NO;
    
    UITouch* touch = [touches anyObject];
    CGPoint touchLocation = [touch locationInView:view];
    
    // Don't reposition for finger down events within the deadzone. This makes double-clicking easier.
    if (touch.timestamp - lastTouchUp.timestamp > DOUBLE_TAP_DEAD_ZONE_DELAY ||
        sqrt(pow((touchLocation.x / view.bounds.size.width) - (lastTouchUpLocation.x / view.bounds.size.width), 2) +
             pow((touchLocation.y / view.bounds.size.height) - (lastTouchUpLocation.y / view.bounds.size.height), 2)) > DOUBLE_TAP_DEAD_ZONE_DELTA) {
        [view updateCursorLocation:touchLocation isMouse:NO];
    }
    
    if (phoneMode) {
        // Wait briefly for a second finger; a long press on a phone stays a long press
        [pressTimer invalidate];
        pressTimer = [NSTimer scheduledTimerWithTimeInterval:PHONE_PRESS_DELAY
                                                      target:self
                                                    selector:@selector(onPressDelayElapsed:)
                                                    userInfo:nil
                                                     repeats:NO];
    }
    else {
        // Press the left button down
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
        pressed = YES;

        // Start the long press timer
        longPressTimer = [NSTimer scheduledTimerWithTimeInterval:LONG_PRESS_ACTIVATION_DELAY
                                                          target:self
                                                        selector:@selector(onLongPressStart:)
                                                        userInfo:nil
                                                         repeats:NO];
    }
    
    lastTouchDown = touch;
    lastTouchDownLocation = touchLocation;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    // Ignore touch move events with more than one finger
    if ([[event allTouches] count] > 1) {
        return;
    }
    
    UITouch* touch = [touches anyObject];
    CGPoint touchLocation = [touch locationInView:view];
    
    if (sqrt(pow((touchLocation.x / view.bounds.size.width) - (lastTouchDownLocation.x / view.bounds.size.width), 2) +
             pow((touchLocation.y / view.bounds.size.height) - (lastTouchDownLocation.y / view.bounds.size.height), 2)) > LONG_PRESS_ACTIVATION_DELTA) {
        // Moved too far since touch down. Cancel the long press timer.
        [longPressTimer invalidate];
        longPressTimer = nil;

        // Phone mode: a swipe has started, so press now, still at the start point
        if (phoneMode && pressTimer != nil) {
            [self pressNow];
        }
    }
    if (multiTouch) {
        return;
    }
    
    [view updateCursorLocation:[[touches anyObject] locationInView:view] isMouse:NO];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    // Only fire this logic if all touches have ended
    if ([[event allTouches] count] == [touches count]) {
        // Cancel the long press timer
        [longPressTimer invalidate];
        longPressTimer = nil;

        // Phone mode: a tap quicker than the press delay still taps
        if (phoneMode && pressTimer != nil) {
            [self pressNow];
        }
        pressed = NO;
        multiTouch = NO;

        // Left button up on finger up
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);

        // Raise right button too in case we triggered a long press gesture
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        
        // Remember this last touch for touch-down deadzoning
        lastTouchUp = [touches anyObject];
        lastTouchUpLocation = [lastTouchUp locationInView:view];
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    // Treat this as a normal touchesEnded event
    [self touchesEnded:touches withEvent:event];
}

@end
