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

/// @param host The host's address, as the stream was configured with.
- (instancetype)initWithHost:(NSString *)host;

/// Called on the main thread whenever an answer arrives.
///
/// The rectangle is in fractions of the streamed display: multiply by the video area to get
/// points. CGRectNull means the focused application does not report an insertion point.
@property (nonatomic, copy, nullable) void (^onCaret)(CGRect normalisedCaret);

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
