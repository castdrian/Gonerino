#import <Foundation/Foundation.h>

@interface ChannelManager : NSObject

+ (instancetype)sharedInstance;
- (NSArray<NSString *> *)blockedChannels;
- (void)addBlockedChannel:(NSString *)channelName;
- (void)removeBlockedChannel:(NSString *)channelName;
- (BOOL)isChannelBlocked:(NSString *)channelName;

@end
