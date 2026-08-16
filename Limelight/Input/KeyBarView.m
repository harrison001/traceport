//
//  KeyBarView.m
//  Moonlight
//

#import "KeyBarView.h"
#include <Limelight.h>

/// How a key behaves when tapped.
typedef NS_ENUM(NSInteger, KeyBarKeyKind) {
    /// Sends down and up, and consumes any one-shot modifiers.
    KeyBarKeyKindNormal,
    /// Cycles off -> one-shot -> locked -> off.
    KeyBarKeyKindModifier,
    /// Dismisses the bar.
    KeyBarKeyKindDismiss,
};

/// What a modifier is currently doing.
typedef NS_ENUM(NSInteger, KeyBarModifierState) {
    KeyBarModifierStateOff,
    /// Held for exactly one key, then released. Tapping once gets you here.
    KeyBarModifierStateOneShot,
    /// Held until tapped again. Tapping a second time gets you here.
    KeyBarModifierStateLocked,
};

/// Time in microseconds a normal key is held before being released.
static const useconds_t keyPressHoldTime = 50 * 1000;

@interface KeyBarButton : UIButton
@property (nonatomic, assign) KeyBarKeyKind kind;
@property (nonatomic, assign) short virtualKey;
@property (nonatomic, assign) char modifierMask;
@property (nonatomic, assign) KeyBarModifierState modifierState;
@end

@implementation KeyBarButton
@end

