#import "VideoManager.h"

@interface VideoManager ()
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *blockedVideoArray;
@end

@implementation VideoManager

+ (instancetype)sharedInstance {
    static VideoManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _blockedVideoArray = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedVideos"] mutableCopy]
                                 ?: [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSDictionary *> *)blockedVideos {
    return [self.blockedVideoArray copy];
}

- (void)addBlockedVideo:(NSString *)videoId title:(NSString *)title channel:(NSString *)channel {
    if (!videoId.length)
        return;

    NSDictionary *videoInfo = @{@"id": videoId, @"title": title ?: @"", @"channel": channel ?: @""};

    NSInteger existingIndex =
        [self.blockedVideoArray indexOfObjectPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
            return [obj[@"id"] isEqualToString:videoId];
        }];

    if (existingIndex == NSNotFound) {
        [self.blockedVideoArray addObject:videoInfo];
        [self saveBlockedVideos];
    }
}

- (void)removeBlockedVideo:(NSString *)videoId {
    NSIndexSet *indexes =
        [self.blockedVideoArray indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
            return [obj[@"id"] isEqualToString:videoId];
        }];

    if (indexes.count > 0) {
        [self.blockedVideoArray removeObjectsAtIndexes:indexes];
        [self saveBlockedVideos];
    }
}

- (BOOL)isVideoBlocked:(NSString *)videoId {
    if (![videoId isKindOfClass:[NSString class]] || videoId.length == 0)
        return NO;

    return [self.blockedVideoArray indexOfObjectPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
               return [obj[@"id"] isEqualToString:videoId];
           }] != NSNotFound;
}

- (void)saveBlockedVideos {
    [[NSUserDefaults standardUserDefaults] setObject:self.blockedVideoArray forKey:@"GonerinoBlockedVideos"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)setBlockedVideos:(NSArray<NSDictionary *> *)videos {
    NSMutableArray *validVideos = [NSMutableArray array];
    for (id value in videos) {
        if (![value isKindOfClass:[NSDictionary class]])
            continue;
        NSString *videoId = value[@"id"];
        if (![videoId isKindOfClass:[NSString class]] || videoId.length == 0)
            continue;
        [validVideos addObject:@{
            @"id": videoId,
            @"title": [value[@"title"] isKindOfClass:[NSString class]] ? value[@"title"] : @"",
            @"channel": [value[@"channel"] isKindOfClass:[NSString class]] ? value[@"channel"] : @""
        }];
    }

    self.blockedVideoArray = validVideos;
    [self saveBlockedVideos];
}

@end
