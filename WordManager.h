#import <Foundation/Foundation.h>

@interface WordManager : NSObject

+ (instancetype)sharedInstance;
- (NSArray<NSString *> *)blockedWords;
- (void)addBlockedWord:(NSString *)word;
- (void)removeBlockedWord:(NSString *)word;
- (BOOL)isWordBlocked:(NSString *)text;
- (void)setBlockedWords:(NSArray<NSString *> *)words;

@end