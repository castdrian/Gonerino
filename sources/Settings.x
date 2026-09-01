#import "Settings.h"
#import "Util.h"

#import "ChannelManager.h"
#import "VideoManager.h"
#import "WordManager.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTUIUtils.h>

#define TWEAK_VERSION PACKAGE_VERSION

#define SECTION_HEADER(s)                                                                                              \
    [sectionItems addObject:[objc_getClass("YTSettingsSectionItem")                                                    \
                                          itemWithTitle:@"\t"                                                          \
                                       titleDescription:s                                                              \
                                accessibilityIdentifier:nil                                                            \
                                        detailTextBlock:nil                                                            \
                                            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger sectionItemIndex) {     \
                                                return NO;                                                             \
                                            }]]

static BOOL BooleanPreference(NSString *key, BOOL fallback) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:key] == nil ? fallback : [defaults boolForKey:key];
}

static void SaveBooleanPreference(NSString *key, BOOL value) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:value forKey:key];
    [defaults synchronize];
}

static YTSettingsViewController *SettingsViewControllerForManager(YTSettingsSectionItemManager *manager) {
    id delegate = [manager valueForKey:@"_settingsViewControllerDelegate"];
    return [delegate isKindOfClass:%c(YTSettingsViewController)] ? delegate : nil;
}

static void ShowToastMessage(YTSettingsViewController *viewController, NSString *message) {
    [[%c(YTToastResponderEvent) eventWithMessage:message firstResponder:viewController] send];
}

%hook YTAppSettingsPresentationData

