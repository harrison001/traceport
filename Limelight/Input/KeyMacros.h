//
//  KeyMacros.h
//  Moonlight
//
//  Named chords, grouped per host operating system.
//
//  Two problems this solves. Chords like Command-Space cannot be typed from the key bar at
//  all when a hardware keyboard is attached, because the letter half lives on a system
//  keyboard that is deliberately not shown. And a bar of individual keys makes the user
//  assemble every shortcut themselves, which is what TeamViewer avoids by putting named
//  actions behind one button rather than exposing more keys.
//
//  The macOS list is not designed here. It is the set Harrison arrived at by using
//  TraceRecorder's Quick Input panel daily, help text included.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Which host we are driving. Decides which macro set and which modifier names apply.
typedef NS_ENUM(NSInteger, KeyMacroHost) {
    KeyMacroHostMacOS,
    KeyMacroHostWindows,
};

@interface KeyMacro : NSObject

/// Short label, e.g. "⌘Tab".
@property (nonatomic, copy, readonly) NSString *label;
/// What it does, shown as the menu subtitle, e.g. "Switch to the previous app".
@property (nonatomic, copy, readonly) NSString *help;
/// Win32 virtual key code of the non-modifier key.
@property (nonatomic, assign, readonly) short virtualKey;
/// Modifiers held around it.
@property (nonatomic, assign, readonly) UIKeyModifierFlags modifiers;

/// Whether this belongs on the bar itself rather than in the menu.
///
/// The split is not a guess. TraceRecorder's Quick Input keeps exactly these next to the
/// text field and puts the rest in a group of their own, which is the frequency ordering
/// arrived at by using it.
@property (nonatomic, assign, readonly) BOOL primary;

@end

@interface KeyMacros : NSObject

/// The macros for a host, in the order they should appear.
+ (NSArray<KeyMacro *> *)macrosForHost:(KeyMacroHost)host;

/// The host to assume until the user says otherwise.
///
/// The client cannot discover this: Sunshine's /serverinfo carries no platform field, so
/// there is nothing to read. Until a per-host setting exists, assume the host matches the
/// platform this app is most often used to reach.
+ (KeyMacroHost)defaultHost;

@end

NS_ASSUME_NONNULL_END
