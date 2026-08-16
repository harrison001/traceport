//
//  KeyBarView.m
//  Moonlight
//

#import "KeyBarView.h"
#import "KeyMacros.h"
#import "KeyboardSupport.h"
#include <Limelight.h>

/// What a modifier is currently doing.
typedef NS_ENUM(NSInteger, KeyBarModifierState) {
    KeyBarModifierStateOff,
    /// Held for exactly one key, then released. Tapping once gets you here.
    KeyBarModifierStateOneShot,
    /// Held until tapped again. Tapping a second time gets you here.
    KeyBarModifierStateLocked,
};

/// Time in microseconds a key is held before being released.
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
@property (nonatomic, strong) KeyItem *item;
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

/// Ordinary keys read as the white keys on RealVNC's bar.
static UIColor *KeyBarNormalKeyColor(void) {
    return KeyBarColor(1.00, 0.38);
}

/// Modifiers recede, as they do there.
static UIColor *KeyBarModifierKeyColor(void) {
    return KeyBarColor(0.74, 0.26);
}

@implementation KeyBarView {
    /// Scrolls: the current page.
    UIStackView *_row;
    /// Does not scroll: page control and the two dismissal controls.
    UIStackView *_controls;

    NSArray<KeyPage *> *_pages;
    NSUInteger _pageIndex;

    /// Modifier buttons on the current page. Rebuilt with the page, but the held state that
    /// matters lives on the host, so it is re-applied rather than reset.
    NSMutableArray<KeyBarButton *> *_modifierButtons;
    /// Which modifier flags are held, so a page change does not silently drop them.
    UIKeyModifierFlags _heldOneShot;
    UIKeyModifierFlags _heldLocked;

    KeyBarButton *_pageButton;
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
    _pages = [KeyMacros pagesForHost:[KeyMacros defaultHost]];
    _pageIndex = 0;

    // On iPad the stream fills the screen almost exactly — a 1512x982 Mac desktop into a
    // 1133x744 iPad leaves about 4pt of letterbox — so the bar has no dead space to sit in
    // and unavoidably covers picture. Blur rather than a solid fill, so what it covers stays
    // legible underneath.
    self.backgroundColor = [UIColor clearColor];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:blur];
    [NSLayoutConstraint activateConstraints:@[
        [blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [blur.topAnchor constraintEqualToAnchor:self.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    // The bar is short; bouncing makes it feel loose.
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

    // Controls live outside the scroll view. Dismissing the bar or changing page should never
    // require scrolling to find the key.
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

    // The page must yield to the controls, never the other way round.
    [_controls setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_controls setContentCompressionResistancePriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];

    [self buildControls];
    [self showPage:0];

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

#pragma mark - Pages

/// Rebuilds the scrolling area for one page.
///
/// Modifiers and the clipboard appear on nearly every page on purpose: paging only costs a
/// tap for what is not already in front of you, so the items used constantly are on all of
/// them and never cost anything.
- (void)showPage:(NSUInteger)index {
    _pageIndex = index % _pages.count;
    KeyPage *page = _pages[_pageIndex];

    for (UIView *view in _row.arrangedSubviews) {
        [view removeFromSuperview];
    }
    [_modifierButtons removeAllObjects];

    BOOL first = YES;
    for (KeyGroup *group in page.groups) {
        if (!first) {
            [self addGroupSeparator];
        }
        first = NO;

        for (KeyItem *item in group.items) {
            [self addItem:item];
        }
    }

    [_pageButton setTitle:page.name forState:UIControlStateNormal];
    [self restoreModifierAppearance];
}

- (void)nextPage {
    [self showPage:_pageIndex + 1];
}

/// A page change rebuilds the buttons, but the host still has whatever was held down. Put the
/// new buttons back into that state rather than letting the display disagree with the host.
- (void)restoreModifierAppearance {
    for (KeyBarButton *button in _modifierButtons) {
        UIKeyModifierFlags flag = button.item.modifiers;
        if (_heldLocked & flag) {
            button.modifierState = KeyBarModifierStateLocked;
        } else if (_heldOneShot & flag) {
            button.modifierState = KeyBarModifierStateOneShot;
        } else {
            button.modifierState = KeyBarModifierStateOff;
        }
        [self applyAppearance:button];
    }
}

#pragma mark - Building

- (void)buildControls {
    _pageButton = [self buttonWithTitle:@"Keys" wide:YES];
    [_pageButton addTarget:self action:@selector(pageButtonPressed) forControlEvents:UIControlEventTouchUpInside];
    [_controls addArrangedSubview:_pageButton];

    _keyboardToggle = [self buttonWithTitle:@"⌨" wide:NO];
    [_keyboardToggle addTarget:self action:@selector(keyboardTogglePressed) forControlEvents:UIControlEventTouchUpInside];
    [_controls addArrangedSubview:_keyboardToggle];

    KeyBarButton *done = [self buttonWithTitle:@"Done" wide:YES];
    [done addTarget:self action:@selector(donePressed) forControlEvents:UIControlEventTouchUpInside];
    [_controls addArrangedSubview:done];
}

- (KeyBarButton *)buttonWithTitle:(NSString *)title wide:(BOOL)wide {
    KeyBarButton *button = [KeyBarButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:[KeyBarView isPad] ? 19 : 16
                                               weight:UIFontWeightMedium];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    button.layer.cornerRadius = 8;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
    button.backgroundColor = KeyBarNormalKeyColor();
    button.tintColor = [UIColor labelColor];

    [button.heightAnchor constraintEqualToConstant:[KeyBarView keyHeight]].active = YES;
    CGFloat width = [KeyBarView keyWidth] * (wide ? 1.3 : 1.0);
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:width].active = YES;

    return button;
}

- (void)addItem:(KeyItem *)item {
    KeyBarButton *button = [self buttonWithTitle:item.label wide:item.label.length > 3];
    button.item = item;
    button.modifierState = KeyBarModifierStateOff;
    [button addTarget:self action:@selector(itemPressed:) forControlEvents:UIControlEventTouchUpInside];

    if (item.kind == KeyItemKindModifier) {
        [_modifierButtons addObject:button];
    }

    [self applyAppearance:button];
    [_row addArrangedSubview:button];
}

/// A wide gap between groups. Implemented as an empty view because UIStackView applies its
/// spacing uniformly and cannot vary it per gap.
- (void)addGroupSeparator {
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.widthAnchor constraintEqualToConstant:[KeyBarView groupSpacing] - keySpacing * 2].active = YES;
    [_row addArrangedSubview:spacer];
}

- (void)applyAppearance:(KeyBarButton *)button {
    switch (button.modifierState) {
        case KeyBarModifierStateOff:
            // Resting colour encodes the kind of key, as RealVNC does: modifiers read as grey
            // and everything else as white, so the bar is scannable by shade alone.
            button.backgroundColor = button.item.kind == KeyItemKindModifier
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

#pragma mark - Input

- (void)itemPressed:(KeyBarButton *)button {
    switch (button.item.kind) {
        case KeyItemKindModifier:
            [self advanceModifier:button];
            return;

        case KeyItemKindKey:
            [self sendKey:button.item.virtualKey];
            [self consumeOneShotModifiers];
            return;

        case KeyItemKindMacro:
            // A macro carries its own modifiers, so Copy sends exactly Command-C even while
            // something else is locked down for another purpose.
            [KeyboardSupport sendChordWithVirtualKey:button.item.virtualKey
                                       modifierFlags:button.item.modifiers];
            return;
    }
}

/// off -> one-shot -> locked -> off.
///
/// Deliberately a state machine rather than a double-tap gesture: recognising a double tap
/// delays every single tap by the double-tap interval, which no keyboard can afford. Tapping
/// twice still reaches the locked state, so it behaves the way "double tap to lock" implies.
- (void)advanceModifier:(KeyBarButton *)button {
    UIKeyModifierFlags flag = button.item.modifiers;

    switch (button.modifierState) {
        case KeyBarModifierStateOff:
            button.modifierState = KeyBarModifierStateOneShot;
            _heldOneShot |= flag;
            LiSendKeyboardEvent(button.item.virtualKey, KEY_ACTION_DOWN, [self activeModifierMask]);
            break;

        case KeyBarModifierStateOneShot:
            // Already held on the host; only our intent changes.
            button.modifierState = KeyBarModifierStateLocked;
            _heldOneShot &= ~flag;
            _heldLocked |= flag;
            break;

        case KeyBarModifierStateLocked:
            button.modifierState = KeyBarModifierStateOff;
            _heldLocked &= ~flag;
            LiSendKeyboardEvent(button.item.virtualKey, KEY_ACTION_UP, [self activeModifierMask]);
            break;
    }

    [self applyAppearance:button];
}

- (char)activeModifierMask {
    UIKeyModifierFlags held = _heldOneShot | _heldLocked;
    char mask = 0;
    if (held & UIKeyModifierShift) {
        mask |= MODIFIER_SHIFT;
    }
    if (held & UIKeyModifierControl) {
        mask |= MODIFIER_CTRL;
    }
    if (held & UIKeyModifierAlternate) {
        mask |= MODIFIER_ALT;
    }
    if (held & UIKeyModifierCommand) {
        mask |= MODIFIER_META;
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
    if (_heldOneShot == 0) {
        return;
    }

    for (KeyBarButton *button in _modifierButtons) {
        if (button.modifierState == KeyBarModifierStateOneShot) {
            button.modifierState = KeyBarModifierStateOff;
            _heldOneShot &= ~button.item.modifiers;
            LiSendKeyboardEvent(button.item.virtualKey, KEY_ACTION_UP, [self activeModifierMask]);
            [self applyAppearance:button];
        }
    }
}

- (void)releaseHeldModifiers {
    for (KeyBarButton *button in _modifierButtons) {
        if (button.modifierState != KeyBarModifierStateOff) {
            button.modifierState = KeyBarModifierStateOff;
            LiSendKeyboardEvent(button.item.virtualKey, KEY_ACTION_UP, 0);
            [self applyAppearance:button];
        }
    }
    _heldOneShot = 0;
    _heldLocked = 0;
}

#pragma mark - Controls

- (void)pageButtonPressed {
    [self nextPage];
}

- (void)keyboardTogglePressed {
    [self.delegate keyBarDidToggleSystemKeyboard];
}

- (void)donePressed {
    [self.delegate keyBarDidRequestDismiss];
}

- (void)setSystemKeyboardVisible:(BOOL)visible {
    _keyboardToggle.backgroundColor = visible ? KeyBarNormalKeyColor() : KeyBarModifierKeyColor();
}

@end
