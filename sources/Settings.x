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

static YTSettingsSectionItemManager *CurrentSettingsManager;
static BOOL SettingsCategoryPending;

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
        CurrentSettingsManager = self;
        SettingsCategoryPending = YES;
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

%end

static BOOL SettingsCategoryControllerIsReady(UIViewController *viewController) {
    UINavigationController *navigationController = viewController.navigationController;
    if (!SettingsCategoryPending || !CurrentSettingsManager)
        return NO;
    if (!navigationController)
        return NO;

    NSString *expectedTitle = LocalizedString(@"Gonerino");
    NSArray<NSString *> *titles = @[
        viewController.navigationItem.title ?: @"",
        viewController.title ?: @"",
        navigationController.navigationBar.topItem.title ?: @""
    ];
    for (NSString *title in titles) {
        if ([title isEqualToString:expectedTitle])
            return YES;
    }
    return NO;
}

%hook YTCollectionViewController

- (void)viewWillAppear:(BOOL)animated {
    if (SettingsCategoryControllerIsReady(self)) {
        SettingsCategoryPending = NO;
        OpenCustomSettings(CurrentSettingsManager);
        return;
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    if (SettingsCategoryControllerIsReady(self)) {
        SettingsCategoryPending = NO;
        OpenCustomSettings(CurrentSettingsManager);
        return;
    }
    %orig;
}

%end

%ctor {
    %init;
}
