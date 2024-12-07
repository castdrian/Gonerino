#import "VideoManager.h"

@interface VideoManager ()
@property(nonatomic, strong) NSMutableArray<NSString *> *blockedVideoArray;
@end

@implementation VideoManager

+ (instancetype)sharedInstance {
  static VideoManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[self alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _blockedVideoArray = [[[NSUserDefaults standardUserDefaults]
                             arrayForKey:@"GonerinoBlockedVideos"] mutableCopy]
                             ?: [NSMutableArray array];
  }
  return self;
}

- (NSArray<NSString *> *)blockedVideos {
  return [self.blockedVideoArray copy];
}

- (void)addBlockedVideo:(NSString *)videoTitle {
  if (videoTitle.length > 0) {
    [self.blockedVideoArray addObject:videoTitle];
    [self saveBlockedVideos];
  }
}

- (void)removeBlockedVideo:(NSString *)videoTitle {
  [self.blockedVideoArray removeObject:videoTitle];
  [self saveBlockedVideos];
}

- (BOOL)isVideoBlocked:(NSString *)videoTitle {
  return [self.blockedVideoArray containsObject:videoTitle];
}

- (void)saveBlockedVideos {
  [[NSUserDefaults standardUserDefaults] setObject:self.blockedVideoArray
                                          forKey:@"GonerinoBlockedVideos"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)setBlockedVideos:(NSArray<NSString *> *)videos {
  self.blockedVideoArray = [videos mutableCopy];
  [self saveBlockedVideos];
}

@end