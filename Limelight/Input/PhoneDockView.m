//
//  PhoneDockView.m
//  Moonlight
//

#import "PhoneDockView.h"
#import "KeyboardSupport.h"
#include <Limelight.h>

/// The keys a gateway without the action port still understands: F13–F23, which its bridge
/// turns into the same actions (ios_bridge.py phone_keys).
typedef NS_ENUM(short, PhoneKey) {
    PhoneKeyHome = 0x7C,
    PhoneKeyApps = 0x7D,
    PhoneKeyControlCenter = 0x7E,
    PhoneKeyNotifications = 0x7F,
    PhoneKeySearch = 0x80,
    PhoneKeyLock = 0x81,
    PhoneKeyScreenshot = 0x82,
    PhoneKeyKill = 0x83,
    PhoneKeyBack = 0x84,
    PhoneKeySwipeLeft = 0x85,
    PhoneKeySwipeRight = 0x86,
};

static const CGFloat rowHeight = 46;
static const NSInteger columns = 6;

@implementation PhoneDockView {
    UIStackView *_rows;
    /// Action name → its key, for greying out.
    NSMutableDictionary<NSString *, UIButton *> *_keys;
    UILabel *_toast;
    NSUInteger _toastGeneration;
}

+ (CGFloat)contentHeight {
    return rowHeight * 2 + 8;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    _keys = [NSMutableDictionary dictionary];

    __weak PhoneDockView *weakSelf = self;
    // Most used first, under the thumb: going home, switching and going back is most of what
    // driving a phone is. Lock lives in the overflow — locking the phone remotely means typing
    // the passcode to get back in, which is not something to do by brushing a key.
    //
    // Prev and Next are named for what the user sees, not the finger: the previous page comes
    // in from the left, which takes a swipe to the right.
    NSArray<UIButton *> *top = @[
        [self key:@"Home" symbol:@"house" action:@"home" fallback:PhoneKeyHome],
        [self key:@"Apps" symbol:@"square.stack" action:@"apps" fallback:PhoneKeyApps],
        [self key:@"Back" symbol:@"chevron.backward" action:@"back" fallback:PhoneKeyBack],
        [self key:@"Close" symbol:@"xmark.app" action:@"kill" fallback:PhoneKeyKill],
        [self key:@"Prev" symbol:@"arrow.left" action:@"swiperight" fallback:PhoneKeySwipeRight],
        [self key:@"Next" symbol:@"arrow.right" action:@"swipeleft" fallback:PhoneKeySwipeLeft],
    ];
    NSArray<UIButton *> *bottom = @[
        [self key:@"Control" symbol:@"switch.2" action:@"cc" fallback:PhoneKeyControlCenter],
        [self key:@"Alerts" symbol:@"bell" action:@"notif" fallback:PhoneKeyNotifications],
        [self key:@"Search" symbol:@"magnifyingglass" action:@"search" fallback:PhoneKeySearch],
        [self key:@"Shot" symbol:@"camera.viewfinder" action:@"shot" fallback:PhoneKeyScreenshot],
        [self key:@"Type" symbol:@"keyboard" handler:^{
            if (weakSelf.toggleKeyboard) {
                weakSelf.toggleKeyboard();
            }
        }],
        [self moreKey],
    ];
    NSAssert(top.count == columns && bottom.count == columns, @"Two full rows");

    _rows = [[UIStackView alloc] initWithArrangedSubviews:@[[self row:top], [self row:bottom]]];
    _rows.axis = UILayoutConstraintAxisVertical;
    _rows.distribution = UIStackViewDistributionFillEqually;
    _rows.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_rows];
    [NSLayoutConstraint activateConstraints:@[
        [_rows.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:4],
        [_rows.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor constant:-4],
        [_rows.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
        [_rows.heightAnchor constraintEqualToConstant:rowHeight * 2],
    ]];

    [self buildToast];
    return self;
}

- (UIStackView *)row:(NSArray<UIButton *> *)keys {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:keys];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 2;
    return row;
}

- (UIButton *)key:(NSString *)title symbol:(NSString *)symbol action:(NSString *)action fallback:(PhoneKey)key {
    __weak PhoneDockView *weakSelf = self;
    UIButton *button = [self key:title symbol:symbol handler:^{
        [weakSelf perform:action fallback:key];
    }];
    _keys[action] = button;
    return button;
}

- (UIButton *)key:(NSString *)title symbol:(NSString *)symbol handler:(void (^)(void))handler {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.image = [UIImage systemImageNamed:symbol
                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17]];
    config.imagePlacement = NSDirectionalRectEdgeTop;
    config.imagePadding = 3;
    config.baseForegroundColor = [UIColor colorWithWhite:0.92 alpha:1];
    config.contentInsets = NSDirectionalEdgeInsetsMake(4, 0, 2, 0);
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *a = [attributes mutableCopy];
        a[NSFontAttributeName] = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        return a;
    };
    config.title = title;

    UIButton *button = [UIButton buttonWithConfiguration:config
                                           primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        handler();
    }]];
    button.accessibilityLabel = title;
    return button;
}

