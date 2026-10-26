//
//  PhoneActionClient.h
//  Moonlight
//
//  Asks the gateway driving a phone to do one of the phone's own actions — Home, the app
//  switcher, Back — and hears back whether it actually happened.
//
//  These used to go as F13–F23 key presses through the stream's keyboard channel and the
//  gateway's virtual display, and nothing came back: a key the phone dropped looked exactly like
//  one that worked. The gateway now checks each action took effect, retries or tries another way
//  when it did not, and says which. The keys remain the fallback for a gateway without this.
//
//  Same trust as the caret: the host's pinned certificate, the paired client identity. The
//  gateway serves it on the host's TLS port plus 200.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PhoneActionClient : NSObject

- (instancetype)initWithHost:(NSString *)host
                   httpsPort:(unsigned short)httpsPort
                  serverCert:(nullable NSData *)serverCert;

/// Performs an action by name (home, apps, cc, notif, search, lock, shot, kill, back, swipeleft,
/// swiperight). Called back on the main queue: `result` is the gateway's answer — "ok", "label",
/// "error" — or nil when the gateway could not be reached at all, in which case the caller falls
/// back to the key.
- (void)perform:(NSString *)action completion:(void (^)(NSDictionary *_Nullable result))completion;

/// Replays one finger's gesture on the phone as a real touch. `points` are [x, y, ms]: x and y
/// as fractions of the picture, ms since the finger went down. The gateway decides whether it was
/// a tap, a long press, a swipe or one of the system's edge gestures. Main queue; nil when the
/// gateway could not be reached.
- (void)touch:(NSArray<NSArray<NSNumber *> *> *)points completion:(void (^)(NSDictionary *_Nullable result))completion;

/// What the gateway can do right now: "wda" (whether the swipe-only actions will work) and
/// "wda_only" (which those are), "touch" (whether it takes real touches at all). nil when
/// unreachable. Main queue.
- (void)fetchStatus:(void (^)(NSDictionary *_Nullable status))completion;

/// Must be called when done: the session holds this object until then.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
