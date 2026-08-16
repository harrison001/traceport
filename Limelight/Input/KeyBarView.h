//
//  KeyBarView.h
//  Moonlight
//
//  One class, two surfaces.
//
//  As a **keyboard** it is a line above the system keyboard carrying the keys that keyboard
//  does not have: the modifiers, escape, tab, return, delete, the arrows. It comes and goes
//  with the system keyboard, because that is what it completes.
//
//  As a **pad** it is two columns down the letterbox, carrying a short list of macros the user
//  chose. It stays whether the system keyboard is up or not, and it is editable in place.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What a bar holds.
typedef NS_ENUM(NSInteger, KeyBarContent) {
    /// The keys a keyboard has and the on-screen one does not.
    KeyBarContentKeyboard,
    /// The user's chosen macros.
    KeyBarContentPad,
    /// Both, in one line. For a screen with no letterbox to put a pad in.
    KeyBarContentBoth,
};

@protocol KeyBarPadObserver <NSObject>
- (void)keyBarPadDidChange;
@end

@protocol KeyBarViewDelegate <NSObject>

/// The dismiss key was pressed.
- (void)keyBarDidRequestDismiss;

/// The keyboard key was pressed: show the system keyboard if it is hidden, hide it if not.
///
/// Held modifiers must survive the switch — this changes what is on screen, not what the host
/// thinks is pressed.
- (void)keyBarDidToggleSystemKeyboard;

@end

@interface KeyBarView : UIView

@property (nonatomic, weak) id<KeyBarViewDelegate> delegate;

/// Told when this bar changes the pad's contents, so the pad — a different instance — knows to
/// rebuild. Adding a key from the keyboard is the only thing that does it.
@property (nonatomic, weak) id<KeyBarPadObserver> padDelegate;

/// How much room to leave at the foot of the columns, for whatever is pinned along the bottom.
/// Split layout only.
@property (nonatomic, assign) CGFloat bottomInset;

/// Whether this bar carries the ⋯, ⌨ and Done controls. Exactly one surface should: with a pad
/// on screen the controls belong there, because the pad is the one that is always visible.
@property (nonatomic, assign) BOOL showsControls;

/// @param hostKey Identifies the host, so which operating system it runs is remembered per machine.
/// @param appName The app launched on the host, if any. Gives each app its own pad, the way
///                Stream Deck switches profiles by which application is in front.
- (instancetype)initWithFrame:(CGRect)frame
                      hostKey:(nullable NSString *)hostKey
                      appName:(nullable NSString *)appName
                      content:(KeyBarContent)content;

/// Lays the bar out as one line along an axis.
- (void)setAxis:(UILayoutConstraintAxis)axis;

/// Lays the keys out as two scrolling columns, one down each side, with nothing in between.
///
/// A 1512x982 Mac desktop on an iPhone in landscape fits 677 points wide inside 956, leaving
/// 139 points of pure black down each side — a quarter of the screen holding nothing, and
/// exactly where the thumbs rest. The middle passes touches through to the stream.
///
/// The columns stop above the system keyboard rather than disappearing under it, so the keys
/// stay in reach while typing.
///
/// @param marginWidth How wide the letterbox strip is. The caller measures it; the bar itself
///                    does not know what shape the stream is.
- (void)setSplitLayoutWithMarginWidth:(CGFloat)marginWidth;

/// How thick the bar is across its axis.
+ (CGFloat)barThickness;

/// Rebuilds from the stored pad list. For when another bar changed it.
- (void)reloadPad;

/// Releases every modifier the bar is holding down, on the host and visually.
///
/// Must be called when the stream ends or the bar goes away, otherwise the host is left with a
/// modifier stuck down and every later keystroke arrives modified.
- (void)releaseHeldModifiers;

/// Tells the bar that a key came from the system keyboard, so a one-shot modifier armed here
/// is released as it would be for a key on the bar.
- (void)externalKeyWasTyped;

/// Updates the keyboard key to reflect whether the system keyboard is currently showing.
- (void)setSystemKeyboardVisible:(BOOL)visible;

@end

NS_ASSUME_NONNULL_END
