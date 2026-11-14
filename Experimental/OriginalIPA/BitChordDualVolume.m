#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// Original BitChord-KR 1.0.2 (build 40) IPA only; not the public Apple port.
// White native MPVolumeView track: unchanged iOS system volume.
// 420ms hold: haptic, then horizontal movement changes app-only orange gain.
// App attenuation is applied to AVQueuePlayer (AVPlayer subclass) so that
// existing crossfade values and the original mixWithOthers setting survive.

static NSString *const kGainKey=@"com.choesunbeom.BitChord.dualVolume.gain";
static float gGain=1.0f;
static NSHashTable<AVPlayer *> *gPlayers;
static IMP oldLayout;
static void (*oldSet)(id,SEL,float);
static float (*oldGet)(id,SEL);
static void (*oldPlay)(id,SEL);
static void (*oldPlayRate)(id,SEL,float);
static const void *baseKey=&baseKey,*tagKey=&tagKey,*targetKey=&targetKey;
static const void *barBaseKey=&barBaseKey,*barFillKey=&barFillKey,*barDotKey=&barDotKey;
static float clampGain(float v){return isfinite(v)?fmaxf(0,fminf(1,v)):1;}
static float baseVolume(AVPlayer *p){
  NSNumber *n=objc_getAssociatedObject(p,baseKey);
  return n?n.floatValue:(oldGet?oldGet(p,@selector(volume)):1);
}
static void applyPlayer(AVPlayer *p){
  if(p&&oldSet) oldSet(p,@selector(setVolume:),clampGain(baseVolume(p)*gGain));
}
static void registerPlayer(AVPlayer *p){
  if(!p||!gPlayers)return;
  @synchronized(gPlayers){[gPlayers addObject:p];}
  if(!objc_getAssociatedObject(p,baseKey))
    objc_setAssociatedObject(p,baseKey,@(clampGain(baseVolume(p))),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  applyPlayer(p);
}
static void setPlayerVolume(id self,SEL cmd,float v){
  objc_setAssociatedObject(self,baseKey,@(clampGain(v)),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if(gPlayers)@synchronized(gPlayers){[gPlayers addObject:self];}
  if(oldSet)oldSet(self,cmd,clampGain(v*gGain));
}
static float getPlayerVolume(id self,SEL cmd){
  NSNumber *n=objc_getAssociatedObject(self,baseKey);
  return n?n.floatValue:(oldGet?oldGet(self,cmd):1);
}
static void playerPlay(id self,SEL cmd){registerPlayer(self);if(oldPlay)oldPlay(self,cmd);}
static void playerPlayRate(id self,SEL cmd,float rate){registerPlayer(self);if(oldPlayRate)oldPlayRate(self,cmd,rate);}

static void updateBar(UIView *view){
  CALayer *base=objc_getAssociatedObject(view,barBaseKey);
  CALayer *fill=objc_getAssociatedObject(view,barFillKey);
  CALayer *dot=objc_getAssociatedObject(view,barDotKey);
  if(!base||!fill||!dot)return;
  CGFloat w=MAX(0,view.bounds.size.width-8),h=view.bounds.size.height;
  CGFloat y=MIN(h-2,MAX(h/2+5,1));
  UILongPressGestureRecognizer *r=objc_getAssociatedObject(view,tagKey);
  BOOL active=r&&(r.state==UIGestureRecognizerStateBegan||r.state==UIGestureRecognizerStateChanged);
  CGFloat t=active?4:2.5;
  base.frame=CGRectMake(4,y,w,t);base.cornerRadius=t/2;
  fill.frame=CGRectMake(4,y,w*gGain,t);fill.cornerRadius=t/2;
  CGFloat s=active?8:5;
  dot.frame=CGRectMake(4+MAX(0,MIN(w-s/2,w*gGain-s/2)),y-(s-t)/2,s,s);
  dot.cornerRadius=s/2;
}
static void updateGain(float value){
  gGain=clampGain(value);
  [[NSUserDefaults standardUserDefaults]setFloat:gGain forKey:kGainKey];
  NSArray *players;@synchronized(gPlayers){players=gPlayers.allObjects;}
  for(AVPlayer *p in players)applyPlayer(p);
  [[NSNotificationCenter defaultCenter]postNotificationName:@"BCHDualVolumeGainUpdated" object:nil];
}
@interface BCHDualGestureTarget : NSObject
@property(nonatomic,weak)UIView *host;
@property(nonatomic,strong)id observer;
- (instancetype)initWithHost:(UIView*)host;
- (void)onHold:(UILongPressGestureRecognizer*)r;
@end
@implementation BCHDualGestureTarget
- (instancetype)initWithHost:(UIView*)host{
  if((self=[super init])){
    _host=host;
    __weak UIView *weakHost=host;
    _observer=[[NSNotificationCenter defaultCenter]
      addObserverForName:@"BCHDualVolumeGainUpdated" object:nil
      queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){
        (void)note;updateBar(weakHost);
      }];
  }return self;
}
- (void)dealloc{if(_observer)[[NSNotificationCenter defaultCenter]removeObserver:_observer];}
- (void)onHold:(UILongPressGestureRecognizer*)r{
  UIView *v=self.host;if(!v)return;
  if(r.state==UIGestureRecognizerStateBegan){
    UIImpactFeedbackGenerator *h=[[UIImpactFeedbackGenerator alloc]initWithStyle:UIImpactFeedbackStyleMedium];
    [h prepare];[h impactOccurred];updateBar(v);
  }else if(r.state==UIGestureRecognizerStateChanged){
    CGFloat w=v.bounds.size.width;
    if(w>8)updateGain((float)(([r locationInView:v].x-4)/(w-8)));
    updateBar(v);
  }else if(r.state==UIGestureRecognizerStateEnded||
           r.state==UIGestureRecognizerStateCancelled||
           r.state==UIGestureRecognizerStateFailed){updateBar(v);}
}
@end
static void installOnView(UIView *v){
  if(objc_getAssociatedObject(v,tagKey)){updateBar(v);return;}
  BCHDualGestureTarget *target=[[BCHDualGestureTarget alloc]initWithHost:v];
  UILongPressGestureRecognizer *hold=[[UILongPressGestureRecognizer alloc]
    initWithTarget:target action:@selector(onHold:)];
  hold.minimumPressDuration=0.42;
  hold.allowableMovement=26;
  hold.cancelsTouchesInView=YES;
  [v addGestureRecognizer:hold];
  objc_setAssociatedObject(v,tagKey,hold,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(v,targetKey,target,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  UIColor *orange=[UIColor colorWithRed:1 green:0.54 blue:0.10 alpha:1];
  CALayer *base=[CALayer layer],*fill=[CALayer layer],*dot=[CALayer layer];
  base.backgroundColor=[orange colorWithAlphaComponent:0.30].CGColor;
  fill.backgroundColor=orange.CGColor;dot.backgroundColor=orange.CGColor;
  base.zPosition=1000;fill.zPosition=1001;dot.zPosition=1002;
  [v.layer addSublayer:base];[v.layer addSublayer:fill];[v.layer addSublayer:dot];
  objc_setAssociatedObject(v,barBaseKey,base,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(v,barFillKey,fill,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(v,barDotKey,dot,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  updateBar(v);
}
static void layoutHook(id v,SEL sel){
  if(oldLayout)((void(*)(id,SEL))oldLayout)(v,sel);
  installOnView(v);
}
static void swizzle(Class cls,SEL sel,IMP replacement,IMP *original){
  Method method=class_getInstanceMethod(cls,sel);
  if(method)*original=method_setImplementation(method,replacement);
  else NSLog(@"[BCHDualVolume] missing selector %@",NSStringFromSelector(sel));
}
__attribute__((constructor))static void initDualVolume(void){
  @autoreleasepool{
    gPlayers=[NSHashTable weakObjectsHashTable];
    if([[NSUserDefaults standardUserDefaults]objectForKey:kGainKey])
      gGain=clampGain([[NSUserDefaults standardUserDefaults]floatForKey:kGainKey]);
    Class cls=[AVPlayer class];
    swizzle(cls,@selector(setVolume:),(IMP)setPlayerVolume,(IMP*)&oldSet);
    swizzle(cls,@selector(volume),(IMP)getPlayerVolume,(IMP*)&oldGet);
    swizzle(cls,@selector(play),(IMP)playerPlay,(IMP*)&oldPlay);
    swizzle(cls,@selector(playImmediatelyAtRate:),(IMP)playerPlayRate,(IMP*)&oldPlayRate);
    Class native=objc_getClass("_TtC8BitChord17CentredVolumeView");
    if(native)swizzle(native,@selector(layoutSubviews),(IMP)layoutHook,&oldLayout);
    else NSLog(@"[BCHDualVolume] no original Swift CentredVolumeView");
    NSLog(@"[BCHDualVolume] original IPA extension loaded, gain=%f",gGain);
  }
}
