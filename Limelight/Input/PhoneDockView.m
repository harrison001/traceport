//
//  PhoneDockView.m
//  Moonlight
//

#import "PhoneDockView.h"
#import "KeyboardSupport.h"
#include <Limelight.h>

/// F13–F23 mean nothing to a phone; the gateway bridge turns each into the phone action it is
/// named for here (ios_bridge.py phone_keys). Back, Kill and the two flicks are real finger
/// swipes made through WebDriverAgent, so they need it running on the phone.
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

    __weak PhoneDockView *weakSelf = self;
    // Most used first, under the thumb: going home, switching and going back is most of what
    // driving a phone is. Lock lives in the overflow — locking the phone remotely means typing
    // the passcode to get back in, which is not something to do by brushing a key.
    NSArray<UIButton *> *top = @[
        [self key:@"Home" symbol:@"house" send:PhoneKeyHome],
        [self key:@"Apps" symbol:@"square.stack" send:PhoneKeyApps],
        [self key:@"Back" symbol:@"chevron.backward" send:PhoneKeyBack],
        [self key:@"Close" symbol:@"xmark.app" send:PhoneKeyKill],
        [self key:@"Prev" symbol:@"arrow.left" send:PhoneKeySwipeLeft],
        [self key:@"Next" symbol:@"arrow.right" send:PhoneKeySwipeRight],
    ];
    NSArray<UIButton *> *bottom = @[
        [self key:@"Control" symbol:@"switch.2" send:PhoneKeyControlCenter],
        [self key:@"Alerts" symbol:@"bell" send:PhoneKeyNotifications],
        [self key:@"Search" symbol:@"magnifyingglass" action:^{
            [weakSelf sendKey:PhoneKeySearch modifiers:0];
            // Spotlight is now waiting for a query
            if (weakSelf.showKeyboard) {
                weakSelf.showKeyboard();
            }
        }],
        [self key:@"Shot" symbol:@"camera.viewfinder" send:PhoneKeyScreenshot],
        [self key:@"Type" symbol:@"keyboard" action:^{
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
    return self;
}

- (UIStackView *)row:(NSArray<UIButton *> *)keys {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:keys];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 2;
    return row;
}

- (UIButton *)key:(NSString *)title symbol:(NSString *)symbol send:(PhoneKey)key {
    __weak PhoneDockView *weakSelf = self;
    return [self key:title symbol:symbol action:^{
        [weakSelf sendKey:key modifiers:0];
    }];
}

- (UIButton *)key:(NSString *)title symbol:(NSString *)symbol action:(void (^)(void))action {
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
        action();
    }]];
    button.accessibilityLabel = title;
    return button;
}

/// The rest: text editing, scrolling and Lock. Used often enough to keep, not often enough to
/// spend a key on.
- (UIButton *)moreKey {
    UIButton *button = [self key:@"More" symbol:@"ellipsis" action:^{}];
    __weak PhoneDockView *weakSelf = self;
    UIAction *(^chord)(NSString *, NSString *, short) = ^UIAction *(NSString *title, NSString *symbol, short key) {
        return [UIAction actionWithTitle:title image:[UIImage systemImageNamed:symbol] identifier:nil
                                 handler:^(UIAction *a) {
            [weakSelf sendKey:key modifiers:UIKeyModifierCommand];
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
        [weakSelf sendKey:PhoneKeyLock modifiers:0];
    }];
    lock.attributes = UIMenuElementAttributesDestructive;
    button.menu = [UIMenu menuWithChildren:@[text, scroll, lock]];
    button.showsMenuAsPrimaryAction = YES;
    return button;
}

- (void)sendKey:(short)key modifiers:(UIKeyModifierFlags)modifiers {
    [KeyboardSupport sendChordWithVirtualKey:key modifierFlags:modifiers];
}

@end
