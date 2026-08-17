//
//  KeyBarView.m
//  Moonlight
//

#import "KeyBarView.h"
#import "KeyMacros.h"
#import "KeyboardSupport.h"
#include <Limelight.h>

/// Which commit this binary was built from, injected by the build command.
///
/// Installing an app does not replace the copy already running, and there is no way to see
/// from the outside which one a phone is executing. Twice now a change has been reported as
/// missing when the question was really "is this even the new build". One line in the ⋯ menu
/// answers it in a second.
#ifndef KEYBAR_BUILD_ID
#define KEYBAR_BUILD_ID "dev"
#endif

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

/// How long Spotlight is given to appear before it is typed into, and to rank what was typed
/// before Return is pressed.
static const useconds_t spotlightOpenTime = 450 * 1000;
/// Matches KeyboardSupport's: a modifier has to be down before the key it modifies arrives.
static const useconds_t modifierSettleTime = 30 * 1000;
static const useconds_t spotlightRankTime = 600 * 1000;

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

static CGFloat const rowVerticalInset = 8;
static const CGFloat rowHorizontalInset = 12;

/// Label sizes. The columns use whatever of these two fits (see splitFontSize).
static const CGFloat padFontSize = 19;
static const CGFloat phoneFontSize = 16;

/// Below this a key cannot be read at arm's length, and an unreadable key is worse than one
/// that has a row to itself.
static const CGFloat minimumSplitFontSize = 13;

/// A label this short is a chord — "⌘␣", "⇧⌘4", "中/A" — and is expected to share a row.
/// Anything longer is a name like "Mission Control", which never will.
static const NSUInteger chordLabelLength = 4;

/// Padding inside a column, which is charged four times across a row of two — twice at the
/// column's edges and twice inside each key.
///
/// The ordinary 8pt of each spends 54 of the 87 points a 16:9 stream leaves beside it on a phone,
/// which left 33 points for two labels and is why almost nothing paired. These are the widths a
/// column can actually afford.
static const CGFloat splitColumnInset = 4;
static const CGFloat splitKeyInset = 3;

/// Shrinking past the point where most keys pair buys nothing and costs legibility: one stubborn
/// label like "⌃⌘F" should take a row of its own rather than drag the type down for all of them.
static const CGFloat splitPairingTarget = 0.75;

@interface KeyBarButton : UIButton
@property (nonatomic, strong) KeyItem *item;
@property (nonatomic, assign) KeyBarModifierState modifierState;
@end

@implementation KeyBarButton
@end

/// A blurred strip with a scrolling stack of keys in it. One of these is the whole bar when it
/// lies along an edge; two of them are the columns down either side of the picture.
@interface KeyBarPanel : UIView
@property (nonatomic, strong, readonly) UIScrollView *scrollView;
@property (nonatomic, strong, readonly) UIStackView *stack;
/// Whether the blurred slab behind the keys is drawn. Off when the keys float over black.
@property (nonatomic, assign) BOOL showsBackground;
@end

@implementation KeyBarPanel {
    UIVisualEffectView *_blur;
}

- (void)setShowsBackground:(BOOL)showsBackground {
    _showsBackground = showsBackground;
    _blur.hidden = !showsBackground;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    // On iPad the stream fills the screen almost exactly — a 1512x982 Mac desktop into a
    // 1133x744 iPad leaves about 4pt of letterbox — so the bar has no dead space to sit in and
    // unavoidably covers picture. Blur rather than a solid fill, so what it covers stays
    // legible underneath.
    self.backgroundColor = [UIColor clearColor];
    _showsBackground = YES;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:blur];
    _blur = blur;

    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    // The bar is thin; bouncing makes it feel loose.
    _scrollView.alwaysBounceHorizontal = NO;
    _scrollView.alwaysBounceVertical = NO;
    // A scroll view adds the safe area to its content inset by default. Once a column is flush
    // with the screen edge that means 59pt of inset on the outer side in landscape, which
    // squeezes a 139pt column of keys down to 60pt and truncates every label to an ellipsis.
    // The panel is already positioned deliberately; it does not want the help.
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self addSubview:_scrollView];

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.spacing = keySpacing;
    _stack.layoutMarginsRelativeArrangement = YES;
    // A view folds the safe area into its layout margins by default. Down a column flush with
    // the screen edge that is 59pt of margin on the outer side in landscape, which squeezes
    // 139pt of keys into 60pt and truncates every label to an ellipsis. The margins here are
    // deliberate and complete.
    _stack.insetsLayoutMarginsFromSafeArea = NO;
    [_scrollView addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [blur.topAnchor constraintEqualToAnchor:self.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    return self;
}

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

/// Floating keys, for the columns down the letterbox.
///
/// The on-screen game controller is the precedent here, and it is in this app already: its
/// D-pad and its four face buttons are CALayers added straight to the stream view, drawn as
/// translucent shapes with no slab behind them and no border around them. Over the black
/// letterbox that reads as part of the app rather than as a panel bolted onto the picture, and
/// it is what a Moonlight user already knows. A blurred slab is only worth its weight where
/// the bar has to cover picture, which down the sides it never does.
static UIColor *KeyBarFloatingKeyColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.22];
}

static UIColor *KeyBarFloatingModifierColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.11];
}

/// Where the keys are.
typedef NS_ENUM(NSInteger, KeyBarLayout) {
    /// One scrolling line along an edge, controls at its far end.
    KeyBarLayoutLine,
    /// Two scrolling columns, one down each side, controls at the foot of the right one.
    KeyBarLayoutSplit,
};

