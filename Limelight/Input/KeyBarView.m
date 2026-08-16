//
//  KeyBarView.m
//  Moonlight
//

#import "KeyBarView.h"
#import "KeyMacros.h"
#import "KeyboardSupport.h"
#include <Limelight.h>

/// How a key behaves when tapped.
typedef NS_ENUM(NSInteger, KeyBarKeyKind) {
    /// Sends down and up, and consumes any one-shot modifiers.
    KeyBarKeyKindNormal,
    /// Cycles off -> one-shot -> locked -> off.
    KeyBarKeyKindModifier,
    /// Dismisses the bar.
    KeyBarKeyKindDismiss,
    /// Shows or hides the system keyboard, leaving the bar in place.
    KeyBarKeyKindKeyboardToggle,
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

/// Key metrics, measured from RealVNC Viewer on the same two devices (2026-08-15).
///
/// It does not use one size everywhere: 60.0 x 56.5pt on iPad, 32.3 x 33.3pt on iPhone.
/// We match it on iPad, but hold the phone at Apple's 44pt minimum hit target rather than
/// following it down to 33pt, which is below what the guidelines call comfortable.
static const CGFloat padKeyWidth = 60;
static const CGFloat padKeyHeight = 56;
static const CGFloat phoneKeySide = 44;

/// Gap between keys inside a group, and between groups. RealVNC uses 6pt and 33pt on iPad:
/// the wide separator is what lets you find a group without reading the labels.
static const CGFloat keySpacing = 6;
static const CGFloat padGroupSpacing = 33;
static const CGFloat phoneGroupSpacing = 24;

static const CGFloat rowVerticalInset = 8;
static const CGFloat rowHorizontalInset = 12;

@interface KeyBarButton : UIButton
@property (nonatomic, assign) KeyBarKeyKind kind;
@property (nonatomic, assign) short virtualKey;
@property (nonatomic, assign) char modifierMask;
@property (nonatomic, assign) KeyBarModifierState modifierState;
@end

@implementation KeyBarButton
@end

/// Key faces have to be lighter than the bar behind them in both appearances, the way the
/// system keyboard does it. The semantic greys do not give that: in dark mode the "grouped
/// background" colours collapse into the bar and the keys vanish, leaving bare labels.
static UIColor *KeyBarColor(CGFloat lightWhite, CGFloat darkWhite) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        CGFloat white = traits.userInterfaceStyle == UIUserInterfaceStyleDark ? darkWhite : lightWhite;
        return [UIColor colorWithWhite:white alpha:1.0];
    }];
}

static UIColor *KeyBarBackgroundColor(void) {
    return KeyBarColor(0.87, 0.14);
}

/// Normal keys read as the white keys on RealVNC's bar.
static UIColor *KeyBarNormalKeyColor(void) {
    return KeyBarColor(1.00, 0.38);
}

/// Modifiers recede, as they do there.
static UIColor *KeyBarModifierKeyColor(void) {
    return KeyBarColor(0.74, 0.26);
}

@implementation KeyBarView {
    /// Scrolls: the keys themselves.
    UIStackView *_row;
    /// Does not scroll: the controls, which must stay reachable however far the keys scroll.
    UIStackView *_controls;
    NSMutableArray<KeyBarButton *> *_modifierButtons;
    KeyBarButton *_keyboardToggle;
}

