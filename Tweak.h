#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ChannelManager.h"

@class YTAsyncCollectionView;
@class _ASCollectionViewCell;
@class ASDisplayNode;
@class ASTextNode;

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

NS_ASSUME_NONNULL_END
