//
//  StreamView.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamView.h"
#include <Limelight.h>
#import "DataManager.h"
#import "ControllerSupport.h"
#import "KeyboardSupport.h"
#import "RelativeTouchHandler.h"
#import "AbsoluteTouchHandler.h"
#import "KeyboardInputField.h"

#if !TARGET_OS_TV
#import "KeyBarView.h"
#import "CaretTracker.h"

@interface StreamView () <KeyBarViewDelegate, KeyBarPadObserver>
@end
#endif

static const double X1_MOUSE_SPEED_DIVISOR = 2.5;

@implementation StreamView {
    OnScreenControls* onScreenControls;

    KeyboardInputField* keyInputField;
    BOOL isInputingText;
    NSMutableSet* keysDown;
#if !TARGET_OS_TV
    /// The line above the system keyboard: modifiers, escape, tab, return, delete, arrows.
    KeyBarView* keyBar;
    /// The columns down the letterbox: a short list of macros the user chose. Nil when the
    /// stream leaves no letterbox to put them in, and then keyBar carries both.
    KeyBarView* macroPad;
    CaretTracker* caretTracker;
    /// How far the picture is currently lifted to clear the keyboard.
    CGFloat pictureLift;
    BOOL caretLogged;
    BOOL systemKeyboardVisible;
    /// Identifies the host, so its operating system is remembered per machine.
    NSString* hostKey;
    /// The app launched on the host, which gives each app its own bar customisations.
    NSString* streamedAppName;
#endif
    
    float streamAspectRatio;
    
    // iOS 13.4 mouse support
    NSInteger lastMouseButtonMask;
    float lastMouseX;
    float lastMouseY;
    CGPoint lastScrollTranslation;
    
    // Citrix X1 mouse support
    X1Mouse* x1mouse;
    double accumulatedMouseDeltaX;
    double accumulatedMouseDeltaY;
    
    UIResponder* touchHandler;
    
    id<UserInteractionDelegate> interactionDelegate;
    NSTimer* interactionTimer;
    BOOL hasUserInteracted;
    
    NSDictionary<NSString *, NSNumber *> *dictCodes;
}

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig {
    self->interactionDelegate = interactionDelegate;
    self->streamAspectRatio = (float)streamConfig.width / (float)streamConfig.height;
#if !TARGET_OS_TV
    self->hostKey = streamConfig.host;
    self->streamedAppName = streamConfig.appName;
#endif
    
    TemporarySettings* settings = [[[DataManager alloc] init] getSettings];
    
    keysDown = [[NSMutableSet alloc] init];
    keyInputField = [[KeyboardInputField alloc] initWithFrame:CGRectZero];
    [keyInputField setKeyboardType:UIKeyboardTypeDefault];
    [keyInputField setAutocorrectionType:UITextAutocorrectionTypeNo];
    [keyInputField setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [keyInputField setSpellCheckingType:UITextSpellCheckingTypeNo];
    [self addSubview:keyInputField];
    
#if TARGET_OS_TV
    // tvOS requires RelativeTouchHandler to manage Apple Remote input
    self->touchHandler = [[RelativeTouchHandler alloc] initWithView:self];
#else
    // iOS uses RelativeTouchHandler or AbsoluteTouchHandler depending on user preference
    if (settings.absoluteTouchMode) {
        self->touchHandler = [[AbsoluteTouchHandler alloc] initWithView:self];
    }
    else {
        self->touchHandler = [[RelativeTouchHandler alloc] initWithView:self];
    }
    
    onScreenControls = [[OnScreenControls alloc] initWithView:self controllerSup:controllerSupport streamConfig:streamConfig];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    if (settings.absoluteTouchMode) {
        Log(LOG_I, @"On-screen controls disabled in absolute touch mode");
        [onScreenControls setLevel:OnScreenControlsLevelOff];
    }
    else if (level == OnScreenControlsLevelAuto) {
        [controllerSupport initAutoOnScreenControlMode:onScreenControls];
    }
    else {
        Log(LOG_I, @"Setting manual on-screen controls level: %d", (int)level);
        [onScreenControls setLevel:level];
    }
    
    // It would be nice to just use GCMouse on iOS 14+ and the older API on iOS 13
    // but unfortunately that isn't possible today. GCMouse doesn't recognize many
    // mice correctly, but UIKit does. We will register for both and ignore UIKit
    // events if a GCMouse is connected.
    if (@available(iOS 13.4, *)) {
        [self addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self]];
        
        UIPanGestureRecognizer *discreteMouseWheelRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mouseWheelMovedDiscrete:)];
        discreteMouseWheelRecognizer.maximumNumberOfTouches = 0;
        discreteMouseWheelRecognizer.allowedScrollTypesMask = UIScrollTypeMaskDiscrete;
        discreteMouseWheelRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:discreteMouseWheelRecognizer];
        
        UIPanGestureRecognizer *continuousMouseWheelRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mouseWheelMovedContinuous:)];
        continuousMouseWheelRecognizer.maximumNumberOfTouches = 0;
        continuousMouseWheelRecognizer.allowedScrollTypesMask = UIScrollTypeMaskContinuous;
        continuousMouseWheelRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:continuousMouseWheelRecognizer];
    }
    
#if defined(__IPHONE_16_1) || defined(__TVOS_16_1)
    if (@available(iOS 16.1, *)) {
        UIHoverGestureRecognizer *stylusHoverRecognizer = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(sendStylusHoverEvent:)];
        stylusHoverRecognizer.allowedTouchTypes = @[@(UITouchTypePencil)];
        [self addGestureRecognizer:stylusHoverRecognizer];
    }
#endif
#endif
    
    x1mouse = [[X1Mouse alloc] init];
    x1mouse.delegate = self;
    
    if (settings.btMouseSupport) {
        [x1mouse start];
    }
    
    // This is critical to ensure keyboard events are delivered to this
    // StreamView and not our parent UIView, especially on tvOS.
    [self becomeFirstResponder];
}

