//
//  PhoneTouchHandler.m
//  Moonlight
//

#import "PhoneTouchHandler.h"

/// Samples closer together than this add nothing: the gateway keeps four points of a path anyway.
static const NSTimeInterval sampleInterval = 0.012;

/// Gestures waiting while one is being replayed. The phone takes most of a second per gesture, so
/// a burst of taps queues up; past this many the oldest is dropped rather than replayed late.
static const NSUInteger maxQueued = 4;

@implementation PhoneTouchHandler {
    __weak StreamView *_view;
    PhoneActionClient *_client;

    UITouch *_finger;
    NSTimeInterval _start;
    NSTimeInterval _lastSample;
    NSMutableArray<NSArray<NSNumber *> *> *_points;
    BOOL _abandoned;       // a second finger joined: two fingers are a scroll, not a touch

    NSMutableArray<NSArray *> *_queue;
    BOOL _sending;
}

- (instancetype)initWithView:(StreamView *)view client:(PhoneActionClient *)client {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _view = view;
    _client = client;
    _queue = [NSMutableArray array];
    return self;
}

- (NSArray<NSNumber *> *)sample:(UITouch *)touch {
    StreamView *view = _view;
    CGPoint p = [view normalizedVideoPoint:[touch locationInView:view]];
    double ms = (touch.timestamp - _start) * 1000.0;
    return @[@(round(p.x * 10000) / 10000), @(round(p.y * 10000) / 10000), @(round(ms))];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_finger != nil || [[event allTouches] count] > 1) {
        _abandoned = YES;
        return;
    }
    _finger = [touches anyObject];
    _start = _lastSample = _finger.timestamp;
    _abandoned = NO;
    _points = [NSMutableArray arrayWithObject:[self sample:_finger]];
    [self rippleAt:[_finger locationInView:_view]];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_finger == nil || _abandoned || ![touches containsObject:_finger]) {
        return;
    }
    if (_finger.timestamp - _lastSample >= sampleInterval) {
        _lastSample = _finger.timestamp;
        [_points addObject:[self sample:_finger]];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_finger == nil || ![touches containsObject:_finger]) {
        return;
    }
    if (!_abandoned) {
        [_points addObject:[self sample:_finger]];
        [self enqueue:[_points copy]];
    }
    _finger = nil;
    _points = nil;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_finger != nil && [touches containsObject:_finger]) {
        _finger = nil;
        _points = nil;
    }
}

#pragma mark - Sending, one at a time and in order

- (void)enqueue:(NSArray *)points {
    if (_queue.count >= maxQueued) {
        [_queue removeObjectAtIndex:0];
    }
    [_queue addObject:points];
    [self pump];
}

- (void)pump {
    if (_sending || _queue.count == 0) {
        return;
    }
    NSArray *points = _queue.firstObject;
    [_queue removeObjectAtIndex:0];
    _sending = YES;
    __weak PhoneTouchHandler *weakSelf = self;
    [_client touch:points completion:^(NSDictionary *result) {
        PhoneTouchHandler *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf->_sending = NO;
        if (strongSelf.onResult) {
            strongSelf.onResult(result);
        }
        [strongSelf pump];
    }];
}

#pragma mark - Showing the touch landed

/// The phone answers most of a second later; a ring where the finger went down says straight away
/// that the touch was taken, so the wait does not read as a missed tap.
- (void)rippleAt:(CGPoint)point {
    StreamView *view = _view;
    if (view == nil) {
        return;
    }
    CAShapeLayer *ring = [CAShapeLayer layer];
    CGFloat r = 22;
    ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-r, -r, 2 * r, 2 * r)].CGPath;
    ring.position = point;
    ring.fillColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    ring.strokeColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    ring.lineWidth = 1.5;
    [view.layer addSublayer:ring];

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ [ring removeFromSuperlayer]; }];
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @0.6;
    grow.toValue = @1.3;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[grow, fade];
    group.duration = 0.45;
    group.removedOnCompletion = NO;
    group.fillMode = kCAFillModeForwards;
    [ring addAnimation:group forKey:nil];
    [CATransaction commit];
}

@end
