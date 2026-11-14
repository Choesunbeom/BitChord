#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

// Only for the user's ORIGINAL BitChord-KR v1.0.2 build 40 IPA.
// The previous version installed a UILongPressGestureRecognizer on
// CentredVolumeView. That view paints the bar, but does not receive touches:
// the original SwiftUI/MPVolumeView slider handles them above it.
// V2 installs an explicit clear touch surface in UIWindow above the system
// slider. Short tap/drag is forwarded to Apple's MPVolumeView's UISlider.
// A 0.42s hold switches to app-only AVPlayer gain and gives one haptic.
// The original AVAudioSession/mixWithOthers configuration is untouched.

static NSString *const kBCHGainKey = @"com.choesunbeom.BitChord.dualVolume.gain";
static const void *kBCHBaseGainKey = &kBCHBaseGainKey;
static const void *kBCHOverlayKey = &kBCHOverlayKey;
static float gAppGain = 1.0f;
static NSHashTable<AVPlayer *> *gActivePlayers;
static void (*origSetVolume)(id, SEL, float);
static float (*origGetVolume)(id, SEL);
static void (*origPlay)(id, SEL);
static void (*origPlayRate)(id, SEL, float);
static id (*origPlayerInit)(id, SEL);
static id (*origInitWithPlayerItem)(id, SEL, AVPlayerItem *);
static id (*origQueueInitWithItems)(id, SEL, NSArray<AVPlayerItem *> *);
static void (*origSetRate)(id, SEL, float);
static void (*origReplaceItem)(id, SEL, AVPlayerItem *);
static void (*origQueueInsert)(id, SEL, AVPlayerItem *, AVPlayerItem *);
static void (*origLayout)(id, SEL);
static void (*origDidMoveToWindow)(id, SEL);

