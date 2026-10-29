//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "PhoneActionClient.h"
#import "KeyboardSupport.h"
#import "PhoneTouchHandler.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>
#include <netdb.h>
#include <unistd.h>
#import <AVFoundation/AVFoundation.h>

#if !TARGET_OS_TV
// Sends this phone's microphone to the host, where TracePort's gateway feeds it into the remote
// phone's call as its microphone (tools/bthid/mic_rx.py). Moonlight's protocol has no microphone
// channel, so this is a separate UDP stream to port 48110: 'TPM1' + seq (u32 LE) + flags (u32 LE,
// 0 = s16le mono 16 kHz) + 20 ms of audio. Voice processing gives echo cancellation and noise
// suppression, which matters because the other party's voice is playing from this phone's speaker.
@interface TPMicUplink : NSObject
@property (nonatomic, readonly) BOOL running;
- (NSString *)startWithHost:(NSString *)host;   // nil on success, otherwise why it failed
- (void)stop;
@end

static const int kMicPort = 48110;
static const double kMicRate = 16000;
enum { kMicFrameBytes = 640 };              // 20 ms of 16 kHz mono s16

@implementation TPMicUplink {
    AVAudioEngine *_engine;
    AVAudioSinkNode *_sink;
    dispatch_queue_t _sendQueue;
    AVAudioConverter *_converter;
    AVAudioFormat *_outFormat;
    NSMutableData *_pending;
    int _sock;
    struct sockaddr_storage _addr;
    socklen_t _addrLen;
    uint32_t _seq;
}

// The stream's host string may carry a port ("host:port", "[v6]:port") or be a bare IPv6 address.
+ (NSString *)bareHost:(NSString *)host {
    if ([host hasPrefix:@"["]) {
        NSRange close = [host rangeOfString:@"]"];
        return close.location != NSNotFound ? [host substringWithRange:NSMakeRange(1, close.location - 1)] : host;
    }
    NSArray<NSString *> *parts = [host componentsSeparatedByString:@":"];
    return parts.count == 2 ? parts[0] : host;
}

