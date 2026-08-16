//
//  KeyMacros.m
//  Moonlight
//

#import "KeyMacros.h"

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

@implementation KeyPage

+ (instancetype)pageNamed:(NSString *)name groups:(NSArray<KeyGroup *> *)groups {
    KeyPage *page = [[KeyPage alloc] init];
    if (page != nil) {
        page->_name = [name copy];
        page->_groups = [groups copy];
    }
    return page;
}

@end

@implementation KeyMacros

/// Always leftmost, on every page, so their position never moves.
+ (KeyGroup *)modifiersForHost:(KeyMacroHost)host {
    BOOL mac = host == KeyMacroHostMacOS;
    return [KeyGroup groupWithItems:@[
        [KeyItem modifier:@"⇧" code:0xA0 flag:UIKeyModifierShift],
        [KeyItem modifier:@"⌃" code:0xA2 flag:UIKeyModifierControl],
        [KeyItem modifier:mac ? @"⌥" : @"alt" code:0xA4 flag:UIKeyModifierAlternate],
        [KeyItem modifier:mac ? @"⌘" : @"⊞" code:0x5B flag:UIKeyModifierCommand],
    ]];
}

/// Repeated on most pages: these are used constantly and should never need a page change.
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

+ (NSArray<KeyPage *> *)pagesForHost:(KeyMacroHost)host {
    return host == KeyMacroHostMacOS ? [self macOSPages] : [self windowsPages];
}

/// The macOS action set is not designed here: it is what TraceRecorder's Quick Input panel
/// ended up with after daily use, help text and all, relabelled from chords to what they do.
+ (NSArray<KeyPage *> *)macOSPages {
    static NSArray<KeyPage *> *pages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        KeyGroup *modifiers = [self modifiersForHost:KeyMacroHostMacOS];
        KeyGroup *clipboard = [self clipboardForHost:KeyMacroHostMacOS];

        pages = @[
            [KeyPage pageNamed:@"Keys" groups:@[
                modifiers,
                clipboard,
                [KeyGroup groupWithItems:@[
                    [KeyItem key:@"esc" code:0x1B],
                    [KeyItem key:@"tab" code:0x09],
                    [KeyItem key:@"↵" code:0x0D],
                    [KeyItem key:@"⌦" code:0x2E],
                ]],
                [self arrows],
            ]],

            [KeyPage pageNamed:@"Apps" groups:@[
                modifiers,
                clipboard,
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
            ]],

            [KeyPage pageNamed:@"Desktop" groups:@[
                modifiers,
                [KeyGroup groupWithItems:@[
                    [KeyItem macro:@"Mission Control" code:0x26 flags:UIKeyModifierControl],
                    [KeyItem macro:@"App Exposé" code:0x28 flags:UIKeyModifierControl],
                    [KeyItem macro:@"Desktop ←" code:0x25 flags:UIKeyModifierControl],
                    [KeyItem macro:@"Desktop →" code:0x27 flags:UIKeyModifierControl],
                ]],
                [KeyGroup groupWithItems:@[
                    [KeyItem macro:@"Spotlight" code:0x20 flags:UIKeyModifierCommand],
                    [KeyItem macro:@"Screenshot" code:0x34
                              flags:UIKeyModifierCommand | UIKeyModifierShift],
                ]],
            ]],

            [KeyPage pageNamed:@"Nav" groups:@[
                modifiers,
                [self arrows],
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
            ]],

            [KeyPage pageNamed:@"Fn" groups:@[
                modifiers,
                [self functionKeys],
            ]],
        ];
    });
    return pages;
}

/// The Windows equivalents. Standard shortcuts rather than ones proven in use, which is a
/// weaker basis than the macOS set and worth saying so.
+ (NSArray<KeyPage *> *)windowsPages {
    static NSArray<KeyPage *> *pages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        KeyGroup *modifiers = [self modifiersForHost:KeyMacroHostWindows];
        KeyGroup *clipboard = [self clipboardForHost:KeyMacroHostWindows];

        pages = @[
            [KeyPage pageNamed:@"Keys" groups:@[
                modifiers,
                clipboard,
                [KeyGroup groupWithItems:@[
                    [KeyItem key:@"esc" code:0x1B],
                    [KeyItem key:@"tab" code:0x09],
                    [KeyItem key:@"↵" code:0x0D],
                    [KeyItem key:@"⌦" code:0x2E],
                ]],
                [self arrows],
            ]],

            [KeyPage pageNamed:@"Apps" groups:@[
                modifiers,
                clipboard,
                [KeyGroup groupWithItems:@[
                    [KeyItem macro:@"Switch App" code:0x09 flags:UIKeyModifierAlternate],
                    [KeyItem macro:@"Close" code:0x73 flags:UIKeyModifierAlternate],
                    [KeyItem macro:@"Desktop" code:0x44 flags:UIKeyModifierCommand],
                    [KeyItem macro:@"Explorer" code:0x45 flags:UIKeyModifierCommand],
                    [KeyItem macro:@"Lock" code:0x4C flags:UIKeyModifierCommand],
                    [KeyItem macro:@"Start" code:0x5B flags:0],
                ]],
            ]],

            [KeyPage pageNamed:@"Desktop" groups:@[
                modifiers,
                [KeyGroup groupWithItems:@[
                    [KeyItem macro:@"Task Manager" code:0x1B
                              flags:UIKeyModifierControl | UIKeyModifierShift],
                    [KeyItem macro:@"Game Bar" code:0x47 flags:UIKeyModifierCommand],
                    [KeyItem macro:@"Screenshot" code:0x53
                              flags:UIKeyModifierCommand | UIKeyModifierShift],
                ]],
            ]],

            [KeyPage pageNamed:@"Nav" groups:@[
                modifiers,
                [self arrows],
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
            ]],

            [KeyPage pageNamed:@"Fn" groups:@[
                modifiers,
                [self functionKeys],
            ]],
        ];
    });
    return pages;
}

+ (KeyMacroHost)defaultHost {
    return KeyMacroHostMacOS;
}

@end
