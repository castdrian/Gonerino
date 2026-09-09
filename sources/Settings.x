#import "Settings.h"
#import "CustomSettings.h"
#import "Localization.h"
#import <stdarg.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void *SettingsManagerAssociationKey = &SettingsManagerAssociationKey;
static const NSUInteger SettingsGroup = 0x67726e72;

#if GONERINO_SETTINGS_DEBUG
static NSString *const SettingsDebugTag = @"[DEBUG-GONERINO-SETTINGS-FIX1]";

static dispatch_queue_t SettingsDebugQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("dev.adrian.gonerino.settings-debug", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void SettingsDebugLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", SettingsDebugTag, message ?: @""];
    dispatch_async(SettingsDebugQueue(), ^{
        NSString *consoleLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSLog(@"%@", consoleLine);
        NSArray<NSString *> *documentPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                                  NSUserDomainMask,
                                                                                  YES);
        NSString *documentPath = documentPaths.firstObject;
        if (documentPath.length == 0)
            return;
        NSString *logPath = [documentPath stringByAppendingPathComponent:@"gonerino-settings-debug.log"];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:logPath])
            [fileManager createFileAtPath:logPath contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!handle)
            return;
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}

#else
static void SettingsDebugLog(NSString *format, ...) {
    (void)format;
}
#endif

static void AssociateSettingsDestinationManager(UIViewController *viewController,
                                                YTSettingsSectionItemManager *manager);

static NSString *SettingsDebugObject(id object) {
    if (!object)
        return @"(nil)";
    return [NSString stringWithFormat:@"%@@%p", NSStringFromClass([object class]), object];
}

static id SettingsObjectValue(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SettingsIvarObject(id object, const char *name) {
    if (!object || !name)
        return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    const char *typeEncoding = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!typeEncoding || typeEncoding[0] != '@')
        return nil;
    return object_getIvar(object, ivar);
}

static YTSettingsViewController *SettingsViewControllerFromObject(id object) {
    if ([object isKindOfClass:%c(YTSettingsViewController)])
        return (YTSettingsViewController *)object;
    return nil;
}

static BOOL ViewControllerHierarchyContains(UIViewController *rootViewController,
                                             UIViewController *target,
                                             NSUInteger depth) {
    if (!rootViewController || !target || depth > 12)
        return NO;
    if (rootViewController == target)
        return YES;
    if (rootViewController.presentedViewController && !rootViewController.presentedViewController.isBeingDismissed &&
        ViewControllerHierarchyContains(rootViewController.presentedViewController, target, depth + 1))
        return YES;
    for (UIViewController *childViewController in rootViewController.childViewControllers) {
        if (ViewControllerHierarchyContains(childViewController, target, depth + 1))
            return YES;
    }
    return NO;
}

static UINavigationController *NavigationControllerContaining(UIViewController *rootViewController,
                                                               UIViewController *target,
                                                               NSUInteger depth) {
    if (!rootViewController || !target || depth > 8)
        return nil;
    if ([rootViewController isKindOfClass:[UINavigationController class]] &&
        ViewControllerHierarchyContains(rootViewController, target, 0))
        return (UINavigationController *)rootViewController;
    if (rootViewController.presentedViewController && !rootViewController.presentedViewController.isBeingDismissed) {
        UINavigationController *navigationController = NavigationControllerContaining(rootViewController.presentedViewController,
                                                                                         target,
                                                                                         depth + 1);
        if (navigationController)
            return navigationController;
    }
    for (UIViewController *childViewController in rootViewController.childViewControllers) {
        UINavigationController *navigationController = NavigationControllerContaining(childViewController,
                                                                                         target,
                                                                                         depth + 1);
        if (navigationController)
            return navigationController;
    }
    return nil;
}