- (void)startInteractionTimer {
    // Restart user interaction tracking
    hasUserInteracted = NO;
    
    BOOL timerAlreadyRunning = interactionTimer != nil;
    
    // Start/restart the timer
    [interactionTimer invalidate];
    interactionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                        target:self
                        selector:@selector(interactionTimerExpired:)
                        userInfo:nil
                        repeats:NO];
    
    // Notify the delegate if this was a new user interaction
    if (!timerAlreadyRunning) {
        [interactionDelegate userInteractionBegan];
    }
}

- (void)interactionTimerExpired:(NSTimer *)timer {
    if (!hasUserInteracted) {
        // User has finished touching the screen
        interactionTimer = nil;
        [interactionDelegate userInteractionEnded];
    }
    else {
        // User is still touching the screen. Restart the timer.
        [self startInteractionTimer];
    }
}

- (void) showOnScreenControls {
#if !TARGET_OS_TV
    [onScreenControls show];
#endif
}

- (OnScreenControlsLevel) getCurrentOscState {
    if (onScreenControls == nil) {
        return OnScreenControlsLevelOff;
    }
    else {
        return [onScreenControls getLevel];
    }
}

- (CGSize) getVideoAreaSize {
    if (self.bounds.size.width > self.bounds.size.height * streamAspectRatio) {
        return CGSizeMake(self.bounds.size.height * streamAspectRatio, self.bounds.size.height);
    } else {
        return CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
    }
}

- (CGPoint) adjustCoordinatesForVideoArea:(CGPoint)point {
    // These are now relative to the StreamView, however we need to scale them
    // further to make them relative to the actual video portion.
    float x = point.x - self.bounds.origin.x;
    float y = point.y - self.bounds.origin.y;
    
    // For some reason, we don't seem to always get to the bounds of the window
    // so we'll subtract 1 pixel if we're to the left/below of the origin and
    // and add 1 pixel if we're to the right/above. It should be imperceptible
    // to the user but it will allow activation of gestures that require contact
    // with the edge of the screen (like Aero Snap).
    if (x < self.bounds.size.width / 2) {
        x--;
    }
    else {
        x++;
    }
    if (y < self.bounds.size.height / 2) {
        y--;
    }
    else {
        y++;
    }
    
    // This logic mimics what iOS does with AVLayerVideoGravityResizeAspect
    CGSize videoSize = [self getVideoAreaSize];
    CGPoint videoOrigin = CGPointMake(self.bounds.size.width / 2 - videoSize.width / 2,
                                      self.bounds.size.height / 2 - videoSize.height / 2);
    
    // Confine the cursor to the video region. We don't just discard events outside
    // the region because we won't always get one exactly when the mouse leaves the region.
    return CGPointMake(MIN(MAX(x, videoOrigin.x), videoOrigin.x + videoSize.width) - videoOrigin.x,
                       MIN(MAX(y, videoOrigin.y), videoOrigin.y + videoSize.height) - videoOrigin.y);
}

#if !TARGET_OS_TV

- (uint16_t)getRotationFromAzimuthAngle:(float)azimuthAngle {
    // iOS reports azimuth of 0 when the stylus is pointing west, but Moonlight expects
    // rotation of 0 to mean the stylus is pointing north. Rotate the azimuth angle
    // clockwise by 90 degrees to convert from iOS to Moonlight rotation conventions.
    int32_t rotationAngle = (azimuthAngle - M_PI_2) * (180.f / M_PI);
    if (rotationAngle < 0) {
        rotationAngle += 360;
    }
    return (uint16_t)rotationAngle;
}

- (uint8_t)getTiltFromAltitudeAngle:(float)altitudeAngle {
    // iOS reports an altitude of 0 when the stylus is parallel to the touch surface,
    // while Moonlight expects a tilt of 0 when the stylus is perpendicular to the surface.
    // Subtract the tilt angle from 90 to convert from iOS to Moonlight tilt conventions.
    uint8_t altitudeDegs = abs((int16_t)(altitudeAngle * (180.f / M_PI)));
    return 90 - MIN(90, altitudeDegs);
}

- (BOOL)sendStylusEvent:(UITouch*)event {
    uint8_t type;
    
    // Don't touch stylus events if the host doesn't support them. We want to pass
    // them as normal touches for legacy hosts that don't understand pen events.
    if (!(LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS)) {
        return NO;
    }
    
    switch (event.phase) {
        case UITouchPhaseBegan:
            type = LI_TOUCH_EVENT_DOWN;
            break;
        case UITouchPhaseMoved:
            type = LI_TOUCH_EVENT_MOVE;
            break;
        case UITouchPhaseEnded:
            type = LI_TOUCH_EVENT_UP;
            break;
        case UITouchPhaseCancelled:
            type = LI_TOUCH_EVENT_CANCEL;
            break;
        default:
            return YES;
    }

    CGPoint location = [self adjustCoordinatesForVideoArea:[event locationInView:self]];
    CGSize videoSize = [self getVideoAreaSize];
    
    return LiSendPenEvent(type, LI_TOOL_TYPE_PEN, 0, location.x / videoSize.width, location.y / videoSize.height,
                          (event.force / event.maximumPossibleForce) / sin(event.altitudeAngle),
                          0.0f, 0.0f,
                          [self getRotationFromAzimuthAngle:[event azimuthAngleInView:self]],
                          [self getTiltFromAltitudeAngle:event.altitudeAngle]) != LI_ERR_UNSUPPORTED;
}

- (void)sendStylusHoverEvent:(UIHoverGestureRecognizer*)gesture API_AVAILABLE(ios(13.0)) {
    uint8_t type;
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            type = LI_TOUCH_EVENT_HOVER;
            break;

        case UIGestureRecognizerStateEnded:
            type = LI_TOUCH_EVENT_HOVER_LEAVE;
            break;

        default:
            return;
    }

    CGPoint location = [self adjustCoordinatesForVideoArea:[gesture locationInView:self]];
    CGSize videoSize = [self getVideoAreaSize];
    
    float distance = 0.0f;
#if defined(__IPHONE_16_1) || defined(__TVOS_16_1)
    if (@available(iOS 16.1, *)) {
        distance = gesture.zOffset;
    }
#endif
    
    uint16_t rotationAngle = LI_ROT_UNKNOWN;
    uint8_t tiltAngle = LI_TILT_UNKNOWN;
