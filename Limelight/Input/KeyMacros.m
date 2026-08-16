//
//  KeyMacros.m
//  Moonlight
//

#import "KeyMacros.h"

@implementation KeyMacro

- (instancetype)initWithLabel:(NSString *)label
                         help:(NSString *)help
                   virtualKey:(short)virtualKey
                    modifiers:(UIKeyModifierFlags)modifiers {
    self = [super init];
    if (self != nil) {
        _label = [label copy];
        _help = [help copy];
        _virtualKey = virtualKey;
        _modifiers = modifiers;
    }
    return self;
}

@end

@implementation KeyMacros

+ (KeyMacro *)macro:(NSString *)label
               help:(NSString *)help
                key:(short)virtualKey
          modifiers:(UIKeyModifierFlags)modifiers {
    return [[KeyMacro alloc] initWithLabel:label help:help virtualKey:virtualKey modifiers:modifiers];
}

+ (NSArray<KeyMacro *> *)macrosForHost:(KeyMacroHost)host {
    switch (host) {
        case KeyMacroHostMacOS:
            return [self macOSMacros];
        case KeyMacroHostWindows:
            return [self windowsMacros];
    }
}

/// Taken from TraceRecorder's Quick Input panel, which was arrived at by daily use rather
/// than by listing plausible shortcuts. Letters use their uppercase ASCII value, which is
/// also the Win32 virtual key code.
+ (NSArray<KeyMacro *> *)macOSMacros {
    static NSArray<KeyMacro *> *macros;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        macros = @[
            [self macro:@"⌘A" help:@"Select all" key:0x41 modifiers:UIKeyModifierCommand],
            [self macro:@"⌘C" help:@"Copy" key:0x43 modifiers:UIKeyModifierCommand],
            [self macro:@"⌘X" help:@"Cut" key:0x58 modifiers:UIKeyModifierCommand],
            [self macro:@"⌘V" help:@"Paste" key:0x56 modifiers:UIKeyModifierCommand],
            [self macro:@"⌘Z" help:@"Undo" key:0x5A modifiers:UIKeyModifierCommand],

            [self macro:@"⌘Tab" help:@"Switch to the previous app" key:0x09 modifiers:UIKeyModifierCommand],
            [self macro:@"⇧⌘Tab" help:@"App switcher, backwards" key:0x09
              modifiers:UIKeyModifierCommand | UIKeyModifierShift],
            [self macro:@"⌘`" help:@"Cycle windows of the current app" key:0xC0 modifiers:UIKeyModifierCommand],
            [self macro:@"⌘W" help:@"Close the window" key:0x57 modifiers:UIKeyModifierCommand],
            [self macro:@"⌘Q" help:@"Quit the app" key:0x51 modifiers:UIKeyModifierCommand],
            [self macro:@"⌘H" help:@"Hide the app" key:0x48 modifiers:UIKeyModifierCommand],
            [self macro:@"⌘M" help:@"Minimise the window" key:0x4D modifiers:UIKeyModifierCommand],
            [self macro:@"⌃⌘F" help:@"Toggle full screen" key:0x46
              modifiers:UIKeyModifierCommand | UIKeyModifierControl],

            [self macro:@"⌃←" help:@"Previous desktop or Space" key:0x25 modifiers:UIKeyModifierControl],
            [self macro:@"⌃→" help:@"Next desktop or Space" key:0x27 modifiers:UIKeyModifierControl],
            [self macro:@"⌃↑" help:@"Mission Control" key:0x26 modifiers:UIKeyModifierControl],
            [self macro:@"⌃↓" help:@"App Exposé" key:0x28 modifiers:UIKeyModifierControl],

            [self macro:@"⌘Spc" help:@"Spotlight" key:0x20 modifiers:UIKeyModifierCommand],
            [self macro:@"⇧⌘4" help:@"Screenshot a selection" key:0x34
              modifiers:UIKeyModifierCommand | UIKeyModifierShift],
        ];
    });
    return macros;
}

/// The Windows equivalents of the same jobs. Not yet validated by use, unlike the macOS set —
/// these are the standard shortcuts rather than ones proven in daily work.
+ (NSArray<KeyMacro *> *)windowsMacros {
    static NSArray<KeyMacro *> *macros;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        macros = @[
            [self macro:@"Ctrl+A" help:@"Select all" key:0x41 modifiers:UIKeyModifierControl],
            [self macro:@"Ctrl+C" help:@"Copy" key:0x43 modifiers:UIKeyModifierControl],
            [self macro:@"Ctrl+X" help:@"Cut" key:0x58 modifiers:UIKeyModifierControl],
            [self macro:@"Ctrl+V" help:@"Paste" key:0x56 modifiers:UIKeyModifierControl],
            [self macro:@"Ctrl+Z" help:@"Undo" key:0x5A modifiers:UIKeyModifierControl],

            [self macro:@"Alt+Tab" help:@"Switch to the previous app" key:0x09 modifiers:UIKeyModifierAlternate],
            [self macro:@"Alt+F4" help:@"Close the window" key:0x73 modifiers:UIKeyModifierAlternate],
            [self macro:@"Win+D" help:@"Show the desktop" key:0x44 modifiers:UIKeyModifierCommand],
            [self macro:@"Win+E" help:@"Open File Explorer" key:0x45 modifiers:UIKeyModifierCommand],
            [self macro:@"Win+L" help:@"Lock the machine" key:0x4C modifiers:UIKeyModifierCommand],

            [self macro:@"Win" help:@"Start menu" key:0x5B modifiers:0],
            [self macro:@"Win+G" help:@"Game bar, for screenshots" key:0x47 modifiers:UIKeyModifierCommand],
            [self macro:@"Win+⇧S" help:@"Screenshot a selection" key:0x53
              modifiers:UIKeyModifierCommand | UIKeyModifierShift],

            [self macro:@"Ctrl+⇧Esc" help:@"Task Manager" key:0x1B
              modifiers:UIKeyModifierControl | UIKeyModifierShift],
        ];
    });
    return macros;
}

+ (KeyMacroHost)defaultHost {
    return KeyMacroHostMacOS;
}

@end
