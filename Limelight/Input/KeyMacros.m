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

/// Marks an app jump so it survives a round trip through the stored pad list, which is a list
/// of labels: the arrow is part of the label, and what follows it is the program's name.
NSString * const KeyAppJumpPrefix = @"→";

+ (instancetype)appJump:(NSString *)appName {
    KeyItem *item = [self itemWithLabel:[KeyAppJumpPrefix stringByAppendingString:appName]
                                   kind:KeyItemKindAppJump
                                   code:0
                                  flags:0];
    item->_appName = [appName copy];
    item->_detail = [NSString stringWithFormat:@"Open %@", appName];
    return item;
}

- (instancetype)copyOfSelf {
    KeyItem *copy = [KeyItem itemWithLabel:_label kind:_kind code:_virtualKey flags:_modifiers];
    copy->_steps = _steps;
    copy->_scrollClicks = _scrollClicks;
    copy->_detail = _detail;
    copy->_wantsKeyboard = _wantsKeyboard;
    copy->_appName = _appName;
    return copy;
}

- (instancetype)explained:(NSString *)detail {
    KeyItem *copy = [self copyOfSelf];
    copy->_detail = [detail copy];
    return copy;
}

- (instancetype)needingKeyboard {
    KeyItem *copy = [self copyOfSelf];
    copy->_wantsKeyboard = YES;
    return copy;
}

@end

@implementation KeyGroup

+ (instancetype)groupWithItems:(NSArray<KeyItem *> *)items {
    return [self groupNamed:nil items:items];
}

+ (instancetype)groupNamed:(NSString *)name items:(NSArray<KeyItem *> *)items {
    KeyGroup *group = [[KeyGroup alloc] init];
    if (group != nil) {
        group->_name = [name copy];
        group->_items = [items copy];
    }
    return group;
}

@end

@implementation KeyMacros

#pragma mark - The keyboard

+ (NSArray<KeyGroup *> *)keyboardGroupsForHost:(KeyMacroHost)host
                                    profileKey:(NSString *)profileKey {
    NSArray<NSString *> *hidden = [self hiddenKeyboardLabelsForProfile:profileKey];
    if (hidden.count == 0) {
        return [self keyboardGroupsForHost:host];
    }

    NSMutableArray<KeyGroup *> *groups = [NSMutableArray array];
    for (KeyGroup *group in [self keyboardGroupsForHost:host]) {
        NSMutableArray<KeyItem *> *items = [NSMutableArray array];
        for (KeyItem *item in group.items) {
            // Modifiers are never hidden: they anchor the left end and the one-shot state
            // machine is what makes an unlisted chord typeable at all.
            if (item.kind == KeyItemKindModifier || ![hidden containsObject:item.label]) {
                [items addObject:item];
            }
        }
        if (items.count > 0) {
            [groups addObject:[KeyGroup groupWithItems:items]];
        }
    }
    return groups;
}

static NSString *KeyHiddenDefaultsKey(NSString *profileKey) {
    return [NSString stringWithFormat:@"KeyBar.%@.hidden",
            profileKey.length > 0 ? profileKey : @"default"];
}

+ (NSArray<NSString *> *)hiddenKeyboardLabelsForProfile:(NSString *)profileKey {
    return [[NSUserDefaults standardUserDefaults]
            stringArrayForKey:KeyHiddenDefaultsKey(profileKey)] ?: @[];
}

+ (void)hideKeyboardKey:(KeyItem *)item forProfile:(NSString *)profileKey {
    NSArray<NSString *> *hidden = [self hiddenKeyboardLabelsForProfile:profileKey];
    if ([hidden containsObject:item.label]) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:[hidden arrayByAddingObject:item.label]
                                             forKey:KeyHiddenDefaultsKey(profileKey)];
}

+ (void)resetKeyboardForProfile:(NSString *)profileKey {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:KeyHiddenDefaultsKey(profileKey)];
}

+ (BOOL)keyboardIsCustomisedForProfile:(NSString *)profileKey {
    return [self hiddenKeyboardLabelsForProfile:profileKey].count > 0;
}