- (NSString *)startWithHost:(NSString *)host {
    if (_running) return nil;
    NSString *bare = [TPMicUplink bareHost:host];
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_family = AF_UNSPEC;
    char port[8];
    snprintf(port, sizeof(port), "%d", kMicPort);
    if (getaddrinfo(bare.UTF8String, port, &hints, &res) != 0 || res == NULL) {
        return [NSString stringWithFormat:@"Can't resolve %@", bare];
    }
    _sock = socket(res->ai_family, SOCK_DGRAM, 0);
    memcpy(&_addr, res->ai_addr, res->ai_addrlen);
    _addrLen = res->ai_addrlen;
    freeaddrinfo(res);
    if (_sock < 0) return @"Can't open a UDP socket";
    // Mark the mic as interactive voice: Wi-Fi sends it from the voice queue (WMM AC_VO, DSCP 46)
    // instead of queueing it with the stream's traffic. A one-hour call on 2026-10-28 had the
    // packets arrive 100–817 ms late in bursts (none lost) and the gateway's buffer ran dry each time.
    int svc = NET_SERVICE_TYPE_VO;
    setsockopt(_sock, SOL_SOCKET, SO_NET_SERVICE_TYPE, &svc, sizeof(svc));

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // Play-and-record in voice-chat mode turns on the system's echo cancellation; keep the stream's
    // audio on the speaker and mixed rather than ducked.
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeVoiceChat
                      options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionMixWithOthers
                        error:&err]) {
        [self stop];
        return [NSString stringWithFormat:@"Audio session: %@", err.localizedDescription];
    }
    // Ask for 10 ms I/O buffers so audio comes out of the hardware in small, evenly spaced pieces.
    [session setPreferredIOBufferDuration:0.01 error:nil];
    [session setActive:YES error:nil];

    _engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = _engine.inputNode;
    if (![input setVoiceProcessingEnabled:YES error:&err]) {
        Log(LOG_W, @"Mic uplink: voice processing unavailable: %@", err.localizedDescription);
    }
    if (@available(iOS 17.0, *)) {
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration duck = {
            .enableAdvancedDucking = NO,
            .duckingLevel = AVAudioVoiceProcessingOtherAudioDuckingLevelMin,
        };
        input.voiceProcessingOtherAudioDuckingConfiguration = duck;
    }
    AVAudioFormat *inFormat = [input outputFormatForBus:0];
    _outFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                  sampleRate:kMicRate channels:1 interleaved:YES];
    _converter = [[AVAudioConverter alloc] initFromFormat:inFormat toFormat:_outFormat];
    _pending = [NSMutableData data];
    _seq = 0;

    // A sink node is called on every hardware render cycle (~10 ms here). A tap was simpler but iOS
    // hands taps ~100 ms at a time whatever bufferSize asks for, so packets left in bursts of five
    // or six and the gateway saw 0 ms / 114 ms gaps (median / 95th percentile) and had to buffer
    // ~140 ms to avoid dropouts. The render thread only copies; conversion and sending happen on a
    // serial queue.
    _sendQueue = dispatch_queue_create("io.traceone.mic-uplink", DISPATCH_QUEUE_SERIAL);
    __weak TPMicUplink *weakSelf = self;
    AVAudioFormat *sinkFormat = inFormat;
    _sink = [[AVAudioSinkNode alloc] initWithReceiverBlock:^OSStatus(const AudioTimeStamp *timestamp,
                                                                    AVAudioFrameCount frameCount,
                                                                    const AudioBufferList *inputData) {
        TPMicUplink *strongSelf = weakSelf;
        if (strongSelf == nil || frameCount == 0) return noErr;
        AVAudioPCMBuffer *copy = [[AVAudioPCMBuffer alloc] initWithPCMFormat:sinkFormat frameCapacity:frameCount];
        copy.frameLength = frameCount;
        const AudioBufferList *dst = copy.audioBufferList;
        UInt32 n = MIN(inputData->mNumberBuffers, dst->mNumberBuffers);
        for (UInt32 i = 0; i < n; i++) {
            memcpy(dst->mBuffers[i].mData, inputData->mBuffers[i].mData,
                   MIN(inputData->mBuffers[i].mDataByteSize, dst->mBuffers[i].mDataByteSize));
        }
        dispatch_async(strongSelf->_sendQueue, ^{
            [weakSelf handleBuffer:copy];
        });
        return noErr;
    }];
    [_engine attachNode:_sink];
    [_engine connect:input to:_sink format:inFormat];
    [_engine prepare];
    if (![_engine startAndReturnError:&err]) {
        [self stop];
        return [NSString stringWithFormat:@"Microphone: %@", err.localizedDescription];
    }
    _running = YES;
    Log(LOG_I, @"Mic uplink started to %@:%d (%.0f Hz in)", bare, kMicPort, inFormat.sampleRate);
    return nil;
}

- (void)handleBuffer:(AVAudioPCMBuffer *)buffer {
    AVAudioFrameCount cap = (AVAudioFrameCount)ceil(buffer.frameLength * kMicRate / buffer.format.sampleRate) + 32;
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_outFormat frameCapacity:cap];
    __block BOOL fed = NO;
    NSError *err = nil;
    [_converter convertToBuffer:out error:&err withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *status) {
        if (fed) {
            *status = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        fed = YES;
        *status = AVAudioConverterInputStatus_HaveData;
        return buffer;
    }];
    if (out.frameLength == 0) return;
    [_pending appendBytes:out.int16ChannelData[0] length:out.frameLength * sizeof(int16_t)];

    uint8_t packet[12 + kMicFrameBytes];
    memcpy(packet, "TPM1", 4);
    uint32_t flags = 0;
    while (_pending.length >= kMicFrameBytes) {
        uint32_t seq = CFSwapInt32HostToLittle(_seq++);
        memcpy(packet + 4, &seq, 4);
        memcpy(packet + 8, &flags, 4);
        memcpy(packet + 12, _pending.bytes, kMicFrameBytes);
        sendto(_sock, packet, sizeof(packet), 0, (struct sockaddr *)&_addr, _addrLen);
        [_pending replaceBytesInRange:NSMakeRange(0, kMicFrameBytes) withBytes:NULL length:0];
    }
}

