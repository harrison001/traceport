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

/// Always leftmost, so their position never moves.
+ (KeyGroup *)modifiersForHost:(KeyMacroHost)host {
    BOOL mac = host == KeyMacroHostMacOS;
    return [KeyGroup groupWithItems:@[
        [KeyItem modifier:@"⇧" code:0xA0 flag:UIKeyModifierShift],
        [KeyItem modifier:@"⌃" code:0xA2 flag:UIKeyModifierControl],
        [KeyItem modifier:mac ? @"⌥" : @"alt" code:0xA4 flag:UIKeyModifierAlternate],
        [KeyItem modifier:mac ? @"⌘" : @"⊞" code:0x5B flag:UIKeyModifierCommand],
    ]];
}

+ (KeyGroup *)clipboardForHost:(KeyMacroHost)host {
    UIKeyModifierFlags m = host == KeyMacroHostMacOS ? UIKeyModifierCommand : UIKeyModifierControl;
    return [KeyGroup groupWithItems:@[
        [KeyItem macro:@"Copy" code:0x43 flags:m],
        [KeyItem macro:@"Paste" code:0x56 flags:m],
        [KeyItem macro:@"Cut" code:0x58 flags:m],
        [KeyItem macro:@"All" code:0x41 flags:m],
        [KeyItem macro:@"Undo" code:0x5A flags:m],
    ]];
}

+ (KeyGroup *)arrows {
    return [KeyGroup groupWithItems:@[
        [KeyItem key:@"←" code:0x25],
        [KeyItem key:@"↓" code:0x28],
        [KeyItem key:@"↑" code:0x26],
        [KeyItem key:@"→" code:0x27],
    ]];
}

+ (KeyGroup *)functionKeys {
    NSMutableArray<KeyItem *> *items = [NSMutableArray array];
    for (short i = 0; i < 12; i++) {
        [items addObject:[KeyItem key:[NSString stringWithFormat:@"F%d", i + 1] code:0x70 + i]];
    }
    return [KeyGroup groupWithItems:items];
}

+ (KeyGroup *)editingKeys {
    return [KeyGroup groupWithItems:@[
        [KeyItem key:@"esc" code:0x1B],
        [KeyItem key:@"tab" code:0x09],
        [KeyItem key:@"↵" code:0x0D],
        [KeyItem key:@"⌦" code:0x2E],
    ]];
}

/// Home, End and the two paging keys. Last but one in the row: nothing here is used often
/// enough to sit in front of the tmux commands.
+ (KeyGroup *)navigationKeys {
    return [KeyGroup groupWithItems:@[
        [KeyItem key:@"↖" code:0x24],
        [KeyItem key:@"↘" code:0x23],
        [KeyItem key:@"⇞" code:0x21],
        [KeyItem key:@"⇟" code:0x22],
    ]];
}

+ (NSArray<KeyGroup *> *)groupsForHost:(KeyMacroHost)host {
    return host == KeyMacroHostMacOS ? [self macOSGroups] : [self windowsGroups];
}

/// The macOS action set is not designed here: it is what TraceRecorder's Quick Input panel
/// ended up with after daily use, help text and all, relabelled from chords to what they do.
+ (NSArray<KeyGroup *> *)macOSGroups {
    static NSArray<KeyGroup *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        groups = [@[
            [self modifiersForHost:KeyMacroHostMacOS],
            [self editingKeys],
            [self arrows],
            [self clipboardForHost:KeyMacroHostMacOS],
        ] arrayByAddingObjectsFromArray:[self tmuxGroups]];

        groups = [groups arrayByAddingObjectsFromArray:@[
            [KeyGroup groupWithItems:@[
                [KeyItem macro:@"Switch App" code:0x09 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Windows" code:0xC0 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Close" code:0x57 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Quit" code:0x51 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Hide" code:0x48 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Minimise" code:0x4D flags:UIKeyModifierCommand],
                [KeyItem macro:@"Full Screen" code:0x46
                          flags:UIKeyModifierCommand | UIKeyModifierControl],
            ]],
            [KeyGroup groupWithItems:@[
                [KeyItem macro:@"Mission Control" code:0x26 flags:UIKeyModifierControl],
                [KeyItem macro:@"App Exposé" code:0x28 flags:UIKeyModifierControl],
                [KeyItem macro:@"Desktop ←" code:0x25 flags:UIKeyModifierControl],
                [KeyItem macro:@"Desktop →" code:0x27 flags:UIKeyModifierControl],
                [KeyItem macro:@"Spotlight" code:0x20 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Screenshot" code:0x34
                          flags:UIKeyModifierCommand | UIKeyModifierShift],
            ]],
            [self navigationKeys],
            [KeyGroup groupWithItems:@[
                [KeyItem key:@"ins" code:0x2D],
                [KeyItem key:@"Pause" code:0x13],
                [KeyItem key:@"Break" code:0x03],
            ]],
            [self functionKeys],
        ]];
    });
    return groups;
}

