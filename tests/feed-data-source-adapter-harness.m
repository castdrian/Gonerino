#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "FeedDataSourceAdapter.h"
#import "Util.h"

NSString * const FeedFilterStateDidChangeNotification = @"FeedFilterStateDidChangeNotification";

@interface ASDisplayNode : NSObject
@end

@implementation ASDisplayNode
@end

@interface ASCellNode : ASDisplayNode
@end

@implementation ASCellNode
@end

@interface FakeCollectionNode : NSObject
@property(nonatomic) NSUInteger reloadCalls;
@property(nonatomic, weak) id collectionView;
@end

@implementation FakeCollectionNode

- (void)reloadData {
    self.reloadCalls += 1;
    [self.collectionView setContentOffset:CGPointZero];
}

@end

@interface FakeCollectionView : NSObject
@property(nonatomic, strong) FakeCollectionNode *collectionNode;
@property(nonatomic) CGPoint contentOffset;
@property(nonatomic) BOOL pagingEnabled;
@end

@implementation FakeCollectionView

- (BOOL)isPagingEnabled {
    return self.pagingEnabled;
}

@end

@interface FakeDirectCollectionView : NSObject
@property(nonatomic) BOOL pagingEnabled;
@end

@implementation FakeDirectCollectionView

- (BOOL)isPagingEnabled {
    return NO;
}

@end

@interface FakeNode : NSObject
@property(nonatomic, copy) NSString *identifier;
@end

@implementation FakeNode
@end

@interface FakeDataSource : NSObject
@property(nonatomic, strong) NSArray<NSArray<FakeNode *> *> *nodesBySection;
@end

@implementation FakeDataSource

- (NSInteger)numberOfSectionsInCollectionNode:(id)collectionNode {
    return self.nodesBySection.count;
}

- (NSInteger)collectionNode:(id)collectionNode numberOfItemsInSection:(NSInteger)section {
    return section >= 0 && section < self.nodesBySection.count ? self.nodesBySection[(NSUInteger)section].count : 0;
}

- (NSString *)modelIdentifierForElementAtIndexPath:(NSIndexPath *)indexPath inNode:(id)collectionNode {
    FakeNode *node = self.nodesBySection[(NSUInteger)indexPath.section][(NSUInteger)indexPath.item];
    return node.identifier;
}

- (id)collectionNode:(id)collectionNode nodeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return self.nodesBySection[(NSUInteger)indexPath.section][(NSUInteger)indexPath.item];
}

- (NSIndexPath *)indexPathForElementWithModelIdentifier:(NSString *)identifier inNode:(id)collectionNode {
    for (NSUInteger section = 0; section < self.nodesBySection.count; section++) {
        NSArray<FakeNode *> *nodes = self.nodesBySection[section];
        for (NSUInteger item = 0; item < nodes.count; item++) {
            if ([nodes[item].identifier isEqualToString:identifier])
                return [NSIndexPath indexPathForItem:item inSection:section];
        }
    }
    return nil;
}

- (id)collectionNode:(id)collectionNode nodeBlockForItemAtIndexPath:(NSIndexPath *)indexPath {
    FakeNode *node = [self collectionNode:collectionNode nodeForItemAtIndexPath:indexPath];
    return [^{ return node; } copy];
}

- (NSInteger)numberOfSectionsInCollectionView:(id)collectionView {
    return self.nodesBySection.count;
}

- (NSInteger)collectionView:(id)collectionView numberOfItemsInSection:(NSInteger)section {
    return section >= 0 && section < self.nodesBySection.count ? self.nodesBySection[(NSUInteger)section].count : 0;
}

- (id)collectionView:(id)collectionView nodeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return [self collectionNode:collectionView nodeForItemAtIndexPath:indexPath];
}

- (id)collectionView:(id)collectionView nodeBlockForItemAtIndexPath:(NSIndexPath *)indexPath {
    FakeNode *node = [self collectionView:collectionView nodeForItemAtIndexPath:indexPath];
    return [^{ return node; } copy];
}

@end

static NSMutableDictionary<NSValue *, FeedMetadataRecord *> *MetadataByNode(void) {
    static NSMutableDictionary<NSValue *, FeedMetadataRecord *> *values;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        values = [NSMutableDictionary dictionary];
    });
    return values;
}

static NSValue *NodeKey(id node) {
    return [NSValue valueWithNonretainedObject:node];
}

static BOOL FilteringState = YES;
static NSMutableSet<NSString *> *BlockedIdentifiers(void) {
    static NSMutableSet<NSString *> *values;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        values = [NSMutableSet set];
    });
    return values;
}

@implementation FeedMetadataRecord