- (void)stop {
    if (_engine != nil) {
        [_engine stop];
        if (_sink != nil) {
            [_engine detachNode:_sink];
            _sink = nil;
        }
        [_engine.inputNode setVoiceProcessingEnabled:NO error:nil];
        _engine = nil;
    }
    if (_sock > 0) {
        close(_sock);
    }
    _sock = -1;
    if (_running) {
        // Back to what Connection.m set up for stream audio.
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        Log(LOG_I, @"Mic uplink stopped after %u packets", _seq);
    }
    _running = NO;
}
@end
#endif

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    CGSize _keyboardSize;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
    UIPanGestureRecognizer *_twoFingerScrollRecognizer;      // touchscreen mode: two fingers scroll the host
    CGPoint _lastTwoFingerTranslation;
    UIScreenEdgePanGestureRecognizer *_phoneHomeRecognizer;  // phone host: swipe up from the bottom edge
    TPMicUplink *_micUplink;
    UIButton *_micButton;
    BOOL _phoneHost;                                     // a phone through the TracePort gateway
    UILabel *_phoneToast;                                // phone host: what an action or touch came to
    NSUInteger _phoneToastGeneration;
    PhoneTouchHandler *_phoneTouch;                      // phone host: real touch, when it is on
    BOOL _realTouchWanted;                               // the switch, remembered per host
    BOOL _gatewayTouches;                                // the gateway says it can replay touches now
    NSArray<NSString *> *_gatewayAlertKeys;              // the gateway's active alerts, last seen
    PhoneActionClient *_phoneClient;                     // phone host: asks the gateway to do the dock's actions
    NSTimer *_phoneStatusTimer;                          // and, every few seconds, what it can do right now
    NSTimer *_phoneCallTimer;                            // every second: is the phone ringing (PhoneCallCenter)
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];

    // The host list is landscape-only, so the rotate-before-push request in beginStreamSegue is
    // refused while that list is still on top, and the 1s fallback can push us before any rotation
    // lands — a portrait stream then shows up sideways in a landscape window. We are on top now and
    // supportedInterfaceOrientations already allows the stream's shape, so ask again: this time it
    // is granted, the window rotates, and the video (and the touch map that reads the same bounds)
    // lays out upright.
    if (@available(iOS 16.0, *)) {
        BOOL wantPortrait = self.streamConfig.height > self.streamConfig.width;
        BOOL isPortrait = self.view.bounds.size.height > self.view.bounds.size.width;
        UIWindowScene* scene = self.view.window.windowScene;
        if (scene != nil && wantPortrait != isPortrait) {
            [self setNeedsUpdateOfSupportedInterfaceOrientations];
            UIWindowSceneGeometryPreferencesIOS* prefs =
                [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:
                    (wantPortrait ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscape)];
            [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError* e) {
                Log(LOG_W, @"Stream orientation request refused: %@", e);
            }];
        }
    }
#endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettingsForHost:_streamConfig.hostUuid];
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    // A phone host has no buttons of its own on screen: its actions are on the key line (three
    // fingers), and with real touch the phone's own gestures do the rest. The picture gets the
    // whole screen; iOS defers its edge gestures here, so swipes from the edges reach the phone.
    CGRect streamFrame = self.view.frame;
#if !TARGET_OS_TV
    _phoneHost = [HostProfile targetTypeForHost:_streamConfig.hostUuid] == TPTargetPhone;
#endif
    _streamView = [[StreamView alloc] initWithFrame:streamFrame];
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Tip: Swipe from the left edge to disconnect from your PC"];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pictureInPictureClosed:)
                                                 name:VideoDecoderRendererPictureInPictureClosedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    // Only enable scroll and zoom in absolute touch mode
    if (_settings.absoluteTouchMode) {
        _scrollView = [[UIScrollView alloc] initWithFrame:streamFrame];
        // Don't let UIKit pad the content by the safe area: the stream view is laid out against the
        // full screen, so the automatic top inset (Dynamic Island) pushed a portrait stream down and
        // cut off its bottom edge in touchscreen mode.
        _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view addSubview:_scrollView];