/// tmux and every other prefix-key program need a sequence, not a chord: Control-A, released,
/// then the command key. Assembling that from the bar by hand does not work either, because a
/// one-shot modifier is consumed by the next bar key and the letter comes from the system
/// keyboard instead.
///
/// Kept to what Harrison actually drives: zoom a pane, one toggle, and moving the focus
/// between panes. tmux has dozens of bindings and none of the rest were being used.
///
/// The prefix is Control-A rather than tmux's default Control-B, which is what he binds.
+ (NSArray<KeyGroup *> *)tmuxGroups {
    KeyStep *prefix = [KeyStep step:0x41 modifiers:UIKeyModifierControl];  // Control-A
    KeyItem *(^command)(NSString *, short) = ^KeyItem *(NSString *label, short key) {
        return [KeyItem sequence:label steps:@[prefix, [KeyStep step:key modifiers:0]]];
    };

    return @[
        [KeyGroup groupWithItems:@[
            command(@"Zoom", 0x5A),
            // prefix b toggles synchronize-panes, so typing goes to every pane in the window
            // at once. Harrison's binding turns the tmux status bar red while it is on.
            command(@"Sync", 0x42),
            // Prefix then an arrow moves the focus between panes. Spelled out rather than
            // labelled with a bare arrow: in one row these sit near the plain arrow keys, and
            // two keys reading "←" that do different things is the ambiguity that makes a bar
            // untrustworthy. It is also what the pin and hide list keys off.
            command(@"⌃A←", 0x25),
            command(@"⌃A↓", 0x28),
            command(@"⌃A↑", 0x26),
            command(@"⌃A→", 0x27),
        ]],
        // None of the above reaches tmux while the host is composing in a Chinese input
        // source: the Control chord gets through but the command key that follows is eaten
        // by the composition. This is here so the fix is one tap away.
        //
        // It is not sent automatically before every command, because Control-Space toggles
        // rather than selects — firing it blindly would switch a host that was already in
        // English into Chinese, breaking the thing it was meant to protect.
        //
        // macOS switches input source on Control-Space by default. TraceRecorder labels this
        // 中/A, which says what it does better than the chord does.
        [KeyGroup groupWithItems:@[
            [KeyItem macro:@"中/A" code:0x20 flags:UIKeyModifierControl],
        ]],
    ];
}

/// The Windows equivalents. Standard shortcuts rather than ones proven in use, which is a
/// weaker basis than the macOS set and worth saying so.
+ (NSArray<KeyGroup *> *)windowsGroups {
    static NSArray<KeyGroup *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        groups = @[
            [self modifiersForHost:KeyMacroHostWindows],
            [self editingKeys],
            [self arrows],
            [self clipboardForHost:KeyMacroHostWindows],
            [KeyGroup groupWithItems:@[
                [KeyItem macro:@"Switch App" code:0x09 flags:UIKeyModifierAlternate],
                [KeyItem macro:@"Close" code:0x73 flags:UIKeyModifierAlternate],
                [KeyItem macro:@"Desktop" code:0x44 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Explorer" code:0x45 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Lock" code:0x4C flags:UIKeyModifierCommand],
                [KeyItem macro:@"Start" code:0x5B flags:0],
            ]],
            [KeyGroup groupWithItems:@[
                [KeyItem macro:@"Task Manager" code:0x1B
                          flags:UIKeyModifierControl | UIKeyModifierShift],
                [KeyItem macro:@"Game Bar" code:0x47 flags:UIKeyModifierCommand],
                [KeyItem macro:@"Screenshot" code:0x53
                          flags:UIKeyModifierCommand | UIKeyModifierShift],
            ]],
            [self navigationKeys],
            [KeyGroup groupWithItems:@[
                [KeyItem key:@"ins" code:0x2D],
                [KeyItem key:@"Pause" code:0x13],
                [KeyItem key:@"Break" code:0x03],
            ]],
            [self functionKeys],
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
    BOOL modifiersPlaced = NO;

    // Pinned items go to the near end of the row, right after the modifiers. That is the whole
    // of what pinning means now: there is one row, so "your own page" is "first under the thumb".
    if (pinned.count > 0) {
        NSMutableArray<KeyItem *> *items = [NSMutableArray array];
        for (NSString *label in pinned) {
            KeyItem *item = byLabel[label];
            if (item != nil && item.kind != KeyItemKindModifier) {
                [items addObject:item];
            }
        }
        if (items.count > 0) {
            [groups addObject:[self modifiersForHost:host]];
            [groups addObject:[KeyGroup groupWithItems:items]];
            modifiersPlaced = YES;
        }
    }

    for (KeyGroup *group in base) {
        NSMutableArray<KeyItem *> *items = [NSMutableArray array];
        for (KeyItem *item in group.items) {
            if (item.kind == KeyItemKindModifier) {
                // Modifiers are never hidden and appear exactly once, at the front.
                if (!modifiersPlaced) {
                    [items addObject:item];
                }
            } else if (![hidden containsObject:item.label]) {
                // A pinned item keeps its original place too, so muscle memory built before
                // pinning still works.
                [items addObject:item];
            }
        }
        if (items.count > 0) {
            [groups addObject:[KeyGroup groupWithItems:items]];
        }
    }

    return groups;
}

@end
