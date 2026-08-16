//
//  CaretTracker.m
//  Moonlight
//

#import "CaretTracker.h"
#import "CryptoManager.h"
#import "Utils.h"
#include <Limelight.h>

/// Often enough that the picture keeps up with a moving caret, rarely enough that the request
/// costs nothing next to the video stream sharing the same link.
static const NSTimeInterval pollInterval = 0.15;

@interface CaretTracker () <NSURLSessionDelegate>
@end

@implementation CaretTracker {
    NSString *_host;
    unsigned short _httpsPort;
    NSData *_serverCert;
    NSURLSession *_session;
    NSTimer *_timer;
    BOOL _inFlight;
    BOOL _loggedURL;
}

- (instancetype)initWithHost:(NSString *)host
                   httpsPort:(unsigned short)httpsPort
                  serverCert:(nullable NSData *)serverCert {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _host = [host copy];
    _httpsPort = httpsPort;
    _serverCert = [serverCert copy];

    return self;
}

- (void)start {
    if (_timer != nil || _host.length == 0) {
        return;
    }
    // Without the host's certificate there is nothing to pin the connection against, and an
    // unverified answer about where the user is typing is not worth having.
    if (_serverCert == nil) {
        Log(LOG_W, @"Caret tracking: no server certificate for this host, not polling");
        return;
    }

    // A session holds its delegate — this object — until it is invalidated, so it is built when
    // polling starts and torn down when polling stops rather than living as long as the tracker.
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // Anything slower than the poll interval is already stale; failing fast keeps the queue at
    // one request rather than letting them pile up behind a host that has stopped answering.
    configuration.timeoutIntervalForRequest = 1.0;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];

    _timer = [NSTimer scheduledTimerWithTimeInterval:pollInterval
                                              target:self
                                            selector:@selector(poll)
                                            userInfo:nil
                                             repeats:YES];
    [self poll];
}

- (void)stop {
    [_timer invalidate];
    _timer = nil;

    // Releases the session's reference to this object; without it nothing here is ever freed.
    [_session invalidateAndCancel];
    _session = nil;
}

- (void)dealloc {
    [self stop];
}

- (void)poll {
    if (_inFlight) {
        return;  // the host is slower than the poll interval; do not stack requests on it
    }

    // What the stream was configured with is an address and a port together, and the port on it
    // is the streaming one rather than this. Strip it the way the rest of the app does.
    NSString *address = [Utils addressPortStringToAddress:_host];
    // An IPv6 literal has to be bracketed in a URL, and Tailscale hands these out.
    if ([address containsString:@":"] && ![address hasPrefix:@"["]) {
        address = [NSString stringWithFormat:@"[%@]", address];
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@:%u/caret",
                                       address, _httpsPort]];
    if (url == nil) {
        return;
    }

    if (!_loggedURL) {
        _loggedURL = YES;
        Log(LOG_I, @"Caret tracking: %@", url.absoluteString);
    }

    _inFlight = YES;
    __weak CaretTracker *weakSelf = self;
    [[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL precise = NO;
        CGRect caret = [CaretTracker parse:data precise:&precise];
        dispatch_async(dispatch_get_main_queue(), ^{
            CaretTracker *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_inFlight = NO;
            // Only report while still running: an answer that arrives after the keyboard has
            // gone would move the picture for no reason.
            if (strongSelf->_timer != nil && strongSelf.onCaret != nil) {
                strongSelf.onCaret(caret, precise);
            }
        });
    }] resume];
}

#pragma mark - The paired connection

/// Pins the host's certificate, and answers with the client one written at pairing time.
///
/// A host's certificate is self-signed, so the system's own trust evaluation is replaced by the
/// check the rest of the app makes: this is the certificate the host presented when it was
/// paired, and nothing else will do. Kept here rather than shared with HttpManager because the
/// two sessions have nothing in common beyond the certificates themselves.
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *_Nullable))completionHandler {
    NSString *method = challenge.protectionSpace.authenticationMethod;

    if ([method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        if (trust == NULL || SecTrustGetCertificateCount(trust) != 1) {
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
            return;
        }

        SecCertificateRef presented = SecTrustGetCertificateAtIndex(trust, 0);
        CFDataRef presentedData = presented != NULL ? SecCertificateCopyData(presented) : NULL;
        BOOL matches = presentedData != NULL && CFEqual(presentedData, (__bridge CFDataRef)_serverCert);
        if (presentedData != NULL) {
            CFRelease(presentedData);
        }

        if (!matches) {
            Log(LOG_E, @"Caret tracking: server certificate mismatch");
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
            return;
        }
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
        return;
    }

    if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate]) {
        SecIdentityRef identity = [CaretTracker copyClientIdentity];
        if (identity == NULL) {
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
            return;
        }

        SecCertificateRef certificate = NULL;
        SecIdentityCopyCertificate(identity, &certificate);
        NSArray *chain = certificate != NULL ? @[(__bridge_transfer id)certificate] : @[];

        NSURLCredential *credential = [NSURLCredential credentialWithIdentity:identity
                                                                certificates:chain
                                                                 persistence:NSURLCredentialPersistenceForSession];
        CFRelease(identity);
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
        return;
    }

    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

/// The identity the app paired with, or NULL. The caller releases it.
+ (SecIdentityRef)copyClientIdentity CF_RETURNS_RETAINED {
    NSData *store = [CryptoManager readP12FromFile];
    if (store == nil) {
        return NULL;
    }

    // The passphrase the app writes its own store with.
    const void *keys[] = {kSecImportExportPassphrase};
    const void *values[] = {CFSTR("limelight")};
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);

    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)store, options, &items);
    CFRelease(options);

    SecIdentityRef identity = NULL;
    if (status == errSecSuccess && items != NULL && CFArrayGetCount(items) > 0) {
        CFDictionaryRef first = CFArrayGetValueAtIndex(items, 0);
        identity = (SecIdentityRef)CFRetain(CFDictionaryGetValue(first, kSecImportItemIdentity));
    } else {
        Log(LOG_E, @"Caret tracking: could not open the client certificate");
    }
    if (items != NULL) {
        CFRelease(items);
    }

    return identity;
}

/// The body is either {} or the four fractions. Small enough to read directly rather than
/// pulling in a parser.
+ (CGRect)parse:(NSData *)data precise:(BOOL *)precise {
    if (data.length == 0) {
        return CGRectNull;
    }
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return CGRectNull;
    }
    NSDictionary *fields = json;
    NSNumber *x = fields[@"x"];
    NSNumber *y = fields[@"y"];
    if (x == nil || y == nil) {
        return CGRectNull;  // {} — this application does not say where its caret is
    }
    *precise = [fields[@"source"] isEqualToString:@"caret"];
    return CGRectMake(x.doubleValue,
                      y.doubleValue,
                      [fields[@"w"] doubleValue],
                      [fields[@"h"] doubleValue]);
}

@end
