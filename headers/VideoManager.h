#import <Foundation/Foundation.h>

@interface VideoManager : NSObject

@property(nonatomic, readonly) NSArray<NSDictionary *> *blockedVideos;

+ (instancetype)sharedInstance;
- (void)addBlockedVideo:(NSString *)videoId title:(NSString *)title channel:(NSString *)channel;
- (void)removeBlockedVideo:(NSString *)videoId;
- (BOOL)isVideoBlocked:(NSString *)videoId;
- (void)setBlockedVideos:(NSArray<NSDictionary *> *)videos;

@end