#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

#import "rg_date_filter.h"

#import <objc/runtime.h>

static NSString *const kRDFDaysKey = @"RDFDays";

static char kRDFOrigIMPKey;
static char kRDFEntryKey;
static NSString *const kRDFHostKey = @"rdf.host";

static UIViewController *RDFTopViewController(void);

static __weak id gRDFLastAdapter;
static NSMutableArray<NSString *> *gRDFRecentSources;
static NSMutableDictionary<NSString *, NSString *> *gRDFStats;

#pragma mark - Instagram surface (declared, not implemented here)

@interface IGListAdapter : NSObject
- (void)setDataSource:(id)dataSource;
@end

@interface IGProfileViewController : UIViewController
@end

#pragma mark - Model plumbing

// Profile grid objects expose the media through several wrappers depending on
// the Instagram build; try the known key paths in order.
static NSDate *RDFDateFromIvars(id object, NSInteger depth);

static NSDate *RDFTakenAtForObject(id object)
{
    static NSArray<NSString *> *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[
            @"media.takenAtDate",
            @"media.takenAt",
            @"feedItem.media.takenAtDate",
            @"viewModel.media.takenAtDate",
            @"model.media.takenAtDate",
            @"_media.takenAtDate",
            @"takenAtDate",
            @"takenAt"
        ];
    });

    for (NSString *path in paths) {
        @try {
            id value = [object valueForKeyPath:path];
            if ([value isKindOfClass:[NSDate class]]) return value;
            if ([value isKindOfClass:[NSNumber class]]) {
                double stamp = [value doubleValue];
                // Guard against millisecond timestamps and zero placeholders.
                if (stamp > 1000000000.0) {
                    if (stamp > 100000000000.0) stamp /= 1000.0;
                    return [NSDate dateWithTimeIntervalSince1970:stamp];
                }
            }
        } @catch (__unused NSException *exception) {
            // KVC throws for unknown keys on some Swift-backed wrappers.
        }
    }
    return RDFDateFromIvars(object, 0);
}

// Explore items (IGDiscoveryGridItem) do not expose takenAtDate on the same key
// paths as profile media, so fall back to scanning ivars whose names suggest a
// timestamp. Depth is capped to keep this cheap.
static NSDate *RDFDateFromIvars(id object, NSInteger depth)
{
    if (!object || depth > 2) return nil;

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([object class], &count);
    if (!ivars) return nil;

    // First pass: containers such as _media / _model / _viewModel hold the date.
    static NSArray<NSString *> *containers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        containers = @[ @"media", @"model", @"item", @"viewmodel", @"griditem", @"feeditem", @"aweme" ];
    });

    NSDate *found = nil;
    for (unsigned int i = 0; i < count && !found; i++) {
        const char *raw = ivar_getName(ivars[i]);
        if (!raw) continue;
        NSString *name = [[NSString stringWithUTF8String:raw] lowercaseString];

        BOOL isContainer = NO;
        for (NSString *hint in containers) {
            if ([name containsString:hint]) { isContainer = YES; break; }
        }
        if (!isContainer) continue;

        @try {
            id value = object_getIvar(object, ivars[i]);
            if (value && ![value isKindOfClass:[NSString class]]) {
                found = RDFDateFromIvars(value, depth + 1);
            }
        } @catch (__unused NSException *exception) {}
    }

    // Second pass: timestamp-named fields on this object.
    for (unsigned int i = 0; i < count && !found; i++) {
        const char *raw = ivar_getName(ivars[i]);
        if (!raw) continue;
        NSString *name = [[NSString stringWithUTF8String:raw] lowercaseString];
        if (!([name containsString:@"time"] || [name containsString:@"date"] || [name containsString:@"taken"])) continue;

        @try {
            id value = object_getIvar(object, ivars[i]);
            if ([value isKindOfClass:[NSDate class]]) {
                found = value;
            } else if ([value isKindOfClass:[NSNumber class]]) {
                double stamp = [value doubleValue];
                if (stamp > 1000000000.0) {
                    if (stamp > 100000000000.0) stamp /= 1000.0;
                    found = [NSDate dateWithTimeIntervalSince1970:stamp];
                }
            }
        } @catch (__unused NSException *exception) {}
    }

    free(ivars);
    return found;
}

static BOOL RDFLooksLikeProfileReels(id dataSource, NSArray *objects)
{
    NSString *sourceName = NSStringFromClass([dataSource class]);
    if ([sourceName containsString:@"Sundial"] ||
        [sourceName containsString:@"Reel"] ||
        [sourceName containsString:@"Clip"]) {
        return YES;
    }

    for (id object in objects) {
        NSString *name = NSStringFromClass([object class]);
        if ([name containsString:@"Sundial"] ||
            [name containsString:@"Reel"] ||
            [name containsString:@"Clip"]) {
            return YES;
        }
    }
    return NO;
}