#if !TARGET_OS_TV
        // Two fingers scroll the host while the picture is at its normal size; once zoomed they
        // pan the picture as before. Without this, two fingers did nothing at 1x in this mode.
        _scrollView.scrollEnabled = NO;
        _twoFingerScrollRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerScroll:)];
        _twoFingerScrollRecognizer.minimumNumberOfTouches = 2;
        _twoFingerScrollRecognizer.maximumNumberOfTouches = 2;
        _twoFingerScrollRecognizer.cancelsTouchesInView = NO;
        _twoFingerScrollRecognizer.delegate = self;
        [_scrollView addGestureRecognizer:_twoFingerScrollRecognizer];

        if ([HostProfile targetTypeForHost:_streamConfig.hostUuid] == TPTargetPhone) {
            _phoneHomeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(phoneBottomEdgeSwiped:)];
            _phoneHomeRecognizer.edges = UIRectEdgeBottom;
            _phoneHomeRecognizer.delegate = self;
            [self.view addGestureRecognizer:_phoneHomeRecognizer];
        }
#endif
    }
    else {
        // Add StreamView directly in relative mode
        [self.view addSubview:_streamView];
    }
    
#if !TARGET_OS_TV
    if (_phoneHost) {
        _realTouchWanted = [self realTouchPreference];
        _phoneClient = [[PhoneActionClient alloc] initWithHost:_streamConfig.host
                                                     httpsPort:_streamConfig.httpsPort
                                                    serverCert:_streamConfig.serverCert];
        __weak StreamFrameViewController *weakSelf = self;
        _streamView.phoneActionHandler = ^(NSString *action, short fallbackKey) {
            [weakSelf performPhoneAction:action fallbackKey:fallbackKey];
        };
        [self buildPhoneToast];
        [self setUpRealTouch];
        _phoneClient.hostUuid = _streamConfig.hostUuid;
        [self startPhoneStatus];
        // the gateway pushes "needs you" alerts to this device
        [PhoneActionClient requestPushPermission];
        [_phoneClient registerPush];
    }
#endif
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

#if !TARGET_OS_TV
- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    // Two fingers pan the picture only while it is zoomed in; at 1x they scroll the host
    scrollView.scrollEnabled = scrollView.zoomScale > 1.01;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Pinch-to-zoom keeps working alongside the two-finger scroll
    return gestureRecognizer == _twoFingerScrollRecognizer || other == _twoFingerScrollRecognizer;
}

- (void)twoFingerScroll:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        _lastTwoFingerTranslation = CGPointZero;
        // Scrolling acts on whatever is under the pointer, so put it between the two fingers
        // (a phone ignores the wheel unless the pointer is over something scrollable).
        if (_scrollView.zoomScale <= 1.01) {
            [_streamView updateCursorLocation:[gesture locationInView:_streamView] isMouse:NO];
        }
        return;
    }
    if (gesture.state != UIGestureRecognizerStateChanged || _scrollView.zoomScale > 1.01) {
        return;
    }
    // Same scale as a trackpad's continuous scroll (StreamView mouseWheelMovedContinuous):
    // a full screen height of travel is 20 notches. Fingers drag the content, as on iOS.
    CGPoint t = [gesture translationInView:self.view];
    const CGFloat notch = 120 * 20;
    short dy = (short)((t.y - _lastTwoFingerTranslation.y) / self.view.bounds.size.height * notch);
    short dx = (short)((t.x - _lastTwoFingerTranslation.x) / self.view.bounds.size.width * notch);
    if (dy != 0) {
        LiSendHighResScrollEvent(dy);
        _lastTwoFingerTranslation.y = t.y;
    }
    if (dx != 0) {
        LiSendHighResHScrollEvent(-dx);
        _lastTwoFingerTranslation.x = t.x;
    }
}

