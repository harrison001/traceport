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

@end

@interface KeyBarView : UIView

@property (nonatomic, weak) id<KeyBarViewDelegate> delegate;

/// Releases every modifier the bar is holding down, on the host and visually.
///
/// Must be called when the stream ends or the bar goes away, otherwise the host is left
/// with a modifier stuck down and every later keystroke arrives modified.
- (void)releaseHeldModifiers;

@end

NS_ASSUME_NONNULL_END
