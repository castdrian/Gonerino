#import "Settings.h"
#import "CustomSettings.h"
#import "Localization.h"
#import <objc/runtime.h>

static void *SettingsManagerAssociationKey = &SettingsManagerAssociationKey;
static const NSUInteger SettingsGroup = 0x67726e72;

static void AssociateSettingsDestinationManager(UIViewController *viewController,
                                                YTSettingsSectionItemManager *manager);

static id SettingsObjectValue(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UINavigationController *NavigationControllerContaining(UIViewController *rootViewController,
                                                               UIViewController *target,
                                                               NSUInteger depth) {
    if (!rootViewController || !target || depth > 8)
        return nil;
    if ([rootViewController isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)rootViewController).viewControllers containsObject:target])
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
    NSNumber *category = SettingsCategoryValue(candidate);
    if (!category)
        category = SettingsCategoryValue(SettingsObjectValue(candidate, @"model"));
    if (category)
        return category.unsignedIntegerValue == SettingsCategory;
    NSString *title = SettingsCandidateTitle(candidate);
    if (title.length > 0)
        return [title isEqualToString:LocalizedString(@"Gonerino")];
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
            id candidate = SettingsObjectValue(settingsViewController, key);
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

%hook YTSettingsViewController

- (void)setSectionItems:(NSMutableArray *)sectionItems
            forCategory:(NSInteger)category
                  title:(NSString *)title
                   icon:(YTIIcon *)icon
       titleDescription:(NSString *)titleDescription
                   headerHidden:(BOOL)headerHidden {
    %orig;
    if (category != SettingsCategory)
        return;
    YTSettingsSectionItemManager *manager = SettingsObjectValue(self, @"_sectionItemManager");
    AssociateSettingsManager(self, manager);
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
}