static void AssociateSettingsManager(YTSettingsViewController *settingsViewController,
                                     YTSettingsSectionItemManager *manager) {
    if (!settingsViewController || !manager)
        return;

    objc_setAssociatedObject(settingsViewController,
                             SettingsManagerAssociationKey,
                             manager,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UINavigationController *navigationController = settingsViewController.navigationController;
    if (!navigationController) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            navigationController = NavigationControllerContaining(window.rootViewController,
                                                                   settingsViewController,
                                                                   0);
            if (navigationController)
                break;
        }
    }
    if (navigationController)
        objc_setAssociatedObject(navigationController,
                                 SettingsManagerAssociationKey,
                                 manager,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIViewController *TopVisibleViewController(UIViewController *viewController) {
    if (!viewController)
        return nil;
    if (viewController.presentedViewController && !viewController.presentedViewController.isBeingDismissed)
        return TopVisibleViewController(viewController.presentedViewController);
    if ([viewController isKindOfClass:[UINavigationController class]])
        return TopVisibleViewController([(UINavigationController *)viewController visibleViewController]);
    if ([viewController isKindOfClass:[UITabBarController class]])
        return TopVisibleViewController([(UITabBarController *)viewController selectedViewController]);
    for (UIViewController *child in viewController.childViewControllers.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window)
            return TopVisibleViewController(child);
    }
    return viewController;
}

static YTSettingsViewController *SettingsViewControllerInHierarchy(UIViewController *viewController,
                                                                    NSUInteger depth) {
    if (!viewController || depth > 12)
        return nil;
    if ([viewController isKindOfClass:%c(YTSettingsViewController)])
        return (YTSettingsViewController *)viewController;
    if (viewController.presentedViewController && !viewController.presentedViewController.isBeingDismissed) {
        YTSettingsViewController *settingsViewController = SettingsViewControllerInHierarchy(viewController.presentedViewController,
                                                                                              depth + 1);
        if (settingsViewController)
            return settingsViewController;
    }
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *childViewController in ((UINavigationController *)viewController).viewControllers) {
            YTSettingsViewController *settingsViewController = SettingsViewControllerInHierarchy(childViewController,
                                                                                                  depth + 1);
            if (settingsViewController)
                return settingsViewController;
        }
    }
    if ([viewController isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *childViewController in ((UISplitViewController *)viewController).viewControllers) {
            YTSettingsViewController *settingsViewController = SettingsViewControllerInHierarchy(childViewController,
                                                                                                  depth + 1);
            if (settingsViewController)
                return settingsViewController;
        }
    }
    for (UIViewController *childViewController in viewController.childViewControllers) {
        YTSettingsViewController *settingsViewController = SettingsViewControllerInHierarchy(childViewController,
                                                                                              depth + 1);
        if (settingsViewController)
            return settingsViewController;
    }
    return nil;
}

static YTSettingsViewController *SettingsViewControllerForManager(YTSettingsSectionItemManager *manager) {
    if (!manager)
        return nil;

    for (NSString *key in @[@"_dataDelegate", @"_settingsViewControllerDelegate"]) {
        id delegate = SettingsObjectValue(manager, key);
        if ([delegate isKindOfClass:%c(YTSettingsViewController)])
            return delegate;
    }

    id responder = nil;
    @try {
        responder = [manager parentResponder];
    } @catch (__unused NSException *exception) {
    }
    for (NSUInteger depth = 0; responder && depth < 8; depth++) {
        if ([responder isKindOfClass:%c(YTSettingsViewController)])
            return responder;
        if (![responder respondsToSelector:@selector(nextResponder)])
            break;
        responder = [responder nextResponder];
    }

    Class settingsClass = %c(YTSettingsViewController);
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *candidate = TopVisibleViewController(window.rootViewController);
        if ([candidate isKindOfClass:settingsClass])
            return (YTSettingsViewController *)candidate;
    }
    return nil;
}

static YTSettingsViewController *SettingsControllerInNavigationController(UINavigationController *navigationController) {
    if (!navigationController)
        return nil;
    for (UIViewController *viewController in navigationController.viewControllers.reverseObjectEnumerator) {
        YTSettingsViewController *settingsViewController = SettingsViewControllerInHierarchy(viewController, 0);
        if (settingsViewController)
            return settingsViewController;
    }
    return nil;
}