/// Swipe up from the bottom edge on a phone host: a quick flick goes home (F13), a swipe that
/// pauses before letting go opens the app switcher (F14), as on the phone itself. The gateway
/// bridge turns F13/F14 into the phone action (see ios_bridge phone_keys).
- (void)phoneBottomEdgeSwiped:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }
    CGPoint t = [gesture translationInView:self.view];
    CGPoint v = [gesture velocityInView:self.view];
    if (t.y > -40) {
        return;   // barely moved: not a swipe
    }
    BOOL switcher = fabs(v.y) < 300;
    Log(LOG_I, @"Phone bottom-edge swipe: %s", switcher ? "app switcher" : "home");
    // Through the gateway like the keys, so it is checked and confirmed; F13/F14 if it cannot be asked
    [self performPhoneAction:switcher ? @"apps" : @"home" fallbackKey:switcher ? 0x7D : 0x7C];
}
#endif

#if !TARGET_OS_TV
- (NSString *)realTouchKey {
    return [@"TracePort.realTouch." stringByAppendingString:_streamConfig.hostUuid ?: _streamConfig.host];
}

/// On unless turned off: it is the way that does not miss.
- (BOOL)realTouchPreference {
    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:[self realTouchKey]];
    return saved == nil ? YES : [saved boolValue];
}

- (void)setUpRealTouch {
    _phoneTouch = [[PhoneTouchHandler alloc] initWithView:_streamView client:_phoneClient];
    __weak StreamFrameViewController *weakSelf = self;
    _phoneTouch.onResult = ^(NSDictionary *result) {
        StreamFrameViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (result == nil) {
            [strongSelf showPhoneToast:@"✗ Touch did not reach the gateway" ok:NO];
            return;
        }
        if ([result[@"ok"] boolValue]) {
            return;   // the phone moving is the answer
        }
        NSString *why = [result[@"error"] isKindOfClass:[NSString class]] ? result[@"error"] : @"";
        if ([result[@"fallback"] boolValue]) {
            // WebDriverAgent went away under us: the pointer still works, so use it until it is back
            [strongSelf gatewayTouchesAvailable:NO];
        }
        [strongSelf showPhoneToast:[@"✗ Touch  " stringByAppendingString:why] ok:NO];
    };
    [self applyTouchRouting];
}

/// The key line's Touch key.
- (void)toggleRealTouch {
    _realTouchWanted = !_realTouchWanted;
    [[NSUserDefaults standardUserDefaults] setBool:_realTouchWanted forKey:[self realTouchKey]];
    [self applyTouchRouting];
    NSString *what = !_realTouchWanted ? @"Pointer"
                   : _gatewayTouches ? @"Real touch"
                                     : @"Real touch — waiting for WebDriverAgent, pointer until then";
    [self showPhoneToast:what ok:YES];
}

/// One of the phone's own actions, asked of the gateway, which does it, checks it took and says
/// so. A gateway that cannot be asked gets the F13–F23 key its bridge also understands.
- (void)performPhoneAction:(NSString *)action fallbackKey:(short)fallbackKey {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    if ([action isEqualToString:@"touchmode"]) {
        [self toggleRealTouch];
        return;
    }
    __weak StreamFrameViewController *weakSelf = self;
    [_phoneClient perform:action completion:^(NSDictionary *result) {
        StreamFrameViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (result == nil) {
            if (fallbackKey != 0) {
                [KeyboardSupport sendChordWithVirtualKey:fallbackKey modifierFlags:0];
            }
            [strongSelf showPhoneToast:@"Sent (gateway did not confirm)" ok:YES];
            return;
        }
        NSString *label = [result[@"label"] isKindOfClass:[NSString class]] ? result[@"label"] : action;
        if ([result[@"ok"] boolValue]) {
            [strongSelf showPhoneToast:[@"✓ " stringByAppendingString:label] ok:YES];
        } else {
            NSString *why = [result[@"error"] isKindOfClass:[NSString class]] ? result[@"error"] : @"";
            [strongSelf showPhoneToast:[NSString stringWithFormat:@"✗ %@  %@", label, why] ok:NO];
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeError];
        }
    }];
}

