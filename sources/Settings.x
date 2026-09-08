#import "Settings.h"
#import "CustomSettings.h"
#import "Localization.h"
#import <objc/runtime.h>

static void *SettingsManagerAssociationKey = &SettingsManagerAssociationKey;
static void *SettingsNavigationTransactionKey = &SettingsNavigationTransactionKey;

static void AssociateSettingsDestinationManager(UIViewController *viewController,
                                                YTSettingsSectionItemManager *manager);

@interface SettingsNavigationTransaction : NSObject
@property(nonatomic, strong) YTSettingsSectionItemManager *manager;
@property(nonatomic, strong) UIViewController *destination;
@property(nonatomic) NSUInteger expectedCategory;
@end

@implementation SettingsNavigationTransaction
@end

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

static UINavigationController *SettingsNavigationController(YTSettingsViewController *settingsViewController) {
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

static UIViewController *SettingsDestinationForTransaction(YTSettingsViewController *settingsViewController,
                                                           UIViewController *candidate) {
    SettingsNavigationTransaction *transaction = objc_getAssociatedObject(settingsViewController,
                                                                           SettingsNavigationTransactionKey);
    if (!transaction)
        return nil;
    if (candidate == transaction.destination || [candidate isKindOfClass:[transaction.destination class]])
        return candidate;
    return transaction.destination;
}

static void ReplacePresentedSettingsDestination(YTSettingsViewController *settingsViewController,
                                                SettingsNavigationTransaction *transaction) {
    UINavigationController *navigationController = SettingsNavigationController(settingsViewController);
    if (!navigationController)
        return;
    UIViewController *topViewController = navigationController.topViewController;
    if (topViewController == settingsViewController || topViewController == transaction.destination)
        return;
    NSMutableArray<UIViewController *> *viewControllers = navigationController.viewControllers.mutableCopy;
    NSUInteger settingsIndex = [viewControllers indexOfObjectIdenticalTo:settingsViewController];
    if (settingsIndex == NSNotFound || settingsIndex + 1 >= viewControllers.count)
        return;
    viewControllers[settingsIndex + 1] = transaction.destination;
    [navigationController setViewControllers:viewControllers animated:NO];
}

static void BeginSettingsNavigationTransaction(YTSettingsViewController *settingsViewController,
                                               YTSettingsSectionItemManager *manager) {
    if (!settingsViewController || !manager)
        return;
    SettingsNavigationTransaction *transaction = [SettingsNavigationTransaction new];
    transaction.manager = manager;
    transaction.expectedCategory = SettingsCategory;
    transaction.destination = CreateCustomSettingsViewController(manager);
    if (!transaction.destination)
        return;
    objc_setAssociatedObject(settingsViewController,
                             SettingsNavigationTransactionKey,
                             transaction,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ReplacePresentedSettingsDestination(settingsViewController, transaction);
    dispatch_async(dispatch_get_main_queue(), ^{
        SettingsNavigationTransaction *current = objc_getAssociatedObject(settingsViewController,
                                                                           SettingsNavigationTransactionKey);
        if (current != transaction)
            return;
        ReplacePresentedSettingsDestination(settingsViewController, transaction);
        objc_setAssociatedObject(settingsViewController,
                                 SettingsNavigationTransactionKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static UIViewController *ConsumeSettingsDestination(YTSettingsViewController *settingsViewController,
                                                    UIViewController *candidate) {
    UIViewController *destination = SettingsDestinationForTransaction(settingsViewController, candidate);
    if (destination)
        objc_setAssociatedObject(settingsViewController,
                                 SettingsNavigationTransactionKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return destination;
}

static void AssociateSettingsDestinationManager(UIViewController *viewController,
                                                YTSettingsSectionItemManager *manager) {
    if (viewController && manager) {
        objc_setAssociatedObject(viewController,
                                 SettingsManagerAssociationKey,
                                 manager,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL IsGonerinoSettingsDestination(UIViewController *viewController) {
    if (!viewController)
        return NO;
    Class customSettingsClass = NSClassFromString(@"SettingsPageViewController");
    if (customSettingsClass && [viewController isKindOfClass:customSettingsClass])
        return NO;
    id model = nil;
    @try {
        model = [viewController valueForKey:@"model"];
    } @catch (__unused NSException *exception) {
    }
    NSString *modelDescription = [model description] ?: @"";
    NSString *categoryMarker = [NSString stringWithFormat:@"category_id: %lu", (unsigned long)SettingsCategory];
    if ([modelDescription containsString:categoryMarker])
        return YES;
    NSString *expectedTitle = LocalizedString(@"Gonerino");
    return [viewController.title isEqualToString:expectedTitle] ||
           [viewController.navigationItem.title isEqualToString:expectedTitle];
}

static UIViewController *CreateSettingsDestinationForCandidate(YTSettingsViewController *settingsViewController,
                                                                UIViewController *candidate) {
    if (!IsGonerinoSettingsDestination(candidate))
        return nil;
    YTSettingsSectionItemManager *manager = objc_getAssociatedObject(settingsViewController,
                                                                     SettingsManagerAssociationKey);
    if (!manager)
        return nil;
    UIViewController *destination = CreateCustomSettingsViewController(manager);
    AssociateSettingsDestinationManager(destination, manager);
    return destination;
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
        [self settingsIntegrationUpdateSectionWithEntry:entry];
        BeginSettingsNavigationTransaction(settingsViewController, self);
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
    YTSettingsSectionItemManager *manager = nil;
    @try {
        manager = [self valueForKey:@"_sectionItemManager"];
    } @catch (__unused NSException *exception) {
    }
    if (category != SettingsCategory && ![title isEqualToString:LocalizedString(@"Gonerino")])
        return;
    AssociateSettingsManager(self, manager);
}

- (void)pushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = ConsumeSettingsDestination(self, viewController);
    if (!customViewController)
        customViewController = CreateSettingsDestinationForCandidate(self, viewController);
    if (customViewController) {
        AssociateSettingsDestinationManager(customViewController,
                                            objc_getAssociatedObject(self, SettingsManagerAssociationKey));
        %orig(customViewController);
        return;
    }
    %orig;
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UIViewController *customViewController = ConsumeSettingsDestination(self, viewController);
    if (!customViewController)
        customViewController = CreateSettingsDestinationForCandidate(self, viewController);
    if (customViewController) {
        AssociateSettingsDestinationManager(customViewController,
                                            objc_getAssociatedObject(self, SettingsManagerAssociationKey));
        %orig(customViewController, animated);
        return;
    }
    %orig;
}

- (void)showOrPushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = ConsumeSettingsDestination(self, viewController);
    AssociateSettingsDestinationManager(customViewController,
                                        objc_getAssociatedObject(self, SettingsManagerAssociationKey));
%orig(customViewController ?: viewController);
}

%end

static YTSettingsViewController *SettingsControllerInNavigationController(UINavigationController *navigationController) {
    return SettingsViewControllerInHierarchy(navigationController.viewControllers.firstObject, 0);
}

static UIViewController *ConsumeNavigationSettingsDestination(UINavigationController *navigationController,
                                                              UIViewController *candidate) {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(navigationController);
    if (!settingsViewController)
        return nil;
    UIViewController *destination = ConsumeSettingsDestination(settingsViewController, candidate);
    if (!destination)
        destination = CreateSettingsDestinationForCandidate(settingsViewController, candidate);
    AssociateSettingsDestinationManager(destination,
                                        objc_getAssociatedObject(settingsViewController,
                                                                 SettingsManagerAssociationKey));
    return destination;
}

%hook YTNavigationController

- (void)pushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = ConsumeNavigationSettingsDestination(self, viewController);
    %orig(customViewController ?: viewController);
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UIViewController *customViewController = ConsumeNavigationSettingsDestination(self, viewController);
    %orig(customViewController ?: viewController, animated);
}

- (void)showOrPushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = ConsumeNavigationSettingsDestination(self, viewController);
    %orig(customViewController ?: viewController);
}

%end

%hook UINavigationController

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    if (settingsViewController) {
        NSUInteger settingsIndex = [viewControllers indexOfObjectIdenticalTo:settingsViewController];
        if (settingsIndex != NSNotFound && settingsIndex + 1 < viewControllers.count) {
            UIViewController *customViewController = ConsumeSettingsDestination(settingsViewController,
                                                                                  viewControllers[settingsIndex + 1]);
            if (customViewController) {
                NSMutableArray<UIViewController *> *replacedViewControllers = viewControllers.mutableCopy;
                replacedViewControllers[settingsIndex + 1] = customViewController;
                %orig(replacedViewControllers);
                return;
            }
        }
    }
    %orig;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    YTSettingsViewController *settingsViewController = SettingsControllerInNavigationController(self);
    if (settingsViewController) {
        NSUInteger settingsIndex = [viewControllers indexOfObjectIdenticalTo:settingsViewController];
        if (settingsIndex != NSNotFound && settingsIndex + 1 < viewControllers.count) {
            UIViewController *customViewController = ConsumeSettingsDestination(settingsViewController,
                                                                                  viewControllers[settingsIndex + 1]);
            if (customViewController) {
                NSMutableArray<UIViewController *> *replacedViewControllers = viewControllers.mutableCopy;
                replacedViewControllers[settingsIndex + 1] = customViewController;
                %orig(replacedViewControllers, animated);
                return;
            }
        }
    }
    %orig;
}

- (void)pushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = ConsumeNavigationSettingsDestination(self, viewController);
    %orig(customViewController ?: viewController);
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UIViewController *customViewController = ConsumeNavigationSettingsDestination(self, viewController);
    %orig(customViewController ?: viewController, animated);
}

- (void)showViewController:(UIViewController *)viewController sender:(id)sender {
    UIViewController *customViewController = ConsumeNavigationSettingsDestination(self, viewController);
    %orig(customViewController ?: viewController, sender);
}

- (void)showOrPushViewController:(UIViewController *)viewController {
    UIViewController *customViewController = ConsumeNavigationSettingsDestination(self, viewController);
    %orig(customViewController ?: viewController);
}

%end

%ctor {
    %init;
}
