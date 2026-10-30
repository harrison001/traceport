//
//  PhoneActionClient.m
//  Moonlight
//

#import "PhoneActionClient.h"
#import "CaretTracker.h"
#import "Utils.h"
#include <Limelight.h>
#import <UserNotifications/UserNotifications.h>
#import <PushKit/PushKit.h>
#import <CallKit/CallKit.h>

/// The gateway's action port sits this far above the host's TLS port, one per Sunshine instance.
static const unsigned short actionPortOffset = 200;

static NSString *const pushTokenKey = @"TracePortPushToken";
static NSString *const pushTokenNotification = @"TracePortPushTokenArrived";
static NSString *const voipTokenKey = @"TracePortVoipToken";
static NSString *const gatewaysKey = @"TracePortGateways";
/// Posted (object: host uuid) when an answered call wants that phone's stream opened.
NSString *const TracePortOpenHostNotification = @"TracePortOpenHost";
NSString *TracePortPendingCallHost = nil;

@interface PhoneActionClient () <NSURLSessionDelegate>
@end

@implementation PhoneActionClient {
    NSString *_base;
    NSData *_serverCert;
    NSURLSession *_session;
}

- (instancetype)initWithHost:(NSString *)host
                   httpsPort:(unsigned short)httpsPort
                  serverCert:(nullable NSData *)serverCert {
    NSString *address = [Utils addressPortStringToAddress:host];
    // An IPv6 literal has to be bracketed in a URL, and Tailscale hands these out.
    if ([address containsString:@":"] && ![address hasPrefix:@"["]) {
        address = [NSString stringWithFormat:@"[%@]", address];
    }
    return [self initWithBase:[NSString stringWithFormat:@"https://%@:%u", address, (unsigned)(httpsPort + actionPortOffset)]
                   serverCert:serverCert];
}

- (instancetype)initWithBase:(NSString *)base serverCert:(nullable NSData *)serverCert {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _base = [base copy];
    _serverCert = [serverCert copy];

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // An action is done, checked and possibly retried on the gateway before it answers: a dropped
    // key that has to be pressed again takes three or four seconds, a swipe that falls back to
    // another way longer still.
    configuration.timeoutIntervalForRequest = 15.0;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(registerPush)
                                                 name:pushTokenNotification object:nil];
    return self;
}

+ (void)requestPushPermission {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                          completionHandler:^(BOOL granted, NSError *error) {
        if (!granted) {
            Log(LOG_I, @"Push: not allowed (%@)", error.localizedDescription ?: @"declined");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] registerForRemoteNotifications];
        });
    }];
}

+ (NSString *)hex:(NSData *)token {
    NSMutableString *hex = [NSMutableString stringWithCapacity:token.length * 2];
    const unsigned char *bytes = token.bytes;
    for (NSUInteger i = 0; i < token.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

+ (void)setPushToken:(NSData *)token {
    [[NSUserDefaults standardUserDefaults] setObject:[self hex:token] forKey:pushTokenKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:pushTokenNotification object:nil];
}

+ (void)setVoipToken:(NSData *)token {
    NSString *hex = [self hex:token];
    if ([hex isEqualToString:[[NSUserDefaults standardUserDefaults] stringForKey:voipTokenKey]]) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:hex forKey:voipTokenKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:pushTokenNotification object:nil];
    // gateways from earlier streams learn it now, not at the next stream
    [[self knownGateways] enumerateKeysAndObjectsUsingBlock:^(NSString *base, NSDictionary *g, BOOL *stop) {
        PhoneActionClient *c = [[PhoneActionClient alloc] initWithBase:base serverCert:g[@"cert"]];
        [c registerPush];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [c invalidate];
        });
    }];
}

+ (NSDictionary<NSString *, NSDictionary *> *)knownGateways {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:gatewaysKey];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

/// Remember this gateway for calls between streams.
- (void)remember {
    if (_serverCert == nil) {
        return;
    }
    NSMutableDictionary *all = [[PhoneActionClient knownGateways] mutableCopy];
    NSMutableDictionary *g = [@{@"cert": _serverCert} mutableCopy];
    NSString *uuid = self.hostUuid ?: all[_base][@"uuid"];
    if (uuid != nil) {
        g[@"uuid"] = uuid;
    }
    all[_base] = g;
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:gatewaysKey];
}