#if defined(__IPHONE_16_4) || defined(__TVOS_16_4)
    if (@available(iOS 16.4, *)) {
        rotationAngle = [self getRotationFromAzimuthAngle:[gesture azimuthAngleInView:self]];
        tiltAngle = [self getTiltFromAltitudeAngle:gesture.altitudeAngle];
    }
#endif
    
    LiSendPenEvent(type, LI_TOOL_TYPE_PEN, 0, location.x / videoSize.width, location.y / videoSize.height,
                   distance, 0.0f, 0.0f, rotationAngle, tiltAngle);
}

#endif

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self handleMouseButtonEvent:BUTTON_ACTION_PRESS
                          forTouches:touches
                           withEvent:event]) {
        // If it's a mouse event, we're done
        return;
    }
    
    Log(LOG_D, @"Touch down");
    
    // Notify of user interaction and start expiration timer
    [self startInteractionTimer];
    
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) {
                    return;
                }
            }
        }
    }
#endif
    
    if (![onScreenControls handleTouchDownEvent:touches]) {
        // We still inform the touch handler even if we're going trigger the
        // keyboard activation gesture. This is important to ensure the touch
        // handler has a consistent view of touch events to correctly suppress
        // activation of one or two finger gestures when a three finger gesture
        // is triggered.
        [touchHandler touchesBegan:touches withEvent:event];
        
        if ([[event allTouches] count] == 3) {
            if (isInputingText) {
                Log(LOG_D, @"Closing the keyboard");
#if !TARGET_OS_TV
                [self dismissKeyBar];
#else
                [keyInputField resignFirstResponder];
#endif
                isInputingText = false;
            } else {
                Log(LOG_D, @"Opening the keyboard");
                // Prepare the textbox used to capture keyboard events.
                keyInputField.delegate = self;
                keyInputField.text = @"0";
#if !TARGET_OS_TV
                [self createKeyBars];

                // With a hardware keyboard attached there is nothing to type on screen, and
                // the system keyboard would cover half the picture for no reason. Start
                // without it, as Jump Desktop and RealVNC do — but this is only the starting
                // point now; the bar carries a key to change it either way.
                [self presentKeyBarWithSystemKeyboard:![self hasHardwareKeyboard]];
#else
                [keyInputField becomeFirstResponder];
#endif
                [keyInputField addTarget:self action:@selector(onKeyboardPressed:) forControlEvents:UIControlEventEditingChanged];
                
                // Undo causes issues for our state management, so turn it off
                [keyInputField.undoManager disableUndoRegistration];
                
                isInputingText = true;
            }
        }
    }
}

#if !TARGET_OS_TV

/// Whether a physical keyboard is attached, in which case the system keyboard is dead weight.
- (BOOL)hasHardwareKeyboard {
    if (@available(iOS 14.0, *)) {
        return [GCKeyboard coalescedKeyboard] != nil;
    }
    return NO;
}

/// Builds both layers: the keyboard, and the pad if this screen has a letterbox to put it in.
- (void)createKeyBars {
    if ([self keyBarMarginWidth] > 0) {
        macroPad = [[KeyBarView alloc] initWithFrame:self.bounds
                                             hostKey:hostKey
                                             appName:streamedAppName
                                             content:KeyBarContentPad];
        macroPad.delegate = self;
        [self pinMacroPad];
    }
    [self createKeyboardBar];
}

/// The line above the system keyboard. Carries the pad's contents too where there is no pad,
/// because otherwise the macros would have nowhere to live.
- (void)createKeyboardBar {
    keyBar = [[KeyBarView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 44)
                                       hostKey:hostKey
                                       appName:streamedAppName
                                       content:macroPad != nil ? KeyBarContentKeyboard
                                                               : KeyBarContentBoth];
    keyBar.delegate = self;
    keyBar.padDelegate = self;
}