+ (NSArray<KeyGroup *> *)keyboardGroupsForHost:(KeyMacroHost)host {
    BOOL mac = host == KeyMacroHostMacOS;
    return @[
        // Leftmost, so their position never moves. Tapping once arms one for the next key,
        // twice holds it down — which is what makes ⌃C typeable with the system keyboard.
        [KeyGroup groupWithItems:@[
            [KeyItem modifier:@"⇧" code:0xA0 flag:UIKeyModifierShift],
            [KeyItem modifier:@"⌃" code:0xA2 flag:UIKeyModifierControl],
            [KeyItem modifier:mac ? @"⌥" : @"alt" code:0xA4 flag:UIKeyModifierAlternate],
            [KeyItem modifier:mac ? @"⌘" : @"⊞" code:0x5B flag:UIKeyModifierCommand],
        ]],
        [KeyGroup groupWithItems:@[
            [KeyItem key:@"esc" code:0x1B],
            [KeyItem key:@"tab" code:0x09],
            [KeyItem key:@"↵" code:0x0D],
            [KeyItem key:@"⌫" code:0x08],
            [KeyItem key:@"⌦" code:0x2E],
        ]],
        // Ahead of the arrows, because this is what they are for: an input method on the host
        // numbers its candidates and you pick one by pressing the number. Reaching them meant
        // switching the system keyboard to its 123 layer, losing sight of the candidates in
        // the process.
        [KeyGroup groupWithItems:@[
            [KeyItem key:@"1" code:0x31],
            [KeyItem key:@"2" code:0x32],
            [KeyItem key:@"3" code:0x33],
            [KeyItem key:@"4" code:0x34],
            [KeyItem key:@"5" code:0x35],
            [KeyItem key:@"6" code:0x36],
            [KeyItem key:@"7" code:0x37],
            [KeyItem key:@"8" code:0x38],
            [KeyItem key:@"9" code:0x39],
        ]],
        [KeyGroup groupWithItems:@[
            [KeyItem key:@"←" code:0x25],
            [KeyItem key:@"↓" code:0x28],
            [KeyItem key:@"↑" code:0x26],
            [KeyItem key:@"→" code:0x27],
        ]],
        // Home, End and the two paging keys. Past the fold, which is what the bar scrolls for.
        [KeyGroup groupWithItems:@[
            [KeyItem key:@"↖" code:0x24],
            [KeyItem key:@"↘" code:0x23],
            [KeyItem key:@"⇞" code:0x21],
            [KeyItem key:@"⇟" code:0x22],
        ]],
        [KeyGroup groupWithItems:@[
            [KeyItem key:@"ins" code:0x2D],
            [KeyItem key:@"Pause" code:0x13],
            [KeyItem key:@"Break" code:0x03],
        ]],
        [KeyGroup groupWithItems:[self functionKeys]],
    ];
}

+ (NSArray<KeyItem *> *)functionKeys {
    NSMutableArray<KeyItem *> *items = [NSMutableArray array];
    for (short i = 0; i < 12; i++) {
        [items addObject:[KeyItem key:[NSString stringWithFormat:@"F%d", i + 1] code:0x70 + i]];
    }
    return items;
}

#pragma mark - The pad

/// tmux and every other prefix-key program need a sequence, not a chord: Control-A, released,
/// then the command key. The prefix is Control-A rather than tmux's default Control-B.
+ (KeyGroup *)tmuxGroup {
    KeyStep *prefix = [KeyStep step:0x41 modifiers:UIKeyModifierControl];  // Control-A
    KeyItem *(^cmd)(NSString *, short, NSString *) =
        ^KeyItem *(NSString *label, short key, NSString *detail) {
        return [[KeyItem sequence:label steps:@[prefix, [KeyStep step:key modifiers:0]]]
                explained:detail];
    };

    return [KeyGroup groupNamed:@"tmux" items:@[
        cmd(@"⌃AZ", 0x5A, @"Zoom the pane"),
        // Harrison's binding turns the tmux status bar red while synchronize-panes is on.
        cmd(@"⌃AB", 0x42, @"Broadcast typing to every pane"),
        cmd(@"⌃A←", 0x25, @"Focus the pane to the left"),
        cmd(@"⌃A↓", 0x28, @"Focus the pane below"),
        cmd(@"⌃A↑", 0x26, @"Focus the pane above"),
        cmd(@"⌃A→", 0x27, @"Focus the pane to the right"),
        cmd(@"⌃AC", 0x43, @"New window"),
        cmd(@"⌃AN", 0x4E, @"Next window"),
        cmd(@"⌃A[", 0xDB, @"Copy mode, to scroll back"),
    ]];
}