@implementation KeyBarView {
    /// The bar itself when it is one line; the right-hand column when it is split. Always the
    /// one holding the controls.
    KeyBarPanel *_primary;
    /// The left-hand column. Split layout only.
    KeyBarPanel *_secondary;
    /// Does not scroll: the settings, keyboard and dismissal controls.
    UIStackView *_controls;

    KeyBarLayout _layout;
    /// How many of _groups came from the keyboard rather than the pad.
    NSUInteger _keyboardGroupCount;
    CGFloat _marginWidth;

    NSArray<KeyGroup *> *_groups;
    NSString *_hostKey;
    /// Host and app together: what you pin while driving one app should not follow you to another.
    NSString *_profileKey;
    UILayoutConstraintAxis _axis;
    NSArray<NSLayoutConstraint *> *_layoutConstraints;

    /// Rebuilt whenever the keys are, but the held state that matters lives on the host, so it
    /// is re-applied rather than reset.
    NSMutableArray<KeyBarButton *> *_modifierButtons;
    /// Which modifier flags are held, so a rebuild does not silently drop them.
    UIKeyModifierFlags _heldOneShot;
    UIKeyModifierFlags _heldLocked;

    BOOL _systemKeyboardVisible;
    KeyBarButton *_settingsButton;
    KeyBarButton *_keyboardToggle;
    KeyBarButton *_doneButton;
    /// Split layout only: the foot of the left column, which holds Done. Three controls across
    /// one 139pt column leaves each about 40pt, and "Done" renders as an ellipsis at that width.
    UIStackView *_secondaryControls;
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

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame hostKey:nil appName:nil content:KeyBarContentBoth];
}

- (instancetype)initWithFrame:(CGRect)frame
                      hostKey:(NSString *)hostKey
                      appName:(NSString *)appName
                      content:(KeyBarContent)content {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _hostKey = [hostKey copy];
    _profileKey = appName.length > 0
        ? [NSString stringWithFormat:@"%@/%@", hostKey ?: @"", appName]
        : [hostKey copy];
    _axis = UILayoutConstraintAxisHorizontal;
    _layout = KeyBarLayoutLine;
    _content = content;
    _showsControls = YES;
    _modifierButtons = [NSMutableArray array];
    _groups = [self currentGroups];

    self.backgroundColor = [UIColor clearColor];

    _primary = [[KeyBarPanel alloc] initWithFrame:CGRectZero];
    _primary.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_primary];

    // Controls live outside the scroll view. Dismissing the bar should never require scrolling
    // to find the key.
    _controls = [[UIStackView alloc] initWithFrame:CGRectZero];
    _controls.translatesAutoresizingMaskIntoConstraints = NO;
    _controls.axis = UILayoutConstraintAxisHorizontal;
    _controls.spacing = keySpacing;
    _controls.layoutMarginsRelativeArrangement = YES;
    _controls.insetsLayoutMarginsFromSafeArea = NO;
    [_primary addSubview:_controls];

    [self applyLayoutConstraints];

    [self buildControls];
    [self buildRow];

    // The caller may have sized us before the keys existed; take the height we actually need.
    CGRect bounds = self.frame;
    bounds.size.height = [KeyBarView barThickness];
    self.frame = bounds;

    return self;
}

/// Used by UIKit when this view is an inputAccessoryView, and by Auto Layout when pinned.
///
/// Split layout has none: the caller pins all four edges, and the bar places its columns in
/// the margins of whatever it is given.
- (CGSize)intrinsicContentSize {
    if (_layout == KeyBarLayoutSplit) {
        return CGSizeMake(UIViewNoIntrinsicMetric, UIViewNoIntrinsicMetric);
    }
    return _axis == UILayoutConstraintAxisHorizontal
        ? CGSizeMake(UIViewNoIntrinsicMetric, [KeyBarView barThickness])
        : CGSizeMake([KeyBarView barThickness], UIViewNoIntrinsicMetric);
}

+ (CGFloat)barThickness {
    return [self keyHeight] + rowVerticalInset * 2;
}

/// Everything between the two columns belongs to the stream.
///
/// Without this the bar would swallow every touch on the picture, since in split layout it
/// covers the whole view in order to reach both margins.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (void)setAxis:(UILayoutConstraintAxis)axis {
    if (_layout == KeyBarLayoutLine && _axis == axis) {
        return;
    }
    _layout = KeyBarLayoutLine;
    _axis = axis;
    _controls.axis = axis;
    [self applyLayoutConstraints];
    // The group separators are sized along the axis, so the keys are rebuilt rather than rotated.
    [self buildRow];
    [self invalidateIntrinsicContentSize];
}

- (void)setBottomInset:(CGFloat)bottomInset {
    if (_bottomInset == bottomInset) {
        return;
    }
    _bottomInset = bottomInset;
    if (_layout == KeyBarLayoutSplit) {
        [self applyLayoutConstraints];
    }
}

- (void)setSplitLayoutWithMarginWidth:(CGFloat)marginWidth {
    if (_layout == KeyBarLayoutSplit && _marginWidth == marginWidth) {
        return;
    }
    _layout = KeyBarLayoutSplit;
    _marginWidth = marginWidth;
    _axis = UILayoutConstraintAxisVertical;
    // Along the bottom of the right column, where three stacked would eat two thirds of what
    // the system keyboard leaves.
    _controls.axis = UILayoutConstraintAxisHorizontal;
    [self applyLayoutConstraints];
    [self buildRow];
    [self invalidateIntrinsicContentSize];
}

