#import "Settings.h"
#import "CustomSettings.h"
#import "Localization.h"

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
            if ([delegate isKindOfClass:%c(YTSettingsViewController)])
                return delegate;
        } @catch (__unused NSException *exception) {
        }
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

static BOOL GonerinoCategoryIsVisible(YTSettingsSectionItemManager *manager) {
    YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(manager);
    UIViewController *topViewController = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            topViewController = TopVisibleViewController(window.rootViewController);
            break;
        }
    }
    if (!topViewController)
        topViewController = settingsViewController.navigationController.topViewController ?: settingsViewController;
    NSString *title = topViewController.title ?: topViewController.navigationItem.title;
    if (title.length == 0)
        title = settingsViewController.navigationController.navigationBar.topItem.title;
    return [title isEqualToString:LocalizedString(@"Gonerino")];
}

static void OpenCustomSettingsWhenCategoryIsVisible(YTSettingsSectionItemManager *manager, NSUInteger attempt) {
    if (GonerinoCategoryIsVisible(manager)) {
        OpenCustomSettings(manager);
        return;
    }

    if (attempt < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           OpenCustomSettingsWhenCategoryIsVisible(manager, attempt + 1);
                       });
    }
}

static const NSUInteger SettingsGroup = 0x67726e72;

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
    [settingsViewController setSectionItems:[NSMutableArray array]
                                forCategory:SettingsCategory
                                      title:LocalizedString(@"Gonerino")
                                       icon:icon
                           titleDescription:nil
                               headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == SettingsCategory) {
        [self settingsIntegrationUpdateSectionWithEntry:entry];
        OpenCustomSettingsWhenCategoryIsVisible(self, 0);
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
    %orig;
    @try {
        YTSettingsSectionItemManager *manager = [self valueForKey:@"_sectionItemManager"];
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

%end

%ctor {
    %init;
}
