//
//  KeyMacros.m
//  Moonlight
//

#import "KeyMacros.h"

@implementation KeyStep

+ (instancetype)step:(short)virtualKey modifiers:(UIKeyModifierFlags)modifiers {
    KeyStep *step = [[KeyStep alloc] init];
    if (step != nil) {
        step->_virtualKey = virtualKey;
        step->_modifiers = modifiers;
    }
    return step;
}

@end

@implementation KeyItem

+ (instancetype)itemWithLabel:(NSString *)label
                         kind:(KeyItemKind)kind
                         code:(short)virtualKey
                        flags:(UIKeyModifierFlags)flags {
    KeyItem *item = [[KeyItem alloc] init];
    if (item != nil) {
        item->_label = [label copy];
        item->_kind = kind;
        item->_virtualKey = virtualKey;
        item->_modifiers = flags;
    }
    return item;
}

+ (instancetype)key:(NSString *)label code:(short)virtualKey {
    return [self itemWithLabel:label kind:KeyItemKindKey code:virtualKey flags:0];
}

+ (instancetype)modifier:(NSString *)label code:(short)virtualKey flag:(UIKeyModifierFlags)flag {
    return [self itemWithLabel:label kind:KeyItemKindModifier code:virtualKey flags:flag];
}

+ (instancetype)macro:(NSString *)label code:(short)virtualKey flags:(UIKeyModifierFlags)flags {
    return [self itemWithLabel:label kind:KeyItemKindMacro code:virtualKey flags:flags];
}

+ (instancetype)sequence:(NSString *)label steps:(NSArray<KeyStep *> *)steps {
    KeyItem *item = [self itemWithLabel:label kind:KeyItemKindSequence code:0 flags:0];
    item->_steps = [steps copy];
    return item;
}

+ (instancetype)scroll:(NSString *)label clicks:(signed char)clicks {
    KeyItem *item = [self itemWithLabel:label kind:KeyItemKindScroll code:0 flags:0];
    item->_scrollClicks = clicks;
    return item;
}

@end

@implementation KeyGroup

+ (instancetype)groupWithItems:(NSArray<KeyItem *> *)items {
    KeyGroup *group = [[KeyGroup alloc] init];
    if (group != nil) {
        group->_items = [items copy];
    }
    return group;
}

@end

@implementation KeyMacros

/// tmux, then the input source, then the text keys. This set is not designed here: it is
/// TraceRecorder's Quick Input panel, which is the same person driving the same Mac, and it
/// settled after daily use rather than on paper.
///
/// Every item is a macro. The bar carries no bare modifiers, no arrows and no letters, because
/// the system keyboard is one tap away and already has them — spending the letterbox on a
/// second keyboard buys nothing. Labels are the chord itself for the same reason the panel
/// does it: "⌘W" is shorter than "Close", says more, and two of them fit on one row.

/// Prefix sequences for tmux. A chord cannot express what a prefix-key program needs:
/// Control-A, released, then the command key. That is two events in order, not one
/// combination, and it is the shape Stream Deck calls a multi-action.
///
/// Kept to what Harrison actually drives: zoom a pane, the broadcast toggle, and moving the
/// focus between panes. The prefix is Control-A rather than tmux's default Control-B.
+ (KeyGroup *)tmuxGroup {
    KeyStep *prefix = [KeyStep step:0x41 modifiers:UIKeyModifierControl];  // Control-A
    KeyItem *(^command)(NSString *, short) = ^KeyItem *(NSString *label, short key) {
        return [KeyItem sequence:label steps:@[prefix, [KeyStep step:key modifiers:0]]];
    };

    return [KeyGroup groupWithItems:@[
        command(@"⌃AZ", 0x5A),
        // prefix b toggles synchronize-panes, so typing goes to every pane in the window at
        // once. Harrison's binding turns the tmux status bar red while it is on.
        command(@"⌃AB", 0x42),
        command(@"⌃A←", 0x25),
        command(@"⌃A↓", 0x28),
        command(@"⌃A↑", 0x26),
        command(@"⌃A→", 0x27),
    ]];
}