#pragma mark - Scope

typedef NS_OPTIONS(NSInteger, RDFSurface) {
    RDFSurfaceNone    = 0,
    RDFSurfaceHome    = 1 << 0,
    RDFSurfaceReels   = 1 << 1,
    RDFSurfaceSearch  = 1 << 2,
    RDFSurfaceProfile = 1 << 3,
};

static NSString *RDFSurfaceName(RDFSurface surface)
{
    switch (surface) {
        case RDFSurfaceHome: return @"首页";
        case RDFSurfaceReels: return @"Reels";
        case RDFSurfaceSearch: return @"搜索 / 发现";
        case RDFSurfaceProfile: return @"个人主页";
        default: return @"未识别";
    }
}

static NSString *RDFDaysKeyForSurface(RDFSurface surface)
{
    switch (surface) {
        case RDFSurfaceHome: return @"RDFDaysHome";
        case RDFSurfaceReels: return @"RDFDaysReels";
        case RDFSurfaceSearch: return @"RDFDaysSearch";
        case RDFSurfaceProfile: return @"RDFDaysProfile";
        default: return kRDFDaysKey;
    }
}

static double RDFDaysForSurface(RDFSurface surface)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *key = RDFDaysKeyForSurface(surface);
    NSNumber *stored = [defaults objectForKey:key];
    if (stored) return stored.doubleValue;
    // Legacy single value: use it until this surface gets its own.
    return [defaults doubleForKey:kRDFDaysKey];
}

static void RDFSetDaysForSurface(RDFSurface surface, double days)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:days forKey:RDFDaysKeyForSurface(surface)];
    [defaults synchronize];
}

static NSString *const kRDFScopeKey = @"RDFScope";

static NSInteger RDFScopeMask(void)
{
    NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kRDFScopeKey];
    if (!stored) return RDFSurfaceHome | RDFSurfaceReels | RDFSurfaceSearch;
    return stored.integerValue;
}

static void RDFSetScopeMask(NSInteger mask)
{
    [[NSUserDefaults standardUserDefaults] setInteger:mask forKey:kRDFScopeKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// The surface is derived from the controller that owns the list, not from the
// data source class: Explore and profile reels share model types, and filtering
// by class name was what pulled Explore into the filter.
static RDFSurface RDFSurfaceForAdapter(id adapter, id dataSource)
{
    UIView *view = nil;
    for (NSString *key in @[@"collectionView", @"_collectionView"]) {
        @try {
            id candidate = [adapter valueForKey:key];
            if ([candidate isKindOfClass:[UIView class]]) { view = candidate; break; }
        } @catch (__unused NSException *exception) {}
    }
    if (!view) {
        for (NSString *key in @[@"collectionView", @"_collectionView"]) {
            @try {
                id candidate = [dataSource valueForKey:key];
                if ([candidate isKindOfClass:[UIView class]]) { view = candidate; break; }
            } @catch (__unused NSException *exception) {}
        }
    }
    if (![view isKindOfClass:[UIView class]]) return RDFSurfaceNone;

    const char *names[32];
    size_t count = 0;
    UIResponder *responder = view;
    while (responder && count < 32) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            names[count++] = class_getName([responder class]);
        }
        responder = [responder nextResponder];
    }
    if (count == 0) return RDFSurfaceNone;
    return (RDFSurface)rg_surface_resolve(names, count);
}

static RDFSurface RDFSurfaceForDataSourceClass(id dataSource)
{
    NSString *name = NSStringFromClass([dataSource class]);
    if ([name containsString:@"Explore"] || [name containsString:@"Discovery"]) return RDFSurfaceSearch;
    if ([name containsString:@"MainFeed"]) return RDFSurfaceHome;
    if ([name containsString:@"Profile"]) return RDFSurfaceProfile;
    if ([name containsString:@"Sundial"]) return RDFSurfaceReels;
    return RDFSurfaceNone;
}