- (void)applyLayoutConstraints {
    if (_layoutConstraints != nil) {
        [NSLayoutConstraint deactivateConstraints:_layoutConstraints];
    }

    if (_layout == KeyBarLayoutSplit) {
        if (_secondary == nil) {
            _secondary = [[KeyBarPanel alloc] initWithFrame:CGRectZero];
            _secondary.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:_secondary];

            _secondaryControls = [[UIStackView alloc] initWithFrame:CGRectZero];
            _secondaryControls.translatesAutoresizingMaskIntoConstraints = NO;
            _secondaryControls.axis = UILayoutConstraintAxisHorizontal;
            _secondaryControls.spacing = keySpacing;
            _secondaryControls.layoutMarginsRelativeArrangement = YES;
            _secondaryControls.insetsLayoutMarginsFromSafeArea = NO;
            _secondaryControls.layoutMargins = UIEdgeInsetsMake(keySpacing, rowVerticalInset,
                                                                rowVerticalInset, rowVerticalInset);
            [_secondary addSubview:_secondaryControls];
        }
        _secondary.hidden = NO;

        // The columns stop at the top of the system keyboard so the keys stay in reach while
        // typing. keyboardLayoutGuide tracks the bottom of the view when no keyboard is up, so
        // one constraint covers both states.
        NSLayoutYAxisAnchor *foot = self.safeAreaLayoutGuide.bottomAnchor;
        if (@available(iOS 15.0, *)) {
            foot = self.keyboardLayoutGuide.topAnchor;
        }
        // With the system keyboard down, the keyboard line pins itself along the bottom and the
        // guide is no longer what keeps the columns clear of it.
        CGFloat footInset = _bottomInset;

        // Flush with the screen edge, and exactly as wide as the letterbox. Not the safe area:
        // in landscape iOS reports a 59pt inset down both sides, and subtracting it from an
        // 87pt letterbox leaves 28pt — a column of slivers with every label an ellipsis. The
        // Dynamic Island does clip a key on one side, which is the price of the full width.
        _layoutConstraints = [@[
            [_secondary.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_secondary.widthAnchor constraintEqualToConstant:_marginWidth],
            [_secondary.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor],
            [_secondary.bottomAnchor constraintEqualToAnchor:foot constant:-footInset],

            [_primary.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_primary.widthAnchor constraintEqualToConstant:_marginWidth],
            [_primary.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor],
            [_primary.bottomAnchor constraintEqualToAnchor:foot constant:-footInset],

        ] arrayByAddingObjectsFromArray:(_showsControls ? @[
            [_controls.leadingAnchor constraintEqualToAnchor:_primary.leadingAnchor],
            [_controls.trailingAnchor constraintEqualToAnchor:_primary.trailingAnchor],
            [_controls.bottomAnchor constraintEqualToAnchor:_primary.safeAreaLayoutGuide.bottomAnchor],

            [_secondaryControls.leadingAnchor constraintEqualToAnchor:_secondary.leadingAnchor],
            [_secondaryControls.trailingAnchor constraintEqualToAnchor:_secondary.trailingAnchor],
            [_secondaryControls.bottomAnchor constraintEqualToAnchor:_secondary.safeAreaLayoutGuide.bottomAnchor],
        ] : @[])];

        _layoutConstraints = [_layoutConstraints arrayByAddingObjectsFromArray:
            [self constraintsForPanel:_primary above:(_showsControls ? _controls.topAnchor : nil)]];

        _layoutConstraints = [_layoutConstraints arrayByAddingObjectsFromArray:
            [self constraintsForPanel:_secondary above:(_showsControls ? _secondaryControls.topAnchor : nil)]];
    }
    else {
        _secondary.hidden = YES;

        BOOL horizontal = _axis == UILayoutConstraintAxisHorizontal;
        _layoutConstraints = [@[
            [_primary.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_primary.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_primary.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_primary.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ] arrayByAddingObjectsFromArray:horizontal ? @[
            [_controls.trailingAnchor constraintEqualToAnchor:_primary.safeAreaLayoutGuide.trailingAnchor],
            [_controls.topAnchor constraintEqualToAnchor:_primary.topAnchor],
            [_controls.bottomAnchor constraintEqualToAnchor:_primary.bottomAnchor],
        ] : @[
            [_controls.bottomAnchor constraintEqualToAnchor:_primary.safeAreaLayoutGuide.bottomAnchor],
            [_controls.leadingAnchor constraintEqualToAnchor:_primary.leadingAnchor],
            [_controls.trailingAnchor constraintEqualToAnchor:_primary.trailingAnchor],
        ]];

        _layoutConstraints = [_layoutConstraints arrayByAddingObjectsFromArray:
            [self constraintsForPanel:_primary
                                above:(horizontal || !_showsControls) ? nil : _controls.topAnchor
                               before:(horizontal && _showsControls) ? _controls.leadingAnchor : nil]];
    }

    [NSLayoutConstraint activateConstraints:_layoutConstraints];
    [self placeDoneButton];

    // Floating over black down the sides; a blurred slab only where the bar covers picture.
    _primary.showsBackground = _layout != KeyBarLayoutSplit;
    _secondary.showsBackground = NO;

    if (_layout == KeyBarLayoutSplit) {
        // Two across a 139pt column: they share it rather than each demanding its own width.
        _controls.distribution = UIStackViewDistributionFillEqually;
        _controls.layoutMargins = UIEdgeInsetsMake(keySpacing, rowVerticalInset,
                                                   rowVerticalInset, rowVerticalInset);
    } else if (_axis == UILayoutConstraintAxisHorizontal) {
        _controls.distribution = UIStackViewDistributionFill;
        _controls.layoutMargins = UIEdgeInsetsMake(rowVerticalInset, keySpacing,
                                                   rowVerticalInset, rowHorizontalInset);
    } else {
        _controls.distribution = UIStackViewDistributionFill;
        _controls.layoutMargins = UIEdgeInsetsMake(keySpacing, rowVerticalInset,
                                                   rowHorizontalInset, rowVerticalInset);
    }

    [self restyleControls];

    // The keys must yield to the controls, never the other way round.
    [_controls setContentHuggingPriority:UILayoutPriorityRequired forAxis:_controls.axis];
    [_controls setContentCompressionResistancePriority:UILayoutPriorityRequired
                                               forAxis:_controls.axis];
}

- (NSArray<NSLayoutConstraint *> *)constraintsForPanel:(KeyBarPanel *)panel
                                                 above:(nullable NSLayoutYAxisAnchor *)foot {
    return [self constraintsForPanel:panel above:foot before:nil];
}

