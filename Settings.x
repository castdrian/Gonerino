#import <version.h>
#import <rootless.h>
#import <YouTubeHeader/YTAlertView.h>
#import <YouTubeHeader/YTHotConfig.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTAppSettingsSectionItemActionController.h>
#import <YouTubeHeader/YTUIUtils.h>
#import "ChannelManager.h"

#define SECTION_HEADER(s) [sectionItems addObject:[%c(YTSettingsSectionItem) itemWithTitle:@"\t" titleDescription:[s uppercaseString] accessibilityIdentifier:nil detailTextBlock:nil selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger sectionItemIndex) { return NO; }]]

static const NSInteger GonerinoSection = 2002;

#define TWEAK_VERSION PACKAGE_VERSION

@interface YTToastResponderEvent : NSObject
+ (instancetype _Nonnull)eventWithMessage:(NSString * _Nonnull)message 
                          firstResponder:(id _Nonnull)responder;
- (void)send;
@end

@interface YTSettingsSectionItemManager (Gonerino)
- (void)updateGonerinoSectionWithEntry:(id)entry;
- (void)updateChannelManagementSection:(YTSettingsViewController *)viewController;
- (UITableView *)findTableViewInView:(UIView *)view;
- (void)reloadGonerinoSection;
@end

@interface YTNavigationController : UINavigationController
@end

@interface YTSettingsViewController ()
@property(nonatomic, strong, readonly) YTNavigationController *navigationController;
@end