static NSArray *RDFFilteredObjects(id dataSource, NSArray *objects, id adapter)
{
    if (objects.count == 0) return objects;

    RDFSurface surface = RDFSurfaceForAdapter(adapter, dataSource);
    if (surface == RDFSurfaceNone) surface = RDFSurfaceForDataSourceClass(dataSource);
    if (surface == RDFSurfaceNone) {
        static NSMutableSet *logged;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ logged = [NSMutableSet set]; });
        NSString *name = NSStringFromClass([dataSource class]);
        @synchronized (logged) {
            if (![logged containsObject:name]) {
                [logged addObject:name];
                NSLog(@"[RDF] unknown surface: %@", name);
            }
        }
        return objects;
    }
    if ((RDFScopeMask() & surface) == 0) return objects;

    double days = RDFDaysForSurface(surface);
    if (fabs(days) < RG_FILTER_MIN_DAYS) return objects;

    // Profile and reels are gated by model names to avoid touching unrelated
    // lists. Explore items are IGDiscoveryGridItem, so that gate has to be
    // skipped there; undated items are still kept by the filter itself.
    if (surface != RDFSurfaceSearch && !RDFLooksLikeProfileReels(dataSource, objects)) return objects;

    RGDateFilter filter = rg_filter_make(days);
    NSDate *now = [NSDate date];
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:objects.count];

    NSUInteger dated = 0;
    for (id object in objects) {
        NSDate *takenAt = RDFTakenAtForObject(object);
        if (!takenAt) {
            // Never drop an item we cannot date; better to over-show than to lose content.
            [kept addObject:object];
            continue;
        }
        dated++;
        NSTimeInterval age = [now timeIntervalSinceDate:takenAt];
        if (rg_filter_should_keep(filter, age)) [kept addObject:object];
    }

    @synchronized ([NSNull null]) {
        if (!gRDFStats) gRDFStats = [NSMutableDictionary dictionary];
        gRDFStats[NSStringFromClass([dataSource class])] =
            [NSString stringWithFormat:@"s=%ld n=%lu d=%lu k=%lu",
             (long)surface, (unsigned long)objects.count,
             (unsigned long)dated, (unsigned long)kept.count];
    }

    return kept;
}

#pragma mark - Data source swizzle

static NSArray *RDFObjectsForListAdapter(id self, SEL _cmd, id adapter)
{
    NSValue *stored = objc_getAssociatedObject([self class], &kRDFOrigIMPKey);
    IMP original = stored ? (IMP)[stored pointerValue] : NULL;
    if (!original) return nil;

    NSArray *objects = ((NSArray *(*)(id, SEL, id))original)(self, _cmd, adapter);
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0) return objects;

    NSArray *filtered = RDFFilteredObjects(self, objects, adapter);
    if (filtered.count != objects.count) {
        NSLog(@"[RDF] surface=%ld %@ -> %lu/%lu (days=%g)",
              (long)RDFSurfaceForAdapter(adapter, self),
              NSStringFromClass([self class]),
              (unsigned long)filtered.count,
              (unsigned long)objects.count,
              RDFDaysForSurface(RDFSurfaceForAdapter(adapter, self)));
    }
    return filtered;
}

