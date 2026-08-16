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

static CGFloat const rowVerticalInset = 8;
static const CGFloat rowHorizontalInset = 12;

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
@end

@implementation KeyBarPanel

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
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:blur];

    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    // The bar is thin; bouncing makes it feel loose.
    _scrollView.alwaysBounceHorizontal = NO;
    _scrollView.alwaysBounceVertical = NO;
    [self addSubview:_scrollView];

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.spacing = keySpacing;
    _stack.layoutMarginsRelativeArrangement = YES;
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
    CGFloat _marginWidth;

    NSArray<KeyGroup *> *_groups;
    NSString *_hostKey;
    /// Host and app together: what you pin while driving one app should not follow you to another.
    NSString *_profileKey;
    UILayoutConstraintAxis _axis;
    NSArray<NSLayoutConstraint *> *_layoutConstraints;

    /// Modifier buttons on the current page. Rebuilt with the page, but the held state that
    /// matters lives on the host, so it is re-applied rather than reset.
    NSMutableArray<KeyBarButton *> *_modifierButtons;
    /// Which modifier flags are held, so a page change does not silently drop them.
    UIKeyModifierFlags _heldOneShot;
    UIKeyModifierFlags _heldLocked;

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
    return [self initWithFrame:frame hostKey:nil appName:nil];
}

- (instancetype)initWithFrame:(CGRect)frame hostKey:(NSString *)hostKey appName:(NSString *)appName {
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
    _modifierButtons = [NSMutableArray array];
    _groups = [KeyMacros groupsForHost:[KeyMacros hostKindForKey:_hostKey] profileKey:_profileKey];

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

        _layoutConstraints = [@[
            [_secondary.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor],
            [_secondary.widthAnchor constraintEqualToConstant:_marginWidth],
            [_secondary.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor],
            [_secondary.bottomAnchor constraintEqualToAnchor:foot],

            [_primary.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor],
            [_primary.widthAnchor constraintEqualToConstant:_marginWidth],
            [_primary.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor],
            [_primary.bottomAnchor constraintEqualToAnchor:foot],

            [_controls.leadingAnchor constraintEqualToAnchor:_primary.leadingAnchor],
            [_controls.trailingAnchor constraintEqualToAnchor:_primary.trailingAnchor],
            [_controls.bottomAnchor constraintEqualToAnchor:_primary.safeAreaLayoutGuide.bottomAnchor],

            [_secondaryControls.leadingAnchor constraintEqualToAnchor:_secondary.leadingAnchor],
            [_secondaryControls.trailingAnchor constraintEqualToAnchor:_secondary.trailingAnchor],
            [_secondaryControls.bottomAnchor constraintEqualToAnchor:_secondary.safeAreaLayoutGuide.bottomAnchor],
        ] arrayByAddingObjectsFromArray:
            [self constraintsForPanel:_primary above:_controls.topAnchor]];

        _layoutConstraints = [_layoutConstraints arrayByAddingObjectsFromArray:
            [self constraintsForPanel:_secondary above:_secondaryControls.topAnchor]];
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
                                above:horizontal ? nil : _controls.topAnchor
                               before:horizontal ? _controls.leadingAnchor : nil]];
    }

    [NSLayoutConstraint activateConstraints:_layoutConstraints];
    [self placeDoneButton];

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
        ? UIEdgeInsetsMake(rowHorizontalInset, rowVerticalInset, rowHorizontalInset, rowVerticalInset)
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

        if (_layout == KeyBarLayoutSplit) {
            for (NSArray<KeyItem *> *row in [self packItems:_groups[i].items]) {
                [self addRow:row to:panel];
            }
        } else {
            for (KeyItem *item in _groups[i].items) {
                [self addItem:item to:panel];
            }
        }
    }

    [self restoreModifierAppearance];
}