static NSNumber *SettingsCategoryValueFromDescription(NSString *description) {
    NSRange markerRange = [description rangeOfString:@"category_id:"];
    if (markerRange.location == NSNotFound)
        return nil;
    NSString *suffix = [description substringFromIndex:NSMaxRange(markerRange)];
    NSScanner *scanner = [NSScanner scannerWithString:suffix];
    unsigned long long value = 0;
    if (![scanner scanUnsignedLongLong:&value])
        return nil;
    return @(value);
}

static NSNumber *SettingsCategoryValue(id object) {
    if (!object)
        return nil;
    for (NSString *key in @[@"category", @"categoryID", @"categoryId", @"settingsCategory"]) {
        id value = SettingsObjectValue(object, key);
        if ([value respondsToSelector:@selector(unsignedIntegerValue)])
            return @([value unsignedIntegerValue]);
    }
    return SettingsCategoryValueFromDescription([object description] ?: @"");
}

static NSString *SettingsCandidateTitle(UIViewController *candidate) {
    if (!candidate)
        return @"";
    if (candidate.title.length > 0)
        return candidate.title;
    return candidate.navigationItem.title ?: @"";
}

static BOOL SettingsCandidateIsGonerino(UIViewController *candidate) {
    if (!candidate)
        return NO;
    Class customSettingsClass = NSClassFromString(@"SettingsPageViewController");
    if (customSettingsClass && [candidate isKindOfClass:customSettingsClass])
        return NO;
    NSArray *objects = @[candidate, SettingsObjectValue(candidate, @"content") ?: [NSNull null]];
    for (id object in objects) {
        if (object == [NSNull null])
            continue;
        NSNumber *category = SettingsCategoryValue(object);
        if (!category)
            category = SettingsCategoryValue(SettingsObjectValue(object, @"model"));
        if (!category)
            category = SettingsCategoryValue(SettingsObjectValue(object, @"navigationEndpoint"));
        if (category)
            return category.unsignedIntegerValue == SettingsCategory;
        if ([object isKindOfClass:[UIViewController class]]) {
            NSString *title = SettingsCandidateTitle((UIViewController *)object);
            if (title.length > 0 && [title isEqualToString:LocalizedString(@"Gonerino")])
                return YES;
        }
    }
    return NO;
}

static YTSettingsSectionItemManager *SettingsManagerForController(YTSettingsViewController *settingsViewController) {
    if (!settingsViewController)
        return nil;
    YTSettingsSectionItemManager *manager = objc_getAssociatedObject(settingsViewController,
                                                                      SettingsManagerAssociationKey);
    if (!manager)
        manager = objc_getAssociatedObject(settingsViewController.navigationController,
                                           SettingsManagerAssociationKey);
    if (!manager) {
        for (NSString *key in @[@"_sectionItemManager", @"sectionItemManager"]) {
            id candidate = SettingsIvarObject(settingsViewController, key.UTF8String);
            if ([candidate isKindOfClass:%c(YTSettingsSectionItemManager)]) {
                manager = candidate;
                break;
            }
        }
    }
    if (manager)
        AssociateSettingsManager(settingsViewController, manager);
    return manager;
}

static UINavigationController *SettingsNavigationControllerForViewController(YTSettingsViewController *settingsViewController) {
    if (!settingsViewController)
        return nil;
    UINavigationController *navigationController = settingsViewController.navigationController;
    if (navigationController)
        return navigationController;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        navigationController = NavigationControllerContaining(window.rootViewController,
                                                               settingsViewController,
                                                               0);
        if (navigationController)
            return navigationController;
    }
    return nil;
}

static UIViewController *CreateSettingsDestinationForCandidate(YTSettingsViewController *settingsViewController,
                                                               UIViewController *candidate) {
    if (!settingsViewController || !candidate)
        return nil;
    Class customSettingsClass = NSClassFromString(@"SettingsPageViewController");
    if (customSettingsClass && [candidate isKindOfClass:customSettingsClass])
        return nil;
    YTSettingsSectionItemManager *manager = SettingsManagerForController(settingsViewController);
    if (!manager)
        return nil;
    if (!SettingsCandidateIsGonerino(candidate))
        return nil;
    UIViewController *destination = CreateCustomSettingsViewController(manager);
    AssociateSettingsDestinationManager(destination, manager);
    return destination;
}