static void RDFInstallDataSource(id dataSource)
{
    if (!dataSource) return;
    Class cls = [dataSource class];
    if (!cls) return;
    if (objc_getAssociatedObject(cls, &kRDFOrigIMPKey)) return;

    SEL selector = NSSelectorFromString(@"objectsForListAdapter:");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

    IMP original = method_getImplementation(method);
    objc_setAssociatedObject(cls, &kRDFOrigIMPKey,
                             [NSValue valueWithPointer:(const void *)original],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    class_replaceMethod(cls, selector, (IMP)RDFObjectsForListAdapter, method_getTypeEncoding(method));

    @synchronized ([NSNull null]) {
        if (!gRDFRecentSources) gRDFRecentSources = [NSMutableArray array];
        NSString *name = NSStringFromClass(cls);
        [gRDFRecentSources removeObject:name];
        [gRDFRecentSources insertObject:name atIndex:0];
        if (gRDFRecentSources.count > 12) [gRDFRecentSources removeLastObject];
    }
    NSLog(@"[RDF] hooked data source %@", NSStringFromClass(cls));
}

static void RDFReloadLists(void)
{
    id adapter = gRDFLastAdapter;
    if (!adapter) return;

    @try {
        SEL update = NSSelectorFromString(@"performUpdatesAnimated:completion:");
        if ([adapter respondsToSelector:update]) {
            void (*call)(id, SEL, BOOL, id) = (void (*)(id, SEL, BOOL, id))objc_msgSend;
            call(adapter, update, NO, nil);
            return;
        }
        SEL reload = NSSelectorFromString(@"reloadDataWithCompletion:");
        if ([adapter respondsToSelector:reload]) {
            void (*call)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            call(adapter, reload, nil);
        }
    } @catch (__unused NSException *exception) {
        NSLog(@"[RDF] reload failed: %@", exception);
    }
}

#pragma mark - Settings sheet


#pragma mark - Input sheet with live conversion

static NSString *RDFHumanDuration(double days)
{
    double magnitude = fabs(days);
    if (magnitude < RG_FILTER_MIN_DAYS) return @"关闭";

    long totalMinutes = lround(magnitude * 1440.0);
    if (totalMinutes < 1) return @"不到 1 分钟";

    long d = totalMinutes / 1440;
    long h = (totalMinutes % 1440) / 60;
    long m = totalMinutes % 60;

    NSMutableString *text = [NSMutableString string];
    if (d > 0) {
        [text appendFormat:@"%ld 天", d];
        if (h > 0) [text appendFormat:@" %ld 小时", h];
    } else if (h > 0) {
        [text appendFormat:@"%ld 小时", h];
        if (m > 0) [text appendFormat:@" %ld 分钟", m];
    } else {
        [text appendFormat:@"%ld 分钟", m];
    }
    return text;
}

@interface RDFInputViewController : UIViewController
@property (nonatomic) double initialDays;
@property (nonatomic) RDFSurface surface;
@property (nonatomic, copy) void (^onCommit)(double days);
@end

@implementation RDFInputViewController {
    UIView *_dim;
    UIView *_card;
    UITextField *_field;
    UIView *_convBox;
    UILabel *_convValue;
    UILabel *_convBadge;
    UILabel *_errorLabel;
    NSArray<UIButton *> *_chips;
    CGFloat _keyboardInset;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;

    _dim = [[UIView alloc] initWithFrame:self.view.bounds];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_dim];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = [UIColor colorWithWhite:0.17 alpha:0.98];
    _card.layer.cornerRadius = 16;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:_card];

    NSString *titleText = [NSString stringWithFormat:@"%@ · 过滤时长", RDFSurfaceName(self.surface)];
    UILabel *title = [self labelWithText:titleText size:16 weight:UIFontWeightSemibold color:UIColor.whiteColor];
    title.frame = CGRectMake(0, 18, 306, 22);
    title.textAlignment = NSTextAlignmentCenter;
    [_card addSubview:title];

    UILabel *subtitle = [self labelWithText:@"正数 = 最近 N 天，负数 = N 天以前，0 = 关闭" size:11.5 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.62 alpha:1]];
    subtitle.frame = CGRectMake(10, 43, 286, 16);
    subtitle.textAlignment = NSTextAlignmentCenter;
    [_card addSubview:subtitle];

    _field = [[UITextField alloc] initWithFrame:CGRectMake(16, 66, 274, 46)];
    _field.backgroundColor = [UIColor colorWithWhite:0 alpha:0.32];
    _field.layer.cornerRadius = 10;
    _field.layer.borderWidth = 1;
    _field.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    _field.textColor = UIColor.whiteColor;
    _field.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    _field.textAlignment = NSTextAlignmentCenter;
    _field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _field.placeholder = @"10 / 0.5 / -10";
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    [_field addTarget:self action:@selector(textChanged:) forControlEvents:UIControlEventEditingChanged];
    [_card addSubview:_field];

    _convBox = [[UIView alloc] initWithFrame:CGRectMake(16, 120, 274, 56)];
    _convBox.backgroundColor = [UIColor colorWithRed:0.49 green:0.23 blue:0.93 alpha:0.20];
    _convBox.layer.cornerRadius = 10;
    _convBox.layer.borderWidth = 1;
    _convBox.layer.borderColor = [UIColor colorWithRed:0.49 green:0.23 blue:0.93 alpha:0.45].CGColor;
    [_card addSubview:_convBox];

    UILabel *convTitle = [self labelWithText:@"约等于" size:10.5 weight:UIFontWeightRegular color:[UIColor colorWithRed:0.72 green:0.66 blue:0.90 alpha:1]];
    convTitle.frame = CGRectMake(12, 9, 160, 14);
    [_convBox addSubview:convTitle];

    _convValue = [self labelWithText:@"" size:14.5 weight:UIFontWeightSemibold color:UIColor.whiteColor];
    _convValue.frame = CGRectMake(12, 25, 170, 20);
    [_convBox addSubview:_convValue];

    _convBadge = [self labelWithText:@"" size:10.5 weight:UIFontWeightMedium color:[UIColor colorWithRed:0.86 green:0.82 blue:1 alpha:1]];
    _convBadge.textAlignment = NSTextAlignmentCenter;
    _convBadge.backgroundColor = [UIColor colorWithRed:0.49 green:0.23 blue:0.93 alpha:0.45];
    _convBadge.layer.cornerRadius = 10;
    _convBadge.clipsToBounds = YES;
    _convBadge.frame = CGRectMake(206, 16, 56, 22);
    [_convBox addSubview:_convBadge];

    _errorLabel = [self labelWithText:@"" size:10.5 weight:UIFontWeightRegular color:[UIColor colorWithRed:1 green:0.55 blue:0.5 alpha:1]];
    _errorLabel.frame = CGRectMake(16, 180, 274, 14);
    [_card addSubview:_errorLabel];

    NSArray *titles = @[@"0.5", @"1", @"7", @"10", @"30", @"-10"];
    NSMutableArray *chips = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        [chip setTitle:titles[i] forState:UIControlStateNormal];
        [chip setTitleColor:[UIColor colorWithWhite:0.88 alpha:1] forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:11.5];
        chip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
        chip.layer.cornerRadius = 13;
        chip.layer.borderWidth = 1;
        chip.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:chip];
        [chips addObject:chip];
    }
    _chips = chips;

    NSArray *actions = @[@"清除", @"取消", @"保存"];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < actions.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setTitle:actions[i] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:i == 2 ? 15.5 : 15 weight:i == 2 ? UIFontWeightSemibold : UIFontWeightRegular];
        UIColor *color = i == 0 ? [UIColor colorWithRed:1 green:0.27 blue:0.23 alpha:1] : [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1];
        [button setTitleColor:color forState:UIControlStateNormal];
        [button addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
        button.tag = 100 + i;
        [_card addSubview:button];
        [buttons addObject:button];
    }

    UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    separator.tag = 55;
    [_card addSubview:separator];

    _field.text = self.initialDays != 0 ? [NSString stringWithFormat:@"%g", self.initialDays] : @"";
    [self refreshConversion];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = 306, height = 374;
    CGFloat x = (CGRectGetWidth(self.view.bounds) - width) / 2;
    CGFloat y = (CGRectGetHeight(self.view.bounds) - height) / 2;
    if (_keyboardInset > 0) {
        y = MIN(y, CGRectGetHeight(self.view.bounds) - _keyboardInset - height - 10);
        y = MAX(24, y);
    }
    _card.frame = CGRectMake(x, y, width, height);

    CGFloat chipWidth = 42, gap = 6;
    CGFloat total = 6 * chipWidth + 5 * gap;
    CGFloat startX = (width - total) / 2;
    for (NSUInteger i = 0; i < _chips.count; i++) {
        _chips[i].frame = CGRectMake(startX + i * (chipWidth + gap), 202, chipWidth, 26);
    }

    UIView *separator = [_card viewWithTag:55];
    separator.frame = CGRectMake(0, 330, width, 1);

    CGFloat buttonWidth = width / 3.0;
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *button = (UIButton *)[_card viewWithTag:100 + i];
        button.frame = CGRectMake(i * buttonWidth, 331, buttonWidth, 43);
        if (i > 0) {
            UIView *line = [_card viewWithTag:200 + i];
            if (!line) {
                line = [[UIView alloc] initWithFrame:CGRectZero];
                line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
                line.tag = 200 + i;
                [_card addSubview:line];
            }
            line.frame = CGRectMake(i * buttonWidth, 331, 1, 43);
        }
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [_field becomeFirstResponder];
}

