#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "Tweak.h"

NS_ASSUME_NONNULL_BEGIN

@interface Util : NSObject

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion;

@end

NS_ASSUME_NONNULL_END