+ (KeyGroup *)inputSourceGroup {
    return [KeyGroup groupNamed:@"Input" items:@[
        // None of the tmux commands reach tmux while the host is composing in a Chinese input
        // source: the Control chord gets through but the command key that follows is eaten by
        // the composition. This is here so the fix is one tap away. It is not sent
        // automatically before every command, because Control-Space toggles rather than
        // selects — firing it blindly would switch a host that was already in English into
        // Chinese, breaking the thing it protects.
        [[KeyItem macro:@"中/A" code:0x20 flags:UIKeyModifierControl]
         explained:@"Switch the host's input source"],
    ]];
}

+ (KeyGroup *)textGroupForHost:(KeyMacroHost)host {
    BOOL mac = host == KeyMacroHostMacOS;
    UIKeyModifierFlags m = mac ? UIKeyModifierCommand : UIKeyModifierControl;
    NSString *sym = mac ? @"⌘" : @"⌃";
    KeyItem *(^chord)(NSString *, short, NSString *) =
        ^KeyItem *(NSString *letter, short key, NSString *detail) {
        return [[KeyItem macro:[sym stringByAppendingString:letter] code:key flags:m]
                explained:detail];
    };

    return [KeyGroup groupNamed:@"Text" items:@[
        chord(@"A", 0x41, @"Select all"),
        chord(@"C", 0x43, @"Copy"),
        chord(@"X", 0x58, @"Cut"),
        chord(@"V", 0x56, @"Paste"),
        chord(@"Z", 0x5A, @"Undo"),
    ]];
}

/// Positive clicks scroll towards the top of the document — the same direction Moonlight's own
/// two-finger pan sends when it is dragged downwards. Three clicks is roughly a few lines.
+ (KeyGroup *)scrollGroup {
    return [KeyGroup groupNamed:@"Scroll" items:@[
        [[KeyItem scroll:@"∧" clicks:3] explained:@"Scroll up"],
        [[KeyItem scroll:@"∨" clicks:-3] explained:@"Scroll down"],
    ]];
}

