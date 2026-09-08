#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class FeedMetadataRecord;

NS_ASSUME_NONNULL_BEGIN

@interface FeedDataSourceAdapter : NSObject

+ (instancetype)adapterWithCollectionView:(UICollectionView *)collectionView dataSource:(id)dataSource;
+ (BOOL)isAdapter:(nullable id)dataSource;
+ (void)preferencesDidChangeForMetadata:(nullable FeedMetadataRecord *)metadata;
+ (nullable FeedMetadataRecord *)cachedMetadataForNode:(nullable id)node;
+ (void)invalidateMetadataForNode:(nullable id)node;
+ (void)rememberMetadata:(FeedMetadataRecord *)metadata forNode:(id)node;
+ (void)rememberMetadata:(FeedMetadataRecord *)metadata forVisibleItemInCollectionView:(UICollectionView *)collectionView;
+ (void)rememberMetadata:(FeedMetadataRecord *)metadata forContentView:(UIView *)contentView inCollectionView:(UICollectionView *)collectionView;
+ (void)rememberMetadata:(FeedMetadataRecord *)metadata forContentView:(UIView *)contentView;
+ (nullable FeedMetadataRecord *)cachedMetadataForContentView:(UIView *)contentView inCollectionView:(UICollectionView *)collectionView;

- (void)upstreamWillReload;
- (void)replaceDataSource:(nullable id)dataSource;
- (nullable FeedMetadataRecord *)metadataForNode:(nullable id)node;
- (BOOL)filteringEnabled;

@end

NS_ASSUME_NONNULL_END
