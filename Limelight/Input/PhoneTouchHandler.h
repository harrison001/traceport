//
//  PhoneTouchHandler.h
//  Moonlight
//
//  Real touch for a phone host: one finger's whole gesture, recorded here and replayed on the
//  phone as a touch by the gateway, which drives it through WebDriverAgent.
//
//  The other way to drive the phone is its AssistiveTouch pointer, steered by a Bluetooth mouse
//  the gateway pretends to be. That pointer has no position the gateway can set, only movements,
//  so where it ends up is an estimate the gateway keeps correcting — and every "the taps land in
//  the wrong place" so far has been that estimate going wrong. A touch replayed at a fraction of
//  the screen lands where it was put.
//
//  The price is time: the phone acts 0.6–1.3 s after the finger lifts, and a drag is replayed as
//  a whole rather than followed. Two fingers still scroll live, through the stream's scroll path.
//

#import "StreamView.h"
#import "PhoneActionClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface PhoneTouchHandler : UIResponder

- (instancetype)initWithView:(StreamView *)view client:(PhoneActionClient *)client;

/// Each gesture's answer from the gateway, nil when it could not be reached. Main queue.
@property (nonatomic, copy, nullable) void (^onResult)(NSDictionary *_Nullable result);

@end

NS_ASSUME_NONNULL_END
