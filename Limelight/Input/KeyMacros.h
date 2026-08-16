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

/// The pages for a host, with the user's own changes applied.
///
/// `profileKey` identifies host and streamed app together. Stream Deck switches its whole
/// layout by which application is focused, and Moonlight is the thing that launched the app
/// on the host, so the same signal is available here for free: what you pin while driving a
/// terminal does not follow you into a design tool.
+ (NSArray<KeyPage *> *)pagesForHost:(KeyMacroHost)host profileKey:(nullable NSString *)profileKey;

/// Adds an item to the profile's own page, which is shown first when it has anything in it.
+ (void)pinItem:(KeyItem *)item forProfile:(nullable NSString *)profileKey;
/// Hides an item everywhere in this profile.
+ (void)hideItem:(KeyItem *)item forProfile:(nullable NSString *)profileKey;
+ (BOOL)isPinned:(KeyItem *)item forProfile:(nullable NSString *)profileKey;
/// Drops every customisation for the profile.
+ (void)resetProfile:(nullable NSString *)profileKey;
+ (BOOL)hasCustomisationForProfile:(nullable NSString *)profileKey;

/// Which operating system a given host runs, as the user has told us.
///
/// The client cannot discover this on its own: Sunshine's /serverinfo carries no platform
/// field, so there is nothing to read and nothing to infer that would not be a guess. It is
/// therefore a setting, remembered per host, and macOS until told otherwise.
+ (KeyMacroHost)hostKindForKey:(nullable NSString *)key;
+ (void)setHostKind:(KeyMacroHost)kind forKey:(nullable NSString *)key;

/// Name shown for a host kind.
+ (NSString *)nameForHostKind:(KeyMacroHost)kind;

/// The host to assume when nothing has been chosen.
+ (KeyMacroHost)defaultHost;

@end

NS_ASSUME_NONNULL_END