+ (NSArray *)settingsCategoryOrder {
    NSArray *order = %orig;
    NSMutableArray *categories = [order mutableCopy];
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
    [mutableGroups insertObject:settingsGroup atIndex:0];
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

    NSMutableArray *sectionItems = [NSMutableArray array];

    SECTION_HEADER(@"Filtering");

    [sectionItems addObject:[%c(YTSettingsSectionItem)
            switchItemWithTitle:@"Enable Gonerino"
               titleDescription:@"Remove blocked content from YouTube feeds"
        accessibilityIdentifier:nil
                       switchOn:BooleanPreference(@"GonerinoEnabled", YES)
                    switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                        SaveBooleanPreference(@"GonerinoEnabled", enabled);
                        [Util refreshFeedViews];
                        return YES;
                    }
                  settingItemId:0]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
            switchItemWithTitle:@"Show Gonerino Button"
               titleDescription:@"Display the quick toggle in the top navigation bar"
        accessibilityIdentifier:nil
                       switchOn:BooleanPreference(@"GonerinoShowButton", YES)
                    switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                        SaveBooleanPreference(@"GonerinoShowButton", enabled);
                        ShowToastMessage(settingsViewController, [NSString stringWithFormat:@"Gonerino button %@",
                                                                            enabled ? @"shown" : @"hidden"]);
                        return YES;
                    }
                  settingItemId:0]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
            switchItemWithTitle:@"Block 'People also watched this video'"
               titleDescription:@"Remove 'People also watched' suggestions"
        accessibilityIdentifier:nil
                       switchOn:BooleanPreference(@"GonerinoPeopleWatched", NO)
                    switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                        SaveBooleanPreference(@"GonerinoPeopleWatched", enabled);
                        [Util refreshFeedViews];
                        return YES;
                    }
                  settingItemId:0]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
            switchItemWithTitle:@"Block 'You might also like this'"
               titleDescription:@"Remove 'You might also like this' suggestions"
        accessibilityIdentifier:nil
                       switchOn:BooleanPreference(@"GonerinoMightLike", NO)
                    switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                        SaveBooleanPreference(@"GonerinoMightLike", enabled);
                        [Util refreshFeedViews];
                        return YES;
                    }
                  settingItemId:0]];

    SECTION_HEADER(@"Blocked Content");

    NSUInteger channelCount = [ChannelManager sharedInstance].blockedChannels.count;
    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"Manage Channels"
               titleDescription:[NSString stringWithFormat:@"%lu blocked channel%@", (unsigned long)channelCount,
                                                           channelCount == 1 ? @"" : @"s"]
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                        YTSettingsViewController *viewController = SettingsViewControllerForManager(self);
                        NSMutableArray *rows = [NSMutableArray array];
                        [rows addObject:[%c(YTSettingsSectionItem)
                                      itemWithTitle:@"Add Channel"
                                   titleDescription:@"Block a new channel"
                            accessibilityIdentifier:nil
                                    detailTextBlock:nil
                                        selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                                            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Channel"
                                                                                                           message:@"Enter the channel name to block"
                                                                                                    preferredStyle:UIAlertControllerStyleAlert];
                                            [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                                textField.placeholder = @"Channel Name";
                                            }];
                                            [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                                                                       style:UIAlertActionStyleDefault
                                                                                     handler:^(UIAlertAction *action) {
                                                NSString *channel = [alert.textFields.firstObject.text
                                                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                                if (channel.length == 0)
                                                    return;
                                                [[ChannelManager sharedInstance] addBlockedChannel:channel];
                                                [self settingsIntegrationReloadSection];
                                                ShowToastMessage(viewController, [NSString stringWithFormat:@"Added %@", channel]);
                                            }]];
                                            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                       style:UIAlertActionStyleCancel
                                                                                     handler:nil]];
                                            [viewController presentViewController:alert animated:YES completion:nil];
                                            return YES;
                                        }]];
                        for (NSString *channel in [ChannelManager sharedInstance].blockedChannels) {
                            [rows addObject:[%c(YTSettingsSectionItem)
                                          itemWithTitle:channel
                                       titleDescription:nil
                                accessibilityIdentifier:nil
                                        detailTextBlock:nil
                                            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                                                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Channel"
                                                                                                               message:[NSString stringWithFormat:@"Delete '%@'?", channel]
                                                                                                        preferredStyle:UIAlertControllerStyleAlert];
                                                [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                                                           style:UIAlertActionStyleDestructive
                                                                                         handler:^(UIAlertAction *action) {
                                                    [[ChannelManager sharedInstance] removeBlockedChannel:channel];
                                                    [self settingsIntegrationReloadSection];
                                                    ShowToastMessage(viewController, [NSString stringWithFormat:@"Deleted %@", channel]);
                                                }]];
                                                [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                           style:UIAlertActionStyleCancel
                                                                                         handler:nil]];
                                                [viewController presentViewController:alert animated:YES completion:nil];
                                                return YES;
                                            }]];
                        }
                        YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
                              initWithNavTitle:@"Manage Channels"
                            pickerSectionTitle:nil
                                          rows:rows
                             selectedItemIndex:0
                               parentResponder:[self parentResponder]];
                        [viewController pushViewController:picker];
                        return YES;
                    }]];

    NSUInteger videoCount = [VideoManager sharedInstance].blockedVideos.count;
    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"Manage Videos"
               titleDescription:[NSString stringWithFormat:@"%lu blocked video%@", (unsigned long)videoCount,
                                                           videoCount == 1 ? @"" : @"s"]
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                        YTSettingsViewController *viewController = SettingsViewControllerForManager(self);
                        NSMutableArray *rows = [NSMutableArray array];
                        for (NSDictionary *video in [VideoManager sharedInstance].blockedVideos) {
                            NSString *videoTitle = video[@"title"] ?: @"Untitled video";
                            [rows addObject:[%c(YTSettingsSectionItem)
                                          itemWithTitle:videoTitle
                                       titleDescription:video[@"channel"]
                                accessibilityIdentifier:nil
                                        detailTextBlock:nil
                                            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                                                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Video"
                                                                                                               message:[NSString stringWithFormat:@"Delete '%@'?", videoTitle]
                                                                                                        preferredStyle:UIAlertControllerStyleAlert];
                                                [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                                                           style:UIAlertActionStyleDestructive
                                                                                         handler:^(UIAlertAction *action) {
                                                    [[VideoManager sharedInstance] removeBlockedVideo:video[@"id"]];
                                                    [self settingsIntegrationReloadSection];
                                                    ShowToastMessage(viewController, [NSString stringWithFormat:@"Deleted %@", videoTitle]);
                                                }]];
                                                [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                           style:UIAlertActionStyleCancel
                                                                                         handler:nil]];
                                                [viewController presentViewController:alert animated:YES completion:nil];
                                                return YES;
                                            }]];
                        }
                        YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
                              initWithNavTitle:@"Manage Videos"
                            pickerSectionTitle:nil
                                          rows:rows
                             selectedItemIndex:0
                               parentResponder:[self parentResponder]];
                        [viewController pushViewController:picker];
                        return YES;
                    }]];

    NSUInteger wordCount = [WordManager sharedInstance].blockedWords.count;
    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"Manage Words"
               titleDescription:[NSString stringWithFormat:@"%lu blocked word%@", (unsigned long)wordCount,
                                                           wordCount == 1 ? @"" : @"s"]
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                        YTSettingsViewController *viewController = SettingsViewControllerForManager(self);
                        NSMutableArray *rows = [NSMutableArray array];
                        [rows addObject:[%c(YTSettingsSectionItem)
                                      itemWithTitle:@"Add Word"
                                   titleDescription:@"Block a new word or phrase"
                            accessibilityIdentifier:nil
                                    detailTextBlock:nil
                                        selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                                            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Word"
                                                                                                           message:@"Enter a word or phrase to block"
                                                                                                    preferredStyle:UIAlertControllerStyleAlert];
                                            [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                                textField.placeholder = @"Word or phrase";
                                            }];
                                            [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                                                                       style:UIAlertActionStyleDefault
                                                                                     handler:^(UIAlertAction *action) {
                                                NSString *word = [alert.textFields.firstObject.text
                                                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                                if (word.length == 0)
                                                    return;
                                                [[WordManager sharedInstance] addBlockedWord:word];
                                                [self settingsIntegrationReloadSection];
                                                ShowToastMessage(viewController, [NSString stringWithFormat:@"Added %@", word]);
                                            }]];
                                            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                       style:UIAlertActionStyleCancel
                                                                                     handler:nil]];
                                            [viewController presentViewController:alert animated:YES completion:nil];
                                            return YES;
                                        }]];
                        for (NSString *word in [WordManager sharedInstance].blockedWords) {
                            [rows addObject:[%c(YTSettingsSectionItem)
                                          itemWithTitle:word
                                       titleDescription:nil
                                accessibilityIdentifier:nil
                                        detailTextBlock:nil
                                            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                                                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Word"
                                                                                                               message:[NSString stringWithFormat:@"Delete '%@'?", word]
                                                                                                        preferredStyle:UIAlertControllerStyleAlert];
                                                [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                                                           style:UIAlertActionStyleDestructive
                                                                                         handler:^(UIAlertAction *action) {
                                                    [[WordManager sharedInstance] removeBlockedWord:word];
                                                    [self settingsIntegrationReloadSection];
                                                    ShowToastMessage(viewController, [NSString stringWithFormat:@"Deleted %@", word]);
                                                }]];
                                                [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                           style:UIAlertActionStyleCancel
                                                                                         handler:nil]];
                                                [viewController presentViewController:alert animated:YES completion:nil];
                                                return YES;
                                            }]];
                        }
                        YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
                              initWithNavTitle:@"Manage Words"
                            pickerSectionTitle:nil
                                          rows:rows
                             selectedItemIndex:0
                               parentResponder:[self parentResponder]];
                        [viewController pushViewController:picker];
                        return YES;
                    }]];

    SECTION_HEADER(@"Manage Settings");

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"Export Settings"
               titleDescription:@"Export your block lists and preferences"
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                        NSDictionary *settings = @{
                            @"blockedChannels": [ChannelManager sharedInstance].blockedChannels,
                            @"blockedVideos": [VideoManager sharedInstance].blockedVideos,
                            @"blockedWords": [WordManager sharedInstance].blockedWords,
                            @"gonerinoEnabled": @(BooleanPreference(@"GonerinoEnabled", YES)),
                            @"showButton": @(BooleanPreference(@"GonerinoShowButton", YES)),
                            @"blockPeopleWatched": @([NSUserDefaults.standardUserDefaults boolForKey:@"GonerinoPeopleWatched"]),
                            @"blockMightLike": @([NSUserDefaults.standardUserDefaults boolForKey:@"GonerinoMightLike"])
                        };
                        NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"gonerino_settings.plist"]];
                        if (![settings writeToURL:url atomically:YES]) {
                            ShowToastMessage(settingsViewController, @"Failed to prepare settings export");
                            return NO;
                        }
                        isImportOperation = NO;
                        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url]];
                        picker.delegate = (id<UIDocumentPickerDelegate>)self;
                        [settingsViewController presentViewController:picker animated:YES completion:nil];
                        return YES;
                    }]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"Import Settings"
               titleDescription:@"Restore your block lists and preferences"
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                        isImportOperation = YES;
                        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                            initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"com.apple.property-list"]]];
                        picker.delegate = (id<UIDocumentPickerDelegate>)self;
                        [settingsViewController presentViewController:picker animated:YES completion:nil];
                        return YES;
                    }]];

    SECTION_HEADER(@"About");

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"GitHub"
               titleDescription:@"View source code and report issues"
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                        return [%c(YTUIUtils) openURL:[NSURL URLWithString:@"https://github.com/castdrian/Gonerino"]];
                    }]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"Donate"
               titleDescription:@"Support Gonerino development"
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                        return [%c(YTUIUtils) openURL:[NSURL URLWithString:@"https://ko-fi.com/castdrian"]];
                    }]];

    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"Version"
               titleDescription:nil
        accessibilityIdentifier:nil
                detailTextBlock:^NSString * { return [NSString stringWithFormat:@"v%@", TWEAK_VERSION]; }
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger index) {
                        return [%c(YTUIUtils) openURL:[NSURL URLWithString:@"https://github.com/castdrian/Gonerino/releases"]];
                    }]];

    YTIIcon *icon = [%c(YTIIcon) new];
    icon.iconType = YT_FILTER;
    [settingsViewController setSectionItems:sectionItems
                                forCategory:SettingsCategory
                                      title:@"Gonerino"
                                       icon:icon
                           titleDescription:nil
                               headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == SettingsCategory) {
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

%new
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0)
        return;

    BOOL importing = isImportOperation;
    isImportOperation = NO;
    YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(self);
    NSURL *url = urls.firstObject;

    if (!importing) {
        NSMutableDictionary *settings = [NSMutableDictionary dictionary];
        settings[@"blockedChannels"] = [ChannelManager sharedInstance].blockedChannels;
        settings[@"blockedVideos"] = [VideoManager sharedInstance].blockedVideos;
        settings[@"blockedWords"] = [WordManager sharedInstance].blockedWords;
        settings[@"gonerinoEnabled"] = @(BooleanPreference(@"GonerinoEnabled", YES));
        settings[@"showButton"] = @(BooleanPreference(@"GonerinoShowButton", YES));
        settings[@"blockPeopleWatched"] = @([NSUserDefaults.standardUserDefaults boolForKey:@"GonerinoPeopleWatched"]);
        settings[@"blockMightLike"] = @([NSUserDefaults.standardUserDefaults boolForKey:@"GonerinoMightLike"]);
        if ([settings writeToURL:url atomically:YES])
            ShowToastMessage(settingsViewController, @"Settings exported successfully");
        else
            ShowToastMessage(settingsViewController, @"Failed to export settings");
        return;
    }

    [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    [url stopAccessingSecurityScopedResource];
    NSError *error = nil;
    NSDictionary *settings = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                                options:NSPropertyListImmutable
                                                                                 format:nil
                                                                                   error:&error]
                                   : nil;
    if (![settings isKindOfClass:[NSDictionary class]]) {
        ShowToastMessage(settingsViewController, @"Invalid settings file");
        return;
    }

    NSArray *channels = settings[@"blockedChannels"];
    if ([channels isKindOfClass:[NSArray class]])
        [[ChannelManager sharedInstance] setBlockedChannels:channels];
    NSArray *videos = settings[@"blockedVideos"];
    if ([videos isKindOfClass:[NSArray class]])
        [[VideoManager sharedInstance] setBlockedVideos:videos];
    NSArray *words = settings[@"blockedWords"];
    if ([words isKindOfClass:[NSArray class]])
        [[WordManager sharedInstance] setBlockedWords:words];

    NSNumber *enabled = settings[@"gonerinoEnabled"];
    if ([enabled isKindOfClass:[NSNumber class]])
        SaveBooleanPreference(@"GonerinoEnabled", enabled.boolValue);
    NSNumber *showButton = settings[@"showButton"];
    if ([showButton isKindOfClass:[NSNumber class]])
        SaveBooleanPreference(@"GonerinoShowButton", showButton.boolValue);
    NSNumber *peopleWatched = settings[@"blockPeopleWatched"];
    if ([peopleWatched isKindOfClass:[NSNumber class]])
        SaveBooleanPreference(@"GonerinoPeopleWatched", peopleWatched.boolValue);
    NSNumber *mightLike = settings[@"blockMightLike"];
    if ([mightLike isKindOfClass:[NSNumber class]])
        SaveBooleanPreference(@"GonerinoMightLike", mightLike.boolValue);

    [self settingsIntegrationReloadSection];
    [Util refreshFeedViews];
    ShowToastMessage(settingsViewController, @"Settings imported successfully");
}

%new
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(self);
    ShowToastMessage(settingsViewController, isImportOperation ? @"Import cancelled" : @"Export cancelled");
    isImportOperation = NO;
}

%end