- (void)keyboardChanged:(NSNotification *)note
{
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat screenHeight = CGRectGetHeight(self.view.bounds);
    _keyboardInset = MAX(0, screenHeight - CGRectGetMinY(frame));
    [UIView animateWithDuration:0.22 animations:^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }];
}

- (void)textChanged:(UITextField *)field
{
    _errorLabel.text = @"";
    [self refreshConversion];
}

- (void)refreshConversion
{
    double value = 0;
    RGDateFilter filter;
    RGParseResult result = rg_parse_days(_field.text.UTF8String, &value, &filter);

    if (result == RGParseInvalid) {
        _convValue.text = @"请输入数字";
        _convBadge.text = @"无效";
        return;
    }
    if (result == RGParseTooSmall) {
        _convValue.text = @"不到 1 分钟";
        _convBadge.text = @"太短";
        return;
    }
    if (result == RGParseTooLarge) {
        _convValue.text = @"超过 1 年";
        _convBadge.text = @"太长";
        return;
    }
    if (result == RGParseEmpty || result == RGParseZero) {
        _convValue.text = @"关闭过滤";
        _convBadge.text = @"关闭";
        return;
    }
    _convValue.text = RDFHumanDuration(value);
    _convBadge.text = value > 0 ? @"最近" : @"更早";
}

- (void)chipTapped:(UIButton *)chip
{
    _field.text = chip.currentTitle;
    [self textChanged:_field];
}

