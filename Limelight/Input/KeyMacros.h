//
//  KeyMacros.h
//  Moonlight
//
//  What the key bar contains, as data rather than as code.
//
//  Shaped after the two systems that do this best. Stream Deck Mobile organises actions into
//  labelled buttons and switches the whole layout by context; Termius builds its key bar from
//  user-defined groups that can be reordered. Both are configurable, both label actions with
//  words, and both group them. Jump Desktop, which hardcodes its own list, is the one that
//  cannot follow a user whose habits differ.
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
    /// Sends several chords in order, with a pause between them.
    ///
    /// Chords cannot express what tmux and every other prefix-key program need: Control-A,
    /// released, then z. That is two events in sequence, not one combination, and it is the
    /// shape Stream Deck calls a multi-action.
    KeyItemKindSequence,
};

/// One step of a sequence.
@interface KeyStep : NSObject
@property (nonatomic, assign, readonly) short virtualKey;
@property (nonatomic, assign, readonly) UIKeyModifierFlags modifiers;
+ (instancetype)step:(short)virtualKey modifiers:(UIKeyModifierFlags)modifiers;
@end

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
+ (instancetype)sequence:(NSString *)label steps:(NSArray<KeyStep *> *)steps;

/// Set only for sequences.
@property (nonatomic, copy, readonly, nullable) NSArray<KeyStep *> *steps;

@end

/// Items that belong together, drawn with a wide gap on either side.
@interface KeyGroup : NSObject
@property (nonatomic, copy, readonly) NSArray<KeyItem *> *items;

/// Marks where the right-hand column starts when the bar is laid out as two columns.
///
/// Splitting by key count puts the break in the wrong place: it lands in the middle of the
/// list by arithmetic, which has nothing to do with which keys are worth having in reach. The
/// break is a decision about what each thumb gets, so it is stated here rather than computed.
@property (nonatomic, assign) BOOL startsSecondColumn;

+ (instancetype)groupWithItems:(NSArray<KeyItem *> *)items;
@end

@interface KeyMacros : NSObject

/// Every group for a host, in one flat list.
///
/// The bar is a single scrolling row, so the order here is the order under the thumb: what is
/// used constantly comes first and is reachable without scrolling, and the long tails — the
/// navigation cluster, the function keys — sit at the end where they cost nothing until they
/// are wanted. There are no pages: a modifier armed on the bar stays armed while you scroll,
/// so nothing has to be visible at the same time as anything else.
+ (NSArray<KeyGroup *> *)groupsForHost:(KeyMacroHost)host;

/// Every group for a host, with the user's own changes applied.
///
/// `profileKey` identifies host and streamed app together. Stream Deck switches its whole
/// layout by which application is focused, and Moonlight is the thing that launched the app
/// on the host, so the same signal is available here for free: what you pin while driving a
/// terminal does not follow you into a design tool.
+ (NSArray<KeyGroup *> *)groupsForHost:(KeyMacroHost)host profileKey:(nullable NSString *)profileKey;

/// Moves an item to the front of the row, ahead of everything but the modifiers.
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
