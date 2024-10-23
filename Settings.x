#import <version.h>
#import <YouTubeHeader/YTAlertView.h>
#import <YouTubeHeader/YTHotConfig.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTAppSettingsSectionItemActionController.h>
#import "ChannelManager.h"

#define LOC(x) [tweakBundle localizedStringForKey:x value:nil table:nil]

static const NSInteger GonerinoSection = 200;

@interface YTSettingsSectionItemManager (Gonerino)
- (void)updateGonerinoSectionWithEntry:(id)entry;
- (UITableView *)findTableViewInView:(UIView *)view;
- (void)reloadGonerinoSection;
@end

%hook YTAppSettingsPresentationData

+ (NSArray *)settingsCategoryOrder {
    NSArray *order = %orig;
    NSMutableArray *mutableOrder = [order mutableCopy];
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    if (insertIndex != NSNotFound) {
        [mutableOrder insertObject:@(GonerinoSection) atIndex:insertIndex + 1];
    }
    return mutableOrder;
}

%end

%hook YTSettingsSectionItemManager

%new
- (void)updateGonerinoSectionWithEntry:(id)entry {
    YTSettingsViewController *delegate = [self valueForKey:@"_dataDelegate"];
    NSMutableArray *sectionItems = [NSMutableArray array];

    YTSettingsSectionItem *addChannel = [%c(YTSettingsSectionItem) itemWithTitle:@"Add Blocked Channel"
        titleDescription:@"Add a channel name to block"
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Add Channel"
                                                                                     message:@"Enter the channel name to block"
                                                                              preferredStyle:UIAlertControllerStyleAlert];
            [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                textField.placeholder = @"Channel Name";
            }];
            UIAlertAction *addAction = [UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                NSString *channelName = alertController.textFields.firstObject.text;
                if (channelName.length > 0) {
                    [[ChannelManager sharedInstance] addBlockedChannel:channelName];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self reloadGonerinoSection];
                    });
                }
            }];
            UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
            [alertController addAction:addAction];
            [alertController addAction:cancelAction];
            [delegate presentViewController:alertController animated:YES completion:nil];
            return YES;
        }];
    [sectionItems addObject:addChannel];

    YTSettingsSectionItem *importChannels = [%c(YTSettingsSectionItem) itemWithTitle:@"Import Blocked Channels"
        titleDescription:@"Import channel names from clipboard"
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            NSString *clipboardContent = [UIPasteboard generalPasteboard].string;
            NSArray *channelNames = [clipboardContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            for (NSString *channelName in channelNames) {
                if (channelName.length > 0) {
                    [[ChannelManager sharedInstance] addBlockedChannel:channelName];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reloadGonerinoSection];
            });
            return YES;
        }];
    [sectionItems addObject:importChannels];

    YTSettingsSectionItem *exportChannels = [%c(YTSettingsSectionItem) itemWithTitle:@"Export Blocked Channels"
        titleDescription:@"Copy channel names to clipboard"
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            NSArray *blockedChannels = [[ChannelManager sharedInstance] blockedChannels];
            NSString *channelList = [blockedChannels componentsJoinedByString:@"\n"];
            [UIPasteboard generalPasteboard].string = channelList;
            return YES;
        }];
    [sectionItems addObject:exportChannels];

    NSArray *blockedChannels = [[ChannelManager sharedInstance] blockedChannels];
    if (blockedChannels.count > 0) {
        YTSettingsSectionItem *separator = [%c(YTSettingsSectionItem) itemWithTitle:@"Blocked Channels"
            titleDescription:nil
            accessibilityIdentifier:nil
            detailTextBlock:nil
            selectBlock:nil];
        separator.enabled = NO;
        [sectionItems addObject:separator];
    }

    for (NSString *channelName in blockedChannels) {
        YTSettingsSectionItem *channelItem = [%c(YTSettingsSectionItem) itemWithTitle:channelName
            titleDescription:nil
            accessibilityIdentifier:nil
            detailTextBlock:nil
            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg1) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Delete Channel"
                                                                                         message:[NSString stringWithFormat:@"Are you sure you want to delete '%@'?", channelName]
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                
                UIAlertAction *deleteAction = [UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                    [[ChannelManager sharedInstance] removeBlockedChannel:channelName];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self reloadGonerinoSection];
                    });
                    
                    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                    [generator prepare];
                    [generator impactOccurred];
                }];
                
                UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
                
                [alertController addAction:deleteAction];
                [alertController addAction:cancelAction];
                
                [delegate presentViewController:alertController animated:YES completion:nil];
                return YES;
            }];
        [sectionItems addObject:channelItem];
    }

    if ([delegate respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        [delegate setSectionItems:sectionItems forCategory:GonerinoSection title:@"Gonerino" icon:nil titleDescription:nil headerHidden:NO];
    } else {
        [delegate setSectionItems:sectionItems forCategory:GonerinoSection title:@"Gonerino" titleDescription:nil headerHidden:NO];
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
        YTSettingsViewController *delegate = [self valueForKey:@"_dataDelegate"];
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

%end

%ctor {
    %init;
}
