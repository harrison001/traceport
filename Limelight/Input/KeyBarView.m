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
    NSString *_hostKey;
    /// Host and app together: what you pin while driving one app should not follow you to another.
    NSString *_profileKey;
    UIScrollView *_scrollView;
    UILayoutConstraintAxis _axis;
    NSArray<NSLayoutConstraint *> *_axisConstraints;

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
    _modifierButtons = [NSMutableArray array];
    _pages = [KeyMacros pagesForHost:[KeyMacros hostKindForKey:_hostKey] profileKey:_profileKey];
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
    scrollView.showsVerticalScrollIndicator = NO;
    // The bar is thin; bouncing makes it feel loose.
    scrollView.alwaysBounceHorizontal = NO;
    scrollView.alwaysBounceVertical = NO;
    [self addSubview:scrollView];
    _scrollView = scrollView;

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

    [self applyAxisConstraints];

    [self buildControls];
    [self showPage:0];

    // The caller may have sized us before the keys existed; take the height we actually need.
    CGRect bounds = self.frame;
    bounds.size.height = [KeyBarView barThickness];
    self.frame = bounds;

    return self;
}

/// Used by UIKit when this view is an inputAccessoryView, and by Auto Layout when pinned.
- (CGSize)intrinsicContentSize {
    return _axis == UILayoutConstraintAxisHorizontal
        ? CGSizeMake(UIViewNoIntrinsicMetric, [KeyBarView barThickness])
        : CGSizeMake([KeyBarView barThickness], UIViewNoIntrinsicMetric);
}

+ (CGFloat)barThickness {
    return [self keyHeight] + rowVerticalInset * 2;
}

- (void)setAxis:(UILayoutConstraintAxis)axis {
    if (_axis == axis) {
        return;
    }
    _axis = axis;
    _row.axis = axis;
    _controls.axis = axis;
    [self applyAxisConstraints];
    [self showPage:_pageIndex];
    [self invalidateIntrinsicContentSize];
}