/// Which of Apple's push services this build's token belongs to: development-signed builds carry a
/// provisioning profile that says so; App Store builds have none and use production.
+ (NSString *)pushEnvironment {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (data == nil) {
        return @"production";
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSRange key = [text rangeOfString:@"<key>aps-environment</key>"];
    if (key.location == NSNotFound) {
        return @"development";
    }
    NSString *rest = [text substringFromIndex:NSMaxRange(key)];
    return [rest rangeOfString:@"production"].location < [rest rangeOfString:@"</string>"].location ? @"production" : @"development";
}

- (void)registerPush {
    if (_session == nil) {
        return;
    }
    [self remember];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *kinds = @[@[pushTokenKey, @"alert"], @[voipTokenKey, @"voip"]];
    for (NSArray *k in kinds) {
        NSString *token = [d stringForKey:k[0]];
        if (token == nil) {
            continue;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                        [NSURL URLWithString:[_base stringByAppendingString:@"/phone/push"]]];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSDictionary *body = @{@"token": token,
                               @"kind": k[1],
                               @"env": [PhoneActionClient pushEnvironment],
                               @"name": UIDevice.currentDevice.name ?: @""};
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [self send:request completion:^(NSDictionary *result) {
            if (result != nil) {
                Log(LOG_I, @"Push: %@ token registered with the gateway (ready %@)", k[1], result[@"push_ready"]);
            }
        }];
    }
}

- (void)fetchCall:(void (^)(NSDictionary *_Nullable))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:[_base stringByAppendingString:@"/phone/call"]]];
    request.timeoutInterval = 3.0;
    [self send:request completion:completion];
}

- (void)callAction:(NSString *)action callId:(NSString *)callId completion:(void (^)(NSDictionary *_Nullable))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:[_base stringByAppendingString:@"/phone/call"]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 8.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"action": action, @"id": callId} options:0 error:nil];
    [self send:request completion:completion];
}

- (void)invalidate {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_session invalidateAndCancel];
    _session = nil;
}

- (void)perform:(NSString *)action completion:(void (^)(NSDictionary *_Nullable))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:[_base stringByAppendingString:@"/phone/action"]]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"name": action} options:0 error:nil];
    [self send:request completion:completion];
}

- (void)touch:(NSArray<NSArray<NSNumber *> *> *)points completion:(void (^)(NSDictionary *_Nullable))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:[_base stringByAppendingString:@"/phone/touch"]]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"points": points} options:0 error:nil];
    [self send:request completion:completion];
}

- (void)fetchStatus:(void (^)(NSDictionary *_Nullable))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:[_base stringByAppendingString:@"/phone/status"]]];
    // A status that takes longer than this is no use for deciding what to grey out
    request.timeoutInterval = 4.0;
    [self send:request completion:completion];
}

- (void)send:(NSURLRequest *)request completion:(void (^)(NSDictionary *_Nullable))completion {
    if (_session == nil || _serverCert == nil || request.URL == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    [[_session dataTaskWithRequest:request
                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *result = nil;
        if (error == nil && data != nil) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            result = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
        } else if (error != nil) {
            Log(LOG_W, @"Phone action: %@ %@", request.URL.path, error.localizedDescription);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    }] resume];
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *_Nullable))completionHandler {
    [CaretTracker answerChallenge:challenge serverCert:_serverCert completionHandler:completionHandler];
}

@end

#pragma mark - Calls

@interface PhoneCallCenter () <PKPushRegistryDelegate, CXProviderDelegate>
@end

@implementation PhoneCallCenter {
    PKPushRegistry *_registry;
    CXProvider *_provider;
    /// uuid → {gateway: base or NSNull, answered: BOOL, ringing: BOOL}
    NSMutableDictionary<NSUUID *, NSMutableDictionary *> *_calls;
    NSDate *_handedOff;
}

+ (instancetype)shared {
    static PhoneCallCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [[PhoneCallCenter alloc] init]; });
    return center;
}

