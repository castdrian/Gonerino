#import <version.h>
#import <YouTubeHeader/YTAlertView.h>
#import <YouTubeHeader/YTHotConfig.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTAppSettingsSectionItemActionController.h>

#define LOC(x) [tweakBundle localizedStringForKey:x value:nil table:nil]

static const NSInteger GonerinoSection = 200;

@interface YTSettingsSectionItemManager (Gonerino)
- (void)updateGonerinoSectionWithEntry:(id)entry;
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

%new(v@:@)
- (void)updateGonerinoSectionWithEntry:(id)entry {
    YTSettingsViewController *delegate = [self valueForKey:@"_dataDelegate"];
    NSMutableArray *sectionItems = [NSMutableArray array];

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

%end

%ctor {
    %init;
}