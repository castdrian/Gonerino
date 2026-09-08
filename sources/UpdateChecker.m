#import "UpdateChecker.h"
#import "Localization.h"
#import "Settings.h"

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

static NSString *GonerinoNormalizedVersion(NSString *version) {
    NSString *normalized = [version hasPrefix:@"v"] ? [version substringFromIndex:1] : version;
    return [normalized componentsSeparatedByString:@"-"].firstObject;
}

static NSComparisonResult GonerinoCompareVersions(NSString *first, NSString *second) {
    NSArray<NSString *> *firstParts = [GonerinoNormalizedVersion(first) componentsSeparatedByString:@"."];
    NSArray<NSString *> *secondParts = [GonerinoNormalizedVersion(second) componentsSeparatedByString:@"."];
    for (NSUInteger index = 0; index < MAX(firstParts.count, secondParts.count); index++) {
        NSInteger firstValue = index < firstParts.count ? firstParts[index].integerValue : 0;
        NSInteger secondValue = index < secondParts.count ? secondParts[index].integerValue : 0;
        if (firstValue < secondValue)
            return NSOrderedAscending;
        if (firstValue > secondValue)
            return NSOrderedDescending;
    }
    return NSOrderedSame;
}

@interface GonerinoNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation GonerinoNotificationDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList |
                      UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    NSString *URLString = response.notification.request.content.userInfo[@"url"];
    NSURL *URL = [URLString isKindOfClass:[NSString class]] ? [NSURL URLWithString:URLString] : nil;
    if (URL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:URL options:@{} completionHandler:^(__unused BOOL success) {}];
        });
    }
    completionHandler();
}

@end

static GonerinoNotificationDelegate *GonerinoNotificationDelegateInstance;

static void GonerinoScheduleUpdateNotification(NSString *version, NSString *URLString) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = LocalizedString(@"Gonerino update available");
        content.body = [NSString stringWithFormat:@"%@ %@", LocalizedString(@"Version"), version];
        content.sound = [UNNotificationSound defaultSound];
        content.userInfo = @{ @"url": URLString, @"version": version };
        NSString *identifier = [NSString stringWithFormat:@"gonerino-update-%@", version];
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1.0 repeats:NO];
        UNNotificationRequest *notification = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:notification withCompletionHandler:nil];
    });
}

static void GonerinoConfigureNotifications(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!GonerinoNotificationDelegateInstance) {
            GonerinoNotificationDelegateInstance = [GonerinoNotificationDelegate new];
            [UNUserNotificationCenter currentNotificationCenter].delegate = GonerinoNotificationDelegateInstance;
        }
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionBadge | UNAuthorizationOptionSound
                              completionHandler:^(__unused BOOL granted, __unused NSError *error) {}];
    });
}

static void GonerinoCheckLatestRelease(void) {
    NSURL *URL = [NSURL URLWithString:@"https://api.github.com/repos/castdrian/Gonerino/releases/latest"];
    if (!URL)
        return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Gonerino" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
              if (![response isKindOfClass:[NSHTTPURLResponse class]] ||
                  ((NSHTTPURLResponse *)response).statusCode < 200 ||
                  ((NSHTTPURLResponse *)response).statusCode >= 300 ||
                  !data)
                  return;
              NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
              if (![release isKindOfClass:[NSDictionary class]])
                  return;
              NSString *latestVersion = GonerinoNormalizedVersion(release[@"tag_name"]);
              if (latestVersion.length == 0 || GonerinoCompareVersions(TWEAK_VERSION, latestVersion) != NSOrderedAscending)
                  return;
              NSString *URLString = [release[@"html_url"] isKindOfClass:[NSString class]] ? release[@"html_url"] : @"https://github.com/castdrian/Gonerino/releases/latest";
              GonerinoScheduleUpdateNotification(latestVersion, URLString);
          }];
    [task resume];
}

void GonerinoStartUpdateChecker(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        GonerinoConfigureNotifications();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(),
                       ^{
                           GonerinoCheckLatestRelease();
                       });
    });
}
