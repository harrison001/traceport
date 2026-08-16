//
//  CaretTracker.h
//  Moonlight
//
//  Asks the host where it is expecting text.
//
//  A phone's on-screen keyboard covers half the picture, and nothing on the client says which
//  half matters — the text field you are typing into is usually the half that is hidden. The
//  host knows: the focused application's insertion point is available through Accessibility,
//  and Sunshine reports it at /caret as a fraction of the streamed display.
//
//  Not every application answers. iTerm2 and Xcode do; Chromium, Electron, Sublime Text and
//  Telegram do not, so the caller needs something to fall back on. Polling stops as soon as the
//  keyboard is gone, because that is the only time any of this matters.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CaretTracker : NSObject

/// Polls over TLS with the paired client certificate, the same way the app asks for the
/// application list. Where someone is typing says as much about what they are doing as the
/// picture does, so it goes over the connection the host already verifies rather than the
/// plain-text port beside it.
///
/// @param host The host's address, as the stream was configured with. The port on it is the
///             streaming one rather than the one wanted here.
/// @param httpsPort The host's TLS port.
/// @param serverCert The host's certificate, to pin against. Nothing is polled without it.
- (instancetype)initWithHost:(NSString *)host
                   httpsPort:(unsigned short)httpsPort
                  serverCert:(nullable NSData *)serverCert;

/// Called on the main thread whenever an answer arrives.
///
/// The rectangle is in fractions of the streamed display: multiply by the video area to get
/// points. CGRectNull means the host had nothing to offer at all.
///
/// `precise` says whether this is the focused application's insertion point or the pointer
/// standing in for it. The pointer is where you clicked to start typing, which is close enough
/// to be worth moving the picture for, and in trackpad mode it is the only thing the client
/// cannot work out for itself — but it has no height, so the caller has to supply one.
@property (nonatomic, copy, nullable) void (^onCaret)(CGRect normalisedCaret, BOOL precise);

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