@interface YTSettingsViewController (Gonerino)
- (void)setSectionItems:(NSArray *)items forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden;
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
    YTSettingsViewController *delegate = [self valueForKey:@"_settingsViewControllerDelegate"];
    NSMutableArray *sectionItems = [NSMutableArray array];

    SECTION_HEADER(@"GONERINO SETTINGS");

    NSUInteger channelCount = [[ChannelManager sharedInstance] blockedChannels].count;
    YTSettingsSectionItem *manageChannels = [%c(YTSettingsSectionItem) itemWithTitle:@"Manage Channels"
        titleDescription:[NSString stringWithFormat:@"%lu blocked channel%@", 
            (unsigned long)channelCount, 
            channelCount == 1 ? @"" : @"s"]
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            NSMutableArray *rows = [NSMutableArray array];
            
            [rows addObject:[%c(YTSettingsSectionItem) itemWithTitle:@"Add Channel"
                titleDescription:@"Block a new channel"
                accessibilityIdentifier:nil
                detailTextBlock:nil
                selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
                    YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
                    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Add Channel"
                        message:@"Enter the channel name to block"
                        preferredStyle:UIAlertControllerStyleAlert];
                    
                    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                        textField.placeholder = @"Channel Name";
                    }];
                    
                    [alertController addAction:[UIAlertAction actionWithTitle:@"Add" 
                        style:UIAlertActionStyleDefault 
                        handler:^(UIAlertAction *action) {
                            NSString *channelName = alertController.textFields.firstObject.text;
                            if (channelName.length > 0) {
                                [[ChannelManager sharedInstance] addBlockedChannel:channelName];
                                [self reloadGonerinoSection];
                                
                                UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                                [generator prepare];
                                [generator impactOccurred];
                                
                                [[%c(YTToastResponderEvent) eventWithMessage:[NSString stringWithFormat:@"Added %@", channelName] 
                                    firstResponder:settingsVC] send];
                            }
                    }]];
                    
                    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" 
                        style:UIAlertActionStyleCancel 
                        handler:nil]];
                    
                    [settingsVC presentViewController:alertController animated:YES completion:nil];
                    return YES;
                }
            ]];
            
            NSArray *blockedChannels = [[ChannelManager sharedInstance] blockedChannels];
            if (blockedChannels.count > 0) {
                [rows addObject:[%c(YTSettingsSectionItem) itemWithTitle:@"\t"
                    titleDescription:@"BLOCKED CHANNELS"
                    accessibilityIdentifier:nil
                    detailTextBlock:nil
                    selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { 
                        return NO; 
                    }
                ]];
                
                for (NSString *channelName in blockedChannels) {
                    [rows addObject:[%c(YTSettingsSectionItem) itemWithTitle:channelName
                        titleDescription:nil
                        accessibilityIdentifier:nil
                        detailTextBlock:nil
                        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
                            YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
                            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Delete Channel"
                                message:[NSString stringWithFormat:@"Are you sure you want to delete '%@'?", channelName]
                                preferredStyle:UIAlertControllerStyleAlert];
                            
                            [alertController addAction:[UIAlertAction actionWithTitle:@"Delete" 
                                style:UIAlertActionStyleDestructive 
                                handler:^(UIAlertAction *action) {
                                    [[ChannelManager sharedInstance] removeBlockedChannel:channelName];
                                    [self reloadGonerinoSection];
                                    
                                    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                                    [generator prepare];
                                    [generator impactOccurred];
                                    
                                    [[%c(YTToastResponderEvent) eventWithMessage:[NSString stringWithFormat:@"Deleted %@", channelName] 
                                        firstResponder:settingsVC] send];
                                }]];
                            
                            [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" 
                                style:UIAlertActionStyleCancel 
                                handler:nil]];
                            
                            [settingsVC presentViewController:alertController animated:YES completion:nil];
                            return YES;
                        }
                    ]];
                }
            }
            
            YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
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

    SECTION_HEADER(@"MANAGE SETTINGS");
    
    YTSettingsSectionItem *exportSettings = [%c(YTSettingsSectionItem) itemWithTitle:@"Export Settings"
        titleDescription:@"Export settings to a plist file"
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
            
            NSMutableDictionary *settings = [NSMutableDictionary dictionary];
            settings[@"blockedChannels"] = [[ChannelManager sharedInstance] blockedChannels];
            
            NSURL *tempFileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"gonerino_settings.plist"]];
            [settings writeToURL:tempFileURL atomically:YES];
            
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] 
                initWithURL:tempFileURL 
                inMode:UIDocumentPickerModeMoveToService];
            picker.delegate = (id<UIDocumentPickerDelegate>)self;
            [settingsVC presentViewController:picker animated:YES completion:nil];
            return YES;
        }];
    [sectionItems addObject:exportSettings];

    YTSettingsSectionItem *importSettings = [%c(YTSettingsSectionItem) itemWithTitle:@"Import Settings"
        titleDescription:@"Import settings from a plist file"
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
            
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] 
                initWithDocumentTypes:@[@"com.apple.property-list"] 
                inMode:UIDocumentPickerModeImport];
            picker.delegate = (id<UIDocumentPickerDelegate>)self;
            [settingsVC presentViewController:picker animated:YES completion:nil];
            return YES;
        }];
    [sectionItems addObject:importSettings];

    SECTION_HEADER(@"ABOUT");

    [sectionItems addObject:[%c(YTSettingsSectionItem) itemWithTitle:@"GitHub"
        titleDescription:@"View source code and report issues"
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            return [%c(YTUIUtils) openURL:[NSURL URLWithString:@"https://github.com/castdrian/Gonerino"]];
        }]];

    [sectionItems addObject:[%c(YTSettingsSectionItem) itemWithTitle:@"Version"
        titleDescription:nil
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *() {
            return [NSString stringWithFormat:@"v%@", TWEAK_VERSION];
        }
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            return [%c(YTUIUtils) openURL:[NSURL URLWithString:@"https://github.com/castdrian/Gonerino/releases"]];
        }]];

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
    if (urls.count == 0) return;
    
    YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
    NSURL *url = urls.firstObject;
    
    if (controller.documentPickerMode == UIDocumentPickerModeImport) {
        NSDictionary *settings = [NSDictionary dictionaryWithContentsOfURL:url];
        if (settings) {
            NSArray *channels = settings[@"blockedChannels"];
            if (channels) {
                [[ChannelManager sharedInstance] setBlockedChannels:[NSMutableArray arrayWithArray:channels]];
            }
            
            [self reloadGonerinoSection];
            [[%c(YTToastResponderEvent) eventWithMessage:@"Settings imported successfully" 
                firstResponder:settingsVC] send];
        }
    } else {
        [[%c(YTToastResponderEvent) eventWithMessage:@"Settings exported successfully" 
            firstResponder:settingsVC] send];
    }
}

%end

%ctor {
    %init;
}