static float BCHClamp(float x) {
    return isfinite(x) ? fmaxf(0.0f, fminf(1.0f, x)) : 1.0f;
}
static float BCHBaseGain(AVPlayer *player) {
    NSNumber *saved = objc_getAssociatedObject(player, kBCHBaseGainKey);
    return saved ? saved.floatValue :
        (origGetVolume ? origGetVolume(player, @selector(volume)) : 1.0f);
}
static void BCHApplyToPlayer(AVPlayer *player) {
    if (player && origSetVolume) {
        origSetVolume(player, @selector(setVolume:),
                      BCHClamp(BCHBaseGain(player) * gAppGain));
    }
}
static void BCHRegisterPlayer(AVPlayer *player) {
    if (!player) return;
    if (!objc_getAssociatedObject(player, kBCHBaseGainKey)) {
        objc_setAssociatedObject(player, kBCHBaseGainKey,
                                 @(BCHClamp(BCHBaseGain(player))),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    @synchronized (gActivePlayers) { [gActivePlayers addObject:player]; }
    BCHApplyToPlayer(player);
}
static void BCHSetVolume(id self, SEL cmd, float value) {
    objc_setAssociatedObject(self, kBCHBaseGainKey, @(BCHClamp(value)),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized (gActivePlayers) { [gActivePlayers addObject:self]; }
    if (origSetVolume)
        origSetVolume(self, cmd, BCHClamp(value * gAppGain));
}
static float BCHGetVolume(id self, SEL cmd) {
    NSNumber *n = objc_getAssociatedObject(self, kBCHBaseGainKey);
    return n ? n.floatValue : (origGetVolume ? origGetVolume(self, cmd) : 1.0f);
}
static void BCHPlay(id self, SEL cmd) {
    BCHRegisterPlayer(self);
    if (origPlay) origPlay(self, cmd);
}
static void BCHPlayRate(id self, SEL cmd, float value) {
    BCHRegisterPlayer(self);
    if (origPlayRate) origPlayRate(self, cmd, value);
}
// Catch real playback deck creation as well as play()/rate changes.
 // BitChord-KR has multiple AVQueuePlayer decks and can start playback by
 // setting rate directly. Its app-only volume never reached those objects in v2.
static id BCHPlayerInit(id self, SEL cmd) {
    id result = origPlayerInit ? origPlayerInit(self,cmd) : nil;
    if (result) BCHRegisterPlayer(result);
    return result;
}
static id BCHInitWithItem(id self, SEL cmd, AVPlayerItem *item) {
    id result=origInitWithPlayerItem?origInitWithPlayerItem(self,cmd,item):nil;
    if (result) BCHRegisterPlayer(result);
    return result;
}
static id BCHQueueInitWithItems(id self, SEL cmd, NSArray<AVPlayerItem*> *items) {
    id result=origQueueInitWithItems?origQueueInitWithItems(self,cmd,items):nil;
    if (result) BCHRegisterPlayer(result);
    return result;
}
static void BCHSetRate(id self,SEL cmd,float rate) {
    BCHRegisterPlayer(self);
    if(origSetRate)origSetRate(self,cmd,rate);
}
static void BCHReplaceItem(id self,SEL cmd,AVPlayerItem *item) {
    BCHRegisterPlayer(self);
    if(origReplaceItem)origReplaceItem(self,cmd,item);
}
static void BCHQueueInsertItem(id self,SEL cmd,AVPlayerItem *item,AVPlayerItem *after) {
    BCHRegisterPlayer(self);
    if(origQueueInsert)origQueueInsert(self,cmd,item,after);
}
static void BCHUpdateAppGain(float value) {
    gAppGain = BCHClamp(value);
    [[NSUserDefaults standardUserDefaults] setFloat:gAppGain forKey:kBCHGainKey];
    NSArray<AVPlayer *> *players;
    @synchronized (gActivePlayers) { players = [gActivePlayers.allObjects copy]; }
    for (AVPlayer *player in players) BCHApplyToPlayer(player);
    NSLog(@"[BCHDualVolume] gain=%.3f active AVPlayers=%lu",gAppGain,(unsigned long)players.count);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BCHDualVolumeUpdated" object:nil];
}

typedef NS_ENUM(NSInteger, BCHTouchMode) {
    BCHTouchIdle = 0, BCHTouchArmed = 1,
    BCHTouchSystem = 2, BCHTouchApp = 3
};

@interface BCHVolumeTouchSurface : UIControl
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSTimer *holdTimer;
@property (nonatomic, strong) MPVolumeView *systemVolumeView;
@property (nonatomic, strong) CALayer *orangeBackground;
@property (nonatomic, strong) CALayer *orangeFill;
@property (nonatomic, strong) CALayer *orangeDot;
@property (nonatomic, strong) CATextLayer *volumeDiagnostics;
@property (nonatomic, assign) BCHTouchMode mode;
@property (nonatomic, assign) CGPoint initialTouch;
@property (nonatomic, assign) CGFloat displayedGain;
@property (nonatomic, strong) id gainObserver;
- (instancetype)initWithSourceView:(UIView *)view;
- (void)refreshLayout;
@end

@implementation BCHVolumeTouchSurface
- (instancetype)initWithSourceView:(UIView *)view {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _sourceView = view;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.userInteractionEnabled = YES;
    self.multipleTouchEnabled = NO;
    self.exclusiveTouch = YES;
    self.clipsToBounds = NO;
    self.mode = BCHTouchIdle;
    self.displayedGain = gAppGain;

    UIColor *orange = [UIColor colorWithRed:1 green:0.54 blue:0.10 alpha:1];
    _orangeBackground = [CALayer layer];
    _orangeFill = [CALayer layer];
    _orangeDot = [CALayer layer];
    _orangeBackground.backgroundColor = [orange colorWithAlphaComponent:0.3].CGColor;
    _orangeFill.backgroundColor = orange.CGColor;
    _orangeDot.backgroundColor = orange.CGColor;
    [self.layer addSublayer:_orangeBackground];
    [self.layer addSublayer:_orangeFill];
    [self.layer addSublayer:_orangeDot];

    // Public UIKit volume component; its slider is our normal-drag target.
    // The real system slider remains visually untouched below this surface.
    _systemVolumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    _systemVolumeView.showsRouteButton = NO;
    _systemVolumeView.showsVolumeSlider = YES;
    _systemVolumeView.alpha = 0.02;
    _systemVolumeView.userInteractionEnabled = NO;
    [self addSubview:_systemVolumeView];

    __weak typeof(self) weakSelf = self;
    _gainObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"BCHDualVolumeUpdated" object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *notification) {
                    (void)notification;
                    BCHVolumeTouchSurface *strong = weakSelf;
                    strong.displayedGain = gAppGain;
                    [strong updateOrangeBar];
                }];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"System and BitChord volume";
    self.accessibilityHint = @"Drag for system volume. Hold for a haptic, then drag for orange BitChord volume.";
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    self.accessibilityCustomActions = @[
        [[UIAccessibilityCustomAction alloc]
            initWithName:@"Increase BitChord volume"
                  target:self selector:@selector(accessibilityIncreaseApp)],
        [[UIAccessibilityCustomAction alloc]
            initWithName:@"Decrease BitChord volume"
                  target:self selector:@selector(accessibilityDecreaseApp)]
    ];
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(refreshLayout)];
    if (@available(iOS 15.0, *)) _displayLink.preferredFrameRateRange =
        CAFrameRateRangeMake(1, 10, 10);
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _volumeDiagnostics=[CATextLayer layer];
    _volumeDiagnostics.contentsScale=UIScreen.mainScreen.scale;
    _volumeDiagnostics.fontSize=10;
    _volumeDiagnostics.alignmentMode=kCAAlignmentCenter;
    _volumeDiagnostics.foregroundColor=UIColor.orangeColor.CGColor;
    [self.layer addSublayer:_volumeDiagnostics];
    [self updateOrangeBar];
    return self;
}
- (void)dealloc {
    [_holdTimer invalidate];
    [_displayLink invalidate];
    if (_gainObserver) [[NSNotificationCenter defaultCenter] removeObserver:_gainObserver];
}
- (BOOL)sourceIsVisible {
    UIView *view = self.sourceView;
    if (!view || !view.window) return NO;
    for (UIView *v = view; v != nil; v = v.superview) {
        if (v.hidden || v.alpha < 0.08) return NO;
    }
    return YES;
}
- (void)refreshLayout {
    UIView *source = self.sourceView;
    UIWindow *window = source.window;
    if (!source || !window) {
        if (self.superview) [self removeFromSuperview];
        return;
    }
    if (self.superview != window) [window addSubview:self];
    CGRect track = [source convertRect:source.bounds toView:window];
    if (CGRectIsNull(track) || CGRectIsEmpty(track)) {
        self.hidden = YES;
        return;
    }
    CGRect padded = CGRectInset(track, 0, -12);
    if (!CGRectEqualToRect(self.frame, padded)) self.frame = padded;
    CGRect windowBounds = window.bounds;
    self.hidden = ![self sourceIsVisible] || !CGRectIntersectsRect(padded, windowBounds);
    if (!self.hidden) [self updateOrangeBar];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateOrangeBar];
}
- (void)updateOrangeBar {
    CGFloat width = MAX(0, self.bounds.size.width - 8);
    CGFloat centerY = self.bounds.size.height * 0.5;
    CGFloat lineY = centerY + 6;
    CGFloat thickness = self.mode == BCHTouchApp ? 4.5 : 2.5;
    CGFloat gain = BCHClamp((float)self.displayedGain);
    self.orangeBackground.frame = CGRectMake(4, lineY, width, thickness);
    self.orangeBackground.cornerRadius = thickness/2;
    self.orangeFill.frame = CGRectMake(4, lineY, width*gain, thickness);
    self.orangeFill.cornerRadius = thickness/2;
    CGFloat dot = self.mode == BCHTouchApp ? 10 : 5;
    CGFloat x = 4 + fmax(0, fmin(width-dot/2, width*gain-dot/2));
    self.orangeDot.frame = CGRectMake(x, lineY+(thickness-dot)/2, dot, dot);
    self.orangeDot.cornerRadius = dot/2;
    // Diagnostic only: read the ACTUAL AVPlayer output volume after applying gain.
    // This does not change native AVPlayer.muted or the audio session.
    NSArray<AVPlayer *> *decks;
    @synchronized(gActivePlayers){decks=[gActivePlayers.allObjects copy];}
    float observed=-1;
    for(AVPlayer *deck in decks) {
        if(origGetVolume) { observed=origGetVolume(deck,@selector(volume)); break; }
    }
    self.volumeDiagnostics.frame=CGRectMake(0,MAX(0,centerY-27),self.bounds.size.width,16);
    self.volumeDiagnostics.string=[NSString stringWithFormat:@"BitChord %d%% · 재생기 %lu · 엔진 %.2f",
               (int)roundf(gain*100),(unsigned long)decks.count,observed];
    self.volumeDiagnostics.hidden=self.mode != BCHTouchApp;
    self.accessibilityValue =
        [NSString stringWithFormat:@"BitChord %d percent", (int)roundf(gain*100)];
}
- (UISlider *)findSliderInView:(UIView *)view {
    if ([view isKindOfClass:UISlider.class]) return (UISlider *)view;
    for (UIView *child in view.subviews) {
        UISlider *slider = [self findSliderInView:child];
        if (slider) return slider;
    }
    return nil;
}
- (void)changeSystemVolumeAt:(CGPoint)point {
    CGFloat width = MAX(1, self.bounds.size.width - 8);
    float level = BCHClamp((point.x-4)/width);
    [self.systemVolumeView layoutIfNeeded];
    UISlider *slider = [self findSliderInView:self.systemVolumeView];
    if (!slider) {
        // The system volume view is lazily populated on some OS releases.
        [self.systemVolumeView setNeedsLayout];
        [self.systemVolumeView layoutIfNeeded];
        slider = [self findSliderInView:self.systemVolumeView];
    }
    if (!slider) {
        NSLog(@"[BCHDualVolume] MPVolumeView slider not ready");
        return;
    }
    [slider setValue:level animated:NO];
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)changeAppVolumeAt:(CGPoint)point {
    CGFloat width = MAX(1, self.bounds.size.width - 8);
    BCHUpdateAppGain((float)((point.x-4)/width));
}
- (void)cancelHoldTimer {
    [self.holdTimer invalidate];
    self.holdTimer = nil;
}
- (void)holdThresholdReached {
    self.holdTimer = nil;
    if (self.mode != BCHTouchArmed) return;
    self.mode = BCHTouchApp;
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurredWithIntensity:0.8];
    [self updateOrangeBar];
    NSLog(@"[BCHDualVolume] long hold recognized");
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    [self cancelHoldTimer];
    self.mode = BCHTouchArmed;
    self.initialTouch = [touch locationInView:self];
    self.holdTimer = [NSTimer timerWithTimeInterval:0.42
                                           target:self
                                         selector:@selector(holdThresholdReached)
                                         userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.holdTimer forMode:NSRunLoopCommonModes];
    [self updateOrangeBar];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    CGPoint point = [touch locationInView:self];
    if (self.mode == BCHTouchArmed &&
        hypot(point.x-self.initialTouch.x, point.y-self.initialTouch.y) > 9) {
        [self cancelHoldTimer];
        self.mode = BCHTouchSystem;
    }
    if (self.mode == BCHTouchSystem) [self changeSystemVolumeAt:point];
    if (self.mode == BCHTouchApp) [self changeAppVolumeAt:point];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = touches.anyObject;
    if (touch && (self.mode == BCHTouchArmed || self.mode == BCHTouchSystem))
        [self changeSystemVolumeAt:[touch locationInView:self]];
    [self cancelHoldTimer];
    self.mode = BCHTouchIdle;
    [self updateOrangeBar];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    [self cancelHoldTimer];
    self.mode = BCHTouchIdle;
    [self updateOrangeBar];
}
- (void)accessibilityIncrement {
    [self changeSystemVolumeAt:CGPointMake(4 + (AVAudioSession.sharedInstance.outputVolume+0.05) *
                                          MAX(1,self.bounds.size.width-8), self.bounds.size.height/2)];
}
- (void)accessibilityDecrement {
    [self changeSystemVolumeAt:CGPointMake(4 + (AVAudioSession.sharedInstance.outputVolume-0.05) *
                                          MAX(1,self.bounds.size.width-8), self.bounds.size.height/2)];
}
- (BOOL)accessibilityIncreaseApp {
    BCHUpdateAppGain(gAppGain+0.05);
    return YES;
}
- (BOOL)accessibilityDecreaseApp {
    BCHUpdateAppGain(gAppGain-0.05);
    return YES;
}
@end