/// The host's input source toggle, on its own so it is easy to find.
///
/// None of the tmux commands reach tmux while the host is composing in a Chinese input source:
/// the Control chord gets through but the command key that follows is eaten by the
/// composition. This is here so the fix is one tap away. It is not sent automatically before
/// every command, because Control-Space toggles rather than selects — firing it blindly would
/// switch a host that was already in English into Chinese, breaking the thing it protects.
+ (KeyGroup *)inputSourceGroup {
    return [KeyGroup groupWithItems:@[
        [KeyItem macro:@"中/A" code:0x20 flags:UIKeyModifierControl],
    ]];
}

/// Delete, escape and the clipboard, exactly the panel's first row.
+ (KeyGroup *)textKeysForHost:(KeyMacroHost)host {
    BOOL mac = host == KeyMacroHostMacOS;
    UIKeyModifierFlags m = mac ? UIKeyModifierCommand : UIKeyModifierControl;
    NSString *sym = mac ? @"⌘" : @"⌃";
    KeyItem *(^chord)(NSString *, short) = ^KeyItem *(NSString *letter, short key) {
        return [KeyItem macro:[sym stringByAppendingString:letter] code:key flags:m];
    };

    return [KeyGroup groupWithItems:@[
        [KeyItem key:@"⌫" code:0x08],
        [KeyItem key:@"⌦" code:0x2E],
        [KeyItem key:@"Esc" code:0x1B],
        chord(@"A", 0x41),
        chord(@"C", 0x43),
        chord(@"X", 0x58),
        chord(@"V", 0x56),
        chord(@"Z", 0x5A),
    ]];
}

/// The wheel.
///
/// Positive clicks scroll towards the top of the document — the same direction Moonlight's own
/// two-finger pan sends when it is dragged downwards. Three clicks is roughly a few lines,
/// which is what the panel settled on.
+ (KeyGroup *)scrollGroup {
    return [KeyGroup groupWithItems:@[
        [KeyItem scroll:@"∧" clicks:3],
        [KeyItem scroll:@"∨" clicks:-3],
    ]];
}

/// Window and desktop navigation. Multi-finger gestures cannot be produced at all from here,
/// so these are their keyboard equivalents — which is what the gestures trigger anyway.
+ (KeyGroup *)systemGroupForHost:(KeyMacroHost)host {
    if (host == KeyMacroHostMacOS) {
        UIKeyModifierFlags cmd = UIKeyModifierCommand;
        UIKeyModifierFlags ctrl = UIKeyModifierControl;
        return [KeyGroup groupWithItems:@[
            [KeyItem macro:@"⌘Tab" code:0x09 flags:cmd],
            [KeyItem macro:@"⇧⌘Tab" code:0x09 flags:cmd | UIKeyModifierShift],
            [KeyItem macro:@"⌘`" code:0xC0 flags:cmd],
            [KeyItem macro:@"⌘W" code:0x57 flags:cmd],
            [KeyItem macro:@"⌘Q" code:0x51 flags:cmd],
            [KeyItem macro:@"⌘H" code:0x48 flags:cmd],
            [KeyItem macro:@"⌘M" code:0x4D flags:cmd],
            [KeyItem macro:@"⌃⌘F" code:0x46 flags:cmd | ctrl],
            [KeyItem macro:@"⌃←" code:0x25 flags:ctrl],
            [KeyItem macro:@"⌃→" code:0x27 flags:ctrl],
            [KeyItem macro:@"⌃↑" code:0x26 flags:ctrl],
            [KeyItem macro:@"⌃↓" code:0x28 flags:ctrl],
            [KeyItem macro:@"⌘Spc" code:0x20 flags:cmd],
            [KeyItem macro:@"⇧⌘4" code:0x34 flags:cmd | UIKeyModifierShift],
        ]];
    }

    // Standard Windows shortcuts rather than ones proven in use, which is a weaker basis than
    // the macOS set and worth saying so. UIKeyModifierCommand is the Windows key here.
    UIKeyModifierFlags win = UIKeyModifierCommand;
    return [KeyGroup groupWithItems:@[
        [KeyItem macro:@"⎇Tab" code:0x09 flags:UIKeyModifierAlternate],
        [KeyItem macro:@"⎇F4" code:0x73 flags:UIKeyModifierAlternate],
        [KeyItem macro:@"⊞Tab" code:0x09 flags:win],
        [KeyItem macro:@"⊞D" code:0x44 flags:win],
        [KeyItem macro:@"⊞E" code:0x45 flags:win],
        [KeyItem macro:@"⊞L" code:0x4C flags:win],
        [KeyItem macro:@"⊞" code:0x5B flags:0],
        [KeyItem macro:@"⌃⇧Esc" code:0x1B flags:UIKeyModifierControl | UIKeyModifierShift],
        [KeyItem macro:@"⊞⇧S" code:0x53 flags:win | UIKeyModifierShift],
    ]];
}