- (void)actionTapped:(UIButton *)sender
{
    NSInteger index = sender.tag - 100;
    if (index == 1) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    if (index == 0) {
        if (self.onCommit) self.onCommit(0);
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    double value = 0;
    RGDateFilter filter;
    RGParseResult result = rg_parse_days(_field.text.UTF8String, &value, &filter);
    if (result == RGParseInvalid) { _errorLabel.text = @"只能输入数字、小数点和负号"; return; }
    if (result == RGParseTooSmall) { _errorLabel.text = @"最短 1 分钟（0.0007 天）"; return; }
    if (result == RGParseTooLarge) { _errorLabel.text = @"最长 1 年（365 天）"; return; }

    double commit = (result == RGParseEmpty || result == RGParseZero) ? 0 : value;
    if (self.onCommit) self.onCommit(commit);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end


#pragma mark - Scope sheet

static NSString *RDFDaysSummaryForSurface(RDFSurface surface)
{
    double days = RDFDaysForSurface(surface);
    if (fabs(days) < RG_FILTER_MIN_DAYS) return @"未设置";
    NSString *human = RDFHumanDuration(days);
    return days > 0 ? [human stringByAppendingString:@"内"] : [human stringByAppendingString:@"以前"];
}

@interface RDFScopeViewController : UIViewController
- (void)refreshValues;
- (void)showDiagnostics:(UILongPressGestureRecognizer *)gesture;
@end

@implementation RDFScopeViewController {
    UIView *_dim;
    UIView *_card;
    NSMutableArray<UILabel *> *_valueLabels;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;

    _dim = [[UIView alloc] initWithFrame:self.view.bounds];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_dim];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = [UIColor colorWithWhite:0.17 alpha:0.98];
    _card.layer.cornerRadius = 16;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:_card];

    UILabel *title = [self label:@"时间过滤" size:16.5 weight:UIFontWeightSemibold color:UIColor.whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.tag = 1;
    title.userInteractionEnabled = YES;
    [title addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(showDiagnostics:)]];
    [_card addSubview:title];

    UILabel *subtitle = [self label:@"每个页面单独设置，开关只决定是否生效" size:11 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.62 alpha:1]];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.tag = 2;
    [_card addSubview:subtitle];

    _valueLabels = [NSMutableArray array];
    NSInteger mask = RDFScopeMask();

    for (NSUInteger i = 0; i < 4; i++) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.tag = 40 + i;
        [row addTarget:self action:@selector(editSurface:) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:row];

        UILabel *name = [self label:RDFSurfaceName((RDFSurface)(1 << i)) size:14 weight:UIFontWeightRegular color:UIColor.whiteColor];
        name.tag = 50 + i;
        [_card addSubview:name];

        UILabel *value = [self label:RDFDaysSummaryForSurface((RDFSurface)(1 << i)) size:12.5 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.62 alpha:1]];
        value.textAlignment = NSTextAlignmentRight;
        value.tag = 60 + i;
        [_card addSubview:value];
        [_valueLabels addObject:value];

        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = [UIColor colorWithRed:0.49 green:0.23 blue:0.93 alpha:1];
        toggle.tag = 20 + i;
        toggle.on = (mask & (1 << i)) != 0;
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        [_card addSubview:toggle];
    }

    UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    separator.tag = 3;
    [_card addSubview:separator];

    UILabel *note = [self label:@"点每一行单独设置时长。单位是天：1 小时 = 0.0417，30 分钟 = 0.021。" size:10.5 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.55 alpha:1]];
    note.numberOfLines = 2;
    note.tag = 4;
    [_card addSubview:note];

    UIView *buttonLine = [[UIView alloc] initWithFrame:CGRectZero];
    buttonLine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    buttonLine.tag = 5;
    [_card addSubview:buttonLine];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeCustom];
    [done setTitle:@"完成" forState:UIControlStateNormal];
    [done setTitleColor:[UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1] forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
    done.tag = 6;
    [done addTarget:self action:@selector(done) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:done];
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshValues];
}

