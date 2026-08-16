//
//  CaretTracker.m
//  Moonlight
//

#import "CaretTracker.h"
#import "Utils.h"
#include <Limelight.h>

/// Often enough that the picture keeps up with a moving caret, rarely enough that the request
/// costs nothing next to the video stream sharing the same link.
static const NSTimeInterval pollInterval = 0.15;

/// Sunshine's unencrypted port. The caret goes over it rather than over the TLS one because the
/// video stream beside it is not encrypted either — a rectangle is not the secret here — and it
/// saves the client the paired-certificate handshake on every poll.
static const NSInteger sunshineHttpPort = 47989;

@implementation CaretTracker {
    NSString *_host;
    NSURLSession *_session;
    NSTimer *_timer;
    BOOL _inFlight;
    BOOL _loggedURL;
}

- (instancetype)initWithHost:(NSString *)host {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _host = [host copy];

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // Anything slower than the poll interval is already stale; failing fast keeps the queue at
    // one request rather than letting them pile up behind a host that has stopped answering.
    configuration.timeoutIntervalForRequest = 1.0;
    _session = [NSURLSession sessionWithConfiguration:configuration];

    return self;
}

- (void)start {
    if (_timer != nil || _host.length == 0) {
        return;
    }
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

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%ld/caret",
                                       address, (long)sunshineHttpPort]];
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
        CGRect caret = [CaretTracker parse:data];
        dispatch_async(dispatch_get_main_queue(), ^{
            CaretTracker *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_inFlight = NO;
            // Only report while still running: an answer that arrives after the keyboard has
            // gone would move the picture for no reason.
            if (strongSelf->_timer != nil && strongSelf.onCaret != nil) {
                strongSelf.onCaret(caret);
            }
        });
    }] resume];
}

/// The body is either {} or the four fractions. Small enough to read directly rather than
/// pulling in a parser.
+ (CGRect)parse:(NSData *)data {
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
    return CGRectMake(x.doubleValue,
                      y.doubleValue,
                      [fields[@"w"] doubleValue],
                      [fields[@"h"] doubleValue]);
}

@end
