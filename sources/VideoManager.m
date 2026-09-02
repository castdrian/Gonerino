#import "VideoManager.h"
#import "Util.h"

static NSString *CleanChannelName(id value) {
    if (![value isKindOfClass:[NSString class]])
        return @"";

    NSString *channel = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *normalized = channel.lowercaseString;
    if ([normalized isEqualToString:@"action menu"] || [normalized isEqualToString:@"more actions"])
        return @"";
    return channel;
}

static NSString *CleanVideoTitle(id value) {
    if (![value isKindOfClass:[NSString class]])
        return @"";

    NSString *title = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [Util isUsableVideoTitle:title] ? title : @"";
}

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
        NSArray *storedVideos = [[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedVideos"];
        NSMutableArray *cleanedVideos = [NSMutableArray array];
        BOOL changed = ![storedVideos isKindOfClass:[NSArray class]];
        for (id value in storedVideos) {
            if (![value isKindOfClass:[NSDictionary class]]) {
                changed = YES;
                continue;
            }

            NSString *videoId = value[@"id"];
            if (![videoId isKindOfClass:[NSString class]] || videoId.length == 0) {
                changed = YES;
                continue;
            }

            NSDictionary *video = @{
                @"id": videoId,
                @"title": CleanVideoTitle(value[@"title"]),
                @"channel": CleanChannelName(value[@"channel"])
            };
            [cleanedVideos addObject:video];
            if (![video isEqual:value])
                changed = YES;
        }
        _blockedVideoArray = cleanedVideos;
        if (changed)
            [self saveBlockedVideos];
    }
    return self;
}

- (NSArray<NSDictionary *> *)blockedVideos {
    return [self.blockedVideoArray copy];
}

- (void)addBlockedVideo:(NSString *)videoId title:(NSString *)title channel:(NSString *)channel {
    if (!videoId.length)
        return;

    NSDictionary *videoInfo = @{@"id": videoId, @"title": CleanVideoTitle(title), @"channel": CleanChannelName(channel)};

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
            @"title": CleanVideoTitle(value[@"title"]),
            @"channel": CleanChannelName(value[@"channel"])
        }];
    }

    self.blockedVideoArray = validVideos;
    [self saveBlockedVideos];
}

@end
