#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "WordManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface Util : NSObject

+ (nullable NSDictionary<NSString *, NSString *> *)videoInfoFromNode:(nullable id)node;
+ (nullable NSDictionary<NSString *, NSString *> *)freshVideoInfoFromNode:(nullable id)node;
+ (nullable NSDictionary<NSString *, NSString *> *)freshVideoInfoFromNode:(nullable id)node
                                                               sourceView:(nullable UIView *)sourceView;
+ (void)refreshFeedViews;
+ (void)showToast:(NSString *)message fromView:(nullable UIView *)view;
+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion;

+ (BOOL)nodeContainsBlockedVideo:(id)node;

+ (UIImage *)createBlockChannelIconWithSize:(CGSize)size;
+ (UIImage *)createBlockVideoIconWithSize:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
