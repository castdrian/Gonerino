#import <Foundation/Foundation.h>

extern NSString *const ChannelManagerBlockedChannelsChangedNotification;

@interface ChannelManager : NSObject

+ (instancetype)sharedInstance;
- (NSArray<NSString *> *)blockedChannels;
- (void)addBlockedChannel:(NSString *)channelName;
- (void)removeBlockedChannel:(NSString *)channelName;
- (BOOL)isChannelBlocked:(NSString *)channelName;

@end
