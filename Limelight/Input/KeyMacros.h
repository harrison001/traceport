//
//  KeyMacros.h
//  Moonlight
//
//  What the key bar contains, as data rather than as code.
//
//  There are two separate sets, because there are two separate surfaces and they answer
//  different questions.
//
//  The line above the system keyboard is a **keyboard**: the keys a hardware keyboard has and
//  the on-screen one does not — the modifiers, escape, tab, return, delete, the arrows. It is
//  fixed, because a keyboard that moves under your fingers is not a keyboard.
//
//  The columns down the letterbox are a **pad**: a short, chosen list of macros. Stream Deck
//  Mobile and Termius both let the user decide what is on the surface, and Jump Desktop's
//  hardcoded list is the thing that cannot fit anyone whose habits differ from its author's.
//  The pad is stored per host and app, so what you put there while driving a terminal does not
//  follow you into anything else.
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
    /// Turns the mouse wheel. Not a key at all, but it is what the hand wants next to them:
    /// in touchscreen mode two fingers pan the picture, so there is otherwise no way to scroll.
    KeyItemKindScroll,
};

/// One step of a sequence.
@interface KeyStep : NSObject
@property (nonatomic, assign, readonly) short virtualKey;
@property (nonatomic, assign, readonly) UIKeyModifierFlags modifiers;
+ (instancetype)step:(short)virtualKey modifiers:(UIKeyModifierFlags)modifiers;
@end

@interface KeyItem : NSObject

/// What appears on the key, and how it is stored: labels are unique within a host's layout and
/// survive a rebuild, which a pointer or an index would not.
@property (nonatomic, copy, readonly) NSString *label;
@property (nonatomic, assign, readonly) KeyItemKind kind;
/// Win32 virtual key code.
@property (nonatomic, assign, readonly) short virtualKey;
/// For macros, the modifiers held around the key. For modifiers, the mask this one contributes.
@property (nonatomic, assign, readonly) UIKeyModifierFlags modifiers;
/// Wheel clicks per tap, positive towards the top of the document. Scroll items only.
@property (nonatomic, assign, readonly) signed char scrollClicks;
/// Set only for sequences.
@property (nonatomic, copy, readonly, nullable) NSArray<KeyStep *> *steps;
/// One line saying what this does, for the add menu. Nothing else in the app has room for it.
@property (nonatomic, copy, readonly, nullable) NSString *detail;

+ (instancetype)key:(NSString *)label code:(short)virtualKey;
+ (instancetype)modifier:(NSString *)label code:(short)virtualKey flag:(UIKeyModifierFlags)flag;
+ (instancetype)macro:(NSString *)label code:(short)virtualKey flags:(UIKeyModifierFlags)flags;
+ (instancetype)sequence:(NSString *)label steps:(NSArray<KeyStep *> *)steps;
+ (instancetype)scroll:(NSString *)label clicks:(signed char)clicks;

/// Returns a copy carrying a one-line description. Chainable onto any of the above.
- (instancetype)explained:(NSString *)detail;

@end

/// Items that belong together, drawn with a wide gap on either side. Named where the name is
/// shown — the add menu groups by it.
@interface KeyGroup : NSObject
@property (nonatomic, copy, readonly, nullable) NSString *name;
@property (nonatomic, copy, readonly) NSArray<KeyItem *> *items;

/// Marks where the right-hand column starts when the bar is laid out as two columns.
///
/// Splitting by key count puts the break in the wrong place: it lands in the middle of the list
/// by arithmetic, which has nothing to do with which keys are worth having in reach.
@property (nonatomic, assign) BOOL startsSecondColumn;

+ (instancetype)groupWithItems:(NSArray<KeyItem *> *)items;
+ (instancetype)groupNamed:(nullable NSString *)name items:(NSArray<KeyItem *> *)items;
@end

@interface KeyMacros : NSObject

#pragma mark - The keyboard

/// The keys a hardware keyboard has and the on-screen one does not.
///
/// No macros here. The system keyboard is directly underneath with the letters on it, and this
/// line is what makes it a whole keyboard rather than half of one.
+ (NSArray<KeyGroup *> *)keyboardGroupsForHost:(KeyMacroHost)host;

/// The same, with whatever the user has hidden taken out.
+ (NSArray<KeyGroup *> *)keyboardGroupsForHost:(KeyMacroHost)host
                                    profileKey:(nullable NSString *)profileKey;

+ (void)hideKeyboardKey:(KeyItem *)item forProfile:(nullable NSString *)profileKey;
+ (void)resetKeyboardForProfile:(nullable NSString *)profileKey;
+ (BOOL)keyboardIsCustomisedForProfile:(nullable NSString *)profileKey;

#pragma mark - The pad

/// Everything that can be put on the pad, grouped by category for the add menu.
+ (NSArray<KeyGroup *> *)macroCatalogueForHost:(KeyMacroHost)host;

/// What is on the pad now: the user's own list, or a short starter set if they have not
/// changed it.
+ (NSArray<KeyItem *> *)padItemsForHost:(KeyMacroHost)host
                             profileKey:(nullable NSString *)profileKey;

+ (void)addToPad:(KeyItem *)item forProfile:(nullable NSString *)profileKey host:(KeyMacroHost)host;
+ (void)removeFromPad:(KeyItem *)item forProfile:(nullable NSString *)profileKey host:(KeyMacroHost)host;
/// Moves an item one place towards the front of the pad.
+ (void)promoteOnPad:(KeyItem *)item forProfile:(nullable NSString *)profileKey host:(KeyMacroHost)host;
+ (void)resetPadForProfile:(nullable NSString *)profileKey;
+ (BOOL)padIsCustomisedForProfile:(nullable NSString *)profileKey;

#pragma mark - Which host

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