+ (NSArray<KeyGroup *> *)groupsForHost:(KeyMacroHost)host {
    return host == KeyMacroHostMacOS ? [self macOSGroups] : [self windowsGroups];
}

+ (NSArray<KeyGroup *> *)macOSGroups {
    static NSArray<KeyGroup *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The left thumb gets tmux and the input source — what this is driven with every day,
        // all of it above the system keyboard without scrolling. The right thumb gets the
        // wheel and system navigation.
        KeyGroup *scroll = [self scrollGroup];
        scroll.startsSecondColumn = YES;

        groups = @[
            [self tmuxGroup],
            [self inputSourceGroup],
            [self textKeysForHost:KeyMacroHostMacOS],
            scroll,
            [self systemGroupForHost:KeyMacroHostMacOS],
        ];
    });
    return groups;
}

+ (NSArray<KeyGroup *> *)windowsGroups {
    static NSArray<KeyGroup *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        KeyGroup *scroll = [self scrollGroup];
        scroll.startsSecondColumn = YES;

        groups = @[
            [self textKeysForHost:KeyMacroHostWindows],
            scroll,
            [self systemGroupForHost:KeyMacroHostWindows],
        ];
    });
    return groups;
}

+ (KeyMacroHost)defaultHost {
    return KeyMacroHostMacOS;
}

/// Per host, because one person may drive a Mac from the sofa and a Windows box at work, and
/// the modifier that means "the system key" is not the same on both.
static NSString *KeyMacroHostDefaultsKey(NSString *key) {
    return [NSString stringWithFormat:@"KeyBarHostKind.%@", key.length > 0 ? key : @"default"];
}

+ (KeyMacroHost)hostKindForKey:(NSString *)key {
    NSString *defaultsKey = KeyMacroHostDefaultsKey(key);
    NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:defaultsKey];
    return stored != nil ? (KeyMacroHost)stored.integerValue : [self defaultHost];
}

+ (void)setHostKind:(KeyMacroHost)kind forKey:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setInteger:kind forKey:KeyMacroHostDefaultsKey(key)];
}

+ (NSString *)nameForHostKind:(KeyMacroHost)kind {
    return kind == KeyMacroHostMacOS ? @"macOS" : @"Windows";
}

#pragma mark - Customisation

/// Items are identified by label. Labels are unique within a layout and survive a rebuild,
/// which a pointer or an index would not.
static NSString *KeyProfileDefaultsKey(NSString *profileKey, NSString *field) {
    return [NSString stringWithFormat:@"KeyBar.%@.%@", profileKey.length > 0 ? profileKey : @"default", field];
}

