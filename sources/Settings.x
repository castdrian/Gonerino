#import "Settings.h"
#import "CustomSettings.h"
#import "Localization.h"

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
    return nil;
}

static BOOL GonerinoCategoryIsVisible(YTSettingsSectionItemManager *manager) {
    YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(manager);
    UIViewController *topViewController = settingsViewController.navigationController.topViewController;
    return [topViewController.title isEqualToString:LocalizedString(@"Gonerino")];
}

static void OpenCustomSettingsWhenCategoryIsVisible(YTSettingsSectionItemManager *manager, NSUInteger attempt) {
    if (GonerinoCategoryIsVisible(manager)) {
        OpenCustomSettings(manager);
        return;
    }

    if (attempt < 12) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           OpenCustomSettingsWhenCategoryIsVisible(manager, attempt + 1);
                       });
    }
}

%hook YTAppSettingsPresentationData

+ (NSArray *)settingsCategoryOrder {
    NSArray *order = %orig;
    NSMutableArray *categories = [order mutableCopy] ?: [NSMutableArray array];
    if (![categories containsObject:@(SettingsCategory)]) {
        NSUInteger insertIndex = [categories indexOfObject:@(1)];
        if (insertIndex == NSNotFound)
            [categories addObject:@(SettingsCategory)];
        else
            [categories insertObject:@(SettingsCategory) atIndex:insertIndex + 1];
    }
    return categories.copy;
}

%end

%hook YTAppSettingsGroupPresentationData

+ (NSArray *)orderedGroups {
    NSArray *groups = %orig;
    for (YTSettingsGroupData *group in groups) {
        if (group.type == SettingsGroup)
            return groups;
    }

    NSMutableArray *mutableGroups = groups.mutableCopy ?: [NSMutableArray array];
    YTSettingsGroupData *settingsGroup = [[%c(YTSettingsGroupData) alloc] initWithGroupType:SettingsGroup];
    [mutableGroups addObject:settingsGroup];
    return mutableGroups.copy;
}

%end

%hook YTSettingsGroupData

- (NSString *)titleForSettingGroupType:(NSUInteger)type {
    if (type == SettingsGroup)
        return @"Gonerino";
    return %orig;
}

- (NSArray<NSNumber *> *)orderedCategoriesForGroupType:(NSUInteger)type {
    if (type == SettingsGroup)
        return @[@(SettingsCategory)];
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
