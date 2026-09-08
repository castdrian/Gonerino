#import "ChannelManager.h"
#import "Util.h"

static BOOL IsGeneratedActionLabel(NSString *channel) {
    NSString *normalized = [[channel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return [normalized isEqualToString:@"action menu"] || [normalized isEqualToString:@"more actions"];
}

@interface ChannelManager ()
@property(nonatomic, strong) NSMutableSet<NSString *> *blockedChannelSet;
@property(copy) NSSet<NSString *> *blockedChannelLookup;
@end

static NSString *ChannelLookupKey(NSString *channel) {
    NSString *normalized = [channel.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *key = [NSMutableString stringWithCapacity:normalized.length];
    NSCharacterSet *allowedCharacters = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger index = 0; index < normalized.length; index++) {
        unichar character = [normalized characterAtIndex:index];
        if ([allowedCharacters characterIsMember:character])
            [key appendFormat:@"%C", character];
    }
    return key.copy;
}

@implementation ChannelManager

+ (instancetype)sharedInstance {
    static ChannelManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _blockedChannelSet = [NSMutableSet set];
        NSMutableSet *lookup = [NSMutableSet set];
        BOOL removedGeneratedActionLabel = NO;
        for (id value in [[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedChannels"]) {
            if (![value isKindOfClass:[NSString class]])
                continue;
            NSString *channel = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (channel.length > 0 && !IsGeneratedActionLabel(channel))
                [_blockedChannelSet addObject:channel];
            else if (channel.length > 0)
                removedGeneratedActionLabel = YES;
        }
        for (NSString *channel in _blockedChannelSet)
            [lookup addObject:ChannelLookupKey(channel)];
        _blockedChannelLookup = lookup.copy;
        if (removedGeneratedActionLabel)
            [self saveBlockedChannels];
    }
    return self;
}

- (NSArray<NSString *> *)blockedChannels {
    return [[self.blockedChannelSet allObjects]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)addBlockedChannel:(NSString *)channelName {
    NSString *channel = [channelName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (channel.length == 0 || IsGeneratedActionLabel(channel))
        return;
    if (![self isChannelBlocked:channel]) {
        [self.blockedChannelSet addObject:channel];
        NSMutableSet *lookup = [self.blockedChannelLookup mutableCopy];
        [lookup addObject:ChannelLookupKey(channel)];
        self.blockedChannelLookup = lookup.copy;
        [self saveBlockedChannels];
    }
    FeedMetadataRecord *metadata = [[FeedMetadataRecord alloc] initWithVideoID:nil title:nil channel:channel];
    [[NSNotificationCenter defaultCenter] postNotificationName:FeedFilterStateDidChangeNotification object:metadata];
}

- (void)removeBlockedChannel:(NSString *)channelName {
    NSString *channel = [channelName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (channel.length > 0 && [self isChannelBlocked:channel]) {
        for (NSString *value in [self.blockedChannelSet copy]) {
            if ([value caseInsensitiveCompare:channel] == NSOrderedSame)
                [self.blockedChannelSet removeObject:value];
        }
        NSMutableSet *lookup = [self.blockedChannelLookup mutableCopy];
        [lookup removeObject:ChannelLookupKey(channel)];
        self.blockedChannelLookup = lookup.copy;
        [self saveBlockedChannels];
        [[NSNotificationCenter defaultCenter] postNotificationName:FeedFilterStateDidChangeNotification object:nil];
    }
}

- (BOOL)isChannelBlocked:(NSString *)channelName {
    if (![channelName isKindOfClass:[NSString class]] || channelName.length == 0)
        return NO;

    return [self.blockedChannelLookup containsObject:ChannelLookupKey(channelName)];
}

- (void)saveBlockedChannels {
    [[NSUserDefaults standardUserDefaults] setObject:[self.blockedChannelSet allObjects]
                                              forKey:@"GonerinoBlockedChannels"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)setBlockedChannels:(NSArray<NSString *> *)channels {
    self.blockedChannelSet = [NSMutableSet set];
    NSMutableSet *lookup = [NSMutableSet set];
    for (id value in channels) {
        if (![value isKindOfClass:[NSString class]])
            continue;
        NSString *channel = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (channel.length > 0 && !IsGeneratedActionLabel(channel))
            [self.blockedChannelSet addObject:channel];
        if (channel.length > 0 && !IsGeneratedActionLabel(channel))
            [lookup addObject:ChannelLookupKey(channel)];
    }
    self.blockedChannelLookup = lookup.copy;
    [self saveBlockedChannels];
    [[NSNotificationCenter defaultCenter] postNotificationName:FeedFilterStateDidChangeNotification object:nil];
}

@end
