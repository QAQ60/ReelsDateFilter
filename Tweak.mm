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

#pragma mark - Instagram surface (declared, not implemented here)

@interface IGListAdapter : NSObject
- (void)setDataSource:(id)dataSource;
@end

@interface IGProfileViewController : UIViewController
@end

#pragma mark - Model plumbing

// Profile grid objects expose the media through several wrappers depending on
// the Instagram build; try the known key paths in order.
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
    return nil;
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

static NSArray *RDFFilteredObjects(id dataSource, NSArray *objects)
{
    double days = [[NSUserDefaults standardUserDefaults] doubleForKey:kRDFDaysKey];
    if (fabs(days) < 0.0001 || objects.count == 0) return objects;
    if (!RDFLooksLikeProfileReels(dataSource, objects)) return objects;

    RGDateFilter filter = rg_filter_make(days);
    NSDate *now = [NSDate date];
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:objects.count];

    for (id object in objects) {
        NSDate *takenAt = RDFTakenAtForObject(object);
        if (!takenAt) {
            // Never drop an item we cannot date; better to over-show than to lose content.
            [kept addObject:object];
            continue;
        }
        NSTimeInterval age = [now timeIntervalSinceDate:takenAt];
        if (rg_filter_should_keep(filter, age)) [kept addObject:object];
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

    NSArray *filtered = RDFFilteredObjects(self, objects);
    if (filtered.count != objects.count) {
        NSLog(@"[RDF] %@ -> %lu/%lu (days=%g)",
              NSStringFromClass([self class]),
              (unsigned long)filtered.count,
              (unsigned long)objects.count,
              [[NSUserDefaults standardUserDefaults] doubleForKey:kRDFDaysKey]);
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

    NSLog(@"[RDF] hooked %@", NSStringFromClass(cls));
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

@interface RDFConfigurator : NSObject
+ (instancetype)shared;
- (void)presentFrom:(UIViewController *)host;
- (void)settingsTapped:(UIBarButtonItem *)sender;
@end

@implementation RDFConfigurator

+ (instancetype)shared
{
    static RDFConfigurator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [RDFConfigurator new]; });
    return shared;
}

- (void)presentFrom:(UIViewController *)host
{
    if (!host) return;

    NSString *hint =
        @"比如输入 10 就只加载 10 天内发布的作品\n"
        @"支持小数点\n"
        @"比如 0.5 就是判断 12 小时内\n\n"
        @"支持输入负数 比如 -10 只刷 10 天以前发布的视频\n"
        @"（注意：输入过大可能无法加载出视频或功能无效）";

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
    double current = [[NSUserDefaults standardUserDefaults] doubleForKey:kRDFDaysKey];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"输入天数"
                                            message:@"正数 = 最近 N 天，负数 = N 天以前，0 = 关闭"
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.placeholder = @"10 / 0.5 / -10";
        field.textAlignment = NSTextAlignmentCenter;
        if (fabs(current) > 0.0001) field.text = [NSString stringWithFormat:@"%g", current];
    }];

    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakHost = host;

    [alert addAction:[UIAlertAction actionWithTitle:@"清除"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf applyDays:0 host:weakHost];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        double value = 0;
        RGDateFilter filter;
        RGParseResult result = rg_parse_days(text.UTF8String, &value, &filter);

        if (result == RGParseInvalid) {
            [weakSelf presentError:@"只能输入数字、小数点和负号" host:weakHost];
            return;
        }
        if (result == RGParseTooLarge) {
            [weakSelf presentError:@"太大了，建议不超过 36500 天" host:weakHost];
            return;
        }
        [weakSelf applyDays:(result == RGParseEmpty || result == RGParseZero) ? 0 : value
                       host:weakHost];
    }]];

    [host presentViewController:alert animated:YES completion:nil];
}

- (void)presentError:(NSString *)message host:(UIViewController *)host
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入无效"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

- (void)applyDays:(double)days host:(UIViewController *)host
{
    [[NSUserDefaults standardUserDefaults] setDouble:days forKey:kRDFDaysKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    RDFReloadLists();
}

- (void)settingsTapped:(UIBarButtonItem *)sender
{
    UIViewController *host = objc_getAssociatedObject(sender, kRDFHostKey.UTF8String);
    [self presentFrom:host ?: RDFTopViewController()];
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

    Method appear = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (appear) {
        gRDFOriginalAppear = method_getImplementation(appear);
        method_setImplementation(appear, (IMP)RDFAppearHook);
    }

    RDFHookSettingsClasses();
}
