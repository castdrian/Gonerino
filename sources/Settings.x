#import "Settings.h"
#import "CustomSettings.h"
#import "Localization.h"
#import <objc/runtime.h>

static void *SettingsManagerAssociationKey = &SettingsManagerAssociationKey;
static void *SettingsCategorySelectionKey = &SettingsCategorySelectionKey;

static UINavigationController *NavigationControllerContaining(UIViewController *rootViewController,
                                                               UIViewController *target,
                                                               NSUInteger depth) {
    if (!rootViewController || !target || depth > 8)
        return nil;
    if ([rootViewController isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)rootViewController).viewControllers containsObject:target])
        return (UINavigationController *)rootViewController;
    if ([rootViewController.presentedViewController isBeingDismissed] == NO) {
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

static YTSettingsSectionItemManager *SettingsManagerInHierarchy(UIViewController *viewController,
                                                                NSUInteger depth) {
    if (!viewController || depth > 8)
        return nil;

    YTSettingsSectionItemManager *manager = objc_getAssociatedObject(viewController,
                                                                     SettingsManagerAssociationKey);
    if (manager)
        return manager;

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *childViewController in ((UINavigationController *)viewController).viewControllers) {
            manager = SettingsManagerInHierarchy(childViewController, depth + 1);
            if (manager)
                return manager;
        }
    }

    manager = SettingsManagerInHierarchy(viewController.presentedViewController, depth + 1);
    if (manager)
        return manager;
    for (UIViewController *childViewController in viewController.childViewControllers) {
        manager = SettingsManagerInHierarchy(childViewController, depth + 1);
        if (manager)
            return manager;
    }
    return nil;
}