- (void)start {
    if (_provider != nil) {
        return;
    }
    _calls = [NSMutableDictionary dictionary];
    CXProviderConfiguration *config = [[CXProviderConfiguration alloc] init];
    config.supportsVideo = NO;
    config.maximumCallGroups = 1;
    config.maximumCallsPerCallGroup = 1;
    config.supportedHandleTypes = [NSSet setWithObjects:@(CXHandleTypePhoneNumber), @(CXHandleTypeGeneric), nil];
    // these are the phone at home's calls, not this device's: keep them out of its Recents
    config.includesCallsInRecents = NO;
    _provider = [[CXProvider alloc] initWithConfiguration:config];
    [_provider setDelegate:self queue:dispatch_get_main_queue()];

    // an answered call waiting in the background is handed to the stream when TracePort comes to the front
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handOffAnsweredCalls)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];

    _registry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    _registry.delegate = self;
    _registry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
}

#pragma mark PushKit

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(PKPushType)type {
    Log(LOG_I, @"Calls: VoIP token ready");
    [PhoneActionClient setVoipToken:credentials.token];
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
             forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion {
    id call = payload.dictionaryPayload[@"call"];
    Log(LOG_I, @"Calls: push %@", call);
    [self event:[call isKindOfClass:[NSDictionary class]] ? call : @{} gateway:nil fromPush:YES completion:completion];
}

#pragma mark Events

- (CXHandle *)handleFor:(NSDictionary *)call {
    NSString *number = [call[@"number"] isKindOfClass:[NSString class]] ? call[@"number"] : @"";
    return number.length > 0 ? [[CXHandle alloc] initWithType:CXHandleTypePhoneNumber value:number]
                             : [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:@"Unknown"];
}

/// One ring or end, from a push or from the stream's polling. A push must end in a reported call
/// (iOS stops delivering VoIP pushes to an app that does not), so a push that changes nothing still
/// reports one — the same UUID again is refused harmlessly, a new one is ended at once.
- (void)event:(NSDictionary *)call gateway:(nullable NSString *)base fromPush:(BOOL)fromPush completion:(void (^)(void))completion {
    NSString *type = [call[@"type"] isKindOfClass:[NSString class]] ? call[@"type"] : @"";
    NSUUID *uuid = [call[@"id"] isKindOfClass:[NSString class]] ? [[NSUUID alloc] initWithUUIDString:call[@"id"]] : nil;
    NSMutableDictionary *known = uuid ? _calls[uuid] : nil;

    if ([type isEqualToString:@"ring"] && uuid != nil && known == nil) {
        NSString *name = [call[@"name"] isKindOfClass:[NSString class]] ? call[@"name"] : @"";
        NSString *number = [call[@"number"] isKindOfClass:[NSString class]] ? call[@"number"] : @"";
        CXCallUpdate *update = [[CXCallUpdate alloc] init];
        update.remoteHandle = [self handleFor:call];
        // who and through what: "Alice · WeChat" for a WeChat invite, "+1 555… · home phone" for a call
        NSString *source = [call[@"source"] isKindOfClass:[NSString class]] ? call[@"source"] : @"";
        NSString *via = [source isEqualToString:@"wechat"] ? @"WeChat" : @"home phone";
        update.localizedCallerName = [NSString stringWithFormat:@"%@ · %@",
                                      name.length > 0 ? name : (number.length > 0 ? number : @"Unknown"), via];
        update.hasVideo = NO;
        update.supportsHolding = NO;
        update.supportsGrouping = NO;
        update.supportsUngrouping = NO;
        update.supportsDTMF = NO;
        _calls[uuid] = [@{@"gateway": base ?: (id)[NSNull null], @"answered": @NO, @"ringing": @YES} mutableCopy];
        [_provider reportNewIncomingCallWithUUID:uuid update:update completion:^(NSError *error) {
            if (error != nil) {
                Log(LOG_W, @"Calls: could not ring (%@)", error.localizedDescription);
                [self->_calls removeObjectForKey:uuid];
                // A Focus on this device keeps CallKit from ringing (2026-10-30: error 3, the call
                // went unnoticed). Leave a time-sensitive notice instead; the user decides in the
                // Focus settings whether it may break through.
                if ([error.domain isEqualToString:CXErrorDomainIncomingCall] &&
                    error.code == CXErrorCodeIncomingCallErrorFilteredByDoNotDisturb) {
                    [self postSilencedNotice:call gateway:base];
                }
            }
            completion();
        }];
        return;
    }

    if ([type isEqualToString:@"end"] && uuid != nil) {
        // a notice left for a call that a Focus silenced goes once the call is over
        [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[uuid.UUIDString]];
    }

    if ([type isEqualToString:@"end"] && known != nil) {
        NSString *why = [call[@"why"] isKindOfClass:[NSString class]] ? call[@"why"] : @"ended";
        // finish with the push while the call still exists (that satisfies PushKit), then end it
        completion();
        if ([why isEqualToString:@"answered"] && [known[@"answered"] boolValue]) {
            // the phone picked up because we asked: the call goes on
            known[@"ringing"] = @NO;
            return;
        }
        CXCallEndedReason reason = [why isEqualToString:@"missed"] ? CXCallEndedReasonUnanswered
                                 : [why isEqualToString:@"answered"] ? CXCallEndedReasonAnsweredElsewhere
                                 : CXCallEndedReasonRemoteEnded;
        [_provider reportCallWithUUID:uuid endedAtDate:nil reason:reason];
        [_calls removeObjectForKey:uuid];
        return;
    }
    if (known != nil) {
        // a repeated ring for a call already showing
        completion();
        return;
    }

    if (!fromPush) {
        completion();
        return;
    }
    NSUUID *placeholder = uuid ?: [NSUUID UUID];
    CXCallUpdate *update = [[CXCallUpdate alloc] init];
    update.remoteHandle = [self handleFor:call];
    [_provider reportNewIncomingCallWithUUID:placeholder update:update completion:^(NSError *error) {
        if (error == nil) {
            [self->_provider reportCallWithUUID:placeholder endedAtDate:nil reason:CXCallEndedReasonRemoteEnded];
        }
        completion();
    }];
}

/// The notice shown instead of the ring when a Focus silenced the call. Tapping it opens the
/// phone's stream, where the call is still ringing (and rings here too once TracePort is in front).
- (void)postSilencedNotice:(NSDictionary *)call gateway:(nullable NSString *)base {
    NSString *name = [call[@"name"] isKindOfClass:[NSString class]] ? call[@"name"] : @"";
    NSString *number = [call[@"number"] isKindOfClass:[NSString class]] ? call[@"number"] : @"";
    NSString *who = name.length > 0 ? name : (number.length > 0 ? number : @"Someone");
    BOOL wechat = [call[@"source"] isEqual:@"wechat"];

    NSDictionary<NSString *, NSDictionary *> *gateways = [PhoneActionClient knownGateways];
    NSString *host = base != nil ? gateways[base][@"uuid"] : nil;
    for (NSDictionary *g in gateways.allValues) {
        if (host == nil && [g[@"uuid"] isKindOfClass:[NSString class]]) {
            host = g[@"uuid"];
        }
    }

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = wechat ? @"WeChat call · home phone" : @"Incoming call · home phone";
    content.body = [NSString stringWithFormat:@"%@ is calling. Focus silenced the ring — tap to open the phone and answer.", who];
    content.sound = [UNNotificationSound defaultSound];
    content.threadIdentifier = @"traceport-calls";
    if (host != nil) {
        content.userInfo = @{@"openHost": host};
    }
    if (@available(iOS 15.0, *)) {
        content.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;
    }
    NSString *ident = [call[@"id"] isKindOfClass:[NSString class]] ? call[@"id"] : [NSUUID UUID].UUIDString;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:ident content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        Log(error ? LOG_W : LOG_I, @"Calls: Focus silenced the ring; notice %@", error ? error.localizedDescription : @"posted");
    }];
}