/// The scroll view fills everything the controls do not, along whichever axis is in use.
- (void)applyAxisConstraints {
    if (_axisConstraints != nil) {
        [NSLayoutConstraint deactivateConstraints:_axisConstraints];
    }

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    UILayoutGuide *content = _scrollView.contentLayoutGuide;
    UILayoutGuide *frame = _scrollView.frameLayoutGuide;

    if (_axis == UILayoutConstraintAxisHorizontal) {
        _axisConstraints = @[
            [_scrollView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
            [_scrollView.trailingAnchor constraintEqualToAnchor:_controls.leadingAnchor],
            [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
            [_controls.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_controls.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_row.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_row.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_row.heightAnchor constraintEqualToAnchor:frame.heightAnchor],
        ];
    } else {
        _axisConstraints = @[
            [_scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:_controls.topAnchor],
            [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [_controls.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
            [_controls.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_controls.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [_row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_row.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_row.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_row.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
        ];
    }

    [NSLayoutConstraint activateConstraints:_axisConstraints];

    // The page must yield to the controls, never the other way round.
    [_controls setContentHuggingPriority:UILayoutPriorityRequired forAxis:_axis];
    [_controls setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:_axis];
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
    [self rebuildPageMenu];
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
    KeyBarButton *text = [self buttonWithTitle:@"Text" wide:YES];
    [text addTarget:self action:@selector(composeTextPressed) forControlEvents:UIControlEventTouchUpInside];
    [_controls addArrangedSubview:text];

    _pageButton = [self buttonWithTitle:@"Keys" wide:YES];
    [_pageButton addTarget:self action:@selector(pageButtonPressed) forControlEvents:UIControlEventTouchUpInside];
    // Tap for the next page, which is the common action; long press for everything else, so
    // jumping to a page and changing the host kind cost nothing in the common case.
    _pageButton.showsMenuAsPrimaryAction = NO;
    [_controls addArrangedSubview:_pageButton];
    [self rebuildPageMenu];

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
    } else {
        // Long press to make the bar your own. Termius and Stream Deck both let the user decide
        // what is on the surface; Jump Desktop's fixed list is the thing that cannot fit anyone
        // whose habits differ from its author's.
        button.showsMenuAsPrimaryAction = NO;
        button.menu = [self customisationMenuForItem:item];
    }

    [self applyAppearance:button];
    [_row addArrangedSubview:button];
}

/// A wide gap between groups. Implemented as an empty view because UIStackView applies its
/// spacing uniformly and cannot vary it per gap.
- (void)addGroupSeparator {
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat gap = [KeyBarView groupSpacing] - keySpacing * 2;
    if (_axis == UILayoutConstraintAxisHorizontal) {
        [spacer.widthAnchor constraintEqualToConstant:gap].active = YES;
    } else {
        [spacer.heightAnchor constraintEqualToConstant:gap].active = YES;
    }
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

- (void)pageButtonPressed {
    [self nextPage];
}

/// Long-press menu on a key: put it on your own page, or take it away.
- (UIMenu *)customisationMenuForItem:(KeyItem *)item {
    __weak KeyBarView *weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    if (![KeyMacros isPinned:item forProfile:_profileKey]) {
        [actions addObject:[UIAction actionWithTitle:@"Add to Mine"
                                               image:[UIImage systemImageNamed:@"pin"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            [KeyMacros pinItem:item forProfile:weakSelf.profileKeyForMenu];
            [weakSelf reloadPagesKeepingPage:NO];
        }]];
    }

    [actions addObject:[UIAction actionWithTitle:@"Hide"
                                           image:[UIImage systemImageNamed:@"eye.slash"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *sender) {
        [KeyMacros hideItem:item forProfile:weakSelf.profileKeyForMenu];
        [weakSelf reloadPagesKeepingPage:YES];
    }]];

    if ([KeyMacros hasCustomisationForProfile:_profileKey]) {
        UIAction *reset = [UIAction actionWithTitle:@"Reset This Bar"
                                              image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *sender) {
            [KeyMacros resetProfile:weakSelf.profileKeyForMenu];
            [weakSelf reloadPagesKeepingPage:NO];
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

- (void)reloadPagesKeepingPage:(BOOL)keep {
    NSUInteger page = keep ? _pageIndex : 0;
    _pages = [KeyMacros pagesForHost:[KeyMacros hostKindForKey:_hostKey] profileKey:_profileKey];
    [self showPage:page];
}

/// Long-press menu: jump straight to a page, and say which operating system this host runs.
- (void)rebuildPageMenu {
    NSMutableArray<UIAction *> *pageActions = [NSMutableArray array];
    [_pages enumerateObjectsUsingBlock:^(KeyPage *page, NSUInteger index, BOOL *stop) {
        UIAction *action = [UIAction actionWithTitle:page.name
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            [self showPage:index];
        }];
        action.state = index == self->_pageIndex ? UIMenuElementStateOn : UIMenuElementStateOff;
        [pageActions addObject:action];
    }];

    KeyMacroHost current = [KeyMacros hostKindForKey:_hostKey];
    NSMutableArray<UIAction *> *hostActions = [NSMutableArray array];
    for (NSNumber *kindNumber in @[@(KeyMacroHostMacOS), @(KeyMacroHostWindows)]) {
        KeyMacroHost kind = (KeyMacroHost)kindNumber.integerValue;
        UIAction *action = [UIAction actionWithTitle:[KeyMacros nameForHostKind:kind]
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction *sender) {
            [self changeHostKind:kind];
        }];
        action.state = kind == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [hostActions addObject:action];
    }

    UIMenu *hostMenu = [UIMenu menuWithTitle:@"Host runs"
                                       image:nil
                                  identifier:nil
                                     options:UIMenuOptionsDisplayInline
                                    children:hostActions];

    _pageButton.menu = [UIMenu menuWithTitle:@"" children:[pageActions arrayByAddingObject:hostMenu]];
}

/// Changing the host kind changes the modifier labels and the whole action set, so the bar is
/// rebuilt from the new pages. Anything held is released first: the keys about to disappear
/// are the ones the host has down.
- (void)changeHostKind:(KeyMacroHost)kind {
    [self releaseHeldModifiers];
    [KeyMacros setHostKind:kind forKey:_hostKey];
    _pages = [KeyMacros pagesForHost:kind profileKey:_profileKey];
    [self showPage:0];
}

- (void)keyboardTogglePressed {
    [self.delegate keyBarDidToggleSystemKeyboard];
}

- (void)donePressed {
    [self.delegate keyBarDidRequestDismiss];
}

/// Composes a whole string and sends it in one go.
///
/// Typing straight through goes key by key, which is right for a terminal but wrong for
/// anything longer: you cannot see what you have written and you cannot fix it before the
/// host receives it. A system alert carries a real text field, so the input method, the
/// candidate list and the cursor all behave normally, and nothing reaches the host until
/// Send.
- (void)composeTextPressed {
    UIViewController *presenter = self.window.rootViewController;
    while (presenter.presentedViewController != nil) {
        presenter = presenter.presentedViewController;
    }
    if (presenter == nil) {
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Send Text"
                                            message:@"Typed here, sent to the host in one piece."
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    __weak UIAlertController *weakAlert = alert;
    void (^send)(BOOL) = ^(BOOL thenReturn) {
        NSString *text = weakAlert.textFields.firstObject.text;
        if (text.length == 0 && !thenReturn) {
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            if (text.length > 0) {
                const char *utf8 = text.UTF8String;
                LiSendUtf8TextEvent(utf8, (int)strlen(utf8));
            }
            if (thenReturn) {
                usleep(keyPressHoldTime);
                LiSendKeyboardEvent(0x0D, KEY_ACTION_DOWN, 0);
                usleep(keyPressHoldTime);
                LiSendKeyboardEvent(0x0D, KEY_ACTION_UP, 0);
            }
        });
    };

    [alert addAction:[UIAlertAction actionWithTitle:@"Send"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { send(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Send + Return"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { send(YES); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)setSystemKeyboardVisible:(BOOL)visible {
    _keyboardToggle.backgroundColor = visible ? KeyBarNormalKeyColor() : KeyBarModifierKeyColor();
}

@end