/// Puts the pad in the letterbox: both strips, with the middle passing through to the stream.
- (void)pinMacroPad {
    UIView *host = [self keyBarHostView];
    macroPad.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:macroPad];
    [macroPad setSplitLayoutWithMarginWidth:[self keyBarMarginWidth]];
    [NSLayoutConstraint activateConstraints:@[
        [macroPad.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [macroPad.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [macroPad.topAnchor constraintEqualToAnchor:host.topAnchor],
        [macroPad.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
}

/// Shows the key bar, with or without the system keyboard under it.
///
/// The bar is the same object either way, so held modifiers survive the switch: this changes
/// what is on screen, not what the host believes is pressed.
- (void)presentKeyBarWithSystemKeyboard:(BOOL)withSystemKeyboard {
    if (withSystemKeyboard) {
        // As an inputAccessoryView, UIKit owns the frame and the bar lies along the top of the
        // system keyboard — which is exactly where a keyboard's missing keys belong.
        [keyBar removeFromSuperview];
        [keyBar setAxis:UILayoutConstraintAxisHorizontal];
        keyBar.translatesAutoresizingMaskIntoConstraints = YES;

        keyInputField.inputAccessoryView = keyBar;
        [keyInputField reloadInputViews];
        [keyInputField becomeFirstResponder];
        // The keyboard's own guide takes over keeping the columns clear.
        macroPad.bottomInset = 0;
    } else {
        // The line stays; it just moves out of the keyboard's window and pins itself along the
        // bottom. Held modifiers survive the move, which is the whole point of it being the
        // same object either way.
        // Resign first, then let go of the accessory view. UIKit wraps an inputAccessoryView in
        // a UICompatibilityInputViewController owned by the keyboard's UIInputWindowController;
        // moving the view out while that is still standing throws
        // UIViewControllerHierarchyInconsistency. Resigning takes the wrapper down first.
        [keyInputField resignFirstResponder];
        keyInputField.inputAccessoryView = nil;
        [self pinKeyBar];
        // And the columns stop above it rather than running underneath.
        macroPad.bottomInset = [KeyBarView barThickness];
    }

    systemKeyboardVisible = withSystemKeyboard;
    [keyBar setSystemKeyboardVisible:withSystemKeyboard];
    [macroPad setSystemKeyboardVisible:withSystemKeyboard];
    [self updateCaretTracking];
}

#pragma mark - Keeping what you are typing into on screen

/// Follows the host's caret only while the keyboard is covering the picture, which is the only
/// time any of it matters.
- (void)updateCaretTracking {
    if (!systemKeyboardVisible) {
        [caretTracker stop];
        caretTracker = nil;
        [self liftPictureBy:0];
        return;
    }
    if (caretTracker != nil) {
        return;
    }

    caretLogged = NO;
    caretTracker = [[CaretTracker alloc] initWithHost:hostKey];
    __weak StreamView *weakSelf = self;
    caretTracker.onCaret = ^(CGRect normalisedCaret, BOOL precise) {
        [weakSelf caretMovedTo:normalisedCaret precise:precise];
    };
    [caretTracker start];
}

/// Lifts the picture just far enough that the caret clears the top of the keyboard.
///
/// The caret arrives as a fraction of the host's display, so it lands wherever the picture is
/// drawn without the client knowing anything about resolutions. A caret the host cannot report
/// leaves the picture where it is rather than guessing — half the applications do not report
/// one, and a picture that jumps to the wrong place is worse than one that does not move.
- (void)caretMovedTo:(CGRect)normalisedCaret precise:(BOOL)precise {
    if (CGRectIsNull(normalisedCaret)) {
        return;
    }

    CGSize video = [self getVideoAreaSize];
    CGFloat videoTop = (self.bounds.size.height - video.height) / 2;

    // The pointer standing in for a caret has no height, and clearing a bare point by eight
    // points leaves the line it sits on still under the keyboard. Give it a line's worth.
    CGFloat height = normalisedCaret.size.height > 0 ? normalisedCaret.size.height : 0.025;
    CGFloat caretBottom = videoTop + (normalisedCaret.origin.y + height) * video.height;

    // Measured on a view that does not move. Reading the keyboard from this view means reading
    // it through the very transform the reading decides, and any such loop settles somewhere
    // other than where it should — correcting for it afterwards is guesswork about what UIKit
    // does with layout guides under a transform. The host view is never lifted, so there is no
    // loop to reason about.
    UIView *reference = [self keyBarHostView];
    CGFloat keyboardTop = reference.bounds.size.height;
    if (@available(iOS 15.0, *)) {
        keyboardTop = reference.keyboardLayoutGuide.layoutFrame.origin.y;
    }

    if (keyboardTop <= 0 || keyboardTop >= self.bounds.size.height) {
        [self liftPictureBy:0];
        return;
    }

    // A line of clearance, so the caret is not sitting exactly on the keyboard's edge.
    CGFloat margin = height * video.height + 8;
    CGFloat needed = caretBottom + margin - keyboardTop;
    CGFloat lift = MAX(0, MIN(needed, videoTop + video.height));
    if (!caretLogged) {
        caretLogged = YES;
        Log(LOG_I, @"%@ at %.3f,%.3f -> bottom %.0fpt, keyboard top %.0fpt, lift %.0fpt",
            precise ? @"Caret" : @"Pointer",
            normalisedCaret.origin.x, normalisedCaret.origin.y, caretBottom, keyboardTop, lift);
    }
    [self liftPictureBy:lift];
}

/// Moves the picture up without touching the stream view's own transform, which the scroll view
/// owns for pinch zoom in touchscreen mode. Touch coordinates follow the move on their own,
/// because everything is still measured inside the view that moved.
- (void)liftPictureBy:(CGFloat)points {
    // A caret moving along its line changes this by a point or two constantly; re-animating for
    // that is what makes the picture look like it is breathing.
    if (fabs(points - pictureLift) < 12 && !(points == 0 && pictureLift != 0)) {
        return;
    }
    pictureLift = points;

    UIView *moved = [self.superview isKindOfClass:[UIScrollView class]] ? self.superview : self;
    [UIView animateWithDuration:0.2 animations:^{
        moved.transform = CGAffineTransformMakeTranslation(0, -points);
    }];
}

/// How much black there is down each side of the picture, or zero if there is not enough to
/// hold a column of keys.
///
/// The letterbox is the difference between the shape of the stream and the shape of the
/// screen. A 1512x982 Mac desktop on an iPhone in landscape leaves 139pt each side; the same
/// desktop on an iPad leaves about 4pt, and there the bar has to cover picture instead.
- (CGFloat)keyBarMarginWidth {
    UIView *host = [self keyBarHostView];
    CGFloat margin = (host.bounds.size.width - [self getVideoAreaSize].width) / 2;
    return margin >= [KeyBarView barThickness] ? margin : 0;
}

/// Pins the keyboard line along the bottom. Only reached where there is no pad, since with a
/// pad the line lives above the system keyboard or not at all.
- (void)pinKeyBar {
    UIView *host = [self keyBarHostView];
    if (keyBar.superview == host) {
        return;
    }

    keyBar.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:keyBar];
    [keyBar setAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [keyBar.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [keyBar.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [keyBar.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
}

/// The view the key bar hangs off.
///
/// In touchscreen mode the stream view sits inside a UIScrollView so the picture can be
/// pinched and panned. Anything parented to the stream view is scaled and scrolled with the
/// picture — a key bar attached there grows to ten times its size and slides off screen the
/// moment you zoom. The bar is a control, not part of the image, so it hangs off the scroll
/// view's parent, which does not move. In trackpad mode there is no scroll view and the
/// stream view is itself the right parent.
- (UIView *)keyBarHostView {
    if ([self.superview isKindOfClass:[UIScrollView class]] && self.superview.superview != nil) {
        return self.superview.superview;
    }
    // Never this view. It is the one that gets lifted to clear the keyboard, and controls that
    // ride up and down with the picture are worse than no controls.
    return self.superview ?: self;
}

- (void)keyBarPadDidChange {
    [macroPad reloadPad];
}

- (void)keyBarDidToggleSystemKeyboard:(KeyBarView *)bar {
    if (keyBar == nil) {
        // Pressed on the pad after the keyboard was dismissed: bring the whole layer back.
        [self createKeyboardBar];
        [self presentKeyBarWithSystemKeyboard:YES];
        return;
    }
    [self presentKeyBarWithSystemKeyboard:!systemKeyboardVisible];
}

- (void)keyBarDidRequestSystemKeyboard:(KeyBarView *)bar {
    if (keyBar == nil) {
        [self createKeyboardBar];
    }
    if (!systemKeyboardVisible || keyBar.superview != nil) {
        [self presentKeyBarWithSystemKeyboard:YES];
    }
}

- (void)keyBar:(KeyBarView *)bar requestsAppNameWithCompletion:(void (^)(NSString *))completion {
    UIViewController *presenter = nil;
    for (UIResponder *responder = self; responder != nil; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            presenter = (UIViewController *)responder;
            break;
        }
    }
    if (presenter == nil) {
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Add App"
                                            message:@"One tap opens it: Spotlight, this name, Return."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Terminal";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        completion(alert.textFields.firstObject.text ?: @"");
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

/// Closes one layer, not both.
///
/// Done on the keyboard puts the keyboard away — the system keyboard with it — and leaves the
/// pad floating in the margins. ✕ on the pad puts the pad away. Whichever goes last takes the
/// session's text input with it.
- (void)keyBarDidRequestDismiss:(KeyBarView *)bar {
    if (bar == macroPad) {
        [macroPad removeFromSuperview];
        macroPad = nil;
        // The line was carrying only the keyboard because the pad had the macros. With the pad
        // gone it has to carry both, or the macros become unreachable.
        if (keyBar != nil) {
            BOOL keyboardWasVisible = systemKeyboardVisible;
            [self teardownKeyboardBar];
            [self createKeyboardBar];
            [self presentKeyBarWithSystemKeyboard:keyboardWasVisible];
        }
    } else {
        [self teardownKeyboardBar];
        macroPad.bottomInset = 0;
    }

    if (keyBar == nil && macroPad == nil) {
        [self dismissKeyBar];
    }
}

/// Takes the keyboard line down without touching the pad.
- (void)teardownKeyboardBar {
    [keyBar releaseHeldModifiers];
    [keyInputField resignFirstResponder];
    keyInputField.inputAccessoryView = nil;
    [keyBar removeFromSuperview];
    keyBar = nil;
    systemKeyboardVisible = NO;
}

/// Tears the key bar down by whichever route it was shown, releasing any held modifiers.
///
/// Skipping the release would leave the host with a modifier stuck down, and every
/// subsequent keystroke would silently arrive modified.
- (void)dismissKeyBar {
    [caretTracker stop];
    caretTracker = nil;
    [self liftPictureBy:0];
    [self teardownKeyboardBar];
    [macroPad removeFromSuperview];
    macroPad = nil;
    isInputingText = false;
}

- (void)keyBarDidRequestDismiss {
    [keyInputField resignFirstResponder];
    [self dismissKeyBar];
    isInputingText = false;
}

#endif

- (UIBarButtonItem *)createButtonWithImageNamed:(NSString *)imageName backgroundColor:(UIColor *)backgroundColor target:(id)target action:(SEL)action keyCode:(NSInteger)keyCode isToggleable:(BOOL)isToggleable {
    UIImage *image = [UIImage imageNamed:imageName];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setImage:image forState:UIControlStateNormal];
    button.frame = CGRectMake(0, 0, 30, 30);
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    button.imageView.backgroundColor = backgroundColor;
    button.imageView.layer.cornerRadius = 10.0;
    button.imageEdgeInsets = UIEdgeInsetsMake(6, 6, 6, 6);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, "keyCode", @(keyCode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, "isToggleable", @(isToggleable), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, "isOn", @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIBarButtonItem *barButton = [[UIBarButtonItem alloc] initWithCustomView:button];
    return barButton;
}

- (void)toolbarButtonClicked:(UIButton *)sender {
    BOOL isToggleable = [objc_getAssociatedObject(sender, "isToggleable") boolValue];
    BOOL isOn = [objc_getAssociatedObject(sender, "isOn") boolValue];
    if (isToggleable){
        isOn = !isOn;
        // Update the button's appearance based on its new state
        if (isOn) {
            sender.imageView.backgroundColor = [UIColor lightGrayColor];
        } else {
            sender.imageView.backgroundColor = [UIColor blackColor];
        }
    }
    // Update the new on/off state of the button
    objc_setAssociatedObject(sender, "isOn", @(isOn), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Get the keyCode parameter and convert to short for key press event
    short keyCode = [objc_getAssociatedObject(sender, "keyCode") shortValue];
    // Close keyboard if done button clicked
    if (!keyCode) {
        [keyInputField resignFirstResponder];
        isInputingText = false;
    }
    else {
        // Send key press event using keyCode parameter, toggle if necessary
        if (isToggleable){
            if (isOn){
                LiSendKeyboardEvent(keyCode, KEY_ACTION_DOWN, 0);
                [keysDown addObject:@(keyCode)];
            } else {
                LiSendKeyboardEvent(keyCode, KEY_ACTION_UP, 0);
                [keysDown removeObject:@(keyCode)];
            }
        }
        else {
            LiSendKeyboardEvent(keyCode, KEY_ACTION_DOWN, 0);
            usleep(50 * 1000);
            LiSendKeyboardEvent(keyCode, KEY_ACTION_UP, 0);
        }
    }
}

- (BOOL)handleMouseButtonEvent:(int)buttonAction forTouches:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        UITouch* touch = [touches anyObject];
        if (touch.type == UITouchTypeIndirectPointer) {
            if (@available(iOS 14.0, *)) {
                if ([GCMouse current] != nil) {
                    // We'll handle this with GCMouse. Do nothing here.
                    return YES;
                }
            }
            
            UIEventButtonMask normalizedButtonMask;
            
            // iOS 14 includes the released button in the buttonMask for the release
            // event, while iOS 13 does not. Normalize that behavior here.
            if (@available(iOS 14.0, *)) {
                if (buttonAction == BUTTON_ACTION_RELEASE) {
                    normalizedButtonMask = lastMouseButtonMask & ~event.buttonMask;
                }
                else {
                    normalizedButtonMask = event.buttonMask;
                }
            }
            else {
                normalizedButtonMask = event.buttonMask;
            }
            
            UIEventButtonMask changedButtons = lastMouseButtonMask ^ normalizedButtonMask;
                        
            for (int i = BUTTON_LEFT; i <= BUTTON_X2; i++) {
                UIEventButtonMask buttonFlag;
                
                switch (i) {
                    // Right and Middle are reversed from what iOS uses
                    case BUTTON_RIGHT:
                        buttonFlag = UIEventButtonMaskForButtonNumber(2);
                        break;
                    case BUTTON_MIDDLE:
                        buttonFlag = UIEventButtonMaskForButtonNumber(3);
                        break;
                        
                    default:
                        buttonFlag = UIEventButtonMaskForButtonNumber(i);
                        break;
                }
                
                if (changedButtons & buttonFlag) {
                    LiSendMouseButtonEvent(buttonAction, i);
                }
            }
            
            lastMouseButtonMask = normalizedButtonMask;
            return YES;
        }
    }
#endif
    
    return NO;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) {
                    return;
                }
            }
        }
        
        UITouch *touch = [touches anyObject];
        if (touch.type == UITouchTypeIndirectPointer) {
            if (@available(iOS 14.0, *)) {
                if ([GCMouse current] != nil) {
                    // We'll handle this with GCMouse. Do nothing here.
                    return;
                }
            }
            
            // We must handle this event to properly support
            // drags while the middle, X1, or X2 mouse buttons are
            // held down. For some reason, left and right buttons
            // don't require this, but we do it anyway for them too.
            // Cursor movement without a button held down is handled
            // in pointerInteraction:regionForRequest:defaultRegion.
            [self updateCursorLocation:[touch locationInView:self] isMouse:YES];
            return;
        }
    }
#endif
    
    hasUserInteracted = YES;
    
    if (![onScreenControls handleTouchMovedEvent:touches]) {
        [touchHandler touchesMoved:touches withEvent:event];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    
    if (@available(iOS 13.4, tvOS 13.4, *)) {
        for (UIPress* press in presses) {
            // For now, we'll treated it as handled if we handle at least one of the
            // UIPress events inside the set.
            if ([KeyboardSupport sendKeyEventForPress:press down:YES]) {
                // This will prevent the legacy UITextField from receiving the event
                handled = YES;
            }
        }
    }
    
    if (!handled) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    
    if (@available(iOS 13.4, tvOS 13.4, *)) {
        for (UIPress* press in presses) {
            // For now, we'll treated it as handled if we handle at least one of the
            // UIPress events inside the set.
            if ([KeyboardSupport sendKeyEventForPress:press down:NO]) {
                // This will prevent the legacy UITextField from receiving the event
                handled = YES;
            }
        }
    }
    
    if (!handled) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self handleMouseButtonEvent:BUTTON_ACTION_RELEASE
                          forTouches:touches
                           withEvent:event]) {
        // If it's a mouse event, we're done
        return;
    }
    
    Log(LOG_D, @"Touch up");
    
    hasUserInteracted = YES;
    
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) {
                    return;
                }
            }
        }
    }