static BOOL PushSettingsDestination(UIViewController *source,
                                    UIViewController *destination,
                                    BOOL animated) {
    if (!source || !destination)
        return NO;
    UINavigationController *navigationController = nil;
    if ([source isKindOfClass:[UINavigationController class]])
        navigationController = (UINavigationController *)source;
    else
        navigationController = source.navigationController;
    if (!navigationController)
        return NO;
    [navigationController pushViewController:destination animated:animated];
    return YES;
}

static void AssociateSettingsDestinationManager(UIViewController *viewController,
                                                YTSettingsSectionItemManager *manager) {
    if (!viewController || !manager)
        return;
    objc_setAssociatedObject(viewController,
                             SettingsManagerAssociationKey,
                             manager,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL PushCustomSettingsDestination(YTSettingsViewController *settingsViewController,
                                          BOOL animated) {
    if (!settingsViewController)
        return NO;
    YTSettingsSectionItemManager *manager = SettingsManagerForController(settingsViewController);
    UINavigationController *navigationController =
        SettingsNavigationControllerForViewController(settingsViewController);
    if (!manager || !navigationController) {
        SettingsDebugLog(@"direct route failed settings=%@ manager=%@ navigation=%@",
                         SettingsDebugObject(settingsViewController),
                         SettingsDebugObject(manager),
                         SettingsDebugObject(navigationController));
        return NO;
    }
    UIViewController *destination = CreateCustomSettingsViewController(manager);
    if (!destination) {
        SettingsDebugLog(@"direct route failed to create destination settings=%@ manager=%@",
                         SettingsDebugObject(settingsViewController),
                         SettingsDebugObject(manager));
        return NO;
    }
    AssociateSettingsDestinationManager(destination, manager);
    [navigationController pushViewController:destination animated:animated];
    SettingsDebugLog(@"direct route pushed settings=%@ manager=%@ navigation=%@ destination=%@ animated=%@",
                     SettingsDebugObject(settingsViewController),
                     SettingsDebugObject(manager),
                     SettingsDebugObject(navigationController),
                     SettingsDebugObject(destination),
                     animated ? @"YES" : @"NO");
    return YES;
}

static NSIndexPath *SettingsCategoryIndexPathForController(YTSettingsViewController *settingsViewController) {
    if (!settingsViewController ||
        ![settingsViewController respondsToSelector:@selector(groupedSettingsIndexPathForSettingCategoryId:)])
        return nil;
    return ((NSIndexPath *(*)(id, SEL, NSUInteger))objc_msgSend)(settingsViewController,
                                                                 @selector(groupedSettingsIndexPathForSettingCategoryId:),
                                                                 SettingsCategory);
}

static BOOL SettingsDestinationContainsCustomPage(UIViewController *viewController) {
    Class customSettingsClass = NSClassFromString(@"SettingsPageViewController");
    if (!customSettingsClass || !viewController)
        return NO;
    if ([viewController isKindOfClass:customSettingsClass])
        return YES;
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *childViewController in ((UINavigationController *)viewController).viewControllers) {
            if ([childViewController isKindOfClass:customSettingsClass])
                return YES;
        }
    }
    return NO;
}

static UIViewController *CreateCustomSettingsSplitDestination(YTSettingsViewController *settingsViewController) {
    YTSettingsSectionItemManager *manager = SettingsManagerForController(settingsViewController);
    if (!manager)
        return nil;
    UIViewController *customSettingsViewController = CreateCustomSettingsViewController(manager);
    if (!customSettingsViewController)
        return nil;
    UINavigationController *navigationController = [[UINavigationController alloc]
        initWithRootViewController:customSettingsViewController];
    navigationController.navigationBarHidden = NO;
    AssociateSettingsDestinationManager(navigationController, manager);
    AssociateSettingsDestinationManager(customSettingsViewController, manager);
    return navigationController;
}

%hook YTAppSettingsGroupPresentationData