/// Places a panel's scroll view and its stack, stopping short of the controls where there are
/// any. The stack is pinned to the content guide on all four sides and matched to the frame
/// guide across the scrolling axis, which is what makes the scroll view size itself to the
/// keys rather than needing a contentSize set by hand.
- (NSArray<NSLayoutConstraint *> *)constraintsForPanel:(KeyBarPanel *)panel
                                                 above:(nullable NSLayoutYAxisAnchor *)foot
                                                before:(nullable NSLayoutXAxisAnchor *)edge {
    UIScrollView *scroll = panel.scrollView;
    UIStackView *stack = panel.stack;
    UILayoutGuide *content = scroll.contentLayoutGuide;
    UILayoutGuide *frame = scroll.frameLayoutGuide;
    UILayoutGuide *safe = panel.safeAreaLayoutGuide;
    BOOL vertical = _axis == UILayoutConstraintAxisVertical;

    stack.axis = _axis;
    stack.layoutMargins = vertical
        ? UIEdgeInsetsMake(rowHorizontalInset, splitColumnInset, rowHorizontalInset, splitColumnInset)
        : UIEdgeInsetsMake(rowVerticalInset, rowHorizontalInset, rowVerticalInset, rowHorizontalInset);

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        vertical ? [stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor]
                 : [stack.heightAnchor constraintEqualToAnchor:frame.heightAnchor],
    ]];

    if (vertical) {
        [constraints addObjectsFromArray:@[
            [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
            [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:foot ?: safe.bottomAnchor],
        ]];
    } else {
        [constraints addObjectsFromArray:@[
            [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:edge ?: safe.trailingAnchor],
            [scroll.topAnchor constraintEqualToAnchor:panel.topAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        ]];
    }

    return constraints;
}

#pragma mark - The row

/// Rebuilds the scrolling row.
///
/// Every key is in it, separated into groups by a wide gap. There is no paging: a page control
/// costs a tap and a guess about which page a key is on, and a bar that scrolls costs a flick
/// that shows you the answer on the way. Modifiers are a state machine, not a held finger, so
/// arming one and then scrolling to the key it modifies works.
- (void)buildRow {
    for (UIView *view in _primary.stack.arrangedSubviews) {
        [view removeFromSuperview];
    }
    for (UIView *view in _secondary.stack.arrangedSubviews) {
        [view removeFromSuperview];
    }
    [_modifierButtons removeAllObjects];

    // Split layout fills the left column first, so the front of the list — the modifiers and
    // everything used constantly — sits under the left thumb without scrolling, and the long
    // tail goes to the right.
    NSUInteger cut = _layout == KeyBarLayoutSplit ? [self secondColumnIndex] : _groups.count;

    KeyBarPanel *panel = _layout == KeyBarLayoutSplit ? _secondary : _primary;
    BOOL first = YES;
    for (NSUInteger i = 0; i < _groups.count; i++) {
        if (i == cut) {
            panel = _primary;
            first = YES;
        }
        if (!first) {
            [self addGroupSeparatorTo:panel];
        }
        first = NO;

        // Which surface an item belongs to decides what its long-press menu offers. Only a
        // bar carrying both has to tell them apart, and there the keyboard comes first.
        BOOL onPad = _content == KeyBarContentPad || i >= _keyboardGroupCount;

        if (_layout == KeyBarLayoutSplit) {
            for (NSArray<KeyItem *> *row in [self packItems:_groups[i].items]) {
                [self addRow:row to:panel onPad:onPad];
            }
        } else {
            for (KeyItem *item in _groups[i].items) {
                [self addItem:item to:panel onPad:onPad];
            }
        }
    }

    [self restoreModifierAppearance];
}

/// The largest label size at which two chords still fit side by side in a column.
///
/// The size used to be fixed, so whether the pad packed two to a row depended on how wide the
/// letterbox happened to be. On anything narrower than about 148pt almost every key came out on
/// its own row — the arrangement the columns exist to avoid. Deriving the size from the width it
/// has to fit makes two-up the rule rather than a coincidence, and gives up type only as far as
/// that takes.
///
/// Measured against the chords alone: a macro named "Mission Control" is never going to share a
/// row, and should not drag every other key down with it.
- (CGFloat)splitFontSize {
    CGFloat natural = [KeyBarView isPad] ? padFontSize : phoneFontSize;
    if (_layout != KeyBarLayoutSplit || _marginWidth <= 0) {
        return natural;
    }

    NSMutableArray<NSString *> *chords = [NSMutableArray array];
    for (KeyGroup *group in _groups) {
        for (KeyItem *item in group.items) {
            if (item.label.length <= chordLabelLength) {
                [chords addObject:item.label];
            }
        }
    }
    if (chords.count == 0) {
        return natural;
    }

    CGFloat budget = [self splitLabelBudget];

    // Stepped and measured rather than scaled from the natural size: a font's advance widths do
    // not fall exactly in proportion to its point size, and an estimate that lands one point too
    // large costs the row it was trying to save.
    for (CGFloat size = natural; size >= minimumSplitFontSize; size -= 1) {
        UIFont *font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
        NSUInteger fitting = 0;
        for (NSString *label in chords) {
            if (ceil([label sizeWithAttributes:@{NSFontAttributeName: font}].width) <= budget) {
                fitting++;
            }
        }
        if ((CGFloat)fitting / chords.count >= splitPairingTarget) {
            return size;
        }
    }
    return minimumSplitFontSize;
}

/// How wide a label may be and still share a row, once the column's own padding and the key's
/// have been taken out of it.
- (CGFloat)splitLabelBudget {
    return (_marginWidth - splitColumnInset * 2 - keySpacing) / 2 - splitKeyInset * 2;
}

/// Packs a group into rows two keys wide, giving a row of its own to anything whose label will
/// not fit in half a column.
///
/// Density is the whole point of the columns: at one key per row only four are in reach above
/// the system keyboard, and half the keys — the modifiers, the arrows, the tmux commands — are
/// labelled with two or three characters and waste most of a 139pt row. Long macro names like
/// "Mission Control" still take the full width, so nothing is truncated to fit.
- (NSArray<NSArray<KeyItem *> *> *)packItems:(NSArray<KeyItem *> *)items {
    CGFloat budget = [self splitLabelBudget];
    UIFont *font = [UIFont systemFontOfSize:[self splitFontSize] weight:UIFontWeightMedium];

    BOOL (^fitsHalf)(KeyItem *) = ^BOOL(KeyItem *item) {
        // Measured against the same budget the size was chosen for, and generously: a label may
        // shrink to 80% before it truncates, so one that misses by a point still reads perfectly.
        // Being strict costs a whole row — "Zoom" overhangs by one point, and paying a row for it
        // also pushes the four pane arrows out of their natural pairs.
        CGSize size = [item.label sizeWithAttributes:@{NSFontAttributeName: font}];
        return ceil(size.width) <= budget + 2;
    };

    NSMutableArray<NSArray<KeyItem *> *> *rows = [NSMutableArray array];
    NSMutableArray<KeyItem *> *pending = [NSMutableArray array];

    for (KeyItem *item in items) {
        if (!fitsHalf(item)) {
            if (pending.count > 0) {
                [rows addObject:[pending copy]];
                [pending removeAllObjects];
            }
            [rows addObject:@[item]];
            continue;
        }
        [pending addObject:item];
        if (pending.count == 2) {
            [rows addObject:[pending copy]];
            [pending removeAllObjects];
        }
    }
    if (pending.count > 0) {
        [rows addObject:[pending copy]];
    }

    return rows;
}

- (void)addRow:(NSArray<KeyItem *> *)items to:(KeyBarPanel *)panel onPad:(BOOL)onPad {
    if (items.count == 1) {
        [self addItem:items.firstObject to:panel onPad:onPad];
        return;
    }

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = keySpacing;
    row.distribution = UIStackViewDistributionFillEqually;
    for (KeyItem *item in items) {
        [row addArrangedSubview:[self buttonForItem:item onPad:onPad]];
    }
    [panel.stack addArrangedSubview:row];
}

/// Where the right-hand column starts: the group that says so, or failing that the boundary
/// nearest the middle by key count.
- (NSUInteger)secondColumnIndex {
    for (NSUInteger i = 0; i < _groups.count; i++) {
        if (_groups[i].startsSecondColumn) {
            return i;
        }
    }

    NSUInteger total = 0;
    for (KeyGroup *group in _groups) {
        total += group.items.count;
    }

    NSUInteger running = 0;
    for (NSUInteger i = 0; i < _groups.count; i++) {
        if (running * 2 >= total) {
            return i;
        }
        running += _groups[i].items.count;
    }
    return _groups.count;
}

/// A rebuild replaces the buttons, but the host still has whatever was held down. Put the new
/// buttons back into that state rather than letting the display disagree with the host.
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

/// Set after init, so the controls are torn down and rebuilt rather than filtered at birth.
- (void)setShowsControls:(BOOL)showsControls {
    if (_showsControls == showsControls) {
        return;
    }
    _showsControls = showsControls;
    for (UIView *view in _controls.arrangedSubviews) {
        [view removeFromSuperview];
    }
    for (UIView *view in _secondaryControls.arrangedSubviews) {
        [view removeFromSuperview];
    }
    _settingsButton = nil;
    _keyboardToggle = nil;
    _doneButton = nil;
    [self buildControls];
    [self applyLayoutConstraints];
}

- (void)buildControls {
    if (!_showsControls) {
        return;
    }

    // Which operating system the host runs is the one thing that has to be reachable and has
    // nowhere else to live. A single tap opens it; it is not something anyone sets twice.
    _settingsButton = [self buttonWithTitle:@"⋯" wide:NO];
    _settingsButton.showsMenuAsPrimaryAction = YES;
    _settingsButton.menu = [self settingsMenu];
    [_controls addArrangedSubview:_settingsButton];

    _keyboardToggle = [self buttonWithTitle:@"⌨" wide:NO];
    [_keyboardToggle addTarget:self action:@selector(keyboardTogglePressed) forControlEvents:UIControlEventTouchUpInside];
    [_controls addArrangedSubview:_keyboardToggle];

    // "Done" on the keyboard, "✕" on the pad: they close different things, and two keys
    // reading Done on one screen is the thing that made the last version confusing.
    _doneButton = [self buttonWithTitle:_content == KeyBarContentPad ? @"✕" : @"Done"
                                   wide:_content != KeyBarContentPad];
    [_doneButton addTarget:self action:@selector(donePressed) forControlEvents:UIControlEventTouchUpInside];
    [self placeDoneButton];
    [self restyleControls];
}

/// Done sits with the other controls when the bar is one line, and alone at the foot of the
/// left column when it is split, where it gets the whole width instead of a third of it.
- (void)placeDoneButton {
    if (_doneButton == nil) {
        return;  // called once from the layout before the controls exist
    }
    [_doneButton removeFromSuperview];
    if (_layout == KeyBarLayoutSplit) {
        [_secondaryControls addArrangedSubview:_doneButton];
    } else {
        [_controls addArrangedSubview:_doneButton];
    }
}

/// The controls carry no KeyItem, so they miss the appearance pass the keys get. Style them by
/// hand whenever the layout changes, or they stay opaque white while the keys go translucent.
- (void)restyleControls {
    for (KeyBarButton *button in @[_settingsButton ?: (KeyBarButton *)NSNull.null,
                                   _keyboardToggle ?: (KeyBarButton *)NSNull.null,
                                   _doneButton ?: (KeyBarButton *)NSNull.null]) {
        if ([button isKindOfClass:[KeyBarButton class]]) {
            [self applyAppearance:button];
        }
    }
    [self setSystemKeyboardVisible:_systemKeyboardVisible];
}

- (KeyBarButton *)buttonWithTitle:(NSString *)title wide:(BOOL)wide {
    KeyBarButton *button = [KeyBarButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:[self splitFontSize] weight:UIFontWeightMedium];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    button.layer.cornerRadius = 8;
    BOOL split = _layout == KeyBarLayoutSplit;
    button.contentEdgeInsets = split ? UIEdgeInsetsMake(0, splitKeyInset, 0, splitKeyInset)
                                     : UIEdgeInsetsMake(0, 8, 0, 8);
    button.backgroundColor = KeyBarNormalKeyColor();
    button.tintColor = [UIColor labelColor];

    [button.heightAnchor constraintEqualToConstant:[KeyBarView keyHeight]].active = YES;

    // The extra width a longer label asks for is what kept two keys from sharing a row: two keys
    // at 1.3x plus the gap come to more than a column is wide, so the row broke apart even when
    // both labels would have fitted. In a column the row divides the width equally anyway, and
    // even the ordinary minimum is wider than half of one, so neither applies there.
    //
    // High rather than required: three controls at their natural widths do not fit across a
    // 139pt column, and shrinking them is better than breaking the layout.
    CGFloat width = split ? 0 : [KeyBarView keyWidth] * (wide ? 1.3 : 1.0);
    NSLayoutConstraint *minimum = [button.widthAnchor constraintGreaterThanOrEqualToConstant:width];
    minimum.priority = UILayoutPriorityDefaultHigh;
    minimum.active = YES;

    return button;
}

- (void)addItem:(KeyItem *)item to:(KeyBarPanel *)panel onPad:(BOOL)onPad {
    [panel.stack addArrangedSubview:[self buttonForItem:item onPad:onPad]];
}

- (KeyBarButton *)buttonForItem:(KeyItem *)item onPad:(BOOL)onPad {
    KeyBarButton *button = [self buttonWithTitle:item.label wide:item.label.length > 3];
    button.item = item;
    button.modifierState = KeyBarModifierStateOff;
    [button addTarget:self action:@selector(itemPressed:) forControlEvents:UIControlEventTouchUpInside];

    if (item.kind == KeyItemKindModifier) {
        [_modifierButtons addObject:button];
    } else {
        // Long press to make the surface your own. Termius and Stream Deck both let the user
        // decide what is on it; Jump Desktop's fixed list is the thing that cannot fit anyone
        // whose habits differ from its author's.
        button.showsMenuAsPrimaryAction = NO;
        button.menu = [self menuForItem:item onPad:onPad];
    }

    [self applyAppearance:button];
    return button;
}

/// A wide gap between groups. Implemented as an empty view because UIStackView applies its
/// spacing uniformly and cannot vary it per gap.
- (void)addGroupSeparatorTo:(KeyBarPanel *)panel {
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat gap = [KeyBarView groupSpacing] - keySpacing * 2;
    if (_axis == UILayoutConstraintAxisHorizontal) {
        [spacer.widthAnchor constraintEqualToConstant:gap].active = YES;
    } else {
        [spacer.heightAnchor constraintEqualToConstant:gap].active = YES;
    }
    [panel.stack addArrangedSubview:spacer];
}

- (void)applyAppearance:(KeyBarButton *)button {
    BOOL floating = _layout == KeyBarLayoutSplit;

    switch (button.modifierState) {
        case KeyBarModifierStateOff:
            // Resting colour encodes the kind of key, as RealVNC does: modifiers read one shade
            // back from everything else, so the bar is scannable without reading the labels.
            if (floating) {
                button.backgroundColor = button.item.kind == KeyItemKindModifier
                    ? KeyBarFloatingModifierColor()
                    : KeyBarFloatingKeyColor();
            } else {
                button.backgroundColor = button.item.kind == KeyItemKindModifier
                    ? KeyBarModifierKeyColor()
                    : KeyBarNormalKeyColor();
            }
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
            button.layer.borderColor = [UIColor whiteColor].CGColor;
            break;
    }

    if (floating) {
        // Always white: the keys sit on the black letterbox, never on picture, so there is no
        // light appearance for them to adapt to.
        button.tintColor = [UIColor whiteColor];
    } else {
        button.tintColor = button.modifierState == KeyBarModifierStateOff
            ? [UIColor labelColor]
            : [UIColor whiteColor];
    }
}

#pragma mark - Input

- (void)itemPressed:(KeyBarButton *)button {
    if (button.item.wantsKeyboard) {
        [self.delegate keyBarDidRequestSystemKeyboard:self];
    }

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

        case KeyItemKindSequence:
            [self sendSequence:button.item.steps];
            return;

        case KeyItemKindScroll:
            LiSendScrollEvent(button.item.scrollClicks);
            return;

        case KeyItemKindAppJump:
            [self jumpToApp:button.item.appName];
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

/// Sends chords one after another, each fully released before the next begins.
///
/// The release matters: a prefix key only counts as a prefix if it is up again before the
/// command key arrives, which is the whole difference between Control-A then z, and
/// Control-A-Z.
- (void)sendSequence:(NSArray<KeyStep *> *)steps {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        for (KeyStep *step in steps) {
            [KeyboardSupport sendChordWithVirtualKey:step.virtualKey modifierFlags:step.modifiers];
            // sendChord dispatches its own work, so leave room for it to finish before the
            // next step starts. Without the gap the host can see the two overlap.
            usleep(120 * 1000);
        }
    });
}