@implementation KeyBarView {
    UIStackView *_row;
    NSMutableArray<KeyBarButton *> *_modifierButtons;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _modifierButtons = [NSMutableArray array];

    self.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    // The bar is short and the keys are small; bouncing makes it feel loose.
    scrollView.alwaysBounceHorizontal = NO;
    [self addSubview:scrollView];

    _row = [[UIStackView alloc] initWithFrame:CGRectZero];
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    _row.axis = UILayoutConstraintAxisHorizontal;
    _row.spacing = 6;
    _row.layoutMarginsRelativeArrangement = YES;
    _row.layoutMargins = UIEdgeInsetsMake(6, 10, 6, 10);
    [scrollView addSubview:_row];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [_row.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [_row.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [_row.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [_row.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [_row.heightAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor],
    ]];

    [self populateKeys];

    return self;
}

/// Win32 virtual key codes, matching what the rest of the client sends.
- (void)populateKeys {
    [self addKeyWithTitle:@"Done" kind:KeyBarKeyKindDismiss virtualKey:0 modifierMask:0];

    [self addKeyWithTitle:@"esc" kind:KeyBarKeyKindNormal virtualKey:0x1B modifierMask:0];
    [self addKeyWithTitle:@"tab" kind:KeyBarKeyKindNormal virtualKey:0x09 modifierMask:0];

    [self addKeyWithTitle:@"⇧" kind:KeyBarKeyKindModifier virtualKey:0xA0 modifierMask:MODIFIER_SHIFT];
    [self addKeyWithTitle:@"⌃" kind:KeyBarKeyKindModifier virtualKey:0xA2 modifierMask:MODIFIER_CTRL];
    [self addKeyWithTitle:@"⌥" kind:KeyBarKeyKindModifier virtualKey:0xA4 modifierMask:MODIFIER_ALT];
    [self addKeyWithTitle:@"⌘" kind:KeyBarKeyKindModifier virtualKey:0x5B modifierMask:MODIFIER_META];

    // Requested in moonlight-ios#650, and present in every client surveyed.
    [self addKeyWithTitle:@"←" kind:KeyBarKeyKindNormal virtualKey:0x25 modifierMask:0];
    [self addKeyWithTitle:@"↓" kind:KeyBarKeyKindNormal virtualKey:0x28 modifierMask:0];
    [self addKeyWithTitle:@"↑" kind:KeyBarKeyKindNormal virtualKey:0x26 modifierMask:0];
    [self addKeyWithTitle:@"→" kind:KeyBarKeyKindNormal virtualKey:0x27 modifierMask:0];

    [self addKeyWithTitle:@"⌦" kind:KeyBarKeyKindNormal virtualKey:0x2E modifierMask:0];
}

- (void)addKeyWithTitle:(NSString *)title
                   kind:(KeyBarKeyKind)kind
             virtualKey:(short)virtualKey
           modifierMask:(char)modifierMask {
    KeyBarButton *button = [KeyBarButton buttonWithType:UIButtonTypeSystem];
    button.kind = kind;
    button.virtualKey = virtualKey;
    button.modifierMask = modifierMask;
    button.modifierState = KeyBarModifierStateOff;

    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    button.layer.cornerRadius = 6;
    button.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;

    [button addTarget:self action:@selector(keyPressed:) forControlEvents:UIControlEventTouchUpInside];

    if (kind == KeyBarKeyKindModifier) {
        [_modifierButtons addObject:button];
    }

    [self applyAppearance:button];
    [_row addArrangedSubview:button];
}

- (void)applyAppearance:(KeyBarButton *)button {
    switch (button.modifierState) {
        case KeyBarModifierStateOff:
            button.backgroundColor = [UIColor tertiarySystemBackgroundColor];
            button.layer.borderWidth = 0;
            break;
        case KeyBarModifierStateOneShot:
            // Filled: armed, but only for the next key.
            button.backgroundColor = [UIColor systemBlueColor];
            button.layer.borderWidth = 0;
            break;
        case KeyBarModifierStateLocked:
            // Filled and outlined: staying down until tapped again.
            button.backgroundColor = [UIColor systemBlueColor];
            button.layer.borderWidth = 2;
            button.layer.borderColor = [UIColor labelColor].CGColor;
            break;
    }

    button.tintColor = button.modifierState == KeyBarModifierStateOff
        ? [UIColor labelColor]
        : [UIColor whiteColor];
}

- (void)keyPressed:(KeyBarButton *)button {
    switch (button.kind) {
        case KeyBarKeyKindDismiss:
            [self.delegate keyBarDidRequestDismiss];
            return;

        case KeyBarKeyKindModifier:
            [self advanceModifier:button];
            return;

        case KeyBarKeyKindNormal:
            [self sendKey:button.virtualKey];
            [self consumeOneShotModifiers];
            return;
    }
}

/// off -> one-shot -> locked -> off.
///
/// Deliberately a state machine rather than a double-tap gesture: recognising a double tap
/// delays every single tap by the double-tap interval, which is unacceptable for a keyboard.
/// Tapping twice in a row still reaches the locked state, so it behaves the way a user
/// expects "double tap to lock" to behave, without the latency.
- (void)advanceModifier:(KeyBarButton *)button {
    switch (button.modifierState) {
        case KeyBarModifierStateOff:
            button.modifierState = KeyBarModifierStateOneShot;
            LiSendKeyboardEvent(button.virtualKey, KEY_ACTION_DOWN, [self activeModifierMask]);
            break;

        case KeyBarModifierStateOneShot:
            // Already held on the host; only our intent changes.
            button.modifierState = KeyBarModifierStateLocked;
            break;

        case KeyBarModifierStateLocked:
            button.modifierState = KeyBarModifierStateOff;
            LiSendKeyboardEvent(button.virtualKey, KEY_ACTION_UP, [self activeModifierMask]);
            break;
    }

    [self applyAppearance:button];
}

- (char)activeModifierMask {
    char mask = 0;
    for (KeyBarButton *button in _modifierButtons) {
        if (button.modifierState != KeyBarModifierStateOff) {
            mask |= button.modifierMask;
        }
    }
    return mask;
}

- (void)sendKey:(short)virtualKey {
    char mask = [self activeModifierMask];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        LiSendKeyboardEvent(virtualKey, KEY_ACTION_DOWN, mask);
        usleep(keyPressHoldTime);
        LiSendKeyboardEvent(virtualKey, KEY_ACTION_UP, mask);
    });
}

/// Releases the modifiers that were armed for a single key. Locked ones stay down.
- (void)consumeOneShotModifiers {
    for (KeyBarButton *button in _modifierButtons) {
        if (button.modifierState == KeyBarModifierStateOneShot) {
            button.modifierState = KeyBarModifierStateOff;
            LiSendKeyboardEvent(button.virtualKey, KEY_ACTION_UP, [self activeModifierMask]);
            [self applyAppearance:button];
        }
    }
}

- (void)releaseHeldModifiers {
    for (KeyBarButton *button in _modifierButtons) {
        if (button.modifierState != KeyBarModifierStateOff) {
            button.modifierState = KeyBarModifierStateOff;
            LiSendKeyboardEvent(button.virtualKey, KEY_ACTION_UP, 0);
            [self applyAppearance:button];
        }
    }
}

@end