#endif
    
    if (![onScreenControls handleTouchUpEvent:touches]) {
        [touchHandler touchesEnded:touches withEvent:event];
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [touchHandler touchesCancelled:touches withEvent:event];
    [self handleMouseButtonEvent:BUTTON_ACTION_RELEASE
                      forTouches:touches
                       withEvent:event];
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                [self sendStylusEvent:touch];
            }
        }
    }
#endif
}

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse {
    CGPoint normalizedLocation = [self adjustCoordinatesForVideoArea:location];
    CGSize videoSize = [self getVideoAreaSize];
    
    // Send the mouse position relative to the video region if it has changed
    // if we're receiving coordinates from a real mouse.
    //
    // NB: It is important for functionality (not just optimization) to only
    // send it if the value has changed. We will receive one of these events
    // any time the user presses a modifier key, which can result in errant
    // mouse motion when using a Citrix X1 mouse.
    if (normalizedLocation.x != lastMouseX || normalizedLocation.y != lastMouseY || !isMouse) {
        if (lastMouseX != 0 || lastMouseY != 0 || !isMouse) {
            LiSendMousePositionEvent(normalizedLocation.x, normalizedLocation.y, videoSize.width, videoSize.height);
        }
        
        if (isMouse) {
            lastMouseX = normalizedLocation.x;
            lastMouseY = normalizedLocation.y;
        }
    }
}

- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction
                       regionForRequest:(UIPointerRegionRequest *)request
                          defaultRegion:(UIPointerRegion *)defaultRegion API_AVAILABLE(ios(13.4)) {
    if (@available(iOS 14.0, *)) {
        if ([GCMouse current] != nil) {
            // We'll handle this with GCMouse. Do nothing here.
            return nil;
        }
    }
    
    // This logic mimics what iOS does with AVLayerVideoGravityResizeAspect
    CGSize videoSize;
    CGPoint videoOrigin;
    if (self.bounds.size.width > self.bounds.size.height * streamAspectRatio) {
        videoSize = CGSizeMake(self.bounds.size.height * streamAspectRatio, self.bounds.size.height);
    } else {
        videoSize = CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
    }
    videoOrigin = CGPointMake(self.bounds.size.width / 2 - videoSize.width / 2,
                              self.bounds.size.height / 2 - videoSize.height / 2);
    
    // Move the cursor on the host if no buttons are pressed.
    // Motion with buttons pressed in handled in touchesMoved:
    if (lastMouseButtonMask == 0) {
        [self updateCursorLocation:request.location isMouse:YES];
    }
    
    // The pointer interaction should cover the video region only
    return [UIPointerRegion regionWithRect:CGRectMake(videoOrigin.x, videoOrigin.y, videoSize.width, videoSize.height) identifier:nil];
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region  API_AVAILABLE(ios(13.4)) {
    // Always hide the mouse cursor over our stream view
    return [UIPointerStyle hiddenPointerStyle];
}

- (void)mouseWheelMovedContinuous:(UIPanGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            break;
        
        case UIGestureRecognizerStateEnded:
        default:
            // Ignore recognition failure and other states
            lastScrollTranslation = CGPointMake(0, 0);
            return;
    }
    
    CGPoint currentScrollTranslation = [gesture translationInView:self];
    const short translationMultiplier = 120 * 20; // WHEEL_DELTA * 20
    
    {
        short translationDeltaY = ((currentScrollTranslation.y - lastScrollTranslation.y) / self.bounds.size.height) * translationMultiplier;
        if (translationDeltaY != 0) {
            LiSendHighResScrollEvent(translationDeltaY);
            lastScrollTranslation = currentScrollTranslation;
        }
    }

    {
        short translationDeltaX = ((currentScrollTranslation.x - lastScrollTranslation.x) / self.bounds.size.width) * translationMultiplier;
        if (translationDeltaX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHighResHScrollEvent(-translationDeltaX);
            lastScrollTranslation = currentScrollTranslation;
        }
    }
}

