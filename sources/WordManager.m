#import "WordManager.h"
#import "Util.h"

@interface WordManager ()
@property(nonatomic, strong) NSMutableSet<NSString *> *blockedWordSet;
@property(copy) NSSet<NSString *> *blockedWordLookup;
@end

static NSString *WordLookupKey(NSString *word) {
    return [word.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

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
        NSMutableSet *lookup = [NSMutableSet set];
        for (id value in [[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedWords"]) {
            if (![value isKindOfClass:[NSString class]])
                continue;
            NSString *word = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (word.length > 0)
                [_blockedWordSet addObject:word];
            if (word.length > 0)
                [lookup addObject:WordLookupKey(word)];
        }
        _blockedWordLookup = lookup.copy;
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
        NSMutableSet *lookup = [self.blockedWordLookup mutableCopy];
        [lookup addObject:WordLookupKey(normalizedWord)];
        self.blockedWordLookup = lookup.copy;
        [self saveBlockedWords];
        [[NSNotificationCenter defaultCenter] postNotificationName:FeedFilterStateDidChangeNotification object:nil];
    }
}

- (void)removeBlockedWord:(NSString *)word {
    if (word) {
        [self.blockedWordSet removeObject:word];
        NSMutableSet *lookup = [self.blockedWordLookup mutableCopy];
        [lookup removeObject:WordLookupKey(word)];
        self.blockedWordLookup = lookup.copy;
        [self saveBlockedWords];
        [[NSNotificationCenter defaultCenter] postNotificationName:FeedFilterStateDidChangeNotification object:nil];
    }
}

- (BOOL)isWordBlocked:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || text.length == 0)
        return NO;
    if (self.blockedWordLookup.count == 0)
        return NO;

    NSString *normalizedText = text.lowercaseString;
    for (NSString *word in self.blockedWordLookup) {
        if ([normalizedText containsString:word]) {
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
    NSMutableSet *lookup = [NSMutableSet set];
    for (id value in words) {
        if (![value isKindOfClass:[NSString class]])
            continue;
        NSString *word = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (word.length > 0)
            [self.blockedWordSet addObject:word];
        if (word.length > 0)
            [lookup addObject:WordLookupKey(word)];
    }
    self.blockedWordLookup = lookup.copy;
    [self saveBlockedWords];
    [[NSNotificationCenter defaultCenter] postNotificationName:FeedFilterStateDidChangeNotification object:nil];
}

@end