/// Window and desktop navigation. Multi-finger gestures cannot be produced from here at all,
/// so these are their keyboard equivalents — which is what the gestures trigger anyway.
+ (KeyGroup *)systemGroupForHost:(KeyMacroHost)host {
    UIKeyModifierFlags shift = UIKeyModifierShift;

    if (host == KeyMacroHostMacOS) {
        UIKeyModifierFlags cmd = UIKeyModifierCommand;
        UIKeyModifierFlags ctrl = UIKeyModifierControl;
        return [KeyGroup groupNamed:@"Windows" items:@[
            [[KeyItem macro:@"⌘Tab" code:0x09 flags:cmd] explained:@"Previous app"],
            [[KeyItem macro:@"⇧⌘Tab" code:0x09 flags:cmd | shift] explained:@"App switcher, back"],
            [[KeyItem macro:@"⌘`" code:0xC0 flags:cmd] explained:@"Cycle this app's windows"],
            [[KeyItem macro:@"⌘W" code:0x57 flags:cmd] explained:@"Close the window"],
            [[KeyItem macro:@"⌘Q" code:0x51 flags:cmd] explained:@"Quit the app"],
            [[KeyItem macro:@"⌘H" code:0x48 flags:cmd] explained:@"Hide the app"],
            [[KeyItem macro:@"⌘M" code:0x4D flags:cmd] explained:@"Minimise the window"],
            [[KeyItem macro:@"⌃⌘F" code:0x46 flags:cmd | ctrl] explained:@"Toggle full screen"],
            [[KeyItem macro:@"⌃←" code:0x25 flags:ctrl] explained:@"Previous desktop"],
            [[KeyItem macro:@"⌃→" code:0x27 flags:ctrl] explained:@"Next desktop"],
            [[KeyItem macro:@"⌃↑" code:0x26 flags:ctrl] explained:@"Mission Control"],
            [[KeyItem macro:@"⌃↓" code:0x28 flags:ctrl] explained:@"App Exposé"],
            [[[KeyItem macro:@"⌘Spc" code:0x20 flags:cmd] explained:@"Spotlight — type to search"]
              needingKeyboard],
            [[KeyItem macro:@"⇧⌘4" code:0x34 flags:cmd | shift] explained:@"Screenshot a selection"],
        ]];
    }

    // Standard Windows shortcuts rather than ones proven in use, which is a weaker basis than
    // the macOS set and worth saying so. UIKeyModifierCommand is the Windows key here.
    UIKeyModifierFlags win = UIKeyModifierCommand;
    UIKeyModifierFlags alt = UIKeyModifierAlternate;
    return [KeyGroup groupNamed:@"Windows" items:@[
        [[KeyItem macro:@"⎇Tab" code:0x09 flags:alt] explained:@"Switch app"],
        [[KeyItem macro:@"⎇F4" code:0x73 flags:alt] explained:@"Close the window"],
        [[KeyItem macro:@"⊞Tab" code:0x09 flags:win] explained:@"Task view"],
        [[KeyItem macro:@"⊞D" code:0x44 flags:win] explained:@"Show the desktop"],
        [[KeyItem macro:@"⊞E" code:0x45 flags:win] explained:@"File Explorer"],
        [[KeyItem macro:@"⊞L" code:0x4C flags:win] explained:@"Lock"],
        [[[KeyItem macro:@"⊞" code:0x5B flags:0] explained:@"Start menu — type to search"]
          needingKeyboard],
        [[KeyItem macro:@"⌃⇧Esc" code:0x1B flags:UIKeyModifierControl | shift]
         explained:@"Task Manager"],
        [[KeyItem macro:@"⊞⇧S" code:0x53 flags:win | shift] explained:@"Snip"],
    ]];
}

+ (NSArray<KeyGroup *> *)macroCatalogueForHost:(KeyMacroHost)host {
    if (host == KeyMacroHostMacOS) {
        return @[
            [self tmuxGroup],
            [self inputSourceGroup],
            [self systemGroupForHost:host],
            [self textGroupForHost:host],
            [self scrollGroup],
        ];
    }
    return @[
        [self systemGroupForHost:host],
        [self textGroupForHost:host],
        [self scrollGroup],
    ];
}

/// What the pad holds before anyone changes it.
///
/// Deliberately short. The pad is a handful of things worth reaching without thinking, not a
/// second keyboard: window switching, the tmux commands this is driven with, and the input
/// source toggle that unblocks them. Everything else is two taps away in the add menu.
+ (NSArray<NSString *> *)defaultPadLabelsForHost:(KeyMacroHost)host {
    if (host == KeyMacroHostMacOS) {
        return @[
            // Left column: getting to a program or a window, which is what a phone is worst at
            // and needs most — there is no Dock to click and no second monitor to glance at.
            @"⌘Spc", @"⌘Tab", @"⌘`", @"⌃↑", @"⌃↓", @"⌃⌘F", @"⌃←", @"⌃→",
            // Right column: what happens once you are there.
            @"⌃AZ", @"⌃AB", @"⌃A←", @"⌃A→", @"中/A", @"∧", @"∨",
        ];
    }
    return @[@"⊞", @"⎇Tab", @"⊞Tab", @"⊞D", @"⊞E", @"⎇F4", @"⌃C", @"⌃V", @"∧", @"∨"];
}

/// Items are stored by label. Labels are unique within a host's catalogue and survive a
/// rebuild, which a pointer or an index would not.
static NSString *KeyPadDefaultsKey(NSString *profileKey) {
    return [NSString stringWithFormat:@"KeyBar.%@.pad",
            profileKey.length > 0 ? profileKey : @"default"];
}

+ (NSArray<NSString *> *)storedPadLabelsForProfile:(NSString *)profileKey {
    return [[NSUserDefaults standardUserDefaults] stringArrayForKey:KeyPadDefaultsKey(profileKey)];
}