- (void)streamSawCalls:(NSDictionary *)state gateway:(NSString *)base {
    NSArray *calls = [state[@"calls"] isKindOfClass:[NSArray class]] ? state[@"calls"] : @[];
    NSMutableSet<NSUUID *> *present = [NSMutableSet set];
    for (id c in calls) {
        if (![c isKindOfClass:[NSDictionary class]] || ![c[@"id"] isKindOfClass:[NSString class]]) {
            continue;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:c[@"id"]];
        if (uuid == nil) {
            continue;
        }
        [present addObject:uuid];
        NSString *st = [c[@"state"] isKindOfClass:[NSString class]] ? c[@"state"] : @"";
        BOOL ringing = [st isEqualToString:@"incoming"] || [st isEqualToString:@"waiting"];
        NSMutableDictionary *known = _calls[uuid];
        if (ringing && known == nil) {
            NSMutableDictionary *ev = [c mutableCopy];
            ev[@"type"] = @"ring";
            [self event:ev gateway:base fromPush:NO completion:^{}];
        } else if (!ringing && known != nil && [known[@"ringing"] boolValue]) {
            [self event:@{@"type": @"end", @"id": c[@"id"], @"why": @"answered"} gateway:base fromPush:NO completion:^{}];
        }
    }
    for (NSUUID *uuid in _calls.allKeys) {
        if (![present containsObject:uuid]) {
            NSString *why = [_calls[uuid][@"ringing"] boolValue] ? @"missed" : @"ended";
            [self event:@{@"type": @"end", @"id": uuid.UUIDString, @"why": why} gateway:base fromPush:NO completion:^{}];
        }
    }
}

