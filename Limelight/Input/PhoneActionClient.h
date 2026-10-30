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

/// Posted (object: host uuid) when an answered call wants that phone's stream opened.
extern NSString *const TracePortOpenHostNotification;

/// The host whose stream an answered call is waiting for (nil when none): the host list opens it
/// as soon as it can — at once, or when the app comes to the front.
extern NSString *_Nullable TracePortPendingCallHost;

@interface PhoneActionClient : NSObject

- (instancetype)initWithHost:(NSString *)host
                   httpsPort:(unsigned short)httpsPort
                  serverCert:(nullable NSData *)serverCert;

/// A client for a gateway remembered earlier (`base` is its action port URL).
- (instancetype)initWithBase:(NSString *)base serverCert:(nullable NSData *)serverCert;

/// The action port URL, e.g. https://100.95.22.106:47184.
@property (nonatomic, readonly) NSString *base;

/// The host this gateway streams (set by the stream view): an answered call opens it.
@property (nonatomic, copy, nullable) NSString *hostUuid;

/// The phone's calls: {state: "idle" | "ringing" | "active", calls: [{id, state, number, name}]}.
/// nil when unreachable. Main queue.
- (void)fetchCall:(void (^)(NSDictionary *_Nullable call))completion;

/// Answers ("answer") or hangs up ("hangup") the phone's call `callId`. Main queue; nil when
/// unreachable, else {ok, error?}.
- (void)callAction:(NSString *)action callId:(NSString *)callId completion:(void (^)(NSDictionary *_Nullable result))completion;

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

/// Push notifications from the gateway ("needs you" alerts, sent through Apple's push service).
/// Asks for permission once and registers with iOS; the token arrives in the app delegate.
+ (void)requestPushPermission;

/// The app delegate hands over the device token here; every live client then registers it.
+ (void)setPushToken:(NSData *)token;

/// The same for the PushKit (VoIP) token that rings calls; also registered with every gateway
/// remembered from earlier streams, so calls ring before the next stream.
+ (void)setVoipToken:(NSData *)token;

/// Gateways remembered from streams: base → {cert, uuid}.
+ (NSDictionary<NSString *, NSDictionary *> *)knownGateways;

/// Tells this gateway where to push (POST /phone/push), if iOS has given a token yet. Also done
/// automatically when a token arrives later.
- (void)registerPush;

/// Must be called when done: the session holds this object until then.
- (void)invalidate;

@end

/// Calls on the driven phone ring here like any phone call (2026-10-29): the gateway sends a VoIP
/// push when one starts ringing (and while streaming, the stream view's polling finds it too); this
/// shows the system's incoming-call screen through CallKit. Answer → the gateway answers on the
/// phone and TracePort opens that phone's stream (the call's sound goes through the stream as
/// always). Decline or end → the gateway hangs up.
@interface PhoneCallCenter : NSObject

+ (instancetype)shared;

/// At launch: PushKit has to be registered before the app finishes launching, or a push that
/// woke it is lost.
- (void)start;

/// The stream view's latest /phone/call answer from the gateway at `base`.
- (void)streamSawCalls:(NSDictionary *)call gateway:(NSString *)base;

/// Ends the system calls of answered calls: their sound goes through the phone's stream, and the
/// stream cannot start its audio while a CallKit call holds the audio session ("Session activation
/// failed", 2026-10-29). Done when TracePort is in front. Returns whether any was ended.
- (BOOL)handOffAnsweredCalls;

/// Seconds since the last hand-off (a large number if never): the stream waits for the audio
/// session to be released before it starts.
- (NSTimeInterval)secondsSinceHandOff;

@end

NS_ASSUME_NONNULL_END