static void BCHInstallOverlay(UIView *source) {
    BCHVolumeTouchSurface *surface =
        objc_getAssociatedObject(source, kBCHOverlayKey);
    if (!surface) {
        surface = [[BCHVolumeTouchSurface alloc] initWithSourceView:source];
        objc_setAssociatedObject(source, kBCHOverlayKey, surface,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [surface refreshLayout];
}
static void BCHLayoutHook(id self, SEL cmd) {
    if (origLayout) origLayout(self, cmd);
    BCHInstallOverlay((UIView *)self);
}
static void BCHDidMoveHook(id self, SEL cmd) {
    if (origDidMoveToWindow) origDidMoveToWindow(self, cmd);
    BCHInstallOverlay((UIView *)self);
}
static void BCHSwizzle(Class cls, SEL sel, IMP newImp, IMP *original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[BCHDualVolume] Missing selector %@", NSStringFromSelector(sel));
        return;
    }
    // Swift subclasses may inherit UIView's didMoveToWindow. Never swap
    // the superclass's method for ALL UIView instances.
    IMP before = method_getImplementation(m);
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        *original = before;  // subclass-local override of inherited method
    } else {
        *original = method_setImplementation(m, newImp);
    }
}
__attribute__((constructor)) static void BCHLoad(void) {
    @autoreleasepool {
        gActivePlayers = [NSHashTable weakObjectsHashTable];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        // One-time gain reset protects existing v4 users against saved 0% silence.
        if (![defaults boolForKey:@"com.choesunbeom.BitChord.dualVolume.v5Reset"]) {
            gAppGain=1.0f;
            [defaults setFloat:gAppGain forKey:kBCHGainKey];
            [defaults setBool:YES forKey:@"com.choesunbeom.BitChord.dualVolume.v5Reset"];
        } else if ([defaults objectForKey:kBCHGainKey]) {
            gAppGain=BCHClamp([defaults floatForKey:kBCHGainKey]);
        }
        Class player = AVPlayer.class;
        BCHSwizzle(player, @selector(setVolume:), (IMP)BCHSetVolume,
                   (IMP *)&origSetVolume);
        BCHSwizzle(player, @selector(volume), (IMP)BCHGetVolume,
                   (IMP *)&origGetVolume);
        BCHSwizzle(player, @selector(play), (IMP)BCHPlay,
                   (IMP *)&origPlay);
        BCHSwizzle(player, @selector(playImmediatelyAtRate:), (IMP)BCHPlayRate,
                   (IMP *)&origPlayRate);
        BCHSwizzle(player, @selector(init), (IMP)BCHPlayerInit,
                   (IMP *)&origPlayerInit);
        BCHSwizzle(player, @selector(initWithPlayerItem:), (IMP)BCHInitWithItem,
                   (IMP *)&origInitWithPlayerItem);
        BCHSwizzle(player, @selector(setRate:), (IMP)BCHSetRate,
                   (IMP *)&origSetRate);
        BCHSwizzle(player, @selector(replaceCurrentItemWithPlayerItem:),
                   (IMP)BCHReplaceItem,(IMP *)&origReplaceItem);
        Class queue=AVQueuePlayer.class;
        BCHSwizzle(queue,@selector(initWithItems:),(IMP)BCHQueueInitWithItems,
                   (IMP *)&origQueueInitWithItems);
        BCHSwizzle(queue,@selector(insertItem:afterItem:),(IMP)BCHQueueInsertItem,
                   (IMP *)&origQueueInsert);
        Class view = objc_getClass("_TtC8BitChord17CentredVolumeView");
        if (view) {
            BCHSwizzle(view, @selector(layoutSubviews), (IMP)BCHLayoutHook,
                       (IMP *)&origLayout);
            BCHSwizzle(view, @selector(didMoveToWindow), (IMP)BCHDidMoveHook,
                       (IMP *)&origDidMoveToWindow);
        } else {
            NSLog(@"[BCHDualVolume] CentredVolumeView not found");
        }
        NSLog(@"[BCHDualVolume] v5 playback restore without AVPlayer.muted override; gain=%f",
              gAppGain);
    }
}
