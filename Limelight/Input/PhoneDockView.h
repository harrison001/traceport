//
//  PhoneDockView.h
//  Moonlight
//
//  The controls for a phone host, along the bottom of the screen.
//
//  A phone streamed to a phone fills the screen edge to edge, so there is no letterbox for the
//  pad, and most of a desktop keyboard means nothing to it anyway. What a phone needs is its own
//  buttons — Home, the app switcher, Back — one tap away and never covering the picture. The
//  picture is laid out above the dock rather than under it.
//
//  Text: the phone shows its own keyboard when a field wants text, and with real touch its keys
//  can be tapped like any other; for typing fast, this device's keyboard goes through the gateway as a
//  hardware keyboard, brought up by the ⌨ key only when it is wanted.
//

#import <UIKit/UIKit.h>
#import "PhoneActionClient.h"

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(ios(15.0))
@interface PhoneDockView : UIView

/// The ⌨ key, and keys like Search that leave the phone waiting for text.
@property (nonatomic, copy, nullable) void (^toggleKeyboard)(void);
@property (nonatomic, copy, nullable) void (^showKeyboard)(void);

/// Asks the gateway to do an action and hears back whether it happened. Set by the owner; when
/// it is nil, or the gateway cannot be reached, the key is sent the old way, unconfirmed.
@property (nonatomic, strong, nullable) PhoneActionClient *client;

/// Height of the keys alone, without the home indicator's strip below them. Compact is the one
/// row left when touches go to the phone as real touches: the phone's own gestures do the rest.
+ (CGFloat)contentHeightCompact:(BOOL)compact;

- (instancetype)initWithFrame:(CGRect)frame compact:(BOOL)compact;

/// Real touch: the stream's touches are replayed on the phone as touches, instead of steering its
/// pointer. The dock shows the switch; the owner does the switching and remembers the choice.
@property (nonatomic) BOOL realTouch;
@property (nonatomic, copy, nullable) void (^realTouchChanged)(BOOL on);

/// A line above the dock saying what just happened.
- (void)showToast:(NSString *)text ok:(BOOL)ok;

/// Greys out the keys for these actions — the ones that need WebDriverAgent, while it is down.
/// They stay pressable: pressing one says why it cannot work, which beats a key that is simply dead.
- (void)setUnavailableActions:(NSSet<NSString *> *)actions;

@end

NS_ASSUME_NONNULL_END
