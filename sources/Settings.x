#import "Settings.h"
#import "Util.h"

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
    if (self.type != 1)
        return %orig;
    NSMutableArray *mutableCategories = %orig.mutableCopy;
    [mutableCategories insertObject:@(GonerinoSection) atIndex:0];
    return mutableCategories.copy;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray *)settingsCategoryOrder {
    NSArray *order               = %orig;
    NSMutableArray *mutableOrder = [order mutableCopy];
    NSUInteger insertIndex       = [order indexOfObject:@(1)];
    if (insertIndex != NSNotFound) {
        [mutableOrder insertObject:@(GonerinoSection) atIndex:insertIndex + 1];
    }
    return mutableOrder;
}

%end

%hook YTSettingsSectionItemManager

%new
- (void)updateGonerinoSectionWithEntry:(id)entry {
    YTSettingsViewController *delegate = [self valueForKey:@"_settingsViewControllerDelegate"];
    NSMutableArray *sectionItems       = [NSMutableArray array];

    SECTION_HEADER(@"Gonerino Settings");

    YTSettingsSectionItem *showButtonToggle = [%c(YTSettingsSectionItem)
            switchItemWithTitle:@"Show Gonerino Button"
               titleDescription:@"Display Gonerino toggle button in top navbar"
        accessibilityIdentifier:nil
                       switchOn:[[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                                    ? YES
                                    : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"]
                    switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"GonerinoShowButton"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
                        [[%c(YTToastResponderEvent)
                            eventWithMessage:[NSString
                                                 stringWithFormat:@"Gonerino button %@", enabled ? @"shown" : @"hidden"]
                              firstResponder:settingsVC] send];
                        return YES;
                    }
                  settingItemId:0];
    [sectionItems addObject:showButtonToggle];

    NSUInteger channelCount               = [[ChannelManager sharedInstance] blockedChannels].count;
    YTSettingsSectionItem *manageChannels = [%c(YTSettingsSectionItem)
                  itemWithTitle:@"Manage Channels"
               titleDescription:[NSString stringWithFormat:@"%lu blocked channel%@", (unsigned long)channelCount,
                                                           channelCount == 1 ? @"" : @"s"]
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                        NSMutableArray *rows = [NSMutableArray array];

                        [rows
                            addObject:
                                [%c(YTSettingsSectionItem)
                                              itemWithTitle:@"Add Channel"
                                           titleDescription:@"Block a new channel"
                                    accessibilityIdentifier:nil
                                            detailTextBlock:nil
                                                selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                                                    YTSettingsViewController *settingsVC =
                                                        [self valueForKey:@"_settingsViewControllerDelegate"];
                                                    UIAlertController *alertController = [UIAlertController
                                                        alertControllerWithTitle:@"Add Channel"
                                                                         message:@"Enter the "
                                                                                 @"channel name to "
                                                                                 @"block"
                                                                  preferredStyle:UIAlertControllerStyleAlert];

                                                    [alertController
                                                        addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                                            textField.placeholder = @"Channel Name";
                                                        }];

                                                    [alertController
                                                        addAction:
                                                            [UIAlertAction
                                                                actionWithTitle:@"Add"
                                                                          style:UIAlertActionStyleDefault
                                                                        handler:^(UIAlertAction *action) {
                                                                            NSString *channelName =
                                                                                alertController.textFields.firstObject
                                                                                    .text;
                                                                            if (channelName.length > 0) {
                                                                                [[ChannelManager sharedInstance]
                                                                                    addBlockedChannel:channelName];
                                                                                [self reloadGonerinoSection];

                                                                                UIImpactFeedbackGenerator *generator =
                                                                                    [[UIImpactFeedbackGenerator alloc]
                                                                                        initWithStyle:
                                                                                            UIImpactFeedbackStyleMedium];
                                                                                [generator prepare];
                                                                                [generator impactOccurred];

                                                                                [[%c(YTToastResponderEvent)
                                                                                    eventWithMessage:
                                                                                        [NSString stringWithFormat:
                                                                                                      @"A"
                                                                                                      @"d"
                                                                                                      @"d"
                                                                                                      @"e"
                                                                                                      @"d"
                                                                                                      @" "
                                                                                                      @"%"
                                                                                                      @"@",
                                                                                                      channelName]
                                                                                      firstResponder:settingsVC] send];
                                                                            }
                                                                        }]];

                                                    [alertController
                                                        addAction:[UIAlertAction
                                                                      actionWithTitle:@"Cancel"
                                                                                style:UIAlertActionStyleCancel
                                                                              handler:nil]];

                                                    [settingsVC presentViewController:alertController
                                                                             animated:YES
                                                                           completion:nil];
                                                    return YES;
                                                }]];

                        for (NSString *channelName in [[ChannelManager sharedInstance] blockedChannels]) {
                            [rows
                                addObject:
                                    [%c(YTSettingsSectionItem)
                                                  itemWithTitle:channelName
                                               titleDescription:nil
                                        accessibilityIdentifier:nil
                                                detailTextBlock:nil
                                                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                                                        YTSettingsViewController *settingsVC =
                                                            [self valueForKey:@"_settingsViewControllerDelegate"];
                                                        UIAlertController *alertController = [UIAlertController
                                                            alertControllerWithTitle:@"Delete Channel"
                                                                             message:[NSString
                                                                                         stringWithFormat:@"Are you "
                                                                                                          @"sure "
                                                                                                          @"you "
                                                                                                          @"want to "
                                                                                                          @"delete "
                                                                                                          @"'%@'?",
                                                                                                          channelName]
                                                                      preferredStyle:UIAlertControllerStyleAlert];

                                                        [alertController
                                                            addAction:
                                                                [UIAlertAction
                                                                    actionWithTitle:@"Delete"
                                                                              style:UIAlertActionStyleDestructive
                                                                            handler:^(UIAlertAction *action) {
                                                                                [[ChannelManager sharedInstance]
                                                                                    removeBlockedChannel:channelName];
                                                                                [self reloadGonerinoSection];

                                                                                UIImpactFeedbackGenerator *generator =
                                                                                    [[UIImpactFeedbackGenerator alloc]
                                                                                        initWithStyle:
                                                                                            UIImpactFeedbackStyleMedium];
                                                                                [generator prepare];
                                                                                [generator impactOccurred];

                                                                                [[%c(YTToastResponderEvent)
                                                                                    eventWithMessage:
                                                                                        [NSString stringWithFormat:
                                                                                                      @"D"
                                                                                                      @"e"
                                                                                                      @"l"
                                                                                                      @"e"
                                                                                                      @"t"
                                                                                                      @"e"
                                                                                                      @"d"
                                                                                                      @" "
                                                                                                      @"%"
                                                                                                      @"@",
                                                                                                      channelName]
                                                                                      firstResponder:settingsVC] send];
                                                                            }]];

                                                        [alertController
                                                            addAction:[UIAlertAction
                                                                          actionWithTitle:@"Cancel"
                                                                                    style:UIAlertActionStyleCancel
                                                                                  handler:nil]];

                                                        [settingsVC presentViewController:alertController
                                                                                 animated:YES
                                                                               completion:nil];
                                                        return YES;
                                                    }]];
                        }

                        YTSettingsViewController *settingsVC   = [self valueForKey:@"_settingsViewControllerDelegate"];
                        YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
                              initWithNavTitle:@"Manage Channels"
                            pickerSectionTitle:nil
                                          rows:rows
                             selectedItemIndex:NSNotFound
                               parentResponder:[self parentResponder]];

                        if ([settingsVC respondsToSelector:@selector(navigationController)]) {
                            UINavigationController *nav = settingsVC.navigationController;
                            [nav pushViewController:picker animated:YES];
                        }
                        return YES;
                    }];
    [sectionItems addObject:manageChannels];

    NSUInteger videoCount               = [[VideoManager sharedInstance] blockedVideos].count;
    YTSettingsSectionItem *manageVideos = [%c(YTSettingsSectionItem)
                  itemWithTitle:@"Manage Videos"
               titleDescription:[NSString stringWithFormat:@"%lu blocked video%@", (unsigned long)videoCount,
                                                           videoCount == 1 ? @"" : @"s"]
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                        NSArray *blockedVideos = [[VideoManager sharedInstance] blockedVideos];
                        if (blockedVideos.count == 0) {
                            YTSettingsViewController *settingsVC =
                                [self valueForKey:@"_settingsViewControllerDelegate"];
                            [[%c(YTToastResponderEvent) eventWithMessage:@"No blocked videos"
                                                                     firstResponder:settingsVC] send];
                            return YES;
                        }

                        NSMutableArray *rows = [NSMutableArray array];

                        [rows addObject:[%c(YTSettingsSectionItem)
                                                      itemWithTitle:@"\t"
                                                   titleDescription:@"Blocked videos"
                                            accessibilityIdentifier:nil
                                                    detailTextBlock:nil
                                                        selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                                                            return NO;
                                                        }]];

                        for (NSDictionary *videoInfo in blockedVideos) {
                            [rows
                                addObject:
                                    [%c(YTSettingsSectionItem)
                                                  itemWithTitle:videoInfo[@"channel"] ?: @"Unknown Channel"
                                               titleDescription:videoInfo[@"title"] ?: @"Unknown Title"
                                        accessibilityIdentifier:nil
                                                detailTextBlock:nil
                                                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                                                        YTSettingsViewController *settingsVC =
                                                            [self valueForKey:@"_settingsViewControllerDelegate"];
                                                        UIAlertController *alertController = [UIAlertController
                                                            alertControllerWithTitle:@"Delete Video"
                                                                             message:[NSString
                                                                                         stringWithFormat:
                                                                                             @"Are you sure you want "
                                                                                             @"to delete '%@'?",
                                                                                             videoInfo[@"title"]]
                                                                      preferredStyle:UIAlertControllerStyleAlert];

                                                        [alertController
                                                            addAction:
                                                                [UIAlertAction
                                                                    actionWithTitle:@"Delete"
                                                                              style:UIAlertActionStyleDestructive
                                                                            handler:^(UIAlertAction *action) {
                                                                                [[VideoManager sharedInstance]
                                                                                    removeBlockedVideo:videoInfo
                                                                                                           [@"id"]];
                                                                                [self reloadGonerinoSection];

                                                                                UIImpactFeedbackGenerator *generator =
                                                                                    [[UIImpactFeedbackGenerator alloc]
                                                                                        initWithStyle:
                                                                                            UIImpactFeedbackStyleMedium];
                                                                                [generator prepare];
                                                                                [generator impactOccurred];

                                                                                [[%c(YTToastResponderEvent)
                                                                                    eventWithMessage:
                                                                                        [NSString
                                                                                            stringWithFormat:
                                                                                                @"Deleted %@",
                                                                                                videoInfo[@"title"]]
                                                                                      firstResponder:settingsVC] send];
                                                                            }]];

                                                        [alertController
                                                            addAction:[UIAlertAction
                                                                          actionWithTitle:@"Cancel"
                                                                                    style:UIAlertActionStyleCancel
                                                                                  handler:nil]];

                                                        [settingsVC presentViewController:alertController
                                                                                 animated:YES
                                                                               completion:nil];
                                                        return YES;
                                                    }]];
                        }

                        YTSettingsViewController *settingsVC   = [self valueForKey:@"_settingsViewControllerDelegate"];
                        YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
                              initWithNavTitle:@"Manage Videos"
                            pickerSectionTitle:nil
                                          rows:rows
                             selectedItemIndex:NSNotFound
                               parentResponder:[self parentResponder]];

                        if ([settingsVC respondsToSelector:@selector(navigationController)]) {
                            UINavigationController *nav = settingsVC.navigationController;
                            [nav pushViewController:picker animated:YES];
                        }
                        return YES;
                    }];
    [sectionItems addObject:manageVideos];

    NSUInteger wordCount               = [[WordManager sharedInstance] blockedWords].count;
    YTSettingsSectionItem *manageWords = [%c(YTSettingsSectionItem)
                  itemWithTitle:@"Manage Words"
               titleDescription:[NSString stringWithFormat:@"%lu blocked word%@", (unsigned long)wordCount,
                                                           wordCount == 1 ? @"" : @"s"]
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                        NSMutableArray *rows = [NSMutableArray array];

                        [rows
                            addObject:
                                [%c(YTSettingsSectionItem)
                                              itemWithTitle:@"Add Word"
                                           titleDescription:@"Block a new word or phrase"
                                    accessibilityIdentifier:nil
                                            detailTextBlock:nil
                                                selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                                                    YTSettingsViewController *settingsVC =
                                                        [self valueForKey:@"_settingsViewControllerDelegate"];
                                                    UIAlertController *alertController = [UIAlertController
                                                        alertControllerWithTitle:@"Add Word"
                                                                         message:@"Enter a word or phrase to block"
                                                                  preferredStyle:UIAlertControllerStyleAlert];

                                                    [alertController
                                                        addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                                            textField.placeholder = @"Word or phrase";
                                                        }];

                                                    [alertController
                                                        addAction:
                                                            [UIAlertAction
                                                                actionWithTitle:@"Add"
                                                                          style:UIAlertActionStyleDefault
                                                                        handler:^(UIAlertAction *action) {
                                                                            NSString *word = alertController.textFields
                                                                                                 .firstObject.text;
                                                                            if (word.length > 0) {
                                                                                [[WordManager sharedInstance]
                                                                                    addBlockedWord:word];
                                                                                [self reloadGonerinoSection];

                                                                                UIImpactFeedbackGenerator *generator =
                                                                                    [[UIImpactFeedbackGenerator alloc]
                                                                                        initWithStyle:
                                                                                            UIImpactFeedbackStyleMedium];
                                                                                [generator prepare];
                                                                                [generator impactOccurred];

                                                                                [[%c(YTToastResponderEvent)
                                                                                    eventWithMessage:
                                                                                        [NSString stringWithFormat:
                                                                                                      @"Added %@", word]
                                                                                      firstResponder:settingsVC] send];
                                                                            }
                                                                        }]];

                                                    [alertController
                                                        addAction:[UIAlertAction
                                                                      actionWithTitle:@"Cancel"
                                                                                style:UIAlertActionStyleCancel
                                                                              handler:nil]];

                                                    [settingsVC presentViewController:alertController
                                                                             animated:YES
                                                                           completion:nil];
                                                    return YES;
                                                }]];

                        for (NSString *word in [[WordManager sharedInstance] blockedWords]) {
                            [rows
                                addObject:
                                    [%c(YTSettingsSectionItem)
                                                  itemWithTitle:word
                                               titleDescription:nil
                                        accessibilityIdentifier:nil
                                                detailTextBlock:nil
                                                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                                                        YTSettingsViewController *settingsVC =
                                                            [self valueForKey:@"_settingsViewControllerDelegate"];
                                                        UIAlertController *alertController = [UIAlertController
                                                            alertControllerWithTitle:@"Delete Word"
                                                                             message:[NSString
                                                                                         stringWithFormat:
                                                                                             @"Are you sure you want "
                                                                                             @"to delete '%@'?",
                                                                                             word]
                                                                      preferredStyle:UIAlertControllerStyleAlert];

                                                        [alertController
                                                            addAction:
                                                                [UIAlertAction
                                                                    actionWithTitle:@"Delete"
                                                                              style:UIAlertActionStyleDestructive
                                                                            handler:^(UIAlertAction *action) {
                                                                                [[WordManager sharedInstance]
                                                                                    removeBlockedWord:word];
                                                                                [self reloadGonerinoSection];

                                                                                UIImpactFeedbackGenerator *generator =
                                                                                    [[UIImpactFeedbackGenerator alloc]
                                                                                        initWithStyle:
                                                                                            UIImpactFeedbackStyleMedium];
                                                                                [generator prepare];
                                                                                [generator impactOccurred];

                                                                                [[%c(YTToastResponderEvent)
                                                                                    eventWithMessage:
                                                                                        [NSString
                                                                                            stringWithFormat:
                                                                                                @"Deleted %@", word]
                                                                                      firstResponder:settingsVC] send];
                                                                            }]];

                                                        [alertController
                                                            addAction:[UIAlertAction
                                                                          actionWithTitle:@"Cancel"
                                                                                    style:UIAlertActionStyleCancel
                                                                                  handler:nil]];

                                                        [settingsVC presentViewController:alertController
                                                                                 animated:YES
                                                                               completion:nil];
                                                        return YES;
                                                    }]];
                        }

                        YTSettingsViewController *settingsVC   = [self valueForKey:@"_settingsViewControllerDelegate"];
                        YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
                              initWithNavTitle:@"Manage Words"
                            pickerSectionTitle:nil
                                          rows:rows
                             selectedItemIndex:NSNotFound
                               parentResponder:[self parentResponder]];

                        if ([settingsVC respondsToSelector:@selector(navigationController)]) {
                            UINavigationController *nav = settingsVC.navigationController;
                            [nav pushViewController:picker animated:YES];
                        }
                        return YES;
                    }];
    [sectionItems addObject:manageWords];

    YTSettingsSectionItem *blockPeopleWatched = [%c(YTSettingsSectionItem)
            switchItemWithTitle:@"Block 'People also watched this video'"
               titleDescription:@"Remove 'People also watched' suggestions"
        accessibilityIdentifier:nil
                       switchOn:[[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoPeopleWatched"]
                    switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"GonerinoPeopleWatched"];
                        YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
                        [[%c(YTToastResponderEvent)
                            eventWithMessage:[NSString stringWithFormat:@"'People also watched' %@",
                                                                        enabled ? @"blocked" : @"unblocked"]
                              firstResponder:settingsVC] send];
                        return YES;
                    }
                  settingItemId:0];
    [sectionItems addObject:blockPeopleWatched];

    YTSettingsSectionItem *blockMightLike = [%c(YTSettingsSectionItem)
            switchItemWithTitle:@"Block 'You might also like this'"
               titleDescription:@"Remove 'You might also like this' suggestions"
        accessibilityIdentifier:nil
                       switchOn:[[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoMightLike"]
                    switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"GonerinoMightLike"];
                        YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
                        [[%c(YTToastResponderEvent)
                            eventWithMessage:[NSString stringWithFormat:@"'You might also like' %@",
                                                                        enabled ? @"blocked" : @"unblocked"]
                              firstResponder:settingsVC] send];
                        return YES;
                    }
                  settingItemId:0];
    [sectionItems addObject:blockMightLike];

    SECTION_HEADER(@"Manage Settings");

    YTSettingsSectionItem *exportSettings = [%c(YTSettingsSectionItem)
                  itemWithTitle:@"Export Settings"
               titleDescription:@"Export settings to a plist file"
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                        YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];

                        NSMutableDictionary *settings = [NSMutableDictionary dictionary];
                        settings[@"blockedChannels"]  = [[ChannelManager sharedInstance] blockedChannels];
                        settings[@"blockedVideos"]    = [[VideoManager sharedInstance] blockedVideos];
                        settings[@"blockedWords"]     = [[WordManager sharedInstance] blockedWords];
                        settings[@"gonerinoEnabled"] =
                            @([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                                  ? YES
                                  : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"]);
                        settings[@"blockPeopleWatched"] =
                            @([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoPeopleWatched"]);
                        settings[@"blockMightLike"] =
                            @([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoMightLike"]);

                        NSURL *tempFileURL =
                            [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                                       stringByAppendingPathComponent:@"gonerino_settings.plist"]];
                        [settings writeToURL:tempFileURL atomically:YES];

                        isImportOperation = NO;

                        UIDocumentPickerViewController *picker =
                            [[UIDocumentPickerViewController alloc] initForExportingURLs:@[tempFileURL]];
                        picker.delegate = (id<UIDocumentPickerDelegate>)self;
                        [settingsVC presentViewController:picker animated:YES completion:nil];
                        return YES;
                    }];
    [sectionItems addObject:exportSettings];

    YTSettingsSectionItem *importSettings = [%c(YTSettingsSectionItem)
                  itemWithTitle:@"Import Settings"
               titleDescription:@"Import settings from a plist file"
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                        YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];

                        isImportOperation = YES;

                        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                            initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"com.apple.property-list"]]];
                        picker.delegate                        = (id<UIDocumentPickerDelegate>)self;
                        [settingsVC presentViewController:picker animated:YES completion:nil];
                        return YES;
                    }];
    [sectionItems addObject:importSettings];

    SECTION_HEADER(@"About");

    [sectionItems
        addObject:[%c(YTSettingsSectionItem) itemWithTitle:@"GitHub"
                                                     titleDescription:@"View source code and report issues"
                                              accessibilityIdentifier:nil
                                                      detailTextBlock:nil
                                                          selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                                                              return [%c(YTUIUtils)
                                                                  openURL:[NSURL URLWithString:@"https://github.com/"
                                                                                               @"castdrian/Gonerino"]];
                                                          }]];

    [sectionItems
        addObject:[%c(YTSettingsSectionItem) itemWithTitle:@"Version"
                      titleDescription:nil
                      accessibilityIdentifier:nil
                      detailTextBlock:^NSString *() { return [NSString stringWithFormat:@"v%@", TWEAK_VERSION]; }
                      selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                          return [%c(YTUIUtils)
                              openURL:[NSURL URLWithString:@"https://github.com/castdrian/Gonerino/releases"]];
                      }]];

    if ([delegate respondsToSelector:@selector(setSectionItems:
                                                   forCategory:title:icon:titleDescription:headerHidden:)]) {
        YTIIcon *icon = [%c(YTIIcon) new];
        icon.iconType = YT_FILTER;

        [delegate setSectionItems:sectionItems
                      forCategory:GonerinoSection
                            title:@"Gonerino"
                             icon:icon
                 titleDescription:nil
                     headerHidden:NO];
    } else {
        [delegate setSectionItems:sectionItems
                      forCategory:GonerinoSection
                            title:@"Gonerino"
                 titleDescription:nil
                     headerHidden:NO];
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == GonerinoSection) {
        [self updateGonerinoSectionWithEntry:entry];
        return;
    }
    %orig;
}