+ (NSArray<NSString *> *)storedListFor:(NSString *)profileKey field:(NSString *)field {
    NSArray *stored = [[NSUserDefaults standardUserDefaults]
        stringArrayForKey:KeyProfileDefaultsKey(profileKey, field)];
    return stored ?: @[];
}

+ (void)storeList:(NSArray<NSString *> *)list for:(NSString *)profileKey field:(NSString *)field {
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:KeyProfileDefaultsKey(profileKey, field)];
}

+ (void)pinItem:(KeyItem *)item forProfile:(NSString *)profileKey {
    NSArray<NSString *> *pinned = [self storedListFor:profileKey field:@"pinned"];
    if ([pinned containsObject:item.label]) {
        return;
    }
    [self storeList:[pinned arrayByAddingObject:item.label] for:profileKey field:@"pinned"];
}

+ (void)hideItem:(KeyItem *)item forProfile:(NSString *)profileKey {
    NSArray<NSString *> *hidden = [self storedListFor:profileKey field:@"hidden"];
    if ([hidden containsObject:item.label]) {
        return;
    }
    [self storeList:[hidden arrayByAddingObject:item.label] for:profileKey field:@"hidden"];
}

+ (BOOL)isPinned:(KeyItem *)item forProfile:(NSString *)profileKey {
    return [[self storedListFor:profileKey field:@"pinned"] containsObject:item.label];
}

+ (void)resetProfile:(NSString *)profileKey {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:KeyProfileDefaultsKey(profileKey, @"pinned")];
    [defaults removeObjectForKey:KeyProfileDefaultsKey(profileKey, @"hidden")];
}

+ (BOOL)hasCustomisationForProfile:(NSString *)profileKey {
    return [self storedListFor:profileKey field:@"pinned"].count > 0
        || [self storedListFor:profileKey field:@"hidden"].count > 0;
}

+ (NSArray<KeyGroup *> *)groupsForHost:(KeyMacroHost)host profileKey:(NSString *)profileKey {
    NSArray<KeyGroup *> *base = [self groupsForHost:host];
    NSArray<NSString *> *pinned = [self storedListFor:profileKey field:@"pinned"];
    NSArray<NSString *> *hidden = [self storedListFor:profileKey field:@"hidden"];

    if (pinned.count == 0 && hidden.count == 0) {
        return base;
    }

    // Look up the pinned labels in the base layout so a pinned item keeps its real behaviour.
    NSMutableDictionary<NSString *, KeyItem *> *byLabel = [NSMutableDictionary dictionary];
    for (KeyGroup *group in base) {
        for (KeyItem *item in group.items) {
            byLabel[item.label] = item;
        }
    }

    NSMutableArray<KeyGroup *> *groups = [NSMutableArray array];

    // Pinned items lead the left column. That is the whole of what pinning means: there is one
    // list, so "your own page" is "first under the thumb".
    if (pinned.count > 0) {
        NSMutableArray<KeyItem *> *items = [NSMutableArray array];
        for (NSString *label in pinned) {
            KeyItem *item = byLabel[label];
            if (item != nil) {
                [items addObject:item];
            }
        }
        if (items.count > 0) {
            [groups addObject:[KeyGroup groupWithItems:items]];
        }
    }

    for (KeyGroup *group in base) {
        NSMutableArray<KeyItem *> *items = [NSMutableArray array];
        for (KeyItem *item in group.items) {
            // A pinned item keeps its original place too, so muscle memory built before
            // pinning still works.
            if (![hidden containsObject:item.label]) {
                [items addObject:item];
            }
        }
        if (items.count > 0) {
            KeyGroup *rebuilt = [KeyGroup groupWithItems:items];
            // Carried over, or hiding one key would move the column break.
            rebuilt.startsSecondColumn = group.startsSecondColumn;
            [groups addObject:rebuilt];
        }
    }

    return groups;
}

@end
