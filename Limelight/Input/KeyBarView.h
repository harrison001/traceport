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

/// Lays the bar out as one line along an axis.
- (void)setAxis:(UILayoutConstraintAxis)axis;

/// Lays the keys out as two scrolling columns, one down each side, with nothing in between.
///
/// A 1512x982 Mac desktop on an iPhone in landscape fits 677 points wide inside 956, leaving
/// 139 points of pure black down each side — a quarter of the screen holding nothing, and
/// exactly where the thumbs rest. Two columns there beat one line along an edge on every
/// count: twice the keys visible, no scrolling for the common ones, and the picture keeps
/// every pixel it had. The middle passes touches through to the stream.
///
/// The columns stop above the system keyboard rather than disappearing under it, so the keys
/// stay in reach while typing — which one line as an inputAccessoryView could never do.
///
/// @param marginWidth How wide the letterbox strip is. The caller measures it; the bar itself
///                    does not know what shape the stream is.
- (void)setSplitLayoutWithMarginWidth:(CGFloat)marginWidth;

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