- (instancetype)initWithVideoID:(NSString *)videoID title:(NSString *)title channel:(NSString *)channel {
    self = [super init];
    if (self) {
        _videoID = [videoID copy] ?: @"";
        _title = [title copy] ?: @"";
        _channel = [channel copy] ?: @"";
    }
    return self;
}

- (NSDictionary<NSString *,NSString *> *)dictionaryRepresentation {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (self.videoID.length > 0)
        result[@"id"] = self.videoID;
    if (self.title.length > 0)
        result[@"title"] = self.title;
    if (self.channel.length > 0)
        result[@"channel"] = self.channel;
    return result.copy;
}

@end

@implementation Util

+ (BOOL)filteringEnabled {
    return FilteringState;
}

+ (FeedMetadataRecord *)feedVideoMetadataFromNode:(id)node {
    return MetadataByNode()[NodeKey(node)];
}

+ (FeedMetadataRecord *)feedVideoMetadataFromModel:(id)model {
    return MetadataByNode()[NodeKey(model)];
}

+ (void)rememberFeedVideoMetadata:(FeedMetadataRecord *)metadata forNode:(id)node {
    if (metadata && node)
        MetadataByNode()[NodeKey(node)] = metadata;
}

+ (FeedMetadataRecord *)cachedFeedVideoMetadataForNode:(id)node {
    return MetadataByNode()[NodeKey(node)];
}

+ (FeedMetadataRecord *)cachedFeedVideoMetadataForVideoID:(NSString *)videoID {
    for (FeedMetadataRecord *metadata in MetadataByNode().allValues) {
        if ([metadata.videoID isEqualToString:videoID])
            return metadata;
    }
    return nil;
}

+ (NSString *)feedVideoIDForObject:(id)object {
    return MetadataByNode()[NodeKey(object)].videoID;
}

+ (void)resetFeedVideoMetadataForNode:(id)node {
    [MetadataByNode() removeObjectForKey:NodeKey(node)];
}

+ (BOOL)nodeContainsBlockedVideo:(id)node metadata:(FeedMetadataRecord *)metadata {
    return FilteringState && [BlockedIdentifiers() containsObject:metadata.videoID ?: @""];
}

@end

@interface FeedDataSourceAdapter (HarnessPrivate)
- (NSInteger)numberOfSectionsInCollectionNode:(id)collectionNode;
- (NSInteger)collectionNode:(id)collectionNode numberOfItemsInSection:(NSInteger)section;
- (id)collectionNode:(id)collectionNode nodeForItemAtIndexPath:(NSIndexPath *)indexPath;
- (id)collectionNode:(id)collectionNode nodeBlockForItemAtIndexPath:(NSIndexPath *)indexPath;
- (NSString *)modelIdentifierForElementAtIndexPath:(NSIndexPath *)indexPath inNode:(id)collectionNode;
- (NSIndexPath *)indexPathForElementWithModelIdentifier:(NSString *)identifier inNode:(id)collectionNode;
- (NSInteger)numberOfSectionsInCollectionView:(id)collectionView;
- (NSInteger)collectionView:(id)collectionView numberOfItemsInSection:(NSInteger)section;
- (id)collectionView:(id)collectionView nodeForItemAtIndexPath:(NSIndexPath *)indexPath;
- (id)collectionView:(id)collectionView nodeBlockForItemAtIndexPath:(NSIndexPath *)indexPath;
@end

