#import <version.h>
#import <rootless.h>
#import <YouTubeHeader/YTAlertView.h>
#import <YouTubeHeader/YTHotConfig.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTSearchableSettingsViewController.h>
#import <YouTubeHeader/YTAppSettingsSectionItemActionController.h>
#import <YouTubeHeader/YTUIUtils.h>
#import "ChannelManager.h"

NS_ASSUME_NONNULL_BEGIN

#define SECTION_HEADER(s) [sectionItems addObject:[objc_getClass("YTSettingsSectionItem") itemWithTitle:@"\t" titleDescription:[s uppercaseString] accessibilityIdentifier:nil detailTextBlock:nil selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger sectionItemIndex) { return NO; }]]

static const NSInteger GonerinoSection = 2002;

#define TWEAK_VERSION PACKAGE_VERSION

@interface YTToastResponderEvent : NSObject
+ (instancetype)eventWithMessage:(NSString *)message firstResponder:(id)responder;
- (void)send;
@end

@interface YTSettingsSectionItemManager (Gonerino)
- (void)updateGonerinoSectionWithEntry:(nullable id)entry;
- (void)updateChannelManagementSection:(nonnull YTSettingsViewController *)viewController;
- (nullable UITableView *)findTableViewInView:(nonnull UIView *)view;
- (void)reloadGonerinoSection;
@end

@interface YTNavigationController : UINavigationController
@end

@interface YTSettingsViewController ()
@property(nonatomic, strong, readonly, nullable) YTNavigationController *navigationController;
@end

@interface YTSettingsViewController (Gonerino)
- (void)setSectionItems:(nullable NSArray *)items forCategory:(NSInteger)category title:(nullable NSString *)title titleDescription:(nullable NSString *)titleDescription headerHidden:(BOOL)headerHidden;
@end

NS_ASSUME_NONNULL_END 