- (void)mouseWheelMovedDiscrete:(UIPanGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            break;
        
        case UIGestureRecognizerStateEnded:
        default:
            // Ignore recognition failure and other states
            lastScrollTranslation = CGPointMake(0, 0);
            return;
    }
    
    // Using velocityInView is 0 for discrete scroll events
    // when scrolling very slowly, but translationInView does work.
    CGPoint currentScrollTranslation = [gesture translationInView:self];
    
    {
        short translationDeltaY = currentScrollTranslation.y - lastScrollTranslation.y;
        if (translationDeltaY != 0) {
            LiSendScrollEvent(translationDeltaY > 0 ? 1 : -1);
        }
    }

    {
        short translationDeltaX = currentScrollTranslation.x - lastScrollTranslation.x;
        if (translationDeltaX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHScrollEvent(translationDeltaX < 0 ? 1 : -1);
        }
    }
    
    lastScrollTranslation = currentScrollTranslation;
}

#endif

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (@available(iOS 13.0, *)) {
        // Disable the 3 finger tap gestures that trigger the copy/paste/undo toolbar on iOS 13+
        return gestureRecognizer.name == nil || ![gestureRecognizer.name hasPrefix:@"kbProductivity."];
    }
    else {
        return YES;
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // This method is called when the "Return" key is pressed.
    LiSendKeyboardEvent(0x0d, KEY_ACTION_DOWN, 0);
    usleep(50 * 1000);
    LiSendKeyboardEvent(0x0d, KEY_ACTION_UP, 0);
    return NO;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    for (NSNumber* keyCode in keysDown) {
        LiSendKeyboardEvent([keyCode shortValue], KEY_ACTION_UP, 0);
    }
    [keysDown removeAllObjects];
}

- (void)onKeyboardPressed:(UITextField *)textField {
    // While an input method is composing, the field holds the composition in progress rather
    // than anything the user has committed. Sending it types the pinyin letters one by one and
    // then the characters they turn into, which is why typing Chinese produced nonsense.
    // Wait for the commit; UIKit clears markedTextRange then and this fires again.
    if (textField.markedTextRange != nil) {
        return;
    }

    NSString* inputText = textField.text;
#if !TARGET_OS_TV
    // A modifier armed on the key bar applies to this keystroke and then stops, exactly as it
    // would for a key on the bar itself.
    [keyBar externalKeyWasTyped];
#endif
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // If the text became empty, we know the user pressed the backspace key.
        if ([inputText isEqual:@""]) {
            LiSendKeyboardEvent(0x08, KEY_ACTION_DOWN, 0);
            usleep(50 * 1000);
            LiSendKeyboardEvent(0x08, KEY_ACTION_UP, 0);
        } else {
            // Character 0 will be our known sentinel value
            
            // Check if any characters exist which can't be represented in a basic key event
            for (int i = 1; i < [inputText length]; i++) {
                struct KeyEvent event = [KeyboardSupport translateKeyEvent:[inputText characterAtIndex:i] withModifierFlags:0];
                if (event.keycode == 0) {
                    // We found an unknown key, so send the entire string as UTF-8
                    const char* utf8String = [inputText UTF8String];
                    
                    // Skip the first character which is our sentinel
                    LiSendUtf8TextEvent(utf8String + 1, (int)strlen(utf8String) - 1);
                    return;
                }
            }
            
            // We didn't find any unknown characters, so send them all as basic key events
            for (int i = 1; i < [inputText length]; i++) {
                struct KeyEvent event = [KeyboardSupport translateKeyEvent:[inputText characterAtIndex:i] withModifierFlags:0];
                assert(event.keycode != 0);
                [self sendLowLevelEvent:event];
            }
        }
    });
    
    // Reset text field back to known state
    textField.text = @"0";
    
    // Move the insertion point back to the end of the text box
    UITextRange *textRange = [textField textRangeFromPosition:textField.endOfDocument toPosition:textField.endOfDocument];
    [textField setSelectedTextRange:textRange];
}

- (void)specialCharPressed:(UIKeyCommand *)cmd {
    struct KeyEvent event = [KeyboardSupport translateKeyEvent:0x20 withModifierFlags:[cmd modifierFlags]];
    event.keycode = [[dictCodes valueForKey:[cmd input]] intValue];
    [self sendLowLevelEvent:event];
}

- (void)keyPressed:(UIKeyCommand *)cmd {
    struct KeyEvent event = [KeyboardSupport translateKeyEvent:[[cmd input] characterAtIndex:0] withModifierFlags:[cmd modifierFlags]];
    [self sendLowLevelEvent:event];
}

- (void)sendLowLevelEvent:(struct KeyEvent)event {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // When we want to send a modified key (like uppercase letters) we need to send the
        // modifier ("shift") seperately from the key itself.
        if (event.modifier != 0) {
            LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_DOWN, event.modifier);
        }
        // Let the host know these are not (necessarily) normalized to US English scancodes
        LiSendKeyboardEvent2(event.keycode, KEY_ACTION_DOWN, event.modifier, SS_KBE_FLAG_NON_NORMALIZED);
        usleep(50 * 1000);
        LiSendKeyboardEvent2(event.keycode, KEY_ACTION_UP, event.modifier, SS_KBE_FLAG_NON_NORMALIZED);
        if (event.modifier != 0) {
            LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_UP, event.modifier);
        }
    });
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