+ (NSArray *)orderedGroups {
    NSArray *groups = %orig;
    for (YTSettingsGroupData *group in groups) {
        if (group.type == SettingsGroup)
            return groups;
    }
    NSMutableArray *result = groups.mutableCopy ?: [NSMutableArray array];
    YTSettingsGroupData *group = [[%c(YTSettingsGroupData) alloc] initWithGroupType:SettingsGroup];
    [result insertObject:group atIndex:0];
    return result.copy;
}

%end

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
    if (self.type == SettingsGroup)
        return @[@(SettingsCategory)];
    return %orig;
}

- (NSArray<NSNumber *> *)orderedCategoriesForGroupType:(NSUInteger)type {
    if (type == SettingsGroup)
        return @[@(SettingsCategory)];
    return %orig;
}

- (NSString *)titleForSettingGroupType:(NSUInteger)type {
    if (type == SettingsGroup)
        return nil;
    return %orig;
}

%end

%hook YTSettingsSectionItemManager

- (id)initWithParentResponder:(id)parentResponder
       controllerDelegate:(id)controllerDelegate
             dataDelegate:(id)dataDelegate
settingsViewControllerDelegate:(id)settingsViewControllerDelegate {
    id result = %orig(parentResponder,
                      controllerDelegate,
                      dataDelegate,
                      settingsViewControllerDelegate);
    YTSettingsViewController *settingsViewController = SettingsViewControllerFromObject(dataDelegate);
    if (!settingsViewController)
        settingsViewController = SettingsViewControllerFromObject(settingsViewControllerDelegate);
    if (!settingsViewController)
        settingsViewController = SettingsViewControllerFromObject(parentResponder);
    if (result && settingsViewController)
        AssociateSettingsManager(settingsViewController, result);
    SettingsDebugLog(@"manager init result=%@ parent=%@ controller=%@ data=%@ settingsDelegate=%@ settings=%@",
                     SettingsDebugObject(result),
                     SettingsDebugObject(parentResponder),
                     SettingsDebugObject(controllerDelegate),
                     SettingsDebugObject(dataDelegate),
                     SettingsDebugObject(settingsViewControllerDelegate),
                     SettingsDebugObject(settingsViewController));
    return result;
}

%new
- (void)settingsIntegrationUpdateSectionWithEntry:(id)entry {
    YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(self);
    if (!settingsViewController)
        return;

    YTIIcon *icon = [%c(YTIIcon) new];
    icon.iconType = YT_FILTER;
    AssociateSettingsManager(settingsViewController, self);
    [settingsViewController setSectionItems:[NSMutableArray array]
                                forCategory:SettingsCategory
                                      title:LocalizedString(@"Gonerino")
                                       icon:icon
                           titleDescription:nil
                               headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == SettingsCategory) {
        YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(self);
        AssociateSettingsManager(settingsViewController, self);
        SettingsDebugLog(@"manager custom section manager=%@ settings=%@ entry=%@",
                         SettingsDebugObject(self),
                         SettingsDebugObject(settingsViewController),
                         SettingsDebugObject(entry));
        [self settingsIntegrationUpdateSectionWithEntry:entry];
        return;
    }
    %orig;
}

%new
- (void)settingsIntegrationReloadSection {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(self);
        if (!settingsViewController)
            return;
        [self settingsIntegrationUpdateSectionWithEntry:nil];
        if ([settingsViewController respondsToSelector:@selector(reloadData)])
            [settingsViewController reloadData];
    });
}

%end

%hook YTWrapperSplitViewController

- (void)didSelectCellAtIndexPath:(NSIndexPath *)indexPath {
    UIViewController *masterViewController = SettingsObjectValue(self, @"viewController");
    UIViewController *secondaryViewController = SettingsObjectValue(self, @"secondViewController");
    YTSettingsViewController *settingsViewController = SettingsViewControllerInHierarchy(masterViewController, 0);
    NSIndexPath *targetIndexPath = nil;
    if (settingsViewController && [settingsViewController respondsToSelector:@selector(groupedSettingsIndexPathForSettingCategoryId:)])
        targetIndexPath = ((NSIndexPath *(*)(id, SEL, NSUInteger))objc_msgSend)(settingsViewController,
                                                                                   @selector(groupedSettingsIndexPathForSettingCategoryId:),
                                                                                   SettingsCategory);
    SettingsDebugLog(@"wrapper select wrapper=%@ index=%@ master=%@ secondary=%@ settings=%@ target=%@",
                     SettingsDebugObject(self),
                     indexPath,
                     SettingsDebugObject(masterViewController),
                     SettingsDebugObject(secondaryViewController),
                     SettingsDebugObject(settingsViewController),
                     targetIndexPath);
    %orig(indexPath);
}