/// Spotlight, the program's name, Return.
///
/// The name goes as one key event per character rather than as a UTF-8 text event, because
/// Sunshine on macOS does not implement text events at all:
///
///     void unicode(input_t &input, char *utf8, int size) {
///       BOOST_LOG(info) << "unicode: Unicode input not yet implemented for MacOS."sv;
///     }
///
/// It logs the line and drops the string, so the first version of this opened Spotlight, typed
/// nothing, and pressed Return on whatever was still highlighted from last time. Program names
/// are ASCII, which translateKeyEvent: handles.
///
/// The waits are what make it work rather than a race. Spotlight needs a moment to appear
/// before it will take keys, and another to rank the results before Return picks the top hit.
- (void)jumpToApp:(NSString *)appName {
    if (appName.length == 0) {
        return;
    }
    NSString *name = [appName copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [KeyboardSupport sendChordWithVirtualKey:0x20 modifierFlags:UIKeyModifierCommand];
        usleep(spotlightOpenTime);

        for (NSUInteger i = 0; i < name.length; i++) {
            struct KeyEvent event = [KeyboardSupport translateKeyEvent:[name characterAtIndex:i]
                                                     withModifierFlags:0];
            if (event.keycode == 0) {
                continue;  // nothing on a keyboard produces it; the rest of the name still helps
            }
            if (event.modifier != 0) {
                LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_DOWN, event.modifier);
                usleep(modifierSettleTime);
            }
            LiSendKeyboardEvent2(event.keycode, KEY_ACTION_DOWN, event.modifier,
                                 SS_KBE_FLAG_NON_NORMALIZED);
            usleep(keyPressHoldTime);
            LiSendKeyboardEvent2(event.keycode, KEY_ACTION_UP, event.modifier,
                                 SS_KBE_FLAG_NON_NORMALIZED);
            if (event.modifier != 0) {
                usleep(modifierSettleTime);
                LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_UP, event.modifier);
            }
        }
        usleep(spotlightRankTime);

        LiSendKeyboardEvent(0x0D, KEY_ACTION_DOWN, 0);
        usleep(keyPressHoldTime);
        LiSendKeyboardEvent(0x0D, KEY_ACTION_UP, 0);
    });
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

