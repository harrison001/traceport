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
//  Text is not typed here. The phone being driven takes the gateway as a hardware keyboard, so
//  its own on-screen keyboard stays hidden; typing goes through this device's keyboard, which the
//  ⌨ key brings up only when it is wanted.
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

/// Height of the keys alone, without the home indicator's strip below them.
+ (CGFloat)contentHeight;

/// Greys out the keys for these actions — the ones that need WebDriverAgent, while it is down.
/// They stay pressable: pressing one says why it cannot work, which beats a key that is simply dead.
- (void)setUnavailableActions:(NSSet<NSString *> *)actions;

@end

NS_ASSUME_NONNULL_END
