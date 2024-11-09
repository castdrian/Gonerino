#import "ChannelManager.h"

@interface ChannelManager ()
@property(nonatomic, strong) NSMutableSet<NSString *> *blockedChannelSet;
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
    _blockedChannelSet =
        [[[NSUserDefaults standardUserDefaults]
            arrayForKey:@"GonerinoBlockedChannels"] mutableCopy]
            ?: [NSMutableSet set];
  }
  return self;
}

- (NSArray<NSString *> *)blockedChannels {
  return [self.blockedChannelSet allObjects];
}

- (void)addBlockedChannel:(NSString *)channelName {
  if (channelName.length > 0) {
    [self.blockedChannelSet addObject:channelName];
    [self saveBlockedChannels];
  }
}

- (void)removeBlockedChannel:(NSString *)channelName {
  if (channelName) {
    [self.blockedChannelSet removeObject:channelName];
    [self saveBlockedChannels];
  }
}

- (BOOL)isChannelBlocked:(NSString *)channelName {
  return [self.blockedChannelSet containsObject:channelName];
}

- (void)saveBlockedChannels {
  [[NSUserDefaults standardUserDefaults]
      setObject:[self.blockedChannelSet allObjects]
         forKey:@"GonerinoBlockedChannels"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)setBlockedChannels:(NSArray<NSString *> *)channels {
    self.blockedChannelSet = [NSMutableSet setWithArray:channels];
    [self saveBlockedChannels];
}

@end