/// Called when a key arrives from the system keyboard rather than from the bar.
///
/// Without this, a one-shot modifier armed on the bar stays armed after typing a letter, so
/// Control-A followed by z reaches the host as Control-A then Control-Z. That is exactly the
/// case a tmux prefix needs to work.
- (void)externalKeyWasTyped {
    [self consumeOneShotModifiers];
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

/// Long-press menu on a key.
///
/// A key on the pad can be moved nearer the thumb or taken off. A key on the keyboard can be
/// copied onto the pad — which is what the old "Add to Mine" did, and the reason anyone
/// long-presses one — or hidden, since nobody uses all twelve function keys.
- (UIMenu *)menuForItem:(KeyItem *)item onPad:(BOOL)onPad {
    __weak KeyBarView *weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    if (onPad) {
        [actions addObject:[UIAction actionWithTitle:@"Move Nearer"
                                               image:[UIImage systemImageNamed:@"arrow.up"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            [KeyMacros promoteOnPad:item forProfile:weakSelf.profileKeyForMenu
                               host:weakSelf.hostKind];
            [weakSelf reloadGroups];
        }]];

        UIAction *remove = [UIAction actionWithTitle:@"Remove"
                                               image:[UIImage systemImageNamed:@"minus.circle"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            [KeyMacros removeFromPad:item forProfile:weakSelf.profileKeyForMenu
                                host:weakSelf.hostKind];
            [weakSelf reloadGroups];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:remove];
    } else {
        [actions addObject:[UIAction actionWithTitle:@"Add to Pad"
                                               image:[UIImage systemImageNamed:@"pin"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            [KeyMacros addToPad:item forProfile:weakSelf.profileKeyForMenu host:weakSelf.hostKind];
            [weakSelf.padDelegate keyBarPadDidChange];
            [weakSelf reloadGroups];
        }]];

        UIAction *hide = [UIAction actionWithTitle:@"Hide"
                                             image:[UIImage systemImageNamed:@"eye.slash"]
                                        identifier:nil
                                           handler:^(__kindof UIAction *sender) {
            [KeyMacros hideKeyboardKey:item forProfile:weakSelf.profileKeyForMenu];
            [weakSelf reloadGroups];
        }];
        hide.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:hide];
    }

    return [UIMenu menuWithTitle:item.detail ?: item.label children:actions];
}

/// The whole catalogue, ticked where a key is already on the pad, tapping to turn it on or off.
///
/// It used to list only what was missing, which reads as the rest having been taken away —
/// looking for a key you already have and not finding it says "gone", not "you have it". The
/// full list with ticks says both at once, and doubles as the way to take one off.
- (UIMenu *)catalogueMenu {
    __weak KeyBarView *weakSelf = self;
    NSMutableSet<NSString *> *onPad = [NSMutableSet set];
    for (KeyGroup *group in _groups) {
        for (KeyItem *item in group.items) {
            [onPad addObject:item.label];
        }
    }

    NSMutableArray<UIMenuElement *> *categories = [NSMutableArray array];
    for (KeyGroup *group in [KeyMacros macroCatalogueForHost:[self hostKind]]) {
        NSMutableArray<UIAction *> *choices = [NSMutableArray array];
        for (KeyItem *item in group.items) {
            BOOL isOn = [onPad containsObject:item.label];
            // Label and meaning together: "⌘`" on its own is not something anyone recognises.
            NSString *title = item.detail.length > 0
                ? [NSString stringWithFormat:@"%@   %@", item.label, item.detail]
                : item.label;
            UIAction *action = [UIAction actionWithTitle:title
                                                   image:nil
                                              identifier:nil
                                                 handler:^(__kindof UIAction *sender) {
                if (isOn) {
                    [KeyMacros removeFromPad:item forProfile:weakSelf.profileKeyForMenu
                                        host:weakSelf.hostKind];
                } else {
                    [KeyMacros addToPad:item forProfile:weakSelf.profileKeyForMenu
                                   host:weakSelf.hostKind];
                }
                [weakSelf.padDelegate keyBarPadDidChange];
                [weakSelf reloadGroups];
            }];
            action.state = isOn ? UIMenuElementStateOn : UIMenuElementStateOff;
            [choices addObject:action];
        }
        if (choices.count > 0) {
            [categories addObject:[UIMenu menuWithTitle:group.name ?: @""
                                                  image:nil
                                             identifier:nil
                                                options:0
                                               children:choices]];
        }
    }

    return [UIMenu menuWithTitle:@"Keys"
                           image:[UIImage systemImageNamed:@"list.bullet"]
                      identifier:nil
                         options:0
                        children:categories];
}

- (NSString *)profileKeyForMenu {
    return _profileKey;
}

/// Where the keys come from, which is the only real difference between the two surfaces.
///
/// The pad arrives as one list and is cut in half so the two columns are the same length. The
/// keyboard arrives already grouped, and its groups are what the wide separators mark.
- (NSArray<KeyGroup *> *)currentGroups {
    KeyMacroHost host = [KeyMacros hostKindForKey:_hostKey];

    NSMutableArray<KeyGroup *> *groups = [NSMutableArray array];
    if (_content != KeyBarContentPad) {
        [groups addObjectsFromArray:[KeyMacros keyboardGroupsForHost:host profileKey:_profileKey]];
    }
    _keyboardGroupCount = groups.count;
    if (_content != KeyBarContentKeyboard) {
        NSArray<KeyItem *> *pad = [KeyMacros padItemsForHost:host profileKey:_profileKey];
        if (_content == KeyBarContentPad && pad.count > 1) {
            NSUInteger half = (pad.count + 1) / 2;
            KeyGroup *second = [KeyGroup groupWithItems:[pad subarrayWithRange:
                                    NSMakeRange(half, pad.count - half)]];
            second.startsSecondColumn = YES;
            [groups addObject:[KeyGroup groupWithItems:
                               [pad subarrayWithRange:NSMakeRange(0, half)]]];
            [groups addObject:second];
        } else if (pad.count > 0) {
            [groups addObject:[KeyGroup groupWithItems:pad]];
        }
    }
    return groups;
}

- (void)reloadPad {
    [self reloadGroups];
}

- (void)reloadGroups {
    _groups = [self currentGroups];
    [self buildRow];
    // Rebuilt rather than left alone: the menu carries the tick showing which host kind is set.
    _settingsButton.menu = [self settingsMenu];
}

/// Which operating system this host runs. It decides the modifier labels and the whole action
/// set, and cannot be discovered: Sunshine's /serverinfo carries no platform field.
- (UIMenu *)hostKindMenu {
    KeyMacroHost current = [KeyMacros hostKindForKey:_hostKey];
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    // Weak, because the button holds the menu, the menu holds this block, and the button is
    // ours. A strong self here would keep the whole bar alive after it is dismissed.
    __weak KeyBarView *weakSelf = self;

    for (NSNumber *kindNumber in @[@(KeyMacroHostMacOS), @(KeyMacroHostWindows)]) {
        KeyMacroHost kind = (KeyMacroHost)kindNumber.integerValue;
        UIAction *action = [UIAction actionWithTitle:[KeyMacros nameForHostKind:kind]
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            [weakSelf changeHostKind:kind];
        }];
        action.state = kind == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }

    return [UIMenu menuWithTitle:@"Host runs"
                           image:nil
                      identifier:nil
                         options:UIMenuOptionsDisplayInline
                        children:actions];
}