- (void)buildPhoneToast {
    _phoneToast = [[UILabel alloc] init];
    _phoneToast.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _phoneToast.textColor = UIColor.whiteColor;
    _phoneToast.textAlignment = NSTextAlignmentCenter;
    _phoneToast.numberOfLines = 2;
    _phoneToast.layer.cornerRadius = 14;
    _phoneToast.layer.masksToBounds = YES;
    _phoneToast.alpha = 0;
    _phoneToast.userInteractionEnabled = NO;
    _phoneToast.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_phoneToast];
    // Near the top, under the island: the key line and the keyboard take the bottom
    [NSLayoutConstraint activateConstraints:@[
        [_phoneToast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_phoneToast.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_phoneToast.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-32],
        [_phoneToast.heightAnchor constraintGreaterThanOrEqualToConstant:28],
    ]];
}

- (void)showPhoneToast:(NSString *)text ok:(BOOL)ok {
    if (_phoneToast == nil) {
        return;
    }
    [self.view bringSubviewToFront:_phoneToast];
    _phoneToast.text = [NSString stringWithFormat:@"  %@  ", text];
    _phoneToast.backgroundColor = ok ? [UIColor colorWithWhite:0.15 alpha:0.9]
                                     : [UIColor colorWithRed:0.55 green:0.1 blue:0.1 alpha:0.92];
    _phoneToast.alpha = 1;
    NSUInteger generation = ++_phoneToastGeneration;
    // A failure stays long enough to read the reason
    __weak StreamFrameViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((ok ? 1.2 : 3.5) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        StreamFrameViewController *strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf->_phoneToastGeneration) {
            return;
        }
        [UIView animateWithDuration:0.3 animations:^{ strongSelf->_phoneToast.alpha = 0; }];
    });
}

/// What the gateway says needs a person (alerts.rs). Shown when the set changes: a new one in red
/// with its text, and a short note once all have cleared.
- (void)gatewayAlerts:(id)alerts {
    if (![alerts isKindOfClass:[NSArray class]]) {
        return;
    }
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSDictionary *newest = nil;
    for (id a in (NSArray *)alerts) {
        if (![a isKindOfClass:[NSDictionary class]] || ![a[@"key"] isKindOfClass:[NSString class]]) {
            continue;
        }
        [keys addObject:a[@"key"]];
        if (![_gatewayAlertKeys containsObject:a[@"key"]]) {
            newest = a;
        }
    }
    NSArray<NSString *> *before = _gatewayAlertKeys ?: @[];
    _gatewayAlertKeys = keys;
    if (newest != nil) {
        NSString *title = [newest[@"title"] isKindOfClass:[NSString class]] ? newest[@"title"] : @"";
        NSString *body = [newest[@"body"] isKindOfClass:[NSString class]] ? newest[@"body"] : @"";
        [self showPhoneToast:[NSString stringWithFormat:@"⚠︎ %@\n%@", title, body] ok:NO];
    } else if (keys.count == 0 && before.count > 0) {
        [self showPhoneToast:@"✓ Gateway back to normal" ok:YES];
    }
}

- (void)gatewayTouchesAvailable:(BOOL)available {
    if (available == _gatewayTouches) {
        return;
    }
    _gatewayTouches = available;
    [self applyTouchRouting];
    if (_realTouchWanted) {
        [self showPhoneToast:available ? @"Real touch ready" : @"Real touch paused — WebDriverAgent is down, using the pointer"
                           ok:available];
    }
}

- (void)applyTouchRouting {
    _streamView.realTouchHandler = (_realTouchWanted && _gatewayTouches) ? _phoneTouch : nil;
}

