//
//  AbsoluteTouchHandler.h
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "StreamView.h"

NS_ASSUME_NONNULL_BEGIN

@interface AbsoluteTouchHandler : UIResponder

-(id)initWithView:(StreamView*)view;

/// Phone mode, for a phone driven through the TracePort gateway. A press there is a real tap on
/// the phone, so the press waits a moment to see whether a second finger follows (two fingers
/// scroll and must not tap), and a long press stays a long press instead of becoming a right click.
-(id)initWithView:(StreamView*)view phoneMode:(BOOL)phoneMode;

@end

NS_ASSUME_NONNULL_END