/// The ⋯ button: everything that is a setting rather than a key.
- (UIMenu *)settingsMenu {
    __weak KeyBarView *weakSelf = self;
    NSMutableArray<UIMenuElement *> *sections = [NSMutableArray array];

    if (_content != KeyBarContentKeyboard) {
        [sections addObject:[self catalogueMenu]];
        [sections addObject:[UIAction actionWithTitle:@"Add App…"
                                                image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *sender) {
            [weakSelf.delegate keyBar:weakSelf requestsAppNameWithCompletion:^(NSString *name) {
                [KeyMacros addAppJump:name forProfile:weakSelf.profileKeyForMenu
                                 host:weakSelf.hostKind];
                [weakSelf reloadGroups];
            }];
        }]];

        if ([KeyMacros padIsCustomisedForProfile:_profileKey]) {
            UIAction *reset =
                [UIAction actionWithTitle:@"Reset Pad"
                                    image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                               identifier:nil
                                  handler:^(__kindof UIAction *sender) {
                [KeyMacros resetPadForProfile:weakSelf.profileKeyForMenu];
                [weakSelf reloadGroups];
            }];
            reset.attributes = UIMenuElementAttributesDestructive;
            [sections addObject:reset];
        }
    }

    if (_content != KeyBarContentPad && [KeyMacros keyboardIsCustomisedForProfile:_profileKey]) {
        UIAction *reset =
            [UIAction actionWithTitle:@"Reset Keyboard"
                                image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                           identifier:nil
                              handler:^(__kindof UIAction *sender) {
            [KeyMacros resetKeyboardForProfile:weakSelf.profileKeyForMenu];
            [weakSelf reloadGroups];
        }];
        reset.attributes = UIMenuElementAttributesDestructive;
        [sections addObject:reset];
    }

    [sections addObject:[self hostKindMenu]];

    // Installing an app does not replace the copy already running, and nothing from the outside
    // says which one a phone is executing. One line here answers it in a second.
    UIAction *build = [UIAction actionWithTitle:@"build " @KEYBAR_BUILD_ID
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction *sender) {}];
    build.attributes = UIMenuElementAttributesDisabled;
    [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                                      options:UIMenuOptionsDisplayInline children:@[build]]];

    return [UIMenu menuWithTitle:@"" children:sections];
}

/// Anything held is released first: the keys about to be replaced are the ones the host has
/// down.
- (void)changeHostKind:(KeyMacroHost)kind {
    [self releaseHeldModifiers];
    [KeyMacros setHostKind:kind forKey:_hostKey];
    [self reloadGroups];
}

- (KeyMacroHost)hostKind {
    return [KeyMacros hostKindForKey:_hostKey];
}

- (void)keyboardTogglePressed {
    [self.delegate keyBarDidToggleSystemKeyboard:self];
}

- (void)donePressed {
    [self.delegate keyBarDidRequestDismiss:self];
}

- (void)setSystemKeyboardVisible:(BOOL)visible {
    _systemKeyboardVisible = visible;
    if (_layout == KeyBarLayoutSplit) {
        _keyboardToggle.backgroundColor = visible
            ? KeyBarFloatingKeyColor()
            : KeyBarFloatingModifierColor();
    } else {
        _keyboardToggle.backgroundColor = visible ? KeyBarNormalKeyColor() : KeyBarModifierKeyColor();
    }
}

@end
