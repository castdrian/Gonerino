#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ReelSequenceFilter : NSObject

+ (NSOrderedSet *)filteredReelsForDataSource:(id)dataSource sourceReels:(NSOrderedSet *)sourceReels;
+ (NSSet *)filteredVideoIDsForDataSource:(id)dataSource sourceVideoIDs:(NSSet *)sourceVideoIDs;
+ (NSInteger)visibleIndexForSourceIndex:(NSInteger)sourceIndex dataSource:(id)dataSource;
+ (NSInteger)sourceIndexForVisibleIndex:(NSInteger)visibleIndex dataSource:(id)dataSource;
+ (NSInteger)visibleIndexForVideoID:(NSString *)videoID dataSource:(id)dataSource;
+ (NSInteger)visibleIndexForObject:(id)object dataSource:(id)dataSource;
+ (void)registerSequenceController:(id)controller dataSource:(id)dataSource;
+ (void)invalidateDataSource:(id)dataSource;
+ (void)invalidateAll;

@end

NS_ASSUME_NONNULL_END