- (void)refreshValues
{
    for (NSUInteger i = 0; i < _valueLabels.count; i++) {
        _valueLabels[i].text = RDFDaysSummaryForSurface((RDFSurface)(1 << i));
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = 306, height = 404;
    CGFloat x = (CGRectGetWidth(self.view.bounds) - width) / 2;
    CGFloat y = (CGRectGetHeight(self.view.bounds) - height) / 2;
    _card.frame = CGRectMake(x, y, width, height);

    [_card viewWithTag:1].frame = CGRectMake(0, 18, width, 22);
    [_card viewWithTag:2].frame = CGRectMake(0, 42, width, 16);

    for (NSUInteger i = 0; i < 4; i++) {
        CGFloat top = 64 + i * 50;
        [_card viewWithTag:40 + i].frame = CGRectMake(0, top, width, 50);
        [_card viewWithTag:50 + i].frame = CGRectMake(18, top + 15, 110, 20);
        [_card viewWithTag:60 + i].frame = CGRectMake(width - 18 - 51 - 8 - 96, top + 16, 96, 18);
        [(UISwitch *)[_card viewWithTag:20 + i] setFrame:CGRectMake(width - 18 - 51, top + 10, 51, 31)];
    }

    [_card viewWithTag:3].frame = CGRectMake(0, 264, width, 1);
    [_card viewWithTag:4].frame = CGRectMake(18, 274, width - 36, 32);
    [_card viewWithTag:5].frame = CGRectMake(0, 352, width, 1);
    [_card viewWithTag:6].frame = CGRectMake(0, 353, width, 50);
}

- (void)toggleChanged:(UISwitch *)toggle
{
    NSInteger index = toggle.tag - 20;
    NSInteger mask = RDFScopeMask();
    if (toggle.isOn) mask |= (1 << index);
    else mask &= ~(1 << index);
    RDFSetScopeMask(mask);
    RDFReloadLists();
}

- (void)editSurface:(UIButton *)sender
{
    RDFSurface surface = (RDFSurface)(1 << (sender.tag - 40));

    RDFInputViewController *controller = [RDFInputViewController new];
    controller.surface = surface;
    controller.initialDays = RDFDaysForSurface(surface);
    __weak typeof(self) weakSelf = self;
    controller.onCommit = ^(double days) {
        RDFSetDaysForSurface(surface, days);
        [weakSelf refreshValues];
        RDFReloadLists();
    };
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showDiagnostics:(UILongPressGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    NSArray *sources;
    @synchronized ([NSNull null]) {
        sources = [gRDFRecentSources copy] ?: @[];
    }
    NSString *text = sources.count ? [sources componentsJoinedByString:@"\n"] : @"还没有捕获到数据源";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已挂上的数据源"
                                                                   message:text
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface RDFConfigurator : NSObject
+ (instancetype)shared;
- (void)presentFrom:(UIViewController *)host;
- (void)settingsTapped:(UIBarButtonItem *)sender;
- (void)commitDays:(double)days;
@end

@implementation RDFConfigurator

+ (instancetype)shared
{
    static RDFConfigurator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [RDFConfigurator new]; });
    return shared;
}

- (void)settingsTapped:(UIBarButtonItem *)sender
{
    UIViewController *host = objc_getAssociatedObject(sender, kRDFHostKey.UTF8String);
    host = host ?: RDFTopViewController();
    RDFScopeViewController *controller = [RDFScopeViewController new];
    [host presentViewController:controller animated:YES completion:nil];
}

- (void)presentFrom:(UIViewController *)host
{
    if (!host) return;

    NSString *hint =
        @"比如输入 10 就只加载 10 天内发布的作品\n"
        @"支持小数点\n"
        @"比如 0.5 就是判断 12 小时内\n\n"
        @"支持输入负数 比如 -10 只刷 10 天以前发布的视频\n"
        @"（注意：输入过大可能无法加载出视频或功能无效）\n"
        @"最长 1 年，最短 1 分钟。\n"
        @"单位是天：1 小时 = 0.0417，30 分钟 = 0.021。";

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"提示"
                                            message:hint
                                     preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"前往输入"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf presentInputFrom:host];
    }]];

    [host presentViewController:alert animated:YES completion:nil];
}

- (void)presentInputFrom:(UIViewController *)host
{
    RDFInputViewController *controller = [RDFInputViewController new];
    controller.surface = RDFSurfaceProfile;
    controller.initialDays = RDFDaysForSurface(RDFSurfaceProfile);
    __weak typeof(self) weakSelf = self;
    controller.onCommit = ^(double days) {
        [weakSelf commitDays:days];
    };
    [host presentViewController:controller animated:YES completion:nil];
}

