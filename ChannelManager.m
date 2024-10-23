#import "ChannelManager.h"

@interface ChannelManager ()
@property (nonatomic, strong) NSMutableArray<NSString *> *channels;
@end

@implementation ChannelManager

+ (instancetype)sharedInstance {
    static ChannelManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _channels = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedChannels"] mutableCopy] ?: [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSString *> *)blockedChannels {
    return [self.channels copy];
}

- (void)addBlockedChannel:(NSString *)channelName {
    if (![self.channels containsObject:channelName]) {
        [self.channels addObject:channelName];
        [self saveChannels];
    }
}

- (void)removeBlockedChannel:(NSString *)channelName {
    [self.channels removeObject:channelName];
    [self saveChannels];
}

- (BOOL)isChannelBlocked:(NSString *)channelName {
    return [self.channels containsObject:channelName];
}

- (void)saveChannels {
    [[NSUserDefaults standardUserDefaults] setObject:self.channels forKey:@"GonerinoBlockedChannels"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
