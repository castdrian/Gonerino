#import "WordManager.h"

@interface WordManager ()
@property(nonatomic, strong) NSMutableSet<NSString *> *blockedWordSet;
@end

@implementation WordManager

+ (instancetype)sharedInstance {
    static WordManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _blockedWordSet = [NSMutableSet set];
        for (id value in [[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedWords"]) {
            if (![value isKindOfClass:[NSString class]])
                continue;
            NSString *word = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (word.length > 0)
                [_blockedWordSet addObject:word];
        }
    }
    return self;
}

- (NSArray<NSString *> *)blockedWords {
    return [self.blockedWordSet allObjects];
}

- (void)addBlockedWord:(NSString *)word {
    NSString *normalizedWord = [word stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalizedWord.length > 0) {
        [self.blockedWordSet addObject:normalizedWord];
        [self saveBlockedWords];
    }
}

- (void)removeBlockedWord:(NSString *)word {
    if (word) {
        [self.blockedWordSet removeObject:word];
        [self saveBlockedWords];
    }
}

- (BOOL)isWordBlocked:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || text.length == 0)
        return NO;

    for (NSString *word in self.blockedWordSet) {
        if ([text.lowercaseString containsString:word.lowercaseString]) {
            return YES;
        }
    }
    return NO;
}

- (void)saveBlockedWords {
    [[NSUserDefaults standardUserDefaults] setObject:[self.blockedWordSet allObjects] forKey:@"GonerinoBlockedWords"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)setBlockedWords:(NSArray<NSString *> *)words {
    self.blockedWordSet = [NSMutableSet set];
    for (id value in words) {
        if (![value isKindOfClass:[NSString class]])
            continue;
        NSString *word = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (word.length > 0)
            [self.blockedWordSet addObject:word];
    }
    [self saveBlockedWords];
}

@end