/// Chords that iPadOS acts on itself and never delivers as UIPress events, so the HID path in
/// pressesBegan: never sees them and the host never receives them. Claiming them as key
/// commands with wantsPriorityOverSystemBehavior is the only way to forward them.
///
/// `input` is what UIKit matches on; `virtualKey` is the Win32 code the host receives.
static const struct {
    const char *input;
    UIKeyModifierFlags modifiers;
    short virtualKey;
} systemReservedChords[] = {
    // Input source switching, and Spotlight on the iPad side.
    { " ",  UIKeyModifierCommand,                        0x20 },  // VK_SPACE
    { " ",  UIKeyModifierCommand | UIKeyModifierControl, 0x20 },
    // App switching.
    { "\t", UIKeyModifierCommand,                        0x09 },  // VK_TAB
    { "\t", UIKeyModifierCommand | UIKeyModifierShift,   0x09 },
    // Window and application management, all swallowed by iPadOS.
    { "h",  UIKeyModifierCommand,                        0x48 },
    { "h",  UIKeyModifierCommand | UIKeyModifierShift,   0x48 },
    { "q",  UIKeyModifierCommand,                        0x51 },
    { "w",  UIKeyModifierCommand,                        0x57 },
    { "m",  UIKeyModifierCommand,                        0x4D },
    // Cycle windows of the same application.
    { "`",  UIKeyModifierCommand,                        0xC0 },  // VK_OEM_3
    { "`",  UIKeyModifierCommand | UIKeyModifierShift,   0xC0 },
};

- (NSArray<UIKeyCommand *> *)systemReservedKeyCommands API_AVAILABLE(ios(15.0)) {
    NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray array];

    for (size_t i = 0; i < sizeof(systemReservedChords) / sizeof(systemReservedChords[0]); i++) {
        UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:@(systemReservedChords[i].input)
                                                    modifierFlags:systemReservedChords[i].modifiers
                                                           action:@selector(systemReservedChordPressed:)];

        // Without this, iPadOS keeps acting on the chord itself and the action never fires.
        command.wantsPriorityOverSystemBehavior = YES;

        [commands addObject:command];
    }

    return commands;
}

- (void)systemReservedChordPressed:(UIKeyCommand *)command API_AVAILABLE(ios(15.0)) {
    for (size_t i = 0; i < sizeof(systemReservedChords) / sizeof(systemReservedChords[0]); i++) {
        if (systemReservedChords[i].modifiers == command.modifierFlags &&
            [@(systemReservedChords[i].input) isEqualToString:command.input]) {
            [KeyboardSupport sendChordWithVirtualKey:systemReservedChords[i].virtualKey
                                       modifierFlags:command.modifierFlags];
            return;
        }
    }
}

- (NSArray<UIKeyCommand *> *)keyCommands
{
    NSString *charset = @"qwertyuiopasdfghjklzxcvbnm1234567890\t§[]\\'\"/.,`<>-´ç+`¡'º;ñ= ";
    
    NSMutableArray<UIKeyCommand *> * commands = [NSMutableArray<UIKeyCommand *> array];
    dictCodes = [[NSDictionary alloc] initWithObjectsAndKeys: [NSNumber numberWithInt: 0x0d], @"\r", [NSNumber numberWithInt: 0x08], @"\b", [NSNumber numberWithInt: 0x1b], UIKeyInputEscape, [NSNumber numberWithInt: 0x28], UIKeyInputDownArrow, [NSNumber numberWithInt: 0x26], UIKeyInputUpArrow, [NSNumber numberWithInt: 0x25], UIKeyInputLeftArrow, [NSNumber numberWithInt: 0x27], UIKeyInputRightArrow, nil];
    
    [charset enumerateSubstringsInRange:NSMakeRange(0, charset.length)
                                options:NSStringEnumerationByComposedCharacterSequences
                             usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:0 action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierShift action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierControl action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierAlternate action:@selector(keyPressed:)]];
                             }];
    
    for (NSString *c in [dictCodes keyEnumerator]) {
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:0
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift | UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift | UIKeyModifierControl
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierControl
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierControl | UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
    }

    // Everything above reaches us through the ordinary responder chain. The system-reserved
    // chords do not, and need to be claimed explicitly.
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        [commands addObjectsFromArray:[self systemReservedKeyCommands]];
    }

    return commands;
}

- (void)connectedStateDidChangeWithIdentifier:(NSUUID * _Nonnull)identifier isConnected:(BOOL)isConnected {
    NSLog(@"Citrix X1 mouse state change: %@ -> %s",
          identifier, isConnected ? "connected" : "disconnected");
}

- (void)mouseDidMoveWithIdentifier:(NSUUID * _Nonnull)identifier deltaX:(int16_t)deltaX deltaY:(int16_t)deltaY {
    accumulatedMouseDeltaX += deltaX / X1_MOUSE_SPEED_DIVISOR;
    accumulatedMouseDeltaY += deltaY / X1_MOUSE_SPEED_DIVISOR;
    
    short shortX = (short)accumulatedMouseDeltaX;
    short shortY = (short)accumulatedMouseDeltaY;
    
    if (shortX == 0 && shortY == 0) {
        return;
    }
    
    LiSendMouseMoveEvent(shortX, shortY);
    
    accumulatedMouseDeltaX -= shortX;
    accumulatedMouseDeltaY -= shortY;
}

- (int) buttonFromX1ButtonCode:(enum X1MouseButton)button {
    switch (button) {
        case X1MouseButtonLeft:
            return BUTTON_LEFT;
        case X1MouseButtonRight:
            return BUTTON_RIGHT;
        case X1MouseButtonMiddle:
            return BUTTON_MIDDLE;
        default:
            return -1;
    }
}

- (void)mouseDownWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, [self buttonFromX1ButtonCode:button]);
}

- (void)mouseUpWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {
    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, [self buttonFromX1ButtonCode:button]);
}

- (void)wheelDidScrollWithIdentifier:(NSUUID * _Nonnull)identifier deltaZ:(int8_t)deltaZ {
    LiSendScrollEvent(deltaZ);
}

#if !TARGET_OS_TV
- (BOOL)isMultipleTouchEnabled {
    return YES;
}
#endif

@end