typedef id (^FeedNodeBlock)(void);

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static void PumpMainQueue(void) {
    for (NSUInteger index = 0; index < 8; index++)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static FeedMetadataRecord *Metadata(NSString *identifier) {
    return [[FeedMetadataRecord alloc] initWithVideoID:identifier title:identifier channel:identifier];
}

int main(void) {
    @autoreleasepool {
        FakeNode *first = [FakeNode new];
        first.identifier = @"first123456";
        FakeNode *blocked = [FakeNode new];
        blocked.identifier = @"block123456";
        FakeNode *third = [FakeNode new];
        third.identifier = @"third123456";
        FakeNode *otherSection = [FakeNode new];
        otherSection.identifier = @"other123456";

        MetadataByNode()[NodeKey(first)] = Metadata(first.identifier);
        MetadataByNode()[NodeKey(blocked)] = Metadata(blocked.identifier);
        MetadataByNode()[NodeKey(third)] = Metadata(third.identifier);
        MetadataByNode()[NodeKey(otherSection)] = Metadata(otherSection.identifier);
        [BlockedIdentifiers() addObject:blocked.identifier];

        FakeDataSource *dataSource = [FakeDataSource new];
        dataSource.nodesBySection = @[@[first, blocked, third], @[otherSection]];
        FakeCollectionNode *collectionNode = [FakeCollectionNode new];
        FakeCollectionView *collectionView = [FakeCollectionView new];
        collectionView.collectionNode = collectionNode;
        collectionNode.collectionView = collectionView;
        [collectionView setContentOffset:CGPointMake(0.0, 780.0)];
        FeedDataSourceAdapter *adapter = [FeedDataSourceAdapter adapterWithCollectionView:(UICollectionView *)collectionView
                                                                                  dataSource:dataSource];

        Require([adapter numberOfSectionsInCollectionNode:collectionNode] == 2, @"section count");
        Require([adapter collectionNode:collectionNode numberOfItemsInSection:0] == 3, @"initial source count");
        id blockedNode = [adapter collectionNode:collectionNode nodeForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
        Require([blockedNode isKindOfClass:NSClassFromString(@"FeedEmptyCellNode")], @"blocked node was not replaced");
        PumpMainQueue();
        Require(CGPointEqualToPoint([collectionView contentOffset], CGPointMake(0.0, 780.0)),
                @"filtered reload did not preserve the feed position");
        Require([adapter collectionNode:collectionNode numberOfItemsInSection:0] == 2, @"blocked item remained in snapshot");
        Require(collectionNode.reloadCalls == 1, @"late metadata caused more than one reload");
        Require([[adapter modelIdentifierForElementAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0] inNode:collectionNode] isEqualToString:third.identifier],
                @"visible index did not translate to source index");
        Require([adapter indexPathForElementWithModelIdentifier:blocked.identifier inNode:collectionNode] == nil,
                @"blocked source identifier remained addressable");
        Require([[adapter indexPathForElementWithModelIdentifier:third.identifier inNode:collectionNode] isEqual:[NSIndexPath indexPathForItem:1 inSection:0]],
                @"surviving source identifier did not translate to visible index");

        FakeCollectionNode *pagedCollectionNode = [FakeCollectionNode new];
        FakeCollectionView *pagedCollectionView = [FakeCollectionView new];
        pagedCollectionView.pagingEnabled = YES;
        pagedCollectionView.collectionNode = pagedCollectionNode;
        pagedCollectionNode.collectionView = pagedCollectionView;
        [pagedCollectionView setContentOffset:CGPointMake(0.0, 1334.0)];
        FeedDataSourceAdapter *pagedAdapter = [FeedDataSourceAdapter adapterWithCollectionView:(UICollectionView *)pagedCollectionView
                                                                                      dataSource:dataSource];
        id pagedBlockedNode = [pagedAdapter collectionNode:pagedCollectionNode
                                  nodeForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
        Require([pagedBlockedNode isKindOfClass:NSClassFromString(@"FeedEmptyCellNode")],
                @"paged blocked node was not replaced");
        PumpMainQueue();
        Require([pagedAdapter collectionNode:pagedCollectionNode numberOfItemsInSection:0] == 2,
                @"paged blocked item remained in snapshot");
        Require(CGPointEqualToPoint([pagedCollectionView contentOffset], CGPointMake(0.0, 1334.0)),
                @"paged filtered reload did not preserve the page position");

        FeedNodeBlock nodeBlock = [adapter collectionNode:collectionNode nodeBlockForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
        [adapter upstreamWillReload];
        id staleNode = nodeBlock();
        Require([staleNode isKindOfClass:NSClassFromString(@"FeedEmptyCellNode")], @"stale node block returned old content");

        FakeDirectCollectionView *directCollectionView = [FakeDirectCollectionView new];
        FeedDataSourceAdapter *directAdapter = [FeedDataSourceAdapter adapterWithCollectionView:(UICollectionView *)directCollectionView
                                                                                       dataSource:dataSource];
        Require([directAdapter numberOfSectionsInCollectionView:(UICollectionView *)directCollectionView] == 2,
                @"direct collection-view section count");
        Require([directAdapter collectionView:(UICollectionView *)directCollectionView numberOfItemsInSection:0] == 3,
                @"direct collection-view source count");
        id directNode = [directAdapter collectionView:(UICollectionView *)directCollectionView
                              nodeForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
        Require(directNode == first, @"direct collection-view node path");
        FeedNodeBlock directNodeBlock = [directAdapter collectionView:(UICollectionView *)directCollectionView
                                             nodeBlockForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
        Require([[directNodeBlock() class] isSubclassOfClass:NSClassFromString(@"FeedEmptyCellNode")],
                @"direct collection-view node block path");
        PumpMainQueue();
        Require([directAdapter collectionView:(UICollectionView *)directCollectionView numberOfItemsInSection:0] == 2,
                @"direct collection-view blocked snapshot");

        NSLog(@"PASS: adapter snapshot, index translation, zero-node fallback, and stale block checks");
    }
    return 0;
}