- (void)setSecondViewController:(UIViewController *)viewController {
    UIViewController *masterViewController = SettingsObjectValue(self, @"viewController");
    YTSettingsViewController *settingsViewController = SettingsViewControllerInHierarchy(masterViewController, 0);
    NSIndexPath *selectedIndexPath = SettingsObjectValue(self, @"selectedCellIndexPath");
    NSIndexPath *matchingIndexPath = SettingsObjectValue(self, @"cellIndexPathForSelectMatchingBlock");
    NSIndexPath *targetIndexPath = SettingsCategoryIndexPathForController(settingsViewController);
    SettingsDebugLog(@"wrapper second wrapper=%@ settings=%@ candidate=%@ title=%@ category=%@ selected=%@ matching=%@",
                     SettingsDebugObject(self),
                     SettingsDebugObject(settingsViewController),
                     SettingsDebugObject(viewController),
                     SettingsCandidateTitle(viewController),
                     SettingsCategoryValue(viewController),
                     selectedIndexPath,
                     matchingIndexPath);
    id candidateContent = SettingsObjectValue(viewController, @"content");
    SettingsDebugLog(@"wrapper candidate content=%@ contentTitle=%@ contentCategory=%@ contentEndpoint=%@ children=%@",
                     SettingsDebugObject(candidateContent),
                     [candidateContent isKindOfClass:[UIViewController class]]
                         ? SettingsCandidateTitle((UIViewController *)candidateContent)
                         : @"",
                     SettingsCategoryValue(candidateContent),
                     SettingsCategoryValue(SettingsObjectValue(candidateContent, @"navigationEndpoint")),
                     SettingsObjectValue(viewController, @"childViewControllers"));
    SettingsDebugLog(@"wrapper category index wrapper=%@ target=%@", SettingsDebugObject(self), targetIndexPath);
    if (SettingsCandidateIsGonerino(viewController) &&
        !SettingsDestinationContainsCustomPage(viewController)) {
        UIViewController *customDestination = CreateCustomSettingsSplitDestination(settingsViewController);
        if (customDestination) {
            %orig(customDestination);
            SettingsDebugLog(@"wrapper second replaced wrapper=%@ settings=%@ candidate=%@ destination=%@",
                             SettingsDebugObject(self),
                             SettingsDebugObject(settingsViewController),
                             SettingsDebugObject(viewController),
                             SettingsDebugObject(customDestination));
            return;
        }
        SettingsDebugLog(@"wrapper second replacement failed wrapper=%@ settings=%@ manager=%@",
                         SettingsDebugObject(self),
                         SettingsDebugObject(settingsViewController),
                         SettingsDebugObject(SettingsManagerForController(settingsViewController)));
    }
    %orig(viewController);
}

- (void)updateSplitPane {
    SettingsDebugLog(@"wrapper update wrapper=%@ selected=%@ second=%@",
                     SettingsDebugObject(self),
                     SettingsObjectValue(self, @"selectedCellIndexPath"),
                     SettingsDebugObject(SettingsObjectValue(self, @"secondViewController")));
    %orig;
}

- (void)updateSplitPane_regular {
    SettingsDebugLog(@"wrapper update regular wrapper=%@ selected=%@ second=%@",
                     SettingsDebugObject(self),
                     SettingsObjectValue(self, @"selectedCellIndexPath"),
                     SettingsDebugObject(SettingsObjectValue(self, @"secondViewController")));
    %orig;
}

