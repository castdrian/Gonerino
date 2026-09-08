#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "WordManager.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FeedFilterStateDidChangeNotification;

@interface FeedMetadataRecord : NSObject

@property(nonatomic, copy, readonly) NSString *videoID;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSString *channel;

- (instancetype)initWithVideoID:(nullable NSString *)videoID
                           title:(nullable NSString *)title
                         channel:(nullable NSString *)channel;
- (NSDictionary<NSString *, NSString *> *)dictionaryRepresentation;

@end

@interface Util : NSObject

+ (nullable NSDictionary<NSString *, NSString *> *)videoInfoFromNode:(nullable id)node;
+ (nullable FeedMetadataRecord *)feedVideoMetadataFromNode:(nullable id)node;
+ (nullable FeedMetadataRecord *)feedVideoMetadataFromModel:(nullable id)model;
+ (nullable FeedMetadataRecord *)feedVideoMetadataFromShortsContentView:(nullable id)contentView;
+ (void)invalidateShortsMetadataForContentView:(nullable id)contentView;
+ (void)rememberFeedVideoMetadata:(nullable FeedMetadataRecord *)metadata forNode:(nullable id)node;
+ (nullable FeedMetadataRecord *)cachedFeedVideoMetadataForNode:(nullable id)node;
+ (nullable NSDictionary<NSString *, NSString *> *)feedVideoInfoFromNode:(nullable id)node;
+ (nullable FeedMetadataRecord *)cachedFeedVideoMetadataForVideoID:(nullable NSString *)videoID;
+ (nullable NSString *)feedVideoIDFromThumbnailURL:(nullable NSURL *)url;
+ (nullable NSString *)feedVideoIDForObject:(nullable id)object;
+ (void)setFeedVideoID:(nullable NSString *)videoID forObject:(nullable id)object;
+ (BOOL)filteringEnabled;
+ (void)refreshPreferenceSnapshot;
+ (nullable NSDictionary<NSString *, NSString *> *)freshVideoInfoFromNode:(nullable id)node;
+ (nullable NSDictionary<NSString *, NSString *> *)freshVideoInfoFromNode:(nullable id)node
                                                               sourceView:(nullable UIView *)sourceView;
+ (void)invalidateVideoInfoForNode:(nullable id)node;
+ (void)resetFeedVideoMetadataForNode:(nullable id)node;
+ (BOOL)isUsableVideoTitle:(nullable NSString *)title;
+ (void)showToast:(NSString *)message fromView:(nullable UIView *)view;
+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion;

+ (BOOL)nodeContainsBlockedVideo:(id)node;
+ (BOOL)nodeContainsBlockedVideo:(id)node metadata:(nullable FeedMetadataRecord *)metadata;
+ (BOOL)nodeContainsBlockedVideo:(id)node
                        videoInfo:(nullable NSDictionary<NSString *, NSString *> *)videoInfo;

+ (UIImage *)createBlockChannelIconWithSize:(CGSize)size;
+ (UIImage *)createBlockVideoIconWithSize:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