/// Asks the gateway every few seconds whether it can replay touches right now (WebDriverAgent
/// running), so real touch steps aside for the pointer while it cannot. A gateway that does not
/// answer changes nothing: it may simply predate the action port.
- (void)startPhoneStatus {
    __weak StreamFrameViewController *weakSelf = self;
    void (^refresh)(void) = ^{
        StreamFrameViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf->_phoneClient fetchStatus:^(NSDictionary *status) {
            StreamFrameViewController *again = weakSelf;
            if (again == nil || status == nil) {
                return;
            }
            BOOL wda = [status[@"wda"] boolValue];
            [again gatewayTouchesAvailable:wda && [status[@"touch"] boolValue]];
            [again gatewayAlerts:status[@"alerts"]];
        }];
    };
    refresh();
    _phoneStatusTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
        refresh();
    }];
    // Calls ring here within a second while streaming, push or no push (PhoneCallCenter)
    _phoneCallTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        StreamFrameViewController *strongSelf = weakSelf;
        PhoneActionClient *client = strongSelf != nil ? strongSelf->_phoneClient : nil;
        [client fetchCall:^(NSDictionary *call) {
            if (call != nil) {
                [[PhoneCallCenter shared] streamSawCalls:call gateway:client.base];
            }
        }];
    }];
}
#endif

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
#if !TARGET_OS_TV
        [_phoneStatusTimer invalidate];
        _phoneStatusTimer = nil;
        [_phoneCallTimer invalidate];
        _phoneCallTimer = nil;
        [_phoneClient invalidate];
        _phoneClient = nil;
        [_micUplink stop];
#endif
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    if ([VideoDecoderRenderer pictureInPicturePossible] || [VideoDecoderRenderer pictureInPictureActive]) {
        // Leaving for another app shrinks the stream into Picture in Picture; nothing to end
        _inactivityTimer = nil;
        return;
    }
    
#if !TARGET_OS_TV
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Back in the app: the stream goes full screen again
    [VideoDecoderRenderer stopPictureInPicture];

    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
    if ([VideoDecoderRenderer pictureInPicturePossible] || [VideoDecoderRenderer pictureInPictureActive]) {
        // Picture in Picture keeps the stream (and the connection) going while the app is away
        Log(LOG_I, @"Backgrounded with Picture in Picture; keeping the stream");
        return;
    }
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    [self returnToMainFrame];
}

- (void)pictureInPictureClosed:(NSNotification *)notification {
    Log(LOG_I, @"Picture in Picture closed while away; ending the stream");
    [self returnToMainFrame];
}

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    
    [self returnToMainFrame];
}

#if !TARGET_OS_TV
- (void)showMicButton {
    if (_micButton != nil) return;
    _micButton = [UIButton buttonWithType:UIButtonTypeSystem];
    CGFloat size = 44;
    CGFloat top = self.view.safeAreaInsets.top + 8;
    _micButton.frame = CGRectMake(self.view.bounds.size.width - size - 12, top, size, size);
    _micButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    _micButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    _micButton.layer.cornerRadius = size / 2;
    _micButton.accessibilityLabel = @"Microphone";
    [_micButton addTarget:self action:@selector(micButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self updateMicButton];
    [self.view addSubview:_micButton];
}

- (void)updateMicButton {
    BOOL on = _micUplink.running;
    [_micButton setImage:[UIImage systemImageNamed:on ? @"mic.fill" : @"mic.slash.fill"] forState:UIControlStateNormal];
    _micButton.tintColor = on ? [UIColor systemRedColor] : [UIColor whiteColor];
}

- (void)micButtonTapped {
    if (_micUplink.running) {
        [_micUplink stop];
        [self updateMicButton];
        return;
    }
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                [self showMicError:@"Microphone access is off. Turn it on in Settings > TracePort."];
                return;
            }
            if (self->_micUplink == nil) {
                self->_micUplink = [[TPMicUplink alloc] init];
            }
            NSString *err = [self->_micUplink startWithHost:self.streamConfig.host];
            if (err != nil) {
                [self showMicError:err];
            }
            [self updateMicButton];
        });
    }];
}

- (void)showMicError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Microphone"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
#endif

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        
        [self->_streamView showOnScreenControls];
#if !TARGET_OS_TV
        [self showMicButton];
#endif
        
        [self->_controllerSupport connectionEstablished];
        
        if (self->_settings.statsOverlay) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking TracePort. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking TracePort. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

// Hold the phone the way the picture is shaped. The host list turns the
// device before pushing us (see beginStreamSegue), so the stream view is
// laid out once in the right shape and never rotates underneath the video.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (self.streamConfig.height > self.streamConfig.width) {
        return UIInterfaceOrientationMaskPortrait;
    }
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

@end
