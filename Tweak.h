#import "ChannelManager.h"
#import "VideoManager.h"
#import "WordManager.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@class YTAsyncCollectionView;
@class _ASCollectionViewCell;
@class ASDisplayNode;
@class ASTextNode;
@class YTWatchController;
@class YTSingleVideoController;
@class YTDefaultSheetController;
@class YTActionSheetAction;
@class YTToastResponderEvent;
@class YTSettingsCell;

NS_ASSUME_NONNULL_BEGIN

@interface YTAsyncCollectionView : UICollectionView

- (void)layoutSubviews;

- (void)performBatchUpdates:(void(NS_NOESCAPE ^ _Nullable)(void))updates
                 completion:(void (^_Nullable)(BOOL finished))completion;

- (NSArray<UICollectionViewCell *> *)visibleCells;

- (nullable NSIndexPath *)indexPathForCell:(UICollectionViewCell *)cell;

- (void)removeOffendingCells;

- (BOOL)nodeContainsBlockedChannelName:(id)node;

- (BOOL)nodeContainsBlockedVideo:(id)node;

@end

@interface _ASCollectionViewCell : UICollectionViewCell

- (nullable ASDisplayNode *)node;

@end

@interface ASDisplayNode : NSObject

@property(nonatomic, copy, nullable) NSString *accessibilityLabel;
@property(nonatomic, copy, nullable) NSString *accessibilityIdentifier;

- (nullable NSArray<ASDisplayNode *> *)subnodes;

@end

@interface ASTextNode : ASDisplayNode

@property(nonatomic, copy, nullable) NSAttributedString *attributedText;

@end

@interface NSObject (ChannelName)

- (nullable NSString *)channelName;
- (nullable NSString *)ownerName;

@end

@interface YTWatchController : NSObject
@property(nonatomic, strong, readonly) YTSingleVideoController *singleVideoController;
- (YTSingleVideoController *)valueForKey:(NSString *)key;
@end

@interface YTSingleVideoController : NSObject
@property(nonatomic, copy, readonly) NSString *channelName;
- (NSString *)valueForKey:(NSString *)key;
@end

@interface YTDefaultSheetController : NSObject
- (void)addAction:(YTActionSheetAction *)action;
- (void)dismiss;
- (id)valueForKey:(NSString *)key;
- (UIImage *)createBlockIconWithOriginalAction:(nullable YTActionSheetAction *)originalAction;
- (UIViewController *)findViewControllerForView:(UIView *)view;
- (void)extractChannelNameFromNode:(id)node completion:(void (^)(NSString *channelName))completion;
- (nullable NSString *)extractVideoTitleFromNode:(id)node;
@end

@interface YTActionSheetAction : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) void (^handler)(id);
@property(nonatomic, strong) UIImage *iconImage;
@property(nonatomic) BOOL shouldDismissOnAction;

+ (instancetype)actionWithTitle:(NSString *)title
                      iconImage:(UIImage *)iconImage
                          style:(NSInteger)style
                        handler:(void (^)(id))handler;

+ (instancetype)actionWithTitle:(NSString *)title iconImage:(UIImage *)iconImage handler:(void (^)(id))handler;
@end

@interface YTActionSheetController : UIViewController
- (void)presentFromView:(UIView *)view;
- (NSArray<YTActionSheetAction *> *)actions;
- (void)addAction:(YTActionSheetAction *)action;
- (void)dismiss;
- (UIViewController *)findViewControllerForView:(UIView *)view;
@end
@interface YTToastResponderEvent : NSObject
+ (instancetype)eventWithMessage:(NSString *)message firstResponder:(UIViewController *)responder;
- (void)send;
@end

@interface YTSettingsSectionItem : NSObject
+ (instancetype)itemWithTitle:(NSString *)title
             titleDescription:(nullable NSString *)titleDescription
      accessibilityIdentifier:(nullable NSString *)accessibilityIdentifier
              detailTextBlock:(nullable NSString * (^)(void))detailTextBlock
                  selectBlock:(BOOL (^)(YTSettingsCell *, NSUInteger))selectBlock
                settingItemId:(NSUInteger)settingItemId;
@end

NS_ASSUME_NONNULL_END