static BOOL RecentGonerinoCategorySelection(YTSettingsSectionItemManager *manager) {
    NSNumber *timestamp = objc_getAssociatedObject(manager, SettingsCategorySelectionKey);
    if (![timestamp isKindOfClass:[NSNumber class]])
        return NO;
    NSTimeInterval age = [NSDate.date timeIntervalSince1970] - timestamp.doubleValue;
    return age >= 0.0 && age < 30.0;
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

static YTSettingsViewController *SettingsViewControllerForManager(YTSettingsSectionItemManager *manager) {
    if (!manager)
        return nil;

    for (NSString *key in @[@"_dataDelegate", @"_settingsViewControllerDelegate"]) {
        @try {
            id delegate = [manager valueForKey:key];
            if ([delegate isKindOfClass:%c(YTSettingsViewController)]) {
                return delegate;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    id responder = nil;
    @try {
        responder = [manager parentResponder];
    } @catch (__unused NSException *exception) {
    }
    for (NSUInteger depth = 0; responder && depth < 8; depth++) {
        if ([responder isKindOfClass:%c(YTSettingsViewController)]) {
            return responder;
        }
        if (![responder respondsToSelector:@selector(nextResponder)])
            break;
        responder = [responder nextResponder];
    }

    Class settingsClass = %c(YTSettingsViewController);
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *candidate = TopVisibleViewController(window.rootViewController);
        if ([candidate isKindOfClass:settingsClass]) {
            return (YTSettingsViewController *)candidate;
        }
    }
    return nil;
}

static const NSUInteger SettingsGroup = 0x67726e72;

static BOOL IsGonerinoSettingsController(UIViewController *viewController) {
    if (!viewController)
        return NO;
    if ([viewController isKindOfClass:NSClassFromString(@"SettingsPageViewController")])
        return NO;

    NSString *expectedTitle = LocalizedString(@"Gonerino");
    NSArray<NSString *> *titles = @[
        viewController.title ?: @"",
        viewController.navigationItem.title ?: @""
    ];
    for (NSString *title in titles) {
        if ([title isEqualToString:expectedTitle])
            return YES;
    }

    @try {
        id category = [viewController valueForKey:@"category"];
        return [category respondsToSelector:@selector(unsignedIntegerValue)] &&
               [category unsignedIntegerValue] == SettingsCategory;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static UIViewController *CustomSettingsDestination(YTSettingsViewController *settingsViewController,
                                                   UIViewController *viewController) {
    YTSettingsSectionItemManager *manager = objc_getAssociatedObject(settingsViewController,
                                                                     SettingsManagerAssociationKey);
    BOOL selected = RecentGonerinoCategorySelection(manager);
    if (!manager || (!IsGonerinoSettingsController(viewController) && !selected))
        return nil;
    objc_setAssociatedObject(manager, SettingsCategorySelectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return CreateCustomSettingsViewController(manager);
}

static YTSettingsSectionItemManager *SettingsManagerForNavigationController(UINavigationController *navigationController) {
    if (!navigationController)
        return nil;

    YTSettingsSectionItemManager *associatedManager = objc_getAssociatedObject(navigationController,
                                                                                 SettingsManagerAssociationKey);
    if (associatedManager)
        return associatedManager;

    for (UIViewController *viewController in navigationController.viewControllers.reverseObjectEnumerator) {
        YTSettingsSectionItemManager *manager = SettingsManagerInHierarchy(viewController, 0);
        if (manager)
            return manager;
    }

    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        YTSettingsSectionItemManager *manager = SettingsManagerInHierarchy(window.rootViewController, 0);
        if (manager)
            return manager;
    }
    return nil;
}

static UIViewController *CustomSettingsDestinationForNavigationController(UINavigationController *navigationController,
                                                                          UIViewController *viewController) {
    YTSettingsSectionItemManager *manager = SettingsManagerForNavigationController(navigationController);
    if (!manager)
        return nil;

    BOOL selected = RecentGonerinoCategorySelection(manager);
    if (!selected && !IsGonerinoSettingsController(viewController))
        return nil;
    objc_setAssociatedObject(manager, SettingsCategorySelectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return CreateCustomSettingsViewController(manager);
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
    YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(self);
    if (category == SettingsCategory) {
        AssociateSettingsManager(settingsViewController, self);
        objc_setAssociatedObject(self,
                                 SettingsCategorySelectionKey,
                                 @([NSDate.date timeIntervalSince1970]),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

- (void)viewWillAppear:(BOOL)animated {
    YTSettingsSectionItemManager *manager = nil;
    @try {
        manager = [self valueForKey:@"_sectionItemManager"];
    } @catch (__unused NSException *exception) {
    }

    %orig;
    @try {
        if ([manager respondsToSelector:@selector(settingsIntegrationUpdateSectionWithEntry:)])
            [manager settingsIntegrationUpdateSectionWithEntry:nil];
    } @catch (__unused NSException *exception) {
    }
}

- (void)loadWithModel:(id)model {
    %orig;
    @try {
        YTSettingsSectionItemManager *manager = [self valueForKey:@"_sectionItemManager"];
        if ([manager respondsToSelector:@selector(settingsIntegrationUpdateSectionWithEntry:)])
            [manager settingsIntegrationUpdateSectionWithEntry:nil];
    } @catch (__unused NSException *exception) {
    }
}

- (void)pushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = CustomSettingsDestination(self, viewController);
    if (customViewController) {
        %orig(customViewController);
        return;
    }
    %orig;
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UIViewController *customViewController = CustomSettingsDestination(self, viewController);
    if (customViewController) {
        %orig(customViewController, animated);
        return;
    }
    %orig;
}

%end

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = CustomSettingsDestinationForNavigationController(self, viewController);
    if (customViewController) {
        %orig(customViewController);
        return;
    }
    %orig;
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UIViewController *customViewController = CustomSettingsDestinationForNavigationController(self, viewController);
    if (customViewController) {
        %orig(customViewController, animated);
        return;
    }
    %orig;
}

%end

%hook YTNavigationController

- (void)pushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = CustomSettingsDestinationForNavigationController(self, viewController);
    if (customViewController) {
        %orig(customViewController);
        return;
    }
    %orig;
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UIViewController *customViewController = CustomSettingsDestinationForNavigationController(self, viewController);
    if (customViewController) {
        %orig(customViewController, animated);
        return;
    }
    %orig;
}

%end

%ctor {
    %init;
}