/// The rest: text editing, scrolling and Lock. Used often enough to keep, not often enough to
/// spend a key on.
- (UIButton *)moreKey {
    UIButton *button = [self key:@"More" symbol:@"ellipsis" handler:^{}];
    __weak PhoneDockView *weakSelf = self;
    UIAction *(^chord)(NSString *, NSString *, short) = ^UIAction *(NSString *title, NSString *symbol, short key) {
        return [UIAction actionWithTitle:title image:[UIImage systemImageNamed:symbol] identifier:nil
                                 handler:^(UIAction *a) {
            [KeyboardSupport sendChordWithVirtualKey:key modifierFlags:UIKeyModifierCommand];
        }];
    };
    UIMenu *text = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                 options:UIMenuOptionsDisplayInline children:@[
        chord(@"Paste", @"doc.on.clipboard", 0x56),
        chord(@"Copy", @"doc.on.doc", 0x43),
        chord(@"Select All", @"selection.pin.in.out", 0x41),
        chord(@"Undo", @"arrow.uturn.backward", 0x5A),
    ]];
    UIMenu *scroll = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                   options:UIMenuOptionsDisplayInline children:@[
        [UIAction actionWithTitle:@"Scroll Up" image:[UIImage systemImageNamed:@"chevron.up"]
                       identifier:nil handler:^(UIAction *a) { LiSendScrollEvent(3); }],
        [UIAction actionWithTitle:@"Scroll Down" image:[UIImage systemImageNamed:@"chevron.down"]
                       identifier:nil handler:^(UIAction *a) { LiSendScrollEvent(-3); }],
    ]];
    UIAction *lock = [UIAction actionWithTitle:@"Lock Screen" image:[UIImage systemImageNamed:@"lock"]
                                    identifier:nil handler:^(UIAction *a) {
        [weakSelf perform:@"lock" fallback:PhoneKeyLock];
    }];
    lock.attributes = UIMenuElementAttributesDestructive;
    button.menu = [UIMenu menuWithChildren:@[text, scroll, lock]];
    button.showsMenuAsPrimaryAction = YES;
    return button;
}

#pragma mark - Doing it

- (void)perform:(NSString *)action fallback:(PhoneKey)key {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];

    // Spotlight is about to wait for a query; the keyboard should be up by the time it does
    if ([action isEqualToString:@"search"] && self.showKeyboard) {
        self.showKeyboard();
    }

    if (self.client == nil) {
        [KeyboardSupport sendChordWithVirtualKey:key modifierFlags:0];
        return;
    }

    __weak PhoneDockView *weakSelf = self;
    [self.client perform:action completion:^(NSDictionary *result) {
        PhoneDockView *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (result == nil) {
            // The gateway predates the action port, or it is unreachable: the old way still works
            // on the former, and on the latter nothing would.
            [KeyboardSupport sendChordWithVirtualKey:key modifierFlags:0];
            [strongSelf showToast:@"Sent (gateway did not confirm)" ok:YES];
            return;
        }
        NSString *label = [result[@"label"] isKindOfClass:[NSString class]] ? result[@"label"] : action;
        if ([result[@"ok"] boolValue]) {
            [strongSelf showToast:[@"✓ " stringByAppendingString:label] ok:YES];
        } else {
            NSString *why = [result[@"error"] isKindOfClass:[NSString class]] ? result[@"error"] : @"";
            [strongSelf showToast:[NSString stringWithFormat:@"✗ %@  %@", label, why] ok:NO];
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeError];
        }
    }];
}

- (void)setUnavailableActions:(NSSet<NSString *> *)actions {
    [_keys enumerateKeysAndObjectsUsingBlock:^(NSString *name, UIButton *button, BOOL *stop) {
        button.alpha = [actions containsObject:name] ? 0.35 : 1.0;
    }];
}

#pragma mark - Saying what happened

- (void)buildToast {
    _toast = [[UILabel alloc] init];
    _toast.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _toast.textColor = UIColor.whiteColor;
    _toast.textAlignment = NSTextAlignmentCenter;
    _toast.numberOfLines = 2;
    _toast.layer.cornerRadius = 14;
    _toast.layer.masksToBounds = YES;
    _toast.alpha = 0;
    _toast.userInteractionEnabled = NO;
    _toast.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_toast];
    // Just above the dock, over the bottom of the picture, where the eye already is
    [NSLayoutConstraint activateConstraints:@[
        [_toast.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_toast.bottomAnchor constraintEqualToAnchor:self.topAnchor constant:-8],
        [_toast.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-32],
        [_toast.heightAnchor constraintGreaterThanOrEqualToConstant:28],
    ]];
    self.clipsToBounds = NO;
}

- (void)showToast:(NSString *)text ok:(BOOL)ok {
    _toast.text = [NSString stringWithFormat:@"  %@  ", text];
    _toast.backgroundColor = ok ? [UIColor colorWithWhite:0.15 alpha:0.9]
                                : [UIColor colorWithRed:0.55 green:0.1 blue:0.1 alpha:0.92];
    _toast.alpha = 1;
    NSUInteger generation = ++_toastGeneration;
    // A failure stays long enough to read the reason
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((ok ? 1.2 : 3.5) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self->_toastGeneration) {
            return;
        }
        [UIView animateWithDuration:0.3 animations:^{ self->_toast.alpha = 0; }];
    });
}

/// The toast hangs above the dock, outside its bounds; let it be seen but not swallow touches.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == _toast ? nil : hit;
}

@end
