#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "Tweak.h"
#import "WordManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface Util : NSObject

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion;

+ (BOOL)nodeContainsBlockedVideo:(id)node;

+ (UIImage *)createBlockChannelIconWithSize:(CGSize)size;
+ (UIImage *)createBlockVideoIconWithSize:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