/// iPad gets bigger keys than iPhone, as RealVNC does — there is room for them and they are
/// easier to hit.
+ (BOOL)isPad {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

+ (CGFloat)keyWidth {
    return [self isPad] ? padKeyWidth : phoneKeySide;
}

+ (CGFloat)keyHeight {
    return [self isPad] ? padKeyHeight : phoneKeySide;
}

+ (CGFloat)groupSpacing {
    return [self isPad] ? padGroupSpacing : phoneGroupSpacing;
}

+ (CGFloat)barHeight {
    return [self keyHeight] + rowVerticalInset * 2;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _modifierButtons = [NSMutableArray array];

    self.backgroundColor = KeyBarBackgroundColor();

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    // The bar is short and the keys are small; bouncing makes it feel loose.
    scrollView.alwaysBounceHorizontal = NO;
    [self addSubview:scrollView];

    _row = [[UIStackView alloc] initWithFrame:CGRectZero];
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    _row.axis = UILayoutConstraintAxisHorizontal;
    _row.spacing = keySpacing;
    _row.layoutMarginsRelativeArrangement = YES;
    _row.layoutMargins = UIEdgeInsetsMake(rowVerticalInset, rowHorizontalInset,
                                          rowVerticalInset, rowHorizontalInset);
    [scrollView addSubview:_row];

    // Controls live outside the scroll view. With thirty-odd keys, anything inside it can end
    // up several swipes away, and dismissing the bar should never require hunting for the key.
    _controls = [[UIStackView alloc] initWithFrame:CGRectZero];
    _controls.translatesAutoresizingMaskIntoConstraints = NO;
    _controls.axis = UILayoutConstraintAxisHorizontal;
    _controls.spacing = keySpacing;
    _controls.layoutMarginsRelativeArrangement = YES;
    _controls.layoutMargins = UIEdgeInsetsMake(rowVerticalInset, keySpacing,
                                               rowVerticalInset, rowHorizontalInset);
    [self addSubview:_controls];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:_controls.leadingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [_controls.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor],
        [_controls.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_controls.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [_row.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [_row.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [_row.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [_row.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [_row.heightAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor],
    ]];

    // The keys must yield to the controls, never the other way round.
    [_controls setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_controls setContentCompressionResistancePriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];

    [self populateKeys];

    // The caller may have sized us before the keys existed; take the height we actually need.
    CGRect bounds = self.frame;
    bounds.size.height = [KeyBarView barHeight];
    self.frame = bounds;

    return self;
}

/// Used by UIKit when this view is an inputAccessoryView, and by Auto Layout when pinned.
- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, [KeyBarView barHeight]);
}

/// Win32 virtual key codes, matching what the rest of the client sends.
///
/// Ordered in groups separated by a wide gap, the way RealVNC does it: modifiers, then
/// editing keys, then the arrows. The separation is what makes a group findable at a glance,
/// without reading any of the labels.
- (void)populateKeys {
    BOOL macHost = [KeyMacros defaultHost] == KeyMacroHostMacOS;

    // RealVNC offers Command and the Windows key side by side, because it cannot know which
    // host it is driving either. Showing both is the cognitive cost of not knowing; we show
    // the one that belongs to the host instead.
    [self addKeyWithTitle:@"⇧" kind:KeyBarKeyKindModifier virtualKey:0xA0 modifierMask:MODIFIER_SHIFT];
    [self addKeyWithTitle:@"⌃" kind:KeyBarKeyKindModifier virtualKey:0xA2 modifierMask:MODIFIER_CTRL];
    [self addKeyWithTitle:macHost ? @"⌥" : @"alt" kind:KeyBarKeyKindModifier virtualKey:0xA4 modifierMask:MODIFIER_ALT];
    [self addKeyWithTitle:macHost ? @"⌘" : @"⊞" kind:KeyBarKeyKindModifier virtualKey:0x5B modifierMask:MODIFIER_META];

    [self addGroupSeparator];

    // Clipboard chords earn a place on the bar itself: one tap instead of arming a modifier
    // and then finding the letter, and they sit in the first screenful so no scroll is needed.
    for (KeyMacro *macro in [KeyMacros macrosForHost:[KeyMacros defaultHost]]) {
        if (macro.primary) {
            [self addMacroKey:macro];
        }
    }

    [self addGroupSeparator];

    [self addKeyWithTitle:@"esc" kind:KeyBarKeyKindNormal virtualKey:0x1B modifierMask:0];
    [self addKeyWithTitle:@"tab" kind:KeyBarKeyKindNormal virtualKey:0x09 modifierMask:0];
    [self addKeyWithTitle:@"⌦" kind:KeyBarKeyKindNormal virtualKey:0x2E modifierMask:0];
    [self addKeyWithTitle:@"ins" kind:KeyBarKeyKindNormal virtualKey:0x2D modifierMask:0];
    [self addKeyWithTitle:@"↵" kind:KeyBarKeyKindNormal virtualKey:0x0D modifierMask:0];

    [self addGroupSeparator];

    // Requested in moonlight-ios#650, and present in every client surveyed.
    [self addKeyWithTitle:@"←" kind:KeyBarKeyKindNormal virtualKey:0x25 modifierMask:0];
    [self addKeyWithTitle:@"↓" kind:KeyBarKeyKindNormal virtualKey:0x28 modifierMask:0];
    [self addKeyWithTitle:@"↑" kind:KeyBarKeyKindNormal virtualKey:0x26 modifierMask:0];
    [self addKeyWithTitle:@"→" kind:KeyBarKeyKindNormal virtualKey:0x27 modifierMask:0];

    [self addGroupSeparator];

    [self addKeyWithTitle:@"↖" kind:KeyBarKeyKindNormal virtualKey:0x24 modifierMask:0];
    [self addKeyWithTitle:@"↘" kind:KeyBarKeyKindNormal virtualKey:0x23 modifierMask:0];
    [self addKeyWithTitle:@"⇞" kind:KeyBarKeyKindNormal virtualKey:0x21 modifierMask:0];
    [self addKeyWithTitle:@"⇟" kind:KeyBarKeyKindNormal virtualKey:0x22 modifierMask:0];

    [self addGroupSeparator];

    // VK_F1 through VK_F12 are consecutive from 0x70.
    for (short i = 0; i < 12; i++) {
        [self addKeyWithTitle:[NSString stringWithFormat:@"F%d", i + 1]
                         kind:KeyBarKeyKindNormal
                   virtualKey:0x70 + i
                 modifierMask:0];
    }

    [self addGroupSeparator];

    [self addKeyWithTitle:@"Pause" kind:KeyBarKeyKindNormal virtualKey:0x13 modifierMask:0];
    [self addKeyWithTitle:@"Break" kind:KeyBarKeyKindNormal virtualKey:0x03 modifierMask:0];

    [self populateControls];
}

/// The three controls that never scroll away.
- (void)populateControls {
    [self addMacroButton];
    _keyboardToggle = [self addKeyWithTitle:@"⌨" kind:KeyBarKeyKindKeyboardToggle
                                 virtualKey:0 modifierMask:0 toStack:_controls];
    [self addKeyWithTitle:@"Done" kind:KeyBarKeyKindDismiss
               virtualKey:0 modifierMask:0 toStack:_controls];
}

- (void)setSystemKeyboardVisible:(BOOL)visible {
    // Struck through when tapping it would bring the keyboard back.
    [_keyboardToggle setTitle:visible ? @"⌨" : @"⌨̶" forState:UIControlStateNormal];
    _keyboardToggle.backgroundColor = visible ? KeyBarNormalKeyColor() : KeyBarModifierKeyColor();
}

/// One button opening a menu of named actions, rather than a dozen more keys.
///
/// This is TeamViewer's shape, and it is the only way to reach chords whose other half lives
/// on the system keyboard — Command-Space cannot be assembled from this bar at all when a
/// hardware keyboard is attached and the system keyboard is therefore not shown.
- (void)addMacroButton {
    KeyBarButton *button = [KeyBarButton buttonWithType:UIButtonTypeSystem];
    button.kind = KeyBarKeyKindNormal;
    [button setTitle:@"⋯" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:[KeyBarView isPad] ? 22 : 19
                                               weight:UIFontWeightMedium];
    button.layer.cornerRadius = 8;
    button.backgroundColor = KeyBarNormalKeyColor();
    button.tintColor = [UIColor labelColor];
    [button.heightAnchor constraintEqualToConstant:[KeyBarView keyHeight]].active = YES;
    [button.widthAnchor constraintEqualToConstant:[KeyBarView keyWidth]].active = YES;

    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (KeyMacro *macro in [KeyMacros macrosForHost:[KeyMacros defaultHost]]) {
        UIAction *action = [UIAction actionWithTitle:macro.help
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction *_Nonnull sender) {
            [KeyboardSupport sendChordWithVirtualKey:macro.virtualKey modifierFlags:macro.modifiers];
        }];
        action.subtitle = macro.label;
        [actions addObject:action];
    }

    button.menu = [UIMenu menuWithTitle:@"" children:actions];
    button.showsMenuAsPrimaryAction = YES;

    [_row addArrangedSubview:button];
}

/// A whole chord on one key, sent as a unit rather than assembled from the bar.
- (void)addMacroKey:(KeyMacro *)macro {
    KeyBarButton *button = [self addKeyWithTitle:macro.label
                                            kind:KeyBarKeyKindNormal
                                      virtualKey:macro.virtualKey
                                    modifierMask:0
                                         toStack:_row];

    // Its own modifiers, not the bar's: pressing Copy should not also apply a locked Shift.
    [button removeTarget:self action:@selector(keyPressed:) forControlEvents:UIControlEventTouchUpInside];
    UIKeyModifierFlags modifiers = macro.modifiers;
    short virtualKey = macro.virtualKey;
    UIAction *send = [UIAction actionWithHandler:^(__kindof UIAction *_Nonnull action) {
        [KeyboardSupport sendChordWithVirtualKey:virtualKey modifierFlags:modifiers];
    }];
    [button addAction:send forControlEvents:UIControlEventTouchUpInside];
}

/// A wide gap between groups. Implemented as an empty view because UIStackView applies its
/// spacing uniformly and cannot vary it per gap.
- (void)addGroupSeparator {
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.widthAnchor constraintEqualToConstant:[KeyBarView groupSpacing] - keySpacing * 2].active = YES;
    [_row addArrangedSubview:spacer];
}

