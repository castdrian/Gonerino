#import <Foundation/Foundation.h>

@interface VideoManager : NSObject

@property(nonatomic, readonly) NSArray<NSString *> *blockedVideos;

+ (instancetype)sharedInstance;
- (void)addBlockedVideo:(NSString *)videoTitle;
- (void)removeBlockedVideo:(NSString *)videoTitle;
- (BOOL)isVideoBlocked:(NSString *)videoTitle;
- (void)setBlockedVideos:(NSArray<NSString *> *)videos;

@end