- (void)updateSplitPane_compact {
    SettingsDebugLog(@"wrapper update compact wrapper=%@ selected=%@ second=%@",
                     SettingsDebugObject(self),
                     SettingsObjectValue(self, @"selectedCellIndexPath"),
                     SettingsDebugObject(SettingsObjectValue(self, @"secondViewController")));
    %orig;
}

- (void)selectDefaultSecondaryPane {
    SettingsDebugLog(@"wrapper select default wrapper=%@ selected=%@ second=%@",
                     SettingsDebugObject(self),
                     SettingsObjectValue(self, @"selectedCellIndexPath"),
                     SettingsDebugObject(SettingsObjectValue(self, @"secondViewController")));
    %orig;
}

- (void)selectMatchingBlock {
    SettingsDebugLog(@"wrapper select matching wrapper=%@ selected=%@ matching=%@ second=%@",
                     SettingsDebugObject(self),
                     SettingsObjectValue(self, @"selectedCellIndexPath"),
                     SettingsObjectValue(self, @"cellIndexPathForSelectMatchingBlock"),
                     SettingsDebugObject(SettingsObjectValue(self, @"secondViewController")));
    %orig;
}

- (void)setSelectMatchingBlock:(id)block {
    SettingsDebugLog(@"wrapper set matching wrapper=%@ block=%@",
                     SettingsDebugObject(self),
                     SettingsDebugObject(block));
    %orig(block);
}

- (void)showViewController:(UIViewController *)viewController sender:(id)sender {
    SettingsDebugLog(@"wrapper show wrapper=%@ candidate=%@ title=%@ category=%@ sender=%@",
                     SettingsDebugObject(self),
                     SettingsDebugObject(viewController),
                     SettingsCandidateTitle(viewController),
                     SettingsCategoryValue(viewController),
                     SettingsDebugObject(sender));
    %orig(viewController, sender);
}

%end

%hook YTAppSettingsSectionItemActionController

- (void)displaySettingsViewController:(UIViewController *)viewController {
    SettingsDebugLog(@"display settings action=%@ candidate=%@ title=%@ category=%@",
                     SettingsDebugObject(self),
                     SettingsDebugObject(viewController),
                     SettingsCandidateTitle(viewController),
                     SettingsCategoryValue(viewController));
    %orig(viewController);
}

%end

%hook YTSettingsViewController

- (void)sendSettingsNavigationEndpointForCategory:(NSUInteger)category {
    SettingsDebugLog(@"category route settings=%@ category=%lu manager=%@ navigation=%@",
                     SettingsDebugObject(self),
                     (unsigned long)category,
                     SettingsDebugObject(SettingsManagerForController(self)),
                     SettingsDebugObject(SettingsNavigationControllerForViewController(self)));
    if (category == SettingsCategory && PushCustomSettingsDestination(self, YES))
        return;
    %orig(category);
}

- (void)didReceiveDrillDownItem:(id)item {
    NSNumber *category = SettingsCategoryValue(item);
    if (category.unsignedIntegerValue == SettingsCategory) {
        SettingsDebugLog(@"drill-down route settings=%@ item=%@ category=%@",
                         SettingsDebugObject(self),
                         SettingsDebugObject(item),
                         category);
        if (PushCustomSettingsDestination(self, YES))
            return;
    }
    %orig(item);
}

- (void)setSectionItems:(NSMutableArray *)sectionItems
            forCategory:(NSInteger)category
                  title:(NSString *)title
                   icon:(YTIIcon *)icon
       titleDescription:(NSString *)titleDescription
                   headerHidden:(BOOL)headerHidden {
    %orig;
    if (category != SettingsCategory)
        return;
    YTSettingsSectionItemManager *manager = SettingsManagerForController(self);
    AssociateSettingsManager(self, manager);
    SettingsDebugLog(@"section items settings=%@ manager=%@ items=%lu",
                     SettingsDebugObject(self),
                     SettingsDebugObject(manager),
                     (unsigned long)sectionItems.count);
}

- (void)pushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(self, viewController);
    if (customViewController && PushSettingsDestination(self, customViewController, YES))
        return;
    %orig(customViewController ?: viewController);
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(self, viewController);
    if (customViewController && PushSettingsDestination(self, customViewController, animated))
        return;
    %orig(customViewController ?: viewController, animated);
}