- (KeyBarButton *)addKeyWithTitle:(NSString *)title
                             kind:(KeyBarKeyKind)kind
                       virtualKey:(short)virtualKey
                     modifierMask:(char)modifierMask {
    return [self addKeyWithTitle:title kind:kind virtualKey:virtualKey modifierMask:modifierMask toStack:_row];
}

- (KeyBarButton *)addKeyWithTitle:(NSString *)title
                             kind:(KeyBarKeyKind)kind
                       virtualKey:(short)virtualKey
                     modifierMask:(char)modifierMask
                          toStack:(UIStackView *)stack {
    KeyBarButton *button = [KeyBarButton buttonWithType:UIButtonTypeSystem];
    button.kind = kind;
    button.virtualKey = virtualKey;
    button.modifierMask = modifierMask;
    button.modifierState = KeyBarModifierStateOff;

    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:[KeyBarView isPad] ? 20 : 17
                                               weight:UIFontWeightMedium];
    button.layer.cornerRadius = 8;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);

    // Uniform width, as RealVNC does: a regular grid is easier to hit than keys that vary
    // with the length of their label. Wider only where the label genuinely needs it.
    CGFloat width = [KeyBarView keyWidth];
    if (title.length > 3) {
        width = MAX(width, [KeyBarView keyWidth] * 1.4);
    }
    [button.heightAnchor constraintEqualToConstant:[KeyBarView keyHeight]].active = YES;
    [button.widthAnchor constraintEqualToConstant:width].active = YES;

    [button addTarget:self action:@selector(keyPressed:) forControlEvents:UIControlEventTouchUpInside];

    if (kind == KeyBarKeyKindModifier) {
        [_modifierButtons addObject:button];
    }

    [self applyAppearance:button];
    [stack addArrangedSubview:button];

    return button;
}

- (void)applyAppearance:(KeyBarButton *)button {
    switch (button.modifierState) {
        case KeyBarModifierStateOff:
            // Resting colour encodes the kind of key, as RealVNC does: modifiers read as grey
            // and everything else as white, so the bar is scannable by shade alone.
            button.backgroundColor = button.kind == KeyBarKeyKindModifier
                ? KeyBarModifierKeyColor()
                : KeyBarNormalKeyColor();
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

        case KeyBarKeyKindKeyboardToggle:
            [self.delegate keyBarDidToggleSystemKeyboard];
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
