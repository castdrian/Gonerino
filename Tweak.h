#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ChannelManager.h"

@class YTAsyncCollectionView;
@class _ASCollectionViewCell;
@class ASDisplayNode;
@class ASTextNode;
@class YTWatchController;
@class YTSingleVideoController;
@class YTDefaultSheetController;
@class YTActionSheetAction;
@class YTToastResponderEvent;

NS_ASSUME_NONNULL_BEGIN

@interface YTAsyncCollectionView : UICollectionView

- (void)layoutSubviews;

- (void)performBatchUpdates:(void (NS_NOESCAPE ^ _Nullable)(void))updates
                 completion:(void (^ _Nullable)(BOOL finished))completion;

- (NSArray<UICollectionViewCell *> *)visibleCells;

- (nullable NSIndexPath *)indexPathForCell:(UICollectionViewCell *)cell;

- (void)removeOffendingCells;

- (BOOL)nodeContainsBlockedChannelName:(id)node;

@end

@interface _ASCollectionViewCell : UICollectionViewCell

- (nullable ASDisplayNode *)node;

@end

@interface ASDisplayNode : NSObject

@property (nonatomic, copy, nullable) NSString *accessibilityLabel;
@property (nonatomic, copy, nullable) NSString *accessibilityIdentifier;

- (nullable NSArray<ASDisplayNode *> *)subnodes;

@end

@interface ASTextNode : ASDisplayNode

@property (nonatomic, copy, nullable) NSAttributedString *attributedText;

@end

@interface NSObject (ChannelName)

- (nullable NSString *)channelName;
- (nullable NSString *)ownerName;

@end

@interface YTWatchController : NSObject
@property (nonatomic, strong, readonly) YTSingleVideoController *singleVideoController;
- (YTSingleVideoController *)valueForKey:(NSString *)key;
@end

@interface YTSingleVideoController : NSObject
@property (nonatomic, copy, readonly) NSString *channelName;
- (NSString *)valueForKey:(NSString *)key;
@end

@interface YTDefaultSheetController : NSObject
- (void)addAction:(YTActionSheetAction *)action;
- (void)dismiss; // YouTube's actual dismiss method
- (id)valueForKey:(NSString *)key;

- (UIImage *)createBlockIconWithOriginalAction:(YTActionSheetAction *)originalAction;

@end

@interface YTActionSheetAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title
                     iconImage:(UIImage *)iconImage
                         style:(NSInteger)style
                      handler:(void (^)(void))handler;
- (id)valueForKey:(NSString *)key;
@end

@interface YTToastResponderEvent : NSObject
+ (instancetype)eventWithMessage:(NSString *)message 
                 firstResponder:(UIViewController *)responder;
- (void)send;
@end

NS_ASSUME_NONNULL_END