%new
- (UITableView *)findTableViewInView:(UIView *)view {
    if ([view isKindOfClass:[UITableView class]]) {
        return (UITableView *)view;
    }
    for (UIView *subview in view.subviews) {
        UITableView *tableView = [self findTableViewInView:subview];
        if (tableView) {
            return tableView;
        }
    }
    return nil;
}

%new
- (void)reloadGonerinoSection {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTSettingsViewController *delegate = [self valueForKey:@"_settingsViewControllerDelegate"];
        if ([delegate isKindOfClass:%c(YTSettingsViewController)]) {
            [self updateGonerinoSectionWithEntry:nil];
            UITableView *tableView = [self findTableViewInView:delegate.view];
            if (tableView) {
                [tableView beginUpdates];
                NSIndexSet *sectionSet = [NSIndexSet indexSetWithIndex:GonerinoSection];
                [tableView reloadSections:sectionSet withRowAnimation:UITableViewRowAnimationAutomatic];
                [tableView endUpdates];
            }
        }
    });
}

%new
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0)
        return;

    YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
    NSURL *url                           = urls.firstObject;

    if (isImportOperation) {
        [url startAccessingSecurityScopedResource];

        NSError *error = nil;
        NSData *data   = [NSData dataWithContentsOfURL:url options:0 error:&error];

        [url stopAccessingSecurityScopedResource];

        if (!data || error) {
            [[%c(YTToastResponderEvent) eventWithMessage:@"Failed to read settings file"
                                                     firstResponder:settingsVC] send];
            return;
        }

        NSDictionary *settings = [NSPropertyListSerialization propertyListWithData:data
                                                                           options:NSPropertyListImmutable
                                                                            format:NULL
                                                                             error:&error];

        if (!settings || error) {
            [[%c(YTToastResponderEvent) eventWithMessage:@"Invalid settings file format"
                                                     firstResponder:settingsVC] send];
            return;
        }

        void (^continueImport)(void) = ^{
            NSArray *words = settings[@"blockedWords"];
            if (words) {
                [[WordManager sharedInstance] setBlockedWords:words];
            }

            NSNumber *peopleWatched = settings[@"blockPeopleWatched"];
            if (peopleWatched) {
                [[NSUserDefaults standardUserDefaults] setBool:[peopleWatched boolValue]
                                                        forKey:@"GonerinoPeopleWatched"];
            }

            NSNumber *mightLike = settings[@"blockMightLike"];
            if (mightLike) {
                [[NSUserDefaults standardUserDefaults] setBool:[mightLike boolValue] forKey:@"GonerinoMightLike"];
            }

            NSNumber *gonerinoEnabled = settings[@"gonerinoEnabled"];
            if (gonerinoEnabled) {
                [[NSUserDefaults standardUserDefaults] setBool:[gonerinoEnabled boolValue] forKey:@"GonerinoEnabled"];
            }

            [[NSUserDefaults standardUserDefaults] synchronize];
            [self reloadGonerinoSection];
            [[%c(YTToastResponderEvent) eventWithMessage:@"Settings imported successfully"
                                                     firstResponder:settingsVC] send];
        };

        NSArray *channels = settings[@"blockedChannels"];
        if (channels) {
            [[ChannelManager sharedInstance] setBlockedChannels:[NSMutableArray arrayWithArray:channels]];
        }

        NSArray *videos = settings[@"blockedVideos"];
        if (videos) {
            if ([videos isKindOfClass:[NSArray class]]) {
                BOOL isValidFormat = YES;
                for (id videoEntry in videos) {
                    if (![videoEntry isKindOfClass:[NSDictionary class]] ||
                        ![videoEntry[@"id"] isKindOfClass:[NSString class]] ||
                        ![videoEntry[@"title"] isKindOfClass:[NSString class]] ||
                        ![videoEntry[@"channel"] isKindOfClass:[NSString class]] || [videoEntry count] != 3) {
                        isValidFormat = NO;
                        break;
                    }
                }

                if (isValidFormat) {
                    [[VideoManager sharedInstance] setBlockedVideos:videos];
                    continueImport();
                } else {
                    [[%c(YTToastResponderEvent)
                        eventWithMessage:@"Format outdated, blocked videos will not be imported"
                          firstResponder:settingsVC] send];

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ continueImport(); });
                }
            } else {
                [[%c(YTToastResponderEvent)
                    eventWithMessage:@"Format outdated, blocked videos will not be imported"
                      firstResponder:settingsVC] send];

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ continueImport(); });
            }
        } else {
            continueImport();
        }
    } else {
        NSMutableDictionary *settings = [NSMutableDictionary dictionary];
        settings[@"blockedChannels"]  = [[ChannelManager sharedInstance] blockedChannels];
        settings[@"blockedVideos"]    = [[VideoManager sharedInstance] blockedVideos];
        settings[@"blockedWords"]     = [[WordManager sharedInstance] blockedWords];
        settings[@"gonerinoEnabled"]  = @([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                                              ? YES
                                              : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"]);
        settings[@"blockPeopleWatched"] =
            @([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoPeopleWatched"]);
        settings[@"blockMightLike"] = @([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoMightLike"]);

        [settings writeToURL:url atomically:YES];
        [[%c(YTToastResponderEvent) eventWithMessage:@"Settings exported successfully"
                                                 firstResponder:settingsVC] send];
    }
}

%new
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
    NSString *message                    = isImportOperation ? @"Import cancelled" : @"Export cancelled";
    [[%c(YTToastResponderEvent) eventWithMessage:message firstResponder:settingsVC] send];
}

%end

%hook YTSettingsViewController

- (void)loadWithModel:(id)model {
    %orig;
    if ([self respondsToSelector:@selector(updateSectionForCategory:withEntry:)]) {
        [(YTSettingsSectionItemManager *)[self valueForKey:@"_sectionItemManager"] updateGonerinoSectionWithEntry:nil];
    }
}

%end

%ctor {
    %init;
}