+ (void)storePadLabels:(NSArray<NSString *> *)labels forProfile:(NSString *)profileKey {
    [[NSUserDefaults standardUserDefaults] setObject:labels forKey:KeyPadDefaultsKey(profileKey)];
}

/// Every catalogue item by label, so a stored label resolves back to the real behaviour.
+ (NSDictionary<NSString *, KeyItem *> *)catalogueByLabelForHost:(KeyMacroHost)host {
    NSMutableDictionary<NSString *, KeyItem *> *byLabel = [NSMutableDictionary dictionary];
    // Keyboard keys included: a key from the line can be put on the pad, which is what the old
    // "Add to Mine" did and the reason anyone long-presses one.
    NSMutableArray<KeyGroup *> *sources = [NSMutableArray array];
    [sources addObjectsFromArray:[self keyboardGroupsForHost:host]];
    [sources addObjectsFromArray:[self macroCatalogueForHost:host]];
    for (KeyGroup *group in sources) {
        for (KeyItem *item in group.items) {
            byLabel[item.label] = item;
        }
    }
    return byLabel;
}

+ (NSArray<KeyItem *> *)padItemsForHost:(KeyMacroHost)host profileKey:(NSString *)profileKey {
    NSArray<NSString *> *labels = [self storedPadLabelsForProfile:profileKey]
                                  ?: [self defaultPadLabelsForHost:host];
    NSDictionary<NSString *, KeyItem *> *byLabel = [self catalogueByLabelForHost:host];

    NSMutableArray<KeyItem *> *items = [NSMutableArray array];
    for (NSString *label in labels) {
        if ([label hasPrefix:KeyAppJumpPrefix]) {
            [items addObject:[KeyItem appJump:[label substringFromIndex:KeyAppJumpPrefix.length]]];
            continue;
        }
        // Silently skips anything this host's catalogue does not have, which is what should
        // happen when the host kind is changed under a stored list.
        KeyItem *item = byLabel[label];
        if (item != nil) {
            [items addObject:item];
        }
    }
    return items;
}

/// The stored list, materialised from the default first if the user has never changed it — so
/// adding one key does not silently discard the other eight.
+ (NSMutableArray<NSString *> *)mutablePadLabelsForHost:(KeyMacroHost)host
                                                profile:(NSString *)profileKey {
    NSArray<NSString *> *labels = [self storedPadLabelsForProfile:profileKey]
                                  ?: [self defaultPadLabelsForHost:host];
    return [labels mutableCopy];
}

+ (void)addToPad:(KeyItem *)item forProfile:(NSString *)profileKey host:(KeyMacroHost)host {
    NSMutableArray<NSString *> *labels = [self mutablePadLabelsForHost:host profile:profileKey];
    if ([labels containsObject:item.label]) {
        return;
    }
    [labels addObject:item.label];
    [self storePadLabels:labels forProfile:profileKey];
}

+ (void)removeFromPad:(KeyItem *)item forProfile:(NSString *)profileKey host:(KeyMacroHost)host {
    NSMutableArray<NSString *> *labels = [self mutablePadLabelsForHost:host profile:profileKey];
    [labels removeObject:item.label];
    [self storePadLabels:labels forProfile:profileKey];
}

+ (void)promoteOnPad:(KeyItem *)item forProfile:(NSString *)profileKey host:(KeyMacroHost)host {
    NSMutableArray<NSString *> *labels = [self mutablePadLabelsForHost:host profile:profileKey];
    NSUInteger index = [labels indexOfObject:item.label];
    if (index == NSNotFound || index == 0) {
        return;
    }
    [labels exchangeObjectAtIndex:index withObjectAtIndex:index - 1];
    [self storePadLabels:labels forProfile:profileKey];
}

+ (void)addAppJump:(NSString *)appName forProfile:(NSString *)profileKey host:(KeyMacroHost)host {
    NSString *name = [appName stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        return;
    }
    [self addToPad:[KeyItem appJump:name] forProfile:profileKey host:host];
}

+ (void)resetPadForProfile:(NSString *)profileKey {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:KeyPadDefaultsKey(profileKey)];
}

+ (BOOL)padIsCustomisedForProfile:(NSString *)profileKey {
    return [self storedPadLabelsForProfile:profileKey] != nil;
}

#pragma mark - Which host

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

@end
