//
//  KeyMacros.h
//  Moonlight
//
//  What the key bar contains, as data rather than as code.
//
//  Shaped after the two systems that do this best. Stream Deck Mobile organises actions into
//  folders and pages of labelled buttons and switches the whole layout by context; Termius
//  builds its key bar from user-defined groups of four that can be reordered. Both are
//  configurable, both label actions with words, and both group them. Jump Desktop, which
//  hardcodes its own list, is the one that cannot follow a user whose habits differ.
//
//  Nothing here is configurable yet, but everything is data, so making it configurable is a
//  matter of persisting these structures rather than rewriting the bar.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Which host we are driving. Decides labels and which layout applies.
typedef NS_ENUM(NSInteger, KeyMacroHost) {
    KeyMacroHostMacOS,
    KeyMacroHostWindows,
};

/// How an item behaves when tapped.
typedef NS_ENUM(NSInteger, KeyItemKind) {
    /// Sends itself, picking up whatever modifiers the bar is holding.
    KeyItemKindKey,
    /// Cycles off, one-shot, locked.
    KeyItemKindModifier,
    /// Sends a complete chord regardless of what the bar is holding.
    KeyItemKindMacro,
};

@interface KeyItem : NSObject

/// What appears on the key. Words for macros, symbols for keys.
@property (nonatomic, copy, readonly) NSString *label;
@property (nonatomic, assign, readonly) KeyItemKind kind;
/// Win32 virtual key code.
@property (nonatomic, assign, readonly) short virtualKey;
/// For macros, the modifiers held around the key. For modifiers, the mask this one contributes.
@property (nonatomic, assign, readonly) UIKeyModifierFlags modifiers;

+ (instancetype)key:(NSString *)label code:(short)virtualKey;
+ (instancetype)modifier:(NSString *)label code:(short)virtualKey flag:(UIKeyModifierFlags)flag;
+ (instancetype)macro:(NSString *)label code:(short)virtualKey flags:(UIKeyModifierFlags)flags;

@end

/// Items that belong together, drawn with a wide gap on either side.
@interface KeyGroup : NSObject
@property (nonatomic, copy, readonly) NSArray<KeyItem *> *items;
+ (instancetype)groupWithItems:(NSArray<KeyItem *> *)items;
@end

/// One screenful of groups, reachable from the page control.
@interface KeyPage : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<KeyGroup *> *groups;
+ (instancetype)pageNamed:(NSString *)name groups:(NSArray<KeyGroup *> *)groups;
@end

@interface KeyMacros : NSObject

/// The pages for a host.
///
/// Modifiers and the clipboard repeat across pages on purpose. Paging costs a tap only for
/// what is not on the current page, so putting the universally used items on every page
/// removes that cost for almost everything — which is how Jump Desktop's keypads work, and
/// the one thing about them worth copying.
+ (NSArray<KeyPage *> *)pagesForHost:(KeyMacroHost)host;

/// The host to assume until the user says otherwise.
///
/// The client cannot discover this: Sunshine's /serverinfo carries no platform field. Note
/// that Stream Deck switches profiles by which application is focused, which is a better
/// signal than the operating system and one we could actually obtain — Moonlight is what
/// launched the app on the host, so it knows which one is running.
+ (KeyMacroHost)defaultHost;

@end

NS_ASSUME_NONNULL_END