- (void)commitDays:(double)days
{
    [[NSUserDefaults standardUserDefaults] setDouble:days forKey:kRDFDaysKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    RDFReloadLists();
}

- (void)presentError:(NSString *)message host:(UIViewController *)host
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入无效"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Entry (Instagram settings)

static UIViewController *RDFTopViewController(void)
{
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;

    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static void RDFAddSettingsEntry(UIViewController *controller)
{
    if (!controller) return;
    NSString *name = NSStringFromClass([controller class]);
    if ([name rangeOfString:@"Setting" options:NSCaseInsensitiveSearch].location == NSNotFound) return;

    UINavigationItem *navigationItem = controller.navigationItem;
    if (!navigationItem) return;
    if (objc_getAssociatedObject(controller, &kRDFEntryKey)) return;

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"时间过滤"
                                                             style:UIBarButtonItemStylePlain
                                                            target:[RDFConfigurator shared]
                                                            action:@selector(settingsTapped:)];
    objc_setAssociatedObject(item, kRDFHostKey.UTF8String, controller, OBJC_ASSOCIATION_ASSIGN);

    NSMutableArray *items = [navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items insertObject:item atIndex:0];
    navigationItem.rightBarButtonItems = items;

    objc_setAssociatedObject(controller, &kRDFEntryKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[RDF] settings entry added to %@", name);
}

static IMP gRDFOriginalAppear;

static void RDFAppearHook(id self, SEL _cmd, BOOL animated)
{
    if (gRDFOriginalAppear) {
        ((void (*)(id, SEL, BOOL))gRDFOriginalAppear)(self, _cmd, animated);
    }
    RDFAddSettingsEntry(self);
}

// Settings controllers that override viewDidAppear: and skip super need their
// own hook; a UIViewController-level swizzle alone would miss them.
static void RDFHookSettingsClasses(void)
{
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return;
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if ([name rangeOfString:@"Setting" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;

        SEL selector = @selector(viewDidAppear:);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL owns = NO;
        for (unsigned int j = 0; j < methodCount; j++) {
            if (sel_isEqual(method_getName(methods[j]), selector)) { owns = YES; break; }
        }
        free(methods);
        if (!owns) continue;

        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;

        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id receiver, BOOL animated) {
            ((void (*)(id, SEL, BOOL))original)(receiver, selector, animated);
            RDFAddSettingsEntry(receiver);
        });
        method_setImplementation(method, replacement);
        NSLog(@"[RDF] settings class hooked: %@", name);
    }
    free(classes);
}

#pragma mark - Manual hooks (no CydiaSubstrate dependency)

static IMP gRDFOriginalSetDataSource;

static void RDFSetDataSourceHook(id self, SEL _cmd, id dataSource)
{
    if (gRDFOriginalSetDataSource) {
        ((void (*)(id, SEL, id))gRDFOriginalSetDataSource)(self, _cmd, dataSource);
    }
    gRDFLastAdapter = self;
    RDFInstallDataSource(dataSource);
}

// Some lists (Explore among them) hand the data source to the adapter's
// initializer instead of assigning it later, so setDataSource: alone misses them.
static IMP gRDFOriginalInitDataSource;
static IMP gRDFOriginalInitLayoutDataSource;

static id RDFInitWithUpdaterDataSource(id self, SEL _cmd, id updater, id dataSource)
{
    id result = nil;
    if (gRDFOriginalInitDataSource) {
        result = ((id (*)(id, SEL, id, id))gRDFOriginalInitDataSource)(self, _cmd, updater, dataSource);
    }
    gRDFLastAdapter = result ?: self;
    RDFInstallDataSource(dataSource);
    NSLog(@"[RDF] adapter init ds=%@", NSStringFromClass([dataSource class]));
    return result;
}

static id RDFInitWithLayoutUpdaterDataSource(id self, SEL _cmd, id layout, id updater, id dataSource)
{
    id result = nil;
    if (gRDFOriginalInitLayoutDataSource) {
        result = ((id (*)(id, SEL, id, id, id))gRDFOriginalInitLayoutDataSource)(self, _cmd, layout, updater, dataSource);
    }
    gRDFLastAdapter = result ?: self;
    RDFInstallDataSource(dataSource);
    NSLog(@"[RDF] adapter init(layout) ds=%@", NSStringFromClass([dataSource class]));
    return result;
}

__attribute__((constructor))
static void RDFInitialize(void)
{
    Class adapterClass = objc_getClass("IGListAdapter");
    if (adapterClass) {
        SEL selector = @selector(setDataSource:);
        Method method = class_getInstanceMethod(adapterClass, selector);
        if (method) {
            gRDFOriginalSetDataSource = method_getImplementation(method);
            method_setImplementation(method, (IMP)RDFSetDataSourceHook);
            NSLog(@"[RDF] installed setDataSource: hook");
        }
    }

    if (adapterClass) {
        SEL initSelector = NSSelectorFromString(@"initWithUpdater:dataSource:");
        Method initMethod = class_getInstanceMethod(adapterClass, initSelector);
        if (initMethod) {
            gRDFOriginalInitDataSource = method_getImplementation(initMethod);
            method_setImplementation(initMethod, (IMP)RDFInitWithUpdaterDataSource);
            NSLog(@"[RDF] installed adapter dataSource init hook");
        }

        SEL layoutSelector = NSSelectorFromString(@"initWithCollectionViewLayout:updater:dataSource:");
        Method layoutMethod = class_getInstanceMethod(adapterClass, layoutSelector);
        if (layoutMethod) {
            gRDFOriginalInitLayoutDataSource = method_getImplementation(layoutMethod);
            method_setImplementation(layoutMethod, (IMP)RDFInitWithLayoutUpdaterDataSource);
            NSLog(@"[RDF] installed adapter layout init hook");
        }
    }

    Method appear = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (appear) {
        gRDFOriginalAppear = method_getImplementation(appear);
        method_setImplementation(appear, (IMP)RDFAppearHook);
    }

    RDFHookSettingsClasses();
}
