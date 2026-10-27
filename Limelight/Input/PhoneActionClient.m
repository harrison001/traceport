//
//  PhoneActionClient.m
//  Moonlight
//

#import "PhoneActionClient.h"
#import "CaretTracker.h"
#import "Utils.h"
#include <Limelight.h>
#import <UserNotifications/UserNotifications.h>

/// The gateway's action port sits this far above the host's TLS port, one per Sunshine instance.
static const unsigned short actionPortOffset = 200;

static NSString *const pushTokenKey = @"TracePortPushToken";
static NSString *const pushTokenNotification = @"TracePortPushTokenArrived";

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
    self = [super init];
    if (self == nil) {
        return nil;
    }

    NSString *address = [Utils addressPortStringToAddress:host];
    // An IPv6 literal has to be bracketed in a URL, and Tailscale hands these out.
    if ([address containsString:@":"] && ![address hasPrefix:@"["]) {
        address = [NSString stringWithFormat:@"[%@]", address];
    }
    _base = [NSString stringWithFormat:@"https://%@:%u", address, (unsigned)(httpsPort + actionPortOffset)];
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

+ (void)setPushToken:(NSData *)token {
    NSMutableString *hex = [NSMutableString stringWithCapacity:token.length * 2];
    const unsigned char *bytes = token.bytes;
    for (NSUInteger i = 0; i < token.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:hex forKey:pushTokenKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:pushTokenNotification object:nil];
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
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:pushTokenKey];
    if (token == nil || _session == nil) {
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:[_base stringByAppendingString:@"/phone/push"]]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"token": token,
                           @"env": [PhoneActionClient pushEnvironment],
                           @"name": UIDevice.currentDevice.name ?: @""};
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [self send:request completion:^(NSDictionary *result) {
        if (result != nil) {
            Log(LOG_I, @"Push: registered with the gateway (ready %@)", result[@"push_ready"]);
        }
    }];
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
