//
//  KeyBarView.h
//  Moonlight
//
//  A horizontally scrolling row of keys that the iOS keyboard does not offer:
//  Esc, Tab, the modifiers, and the arrows. Replaces the fixed UIToolbar, which
//  could not scroll and so could not grow.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol KeyBarViewDelegate <NSObject>

/// The dismiss key was pressed.
- (void)keyBarDidRequestDismiss;

/// The keyboard key was pressed: show the system keyboard if it is hidden, hide it if not.
///
/// The bar stays either way. Held modifiers must survive the switch — this changes what is
/// on screen, not what the host thinks is pressed.
- (void)keyBarDidToggleSystemKeyboard;

@end

@interface KeyBarView : UIView

@property (nonatomic, weak) id<KeyBarViewDelegate> delegate;

/// @param hostKey Identifies the host, so which operating system it runs is remembered per machine.
/// @param appName The app launched on the host, if any. Gives each app its own customisations,
///                the way Stream Deck switches profiles by which application is in front.
- (instancetype)initWithFrame:(CGRect)frame
                      hostKey:(nullable NSString *)hostKey
                      appName:(nullable NSString *)appName;

/// Lays the bar out along an axis.
///
/// Vertical is for the phone in landscape, where the streamed desktop is letterboxed into the
/// middle and leaves a strip of black down each side wide enough to hold the bar without
/// covering any picture at all — which is also where the thumbs are.
- (void)setAxis:(UILayoutConstraintAxis)axis;

/// How thick the bar is across its axis.
+ (CGFloat)barThickness;

/// Releases every modifier the bar is holding down, on the host and visually.
///
/// Must be called when the stream ends or the bar goes away, otherwise the host is left
/// with a modifier stuck down and every later keystroke arrives modified.
- (void)releaseHeldModifiers;

/// Tells the bar that a key came from the system keyboard, so a one-shot modifier armed here
/// is released as it would be for a key on the bar.
- (void)externalKeyWasTyped;

/// Updates the keyboard key to reflect whether the system keyboard is currently showing.
- (void)setSystemKeyboardVisible:(BOOL)visible;

@end

NS_ASSUME_NONNULL_END
