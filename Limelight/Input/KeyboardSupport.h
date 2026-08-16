//
//  KeyboardSupport.h
//  Moonlight
//
//  Created by Diego Waxemberg on 8/25/18.
//  Copyright © 2018 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface KeyboardSupport : NSObject

struct KeyEvent {
    u_short keycode;
    u_short modifierKeycode;
    u_char modifier;
};

+ (BOOL)sendKeyEventForPress:(UIPress*)press down:(BOOL)down API_AVAILABLE(ios(13.4));
+ (BOOL)sendKeyEvent:(UIKey*)key down:(BOOL)down API_AVAILABLE(ios(13.4));
+ (struct KeyEvent) translateKeyEvent:(unichar) inputChar withModifierFlags:(UIKeyModifierFlags)modifierFlags;

/// Sends a complete chord to the host: every modifier down, the key down and up, then the
/// modifiers up again.
///
/// Needed for shortcuts that arrive as a UIKeyCommand rather than as UIPress events, because
/// no separate press is delivered for the modifier keys in that case. Unlike
/// translateKeyEvent:withModifierFlags:, this composes several modifiers at once, so chords
/// such as Command-Shift-Tab can be expressed at all.
///
/// @param keyCode Win32 virtual key code of the non-modifier key.
/// @param modifierFlags UIKit modifier flags to hold down around it.
+ (void)sendChordWithVirtualKey:(short)keyCode modifierFlags:(UIKeyModifierFlags)modifierFlags;

@end
