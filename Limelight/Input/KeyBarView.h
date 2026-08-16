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

/// Identifies the host, so which operating system it runs is remembered per machine.
- (instancetype)initWithFrame:(CGRect)frame hostKey:(nullable NSString *)hostKey;

/// Releases every modifier the bar is holding down, on the host and visually.
///
/// Must be called when the stream ends or the bar goes away, otherwise the host is left
/// with a modifier stuck down and every later keystroke arrives modified.
- (void)releaseHeldModifiers;

/// Updates the keyboard key to reflect whether the system keyboard is currently showing.
- (void)setSystemKeyboardVisible:(BOOL)visible;

@end

NS_ASSUME_NONNULL_END