- (void)showOrPushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(self, viewController);
    if (customViewController && PushSettingsDestination(self, customViewController, YES))
        return;
    %orig(customViewController ?: viewController);
}

- (void)showViewController:(UIViewController *)viewController sender:(id)sender {
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(self, viewController);
    if (customViewController && PushSettingsDestination(self, customViewController, YES))
        return;
    %orig(customViewController ?: viewController, sender);
}

%end

%hook YTNavigationController

- (void)pushViewController:(UIViewController *)viewController {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController, viewController);
    if (customViewController && PushSettingsDestination(self, customViewController, YES))
        return;
    %orig(customViewController ?: viewController);
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController, viewController);
    if (customViewController && PushSettingsDestination(self, customViewController, animated))
        return;
    %orig(customViewController ?: viewController, animated);
}

- (void)showOrPushViewController:(UIViewController *)viewController {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController, viewController);
    if (customViewController && PushSettingsDestination(self, customViewController, YES))
        return;
    %orig(customViewController ?: viewController);
}

- (void)showViewController:(UIViewController *)viewController sender:(id)sender {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController, viewController);
    if (customViewController && PushSettingsDestination(self, customViewController, YES))
        return;
    %orig(customViewController ?: viewController, sender);
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    NSUInteger settingsIndex = [viewControllers indexOfObjectIdenticalTo:settingsViewController];
    if (settingsIndex != NSNotFound && settingsIndex + 1 < viewControllers.count) {
        UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController,
                                                                                         viewControllers[settingsIndex + 1]);
        if (customViewController) {
            NSMutableArray<UIViewController *> *replacedViewControllers = viewControllers.mutableCopy;
            replacedViewControllers[settingsIndex + 1] = customViewController;
            %orig(replacedViewControllers);
            return;
        }
    }
    %orig;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    NSUInteger settingsIndex = [viewControllers indexOfObjectIdenticalTo:settingsViewController];
    if (settingsIndex != NSNotFound && settingsIndex + 1 < viewControllers.count) {
        UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController,
                                                                                         viewControllers[settingsIndex + 1]);
        if (customViewController) {
            NSMutableArray<UIViewController *> *replacedViewControllers = viewControllers.mutableCopy;
            replacedViewControllers[settingsIndex + 1] = customViewController;
            %orig(replacedViewControllers, animated);
            return;
        }
    }
    %orig;
}

%end

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController, viewController);
    if (customViewController) {
        [self pushViewController:customViewController animated:YES];
        return;
    }
    %orig;
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController, viewController);
    %orig(customViewController ?: viewController, animated);
}

- (void)showOrPushViewController:(UIViewController *)viewController {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController, viewController);
    if (customViewController) {
        [self pushViewController:customViewController animated:YES];
        return;
    }
    %orig;
}

- (void)showViewController:(UIViewController *)viewController sender:(id)sender {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    UIViewController *customViewController = CreateSettingsDestinationForCandidate(settingsViewController, viewController);
    if (customViewController) {
        [self pushViewController:customViewController animated:YES];
        return;
    }
    %orig(viewController, sender);
}

%end

%ctor {
    %init;
    SettingsDebugLog(@"constructor bundle=%@ version=%@ os=%@ settingsClass=%@ managerClass=%@ categoryRoute=%@ drillDown=%@",
                     NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
                     PACKAGE_VERSION,
                     UIDevice.currentDevice.systemVersion,
                     NSClassFromString(@"YTSettingsViewController") ? @"available" : @"missing",
                     NSClassFromString(@"YTSettingsSectionItemManager") ? @"available" : @"missing",
                     [NSClassFromString(@"YTSettingsViewController")
                         instancesRespondToSelector:@selector(sendSettingsNavigationEndpointForCategory:)]
                         ? @"available"
                         : @"missing",
                     [NSClassFromString(@"YTSettingsViewController")
                         instancesRespondToSelector:@selector(didReceiveDrillDownItem:)]
                         ? @"available"
                         : @"missing");
}