/// Packs a group into rows two keys wide, giving a row of its own to anything whose label will
/// not fit in half a column.
///
/// Density is the whole point of the columns: at one key per row only four are in reach above
/// the system keyboard, and half the keys — the modifiers, the arrows, the tmux commands — are
/// labelled with two or three characters and waste most of a 139pt row. Long macro names like
/// "Mission Control" still take the full width, so nothing is truncated to fit.
- (NSArray<NSArray<KeyItem *> *> *)packItems:(NSArray<KeyItem *> *)items {
    CGFloat inner = _marginWidth - rowVerticalInset * 2;
    CGFloat half = (inner - keySpacing) / 2;
    UIFont *font = [UIFont systemFontOfSize:[KeyBarView isPad] ? 19 : 16 weight:UIFontWeightMedium];

    BOOL (^fitsHalf)(KeyItem *) = ^BOOL(KeyItem *item) {
        // A little under buttonWithTitle:'s 8pt inset each side: the label may shrink to 80%
        // before it truncates, so a label that misses by a point still reads perfectly. Being
        // strict here costs a whole row — "Zoom" overhangs by one point, and paying a row for
        // it also pushes the four pane arrows out of their natural pairs.
        CGSize size = [item.label sizeWithAttributes:@{NSFontAttributeName: font}];
        return ceil(size.width) + 12 <= half;
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

- (void)addRow:(NSArray<KeyItem *> *)items to:(KeyBarPanel *)panel {
    if (items.count == 1) {
        [self addItem:items.firstObject to:panel];
        return;
    }

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = keySpacing;
    row.distribution = UIStackViewDistributionFillEqually;
    for (KeyItem *item in items) {
        [row addArrangedSubview:[self buttonForItem:item]];
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

- (void)buildControls {
    // Which operating system the host runs is the one thing that has to be reachable and has
    // nowhere else to live. A single tap opens it; it is not something anyone sets twice.
    _settingsButton = [self buttonWithTitle:@"⋯" wide:NO];
    _settingsButton.showsMenuAsPrimaryAction = YES;
    _settingsButton.menu = [self hostKindMenu];
    [_controls addArrangedSubview:_settingsButton];

    _keyboardToggle = [self buttonWithTitle:@"⌨" wide:NO];
    [_keyboardToggle addTarget:self action:@selector(keyboardTogglePressed) forControlEvents:UIControlEventTouchUpInside];
    [_controls addArrangedSubview:_keyboardToggle];

    _doneButton = [self buttonWithTitle:@"Done" wide:YES];
    [_doneButton addTarget:self action:@selector(donePressed) forControlEvents:UIControlEventTouchUpInside];
    [self placeDoneButton];
}

/// Done sits with the other controls when the bar is one line, and alone at the foot of the
/// left column when it is split, where it gets the whole width instead of a third of it.
- (void)placeDoneButton {
    [_doneButton removeFromSuperview];
    if (_layout == KeyBarLayoutSplit) {
        [_secondaryControls addArrangedSubview:_doneButton];
    } else {
        [_controls addArrangedSubview:_doneButton];
    }
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

    // High rather than required: three controls at their natural widths do not fit across a
    // 139pt column, and shrinking them is better than breaking the layout.
    CGFloat width = [KeyBarView keyWidth] * (wide ? 1.3 : 1.0);
    NSLayoutConstraint *minimum = [button.widthAnchor constraintGreaterThanOrEqualToConstant:width];
    minimum.priority = UILayoutPriorityDefaultHigh;
    minimum.active = YES;

    return button;
}

- (void)addItem:(KeyItem *)item to:(KeyBarPanel *)panel {
    [panel.stack addArrangedSubview:[self buttonForItem:item]];
}

- (KeyBarButton *)buttonForItem:(KeyItem *)item {
    KeyBarButton *button = [self buttonWithTitle:item.label wide:item.label.length > 3];
    button.item = item;
    button.modifierState = KeyBarModifierStateOff;
    [button addTarget:self action:@selector(itemPressed:) forControlEvents:UIControlEventTouchUpInside];

    if (item.kind == KeyItemKindModifier) {
        [_modifierButtons addObject:button];
    } else {
        // Long press to make the bar your own. Termius and Stream Deck both let the user decide
        // what is on the surface; Jump Desktop's fixed list is the thing that cannot fit anyone
        // whose habits differ from its author's.
        button.showsMenuAsPrimaryAction = NO;
        button.menu = [self customisationMenuForItem:item];
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

        case KeyItemKindSequence:
            [self sendSequence:button.item.steps];
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

/// Long-press menu on a key: move it to the near end of the row, or take it away.
- (UIMenu *)customisationMenuForItem:(KeyItem *)item {
    __weak KeyBarView *weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    if (![KeyMacros isPinned:item forProfile:_profileKey]) {
        [actions addObject:[UIAction actionWithTitle:@"Move to Front"
                                               image:[UIImage systemImageNamed:@"pin"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            [KeyMacros pinItem:item forProfile:weakSelf.profileKeyForMenu];
            [weakSelf reloadGroups];
        }]];
    }

    [actions addObject:[UIAction actionWithTitle:@"Hide"
                                           image:[UIImage systemImageNamed:@"eye.slash"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *sender) {
        [KeyMacros hideItem:item forProfile:weakSelf.profileKeyForMenu];
        [weakSelf reloadGroups];
    }]];

    if ([KeyMacros hasCustomisationForProfile:_profileKey]) {
        UIAction *reset = [UIAction actionWithTitle:@"Reset This Bar"
                                              image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *sender) {
            [KeyMacros resetProfile:weakSelf.profileKeyForMenu];
            [weakSelf reloadGroups];
        }];
        reset.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                                         options:UIMenuOptionsDisplayInline children:@[reset]]];
    }

    return [UIMenu menuWithTitle:item.label children:actions];
}

- (NSString *)profileKeyForMenu {
    return _profileKey;
}

- (void)reloadGroups {
    _groups = [KeyMacros groupsForHost:[KeyMacros hostKindForKey:_hostKey] profileKey:_profileKey];
    [self buildRow];
    // Rebuilt rather than left alone: the menu carries the tick showing which host kind is set.
    _settingsButton.menu = [self hostKindMenu];
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

    return [UIMenu menuWithTitle:@"Host runs" children:actions];
}

/// Anything held is released first: the keys about to be replaced are the ones the host has
/// down.
- (void)changeHostKind:(KeyMacroHost)kind {
    [self releaseHeldModifiers];
    [KeyMacros setHostKind:kind forKey:_hostKey];
    [self reloadGroups];
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