/// Ask the call's gateway (or each remembered one) to answer or hang up.
- (void)control:(NSString *)action uuid:(NSUUID *)uuid done:(void (^)(BOOL ok, NSString *_Nullable hostUuid))done {
    id gw = _calls[uuid][@"gateway"];
    NSArray<NSString *> *bases = [gw isKindOfClass:[NSString class]] ? @[gw] : [PhoneActionClient knownGateways].allKeys;
    [self control:action uuid:uuid bases:bases index:0 done:done];
}

- (void)control:(NSString *)action uuid:(NSUUID *)uuid bases:(NSArray<NSString *> *)bases index:(NSUInteger)i
           done:(void (^)(BOOL ok, NSString *_Nullable hostUuid))done {
    if (i >= bases.count) {
        done(NO, nil);
        return;
    }
    NSDictionary *g = [PhoneActionClient knownGateways][bases[i]];
    PhoneActionClient *c = [[PhoneActionClient alloc] initWithBase:bases[i] serverCert:g[@"cert"]];
    [c callAction:action callId:uuid.UUIDString completion:^(NSDictionary *result) {
        [c invalidate];
        if ([result[@"ok"] boolValue]) {
            Log(LOG_I, @"Calls: %@ → %@", action, result[@"done"]);
            done(YES, g[@"uuid"]);
        } else {
            Log(LOG_W, @"Calls: %@ at %@ failed: %@", action, bases[i], result[@"error"] ?: @"unreachable");
            [self control:action uuid:uuid bases:bases index:i + 1 done:done];
        }
    }];
}

- (BOOL)handOffAnsweredCalls {
    BOOL any = NO;
    for (NSUUID *uuid in _calls.allKeys) {
        if ([_calls[uuid][@"answered"] boolValue]) {
            Log(LOG_I, @"Calls: handing %@ to the stream", uuid.UUIDString);
            [_provider reportCallWithUUID:uuid endedAtDate:nil reason:CXCallEndedReasonAnsweredElsewhere];
            [_calls removeObjectForKey:uuid];
            any = YES;
        }
    }
    if (any) {
        _handedOff = [NSDate date];
    }
    return any;
}

- (NSTimeInterval)secondsSinceHandOff {
    return _handedOff ? -[_handedOff timeIntervalSinceNow] : 1e9;
}

#pragma mark CXProviderDelegate

- (void)providerDidReset:(CXProvider *)provider {
    [_calls removeAllObjects];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
    NSMutableDictionary *call = _calls[action.callUUID];
    call[@"answered"] = @YES;
    [self control:@"answer" uuid:action.callUUID done:^(BOOL ok, NSString *hostUuid) {
        if (!ok) {
            [action fail];
            [self->_calls removeObjectForKey:action.callUUID];
            return;
        }
        [action fulfill];
        // the call's sound comes through the phone's stream: open it. In front, the system call
        // steps aside right away; in the background or locked it stays (the green call indicator
        // leads back to TracePort) until TracePort comes to the front.
        if (hostUuid != nil) {
            TracePortPendingCallHost = hostUuid;
        }
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            [self handOffAnsweredCalls];
        }
        if (hostUuid != nil) {
            [[NSNotificationCenter defaultCenter] postNotificationName:TracePortOpenHostNotification object:hostUuid];
        }
    }];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    BOOL tracked = _calls[action.callUUID] != nil;
    [action fulfill];
    if (!tracked) {
        return;
    }
    [self control:@"hangup" uuid:action.callUUID done:^(BOOL ok, NSString *hostUuid) {}];
    [_calls removeObjectForKey:action.callUUID];
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
    Log(LOG_I, @"Calls: audio session released");
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
    // the stream plays the call's sound and TPMicUplink records the reply in this same session
}

@end
