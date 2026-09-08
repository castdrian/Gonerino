#import "FeedDataSourceAdapter.h"
#import "Tweak.h"
#import "Util.h"

#import <objc/message.h>
#import <objc/runtime.h>

typedef id _Nullable (^FeedNodeBlock)(void);

@interface FeedCollectionSnapshot : NSObject
@property(nonatomic, copy) NSArray<NSArray<NSNumber *> *> *sourceItemsBySection;
@property(nonatomic, copy) NSArray<NSDictionary<NSNumber *, NSNumber *> *> *visibleItemsBySection;
@property(nonatomic, copy) NSArray<NSNumber *> *sourceCounts;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger sourceGeneration;
@property(nonatomic) BOOL filteringEnabled;
@end

@implementation FeedCollectionSnapshot
@end

@interface FeedDataSourceAdapter ()
@property(nonatomic, weak) UICollectionView *collectionView;
@property(nonatomic, weak) id dataSource;
@property(nonatomic, strong, nullable) FeedCollectionSnapshot *snapshot;
@property(nonatomic, strong) NSMutableDictionary<NSString *, FeedMetadataRecord *> *metadataBySourcePath;
@property(nonatomic, strong) NSMutableDictionary<NSString *, FeedMetadataRecord *> *metadataByIdentifier;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *sourceIdentityByPath;
@property(nonatomic, strong) NSMapTable *sourcePathByNode;
@property(nonatomic, strong) NSMapTable *nodeBySourcePath;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger sourceGeneration;
@property(nonatomic) BOOL reloadQueued;
@property(nonatomic) BOOL performingFilteredReload;
@property(nonatomic) NSUInteger filteredReloadToken;
- (nullable NSIndexPath *)sourceIndexPathForContentView:(UIView *)contentView collectionView:(UICollectionView *)collectionView;
- (void)finishFilteredReloadWithToken:(NSUInteger)token;
- (void)invalidateMetadataForNode:(id)node;
- (FeedCollectionSnapshot *)snapshotForCountRequestWithRetryCount:(NSUInteger)retryCount;
- (nullable NSString *)sourceIdentifierAtIndexPath:(NSIndexPath *)indexPath collectionNode:(nullable id)collectionNode;
- (BOOL)filtersShortsPager;
- (BOOL)filteringEnabledForAdapter;
@end

static NSHashTable<FeedDataSourceAdapter *> *FeedAdapters(void) {
    static NSHashTable<FeedDataSourceAdapter *> *adapters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adapters = [NSHashTable weakObjectsHashTable];
    });
    return adapters;
}

static NSUInteger CurrentFeedPreferencesGeneration = 1;
static NSObject *FeedPreferencesGenerationLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static NSUInteger FeedPreferencesGeneration(void) {
    @synchronized (FeedPreferencesGenerationLock()) {
        return CurrentFeedPreferencesGeneration;
    }
}

static NSUInteger AdvanceFeedPreferencesGeneration(void) {
    @synchronized (FeedPreferencesGenerationLock()) {
        return ++CurrentFeedPreferencesGeneration;
    }
}

static NSString *FeedSourcePathKey(NSIndexPath *indexPath) {
    return [NSString stringWithFormat:@"%ld:%ld", (long)indexPath.section, (long)indexPath.item];
}

static NSString *FeedSourcePathKeyForItem(NSInteger section, NSInteger item) {
    return [NSString stringWithFormat:@"%ld:%ld", (long)section, (long)item];
}

static BOOL IsLikelyVideoIdentifier(NSString *identifier) {
    if (identifier.length != 11)
        return NO;
    static NSCharacterSet *allowedCharacters;
    static NSCharacterSet *disallowedCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedCharacters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
        disallowedCharacters = [allowedCharacters invertedSet];
    });
    return [identifier rangeOfCharacterFromSet:disallowedCharacters].location == NSNotFound;
}

static NSMapTable *FeedNodeToPathMap(void) {
    return [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                     valueOptions:NSPointerFunctionsStrongMemory
                                         capacity:0];
}

static FeedMetadataRecord *MergedFeedMetadata(FeedMetadataRecord *primary, FeedMetadataRecord *secondary) {
    if (!primary)
        return secondary;
    if (!secondary)
        return primary;
    return [[FeedMetadataRecord alloc] initWithVideoID:primary.videoID.length > 0 ? primary.videoID : secondary.videoID
                                                 title:primary.title.length > 0 ? primary.title : secondary.title
                                               channel:primary.channel.length > 0 ? primary.channel : secondary.channel];
}

static FeedMetadataRecord *MetadataWithIdentifier(NSString *identifier, FeedMetadataRecord *metadata) {
    if (identifier.length == 0 || !metadata)
        return metadata;
    if ([metadata.videoID isEqualToString:identifier])
        return metadata;
    return [[FeedMetadataRecord alloc] initWithVideoID:identifier
                                                 title:metadata.title
                                               channel:metadata.channel];
}

static void StoreIdentifierMetadata(NSMutableDictionary<NSString *, FeedMetadataRecord *> *metadataByIdentifier,
                                    NSString *identifier,
                                    FeedMetadataRecord *metadata) {
    if (identifier.length == 0 || !metadata)
        return;
    if (!metadataByIdentifier[identifier] && metadataByIdentifier.count >= 512)
        [metadataByIdentifier removeObjectForKey:metadataByIdentifier.allKeys.firstObject];
    metadataByIdentifier[identifier] = metadata;
}

static void StoreSourcePathMetadata(NSMutableDictionary<NSString *, FeedMetadataRecord *> *metadataBySourcePath,
                                    NSString *sourcePath,
                                    FeedMetadataRecord *metadata) {
    if (sourcePath.length == 0 || !metadata)
        return;
    if (!metadataBySourcePath[sourcePath] && metadataBySourcePath.count >= 1024)
        [metadataBySourcePath removeObjectForKey:metadataBySourcePath.allKeys.firstObject];
    metadataBySourcePath[sourcePath] = metadata;
}

static void StoreSourceIdentity(NSMutableDictionary<NSString *, NSString *> *sourceIdentityByPath,
                                NSString *sourcePath,
                                NSString *identity) {
    if (sourcePath.length == 0 || identity.length == 0)
        return;
    if (!sourceIdentityByPath[sourcePath] && sourceIdentityByPath.count >= 1024)
        [sourceIdentityByPath removeObjectForKey:sourceIdentityByPath.allKeys.firstObject];
    sourceIdentityByPath[sourcePath] = identity;
}

static BOOL FeedMetadataMatches(FeedMetadataRecord *candidate, FeedMetadataRecord *changed) {
    if (!changed)
        return YES;
    if (changed.videoID.length > 0 && [candidate.videoID isEqualToString:changed.videoID])
        return YES;
    if (changed.channel.length > 0 && [candidate.channel caseInsensitiveCompare:changed.channel] == NSOrderedSame)
        return YES;
    if (changed.title.length > 0 && [candidate.title localizedCaseInsensitiveContainsString:changed.title])
        return YES;
    return NO;
}

static BOOL FeedMetadataHasAllFields(FeedMetadataRecord *metadata) {
    return metadata.videoID.length > 0 && metadata.title.length > 0 && metadata.channel.length > 0;
}

static CGSize EmptyFeedNodeCalculateSizeThatFits(id node, SEL selector, CGSize constrainedSize) {
    return CGSizeZero;
}

static Class EmptyFeedNodeClass(void) {
    static Class emptyNodeClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cellNodeClass = NSClassFromString(@"ASCellNode");
        if (!cellNodeClass)
            return;
        emptyNodeClass = objc_allocateClassPair(cellNodeClass, "FeedEmptyCellNode", 0);
        if (!emptyNodeClass)
            return;
        Method sizeMethod = class_getInstanceMethod(cellNodeClass, @selector(calculateSizeThatFits:));
        const char *typeEncoding = sizeMethod ? method_getTypeEncoding(sizeMethod) : "{CGSize=dd}@:{CGSize=dd}";
        class_addMethod(emptyNodeClass,
                        @selector(calculateSizeThatFits:),
                        (IMP)EmptyFeedNodeCalculateSizeThatFits,
                        typeEncoding);
        objc_registerClassPair(emptyNodeClass);
    });
    return emptyNodeClass;
}

static id EmptyFeedNode(void) {
    Class cellNodeClass = EmptyFeedNodeClass();
    if (!cellNodeClass)
        return nil;
    id node = [[cellNodeClass alloc] init];
    if ([node respondsToSelector:@selector(style)]) {
        id style = ((id (*)(id, SEL))objc_msgSend)(node, @selector(style));
        if ([style respondsToSelector:@selector(setPreferredSize:)])
            ((void (*)(id, SEL, CGSize))objc_msgSend)(style, @selector(setPreferredSize:), CGSizeZero);
    }
    if ([node respondsToSelector:@selector(setHidden:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setHidden:), YES);
    if ([node respondsToSelector:@selector(setUserInteractionEnabled:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setUserInteractionEnabled:), NO);
    return node;
}

@implementation FeedDataSourceAdapter

- (BOOL)filtersShortsPager {
    NSString *dataSourceClass = NSStringFromClass([self.dataSource class]).lowercaseString;
    return [dataSourceClass containsString:@"scrollablepage"];
}

- (BOOL)filteringEnabledForAdapter {
    return [Util filteringEnabled] && ![self filtersShortsPager];
}

- (BOOL)filteringEnabled {
    return [self filteringEnabledForAdapter];
}

+ (void)initialize {
    if (self != [FeedDataSourceAdapter class])
        return;
    [[NSNotificationCenter defaultCenter] addObserverForName:FeedFilterStateDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *notification) {
        FeedMetadataRecord *metadata = [notification.object isKindOfClass:[FeedMetadataRecord class]] ? notification.object : nil;
        [self preferencesDidChangeForMetadata:metadata];
    }];
}

+ (instancetype)adapterWithCollectionView:(UICollectionView *)collectionView dataSource:(id)dataSource {
    FeedDataSourceAdapter *adapter = [FeedDataSourceAdapter new];
    adapter.collectionView = collectionView;
    adapter.dataSource = dataSource;
    adapter.metadataBySourcePath = [NSMutableDictionary dictionary];
    adapter.metadataByIdentifier = [NSMutableDictionary dictionary];
    adapter.sourceIdentityByPath = [NSMutableDictionary dictionary];
    adapter.sourcePathByNode = FeedNodeToPathMap();
    adapter.nodeBySourcePath = [NSMapTable strongToWeakObjectsMapTable];
    adapter.generation = FeedPreferencesGeneration();
    adapter.sourceGeneration = 1;
    @synchronized (FeedAdapters()) {
        [FeedAdapters() addObject:adapter];
    }
    return adapter;
}

+ (BOOL)isAdapter:(id)dataSource {
    return [dataSource isKindOfClass:[FeedDataSourceAdapter class]];
}

+ (FeedMetadataRecord *)cachedMetadataForNode:(id)node {
    if (!node)
        return nil;
    NSArray<FeedDataSourceAdapter *> *adapters;
    @synchronized (FeedAdapters()) {
        adapters = FeedAdapters().allObjects;
    }
    FeedMetadataRecord *metadata;
    for (FeedDataSourceAdapter *adapter in adapters) {
        FeedMetadataRecord *candidate = [adapter metadataForNode:node];
        metadata = MergedFeedMetadata(metadata, candidate);
        if (FeedMetadataHasAllFields(metadata))
            break;
    }
    return metadata;
}

+ (void)invalidateMetadataForNode:(id)node {
    if (!node)
        return;
    NSArray<FeedDataSourceAdapter *> *adapters;
    @synchronized (FeedAdapters()) {
        adapters = FeedAdapters().allObjects;
    }
    for (FeedDataSourceAdapter *adapter in adapters)
        [adapter invalidateMetadataForNode:node];
}

+ (void)rememberMetadata:(FeedMetadataRecord *)metadata forNode:(id)node {
    if (!metadata || metadata.dictionaryRepresentation.count == 0 || !node)
        return;
    NSArray<FeedDataSourceAdapter *> *adapters;
    @synchronized (FeedAdapters()) {
        adapters = FeedAdapters().allObjects;
    }
    for (FeedDataSourceAdapter *adapter in adapters)
        [adapter rememberMetadata:metadata forNode:node];
}

+ (void)rememberMetadata:(FeedMetadataRecord *)metadata forVisibleItemInCollectionView:(UICollectionView *)collectionView {
    if (!metadata || metadata.dictionaryRepresentation.count == 0 || !collectionView)
        return;
    NSArray<FeedDataSourceAdapter *> *adapters;
    @synchronized (FeedAdapters()) {
        adapters = FeedAdapters().allObjects;
    }
    for (FeedDataSourceAdapter *adapter in adapters) {
        if (adapter.collectionView == collectionView) {
            [adapter rememberMetadata:metadata forVisibleItemInCollectionView:collectionView];
        }
    }
}

+ (void)rememberMetadata:(FeedMetadataRecord *)metadata forContentView:(UIView *)contentView inCollectionView:(UICollectionView *)collectionView {
    if (!metadata || metadata.dictionaryRepresentation.count == 0 || !contentView || !collectionView)
        return;
    NSArray<FeedDataSourceAdapter *> *adapters;
    @synchronized (FeedAdapters()) {
        adapters = FeedAdapters().allObjects;
    }
    for (FeedDataSourceAdapter *adapter in adapters) {
        if (adapter.collectionView == collectionView)
            [adapter rememberMetadata:metadata forContentView:contentView inCollectionView:collectionView];
    }
}

+ (void)rememberMetadata:(FeedMetadataRecord *)metadata forContentView:(UIView *)contentView {
    if (!metadata || metadata.dictionaryRepresentation.count == 0 || !contentView)
        return;
    NSArray<FeedDataSourceAdapter *> *adapters;
    @synchronized (FeedAdapters()) {
        adapters = FeedAdapters().allObjects;
    }
    for (FeedDataSourceAdapter *adapter in adapters) {
        UICollectionView *collectionView = adapter.collectionView;
        if (!collectionView)
            continue;
        NSString *className = NSStringFromClass([collectionView class]).lowercaseString;
        if (!collectionView.isPagingEnabled && ![className containsString:@"short"] && ![className containsString:@"reel"])
            continue;
        [adapter rememberMetadata:metadata forContentView:contentView inCollectionView:collectionView];
    }
}

+ (FeedMetadataRecord *)cachedMetadataForContentView:(UIView *)contentView inCollectionView:(UICollectionView *)collectionView {
    if (!contentView || !collectionView)
        return nil;
    NSArray<FeedDataSourceAdapter *> *adapters;
    @synchronized (FeedAdapters()) {
        adapters = FeedAdapters().allObjects;
    }
    for (FeedDataSourceAdapter *adapter in adapters) {
        if (adapter.collectionView != collectionView)
            continue;
        NSIndexPath *sourceIndexPath = [adapter sourceIndexPathForContentView:contentView collectionView:collectionView];
        if (!sourceIndexPath)
            continue;
        @synchronized (adapter) {
            FeedMetadataRecord *metadata = adapter.metadataBySourcePath[FeedSourcePathKey(sourceIndexPath)];
            if (metadata)
                return metadata;
        }
    }
    return nil;
}

+ (void)preferencesDidChangeForMetadata:(FeedMetadataRecord *)metadata {
    void (^invalidate)(void) = ^{
        NSUInteger generation = AdvanceFeedPreferencesGeneration();
        NSArray<FeedDataSourceAdapter *> *adapters;
        @synchronized (FeedAdapters()) {
            adapters = FeedAdapters().allObjects;
        }
        NSMutableArray<FeedDataSourceAdapter *> *matchingAdapters = [NSMutableArray array];
        for (FeedDataSourceAdapter *adapter in adapters) {
            if (!metadata || [adapter containsMetadata:metadata])
                [matchingAdapters addObject:adapter];
        }
        if (metadata && matchingAdapters.count == 0)
            [matchingAdapters addObjectsFromArray:adapters];
        for (FeedDataSourceAdapter *adapter in matchingAdapters) {
            @synchronized (adapter) {
                adapter.generation = generation;
            }
            [adapter queueFilteredReload];
        }
    };
    if (NSThread.isMainThread)
        invalidate();
    else
        dispatch_async(dispatch_get_main_queue(), invalidate);
}

- (Class)class {
    return [self.dataSource class] ?: [FeedDataSourceAdapter class];
}

- (BOOL)isKindOfClass:(Class)aClass {
    return aClass == [FeedDataSourceAdapter class] || [self.dataSource isKindOfClass:aClass];
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    return [super conformsToProtocol:protocol] || [self.dataSource conformsToProtocol:protocol];
}

- (void)replaceDataSource:(id)dataSource {
    if (dataSource == self.dataSource)
        return;
    NSArray *nodesToInvalidate = @[];
    @synchronized (self) {
        self.sourceGeneration += 1;
        nodesToInvalidate = [[self.sourcePathByNode keyEnumerator] allObjects];
        [self.metadataBySourcePath removeAllObjects];
        [self.metadataByIdentifier removeAllObjects];
        [self.sourceIdentityByPath removeAllObjects];
        [self.nodeBySourcePath removeAllObjects];
        [self.sourcePathByNode removeAllObjects];
        self.snapshot = nil;
    }
    for (id node in nodesToInvalidate)
        [Util resetFeedVideoMetadataForNode:node];
    self.dataSource = dataSource;
}

- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(collectionView:nodeForItemAtIndexPath:) ||
        selector == @selector(collectionView:nodeBlockForItemAtIndexPath:))
        return [self.dataSource respondsToSelector:selector];
    if (selector == @selector(collectionNode:nodeForItemAtIndexPath:) ||
        selector == @selector(collectionNode:nodeBlockForItemAtIndexPath:) ||
        selector == @selector(collectionNode:nodeModelForItemAtIndexPath:))
        return [self.dataSource respondsToSelector:selector];
    if (selector == @selector(collectionView:numberOfItemsInSection:))
        return [self.dataSource respondsToSelector:selector] || [self.dataSource respondsToSelector:@selector(collectionNode:numberOfItemsInSection:)];
    if (selector == @selector(collectionNode:numberOfItemsInSection:))
        return [self.dataSource respondsToSelector:selector] || [self.dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)];
    if (selector == @selector(numberOfSectionsInCollectionView:))
        return [self.dataSource respondsToSelector:selector] || [self.dataSource respondsToSelector:@selector(numberOfSectionsInCollectionNode:)];
    if (selector == @selector(numberOfSectionsInCollectionNode:))
        return [self.dataSource respondsToSelector:selector] || [self.dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)];
    if (selector == @selector(modelIdentifierForElementAtIndexPath:inNode:) ||
        selector == @selector(indexPathForElementWithModelIdentifier:inNode:) ||
        selector == @selector(presentationIndexPathForModelIndexPath:) ||
        selector == @selector(modelIndexPathForPresentationIndexPath:) ||
        selector == @selector(modelIndexPathForSupplementaryElementOfKind:atPresentationIndexPath:) ||
        selector == @selector(reportItemWillBecomeVisibleWithModelIndexPath:presentationIndexPath:) ||
        selector == @selector(reportItemDidBecomeHiddenWithModelIndexPath:) ||
        selector == @selector(shouldReportVisibilityForItemWithModelIndexPath:))
        return [self.dataSource respondsToSelector:selector];
    return [super respondsToSelector:selector] || [self.dataSource respondsToSelector:selector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [self.dataSource methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if ([self.dataSource respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:self.dataSource];
        return;
    }
    [self doesNotRecognizeSelector:invocation.selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.dataSource respondsToSelector:selector] ? self.dataSource : [super forwardingTargetForSelector:selector];
}

- (id)collectionNodeObject {
    ASCollectionView *collectionView = (ASCollectionView *)self.collectionView;
    return [collectionView respondsToSelector:@selector(collectionNode)] ? collectionView.collectionNode : nil;
}

- (NSInteger)sourceSectionCount {
    id collectionNode = [self collectionNodeObject];
    @try {
        if (collectionNode && [self.dataSource respondsToSelector:@selector(numberOfSectionsInCollectionNode:)])
            return ((NSInteger (*)(id, SEL, id))objc_msgSend)(self.dataSource, @selector(numberOfSectionsInCollectionNode:), collectionNode);
        if ([self.dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)])
            return ((NSInteger (*)(id, SEL, id))objc_msgSend)(self.dataSource, @selector(numberOfSectionsInCollectionView:), self.collectionView);
    } @catch (__unused NSException *exception) {
    }
    if (!collectionNode)
        return 1;
    return 1;
}

- (NSInteger)sourceItemCountForSection:(NSInteger)section {
    id collectionNode = [self collectionNodeObject];
    @try {
        if (collectionNode && [self.dataSource respondsToSelector:@selector(collectionNode:numberOfItemsInSection:)])
            return ((NSInteger (*)(id, SEL, id, NSInteger))objc_msgSend)(self.dataSource, @selector(collectionNode:numberOfItemsInSection:), collectionNode, section);
        if ([self.dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)])
            return ((NSInteger (*)(id, SEL, id, NSInteger))objc_msgSend)(self.dataSource, @selector(collectionView:numberOfItemsInSection:), self.collectionView, section);
    } @catch (__unused NSException *exception) {
    }
    return 0;
}

- (NSString *)sourceIdentifierAtIndexPath:(NSIndexPath *)indexPath collectionNode:(id)collectionNode {
    if (![self.dataSource respondsToSelector:@selector(modelIdentifierForElementAtIndexPath:inNode:)])
        return nil;
    @try {
        id identifier = ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                                @selector(modelIdentifierForElementAtIndexPath:inNode:),
                                                                indexPath,
                                                                collectionNode ?: [self collectionNodeObject]);
        return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (NSString *)sourceIdentifierAtIndexPath:(NSIndexPath *)indexPath {
    return [self sourceIdentifierAtIndexPath:indexPath collectionNode:nil];
}

- (FeedMetadataRecord *)knownMetadataAtSourceIndexPath:(NSIndexPath *)indexPath model:(id)model identifier:(NSString *)identifier {
    BOOL identifierIsVideoID = IsLikelyVideoIdentifier(identifier);
    FeedMetadataRecord *metadata = identifierIsVideoID ? [[FeedMetadataRecord alloc] initWithVideoID:identifier title:nil channel:nil] : nil;
    @synchronized (self) {
        NSString *sourcePath = FeedSourcePathKey(indexPath);
        if (identifier.length > 0) {
            NSString *previousIdentifier = self.sourceIdentityByPath[sourcePath];
            if (previousIdentifier.length > 0 && ![previousIdentifier isEqualToString:identifier])
                [self.metadataBySourcePath removeObjectForKey:sourcePath];
            StoreSourceIdentity(self.sourceIdentityByPath, sourcePath, identifier);
        }
        FeedMetadataRecord *stableMetadata = identifierIsVideoID ? self.metadataByIdentifier[identifier] : nil;
        metadata = MergedFeedMetadata(stableMetadata, metadata);
        FeedMetadataRecord *pathMetadata = self.metadataBySourcePath[sourcePath];
        if (identifierIsVideoID && pathMetadata.videoID.length > 0 &&
            ![pathMetadata.videoID isEqualToString:identifier]) {
            [self.metadataBySourcePath removeObjectForKey:sourcePath];
        } else {
            metadata = MergedFeedMetadata(metadata, pathMetadata);
        }
    }
    if (model) {
        FeedMetadataRecord *modelMetadata = [Util feedVideoMetadataFromModel:model];
        if (identifierIsVideoID && modelMetadata.videoID.length > 0 &&
            ![modelMetadata.videoID isEqualToString:identifier])
            modelMetadata = [[FeedMetadataRecord alloc] initWithVideoID:identifier
                                                                    title:modelMetadata.title
                                                                  channel:modelMetadata.channel];
        metadata = MergedFeedMetadata(modelMetadata, metadata);
        if (metadata.dictionaryRepresentation.count > 0)
            [Util rememberFeedVideoMetadata:metadata forNode:model];
    }
    if (identifierIsVideoID)
        metadata = MetadataWithIdentifier(identifier, metadata);
    if (metadata.dictionaryRepresentation.count > 0) {
        @synchronized (self) {
            StoreSourcePathMetadata(self.metadataBySourcePath, FeedSourcePathKey(indexPath), metadata);
            if (identifierIsVideoID)
                StoreIdentifierMetadata(self.metadataByIdentifier, identifier, metadata);
        }
    }
    return metadata;
}

- (NSArray<NSNumber *> *)sourceCounts {
    NSInteger sectionCount = MAX([self sourceSectionCount], 0);
    NSMutableArray<NSNumber *> *counts = [NSMutableArray arrayWithCapacity:(NSUInteger)sectionCount];
    for (NSInteger section = 0; section < sectionCount; section++) {
        [counts addObject:@(MAX([self sourceItemCountForSection:section], 0))];
    }
    return counts.copy;
}

- (FeedCollectionSnapshot *)snapshotForCountRequest {
    return [self snapshotForCountRequestWithRetryCount:0];
}

- (FeedCollectionSnapshot *)snapshotForCountRequestWithRetryCount:(NSUInteger)retryCount {
    FeedCollectionSnapshot *snapshot = nil;
    BOOL canStoreSnapshot = NO;
    NSArray<NSNumber *> *counts = nil;
    BOOL filteringEnabled = NO;
    NSUInteger generation = 0;
    NSUInteger sourceGeneration = 0;

    for (NSUInteger attempt = retryCount; attempt < 4; attempt++) {
        counts = [self sourceCounts];
        filteringEnabled = [self filteringEnabledForAdapter];
        @synchronized (self) {
            generation = self.generation;
            sourceGeneration = self.sourceGeneration;
            if (self.snapshot && self.snapshot.generation == generation &&
                self.snapshot.sourceGeneration == sourceGeneration &&
                self.snapshot.filteringEnabled == filteringEnabled &&
                [self.snapshot.sourceCounts isEqualToArray:counts])
                return self.snapshot;
        }

        NSMutableArray<NSArray<NSNumber *> *> *sourceItemsBySection = [NSMutableArray arrayWithCapacity:counts.count];
        NSMutableArray<NSDictionary<NSNumber *, NSNumber *> *> *visibleItemsBySection = [NSMutableArray arrayWithCapacity:counts.count];
        NSDictionary<NSString *, FeedMetadataRecord *> *cachedPathMetadata;
        NSDictionary<NSString *, FeedMetadataRecord *> *cachedIdentifierMetadata;
        NSDictionary<NSString *, NSString *> *cachedSourceIdentityByPath;
        @synchronized (self) {
            cachedPathMetadata = [self.metadataBySourcePath copy];
            cachedIdentifierMetadata = [self.metadataByIdentifier copy];
            cachedSourceIdentityByPath = [self.sourceIdentityByPath copy];
        }
        for (NSUInteger section = 0; section < counts.count; section++) {
            NSInteger sourceCount = counts[section].integerValue;
            NSMutableArray<NSNumber *> *sourceItems = [NSMutableArray arrayWithCapacity:(NSUInteger)sourceCount];
            NSMutableDictionary<NSNumber *, NSNumber *> *visibleItems = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)sourceCount];
            for (NSInteger sourceItem = 0; sourceItem < sourceCount; sourceItem++) {
                if (filteringEnabled) {
                    NSString *sourcePath = FeedSourcePathKeyForItem((NSInteger)section, sourceItem);
                    FeedMetadataRecord *metadata = cachedPathMetadata[sourcePath];
                    NSString *identifier = cachedSourceIdentityByPath[sourcePath];
                    metadata = MergedFeedMetadata(metadata, cachedIdentifierMetadata[identifier]);
                    metadata = MergedFeedMetadata(metadata,
                                                  [Util cachedFeedVideoMetadataForVideoID:identifier]);
                    if ([Util nodeContainsBlockedVideo:[NSNull null] metadata:metadata])
                        continue;
                }
                NSInteger visibleItem = (NSInteger)sourceItems.count;
                [sourceItems addObject:@(sourceItem)];
                visibleItems[@(sourceItem)] = @(visibleItem);
            }
            [sourceItemsBySection addObject:sourceItems.copy];
            [visibleItemsBySection addObject:visibleItems.copy];
        }

        snapshot = [FeedCollectionSnapshot new];
        snapshot.sourceItemsBySection = sourceItemsBySection.copy;
        snapshot.visibleItemsBySection = visibleItemsBySection.copy;
        snapshot.sourceCounts = counts;
        snapshot.generation = generation;
            snapshot.sourceGeneration = sourceGeneration;
            snapshot.filteringEnabled = filteringEnabled;
            @synchronized (self) {
                canStoreSnapshot = self.generation == generation &&
                               self.sourceGeneration == sourceGeneration &&
                               [self filteringEnabledForAdapter] == filteringEnabled;
            if (canStoreSnapshot) {
                self.snapshot = snapshot;
                return snapshot;
            }
        }
    }

    return snapshot ?: [FeedCollectionSnapshot new];
}

- (FeedCollectionSnapshot *)currentSnapshot {
    FeedCollectionSnapshot *snapshot;
    NSUInteger generation;
    NSUInteger sourceGeneration;
    @synchronized (self) {
        snapshot = self.snapshot;
        generation = self.generation;
        sourceGeneration = self.sourceGeneration;
    }
    if (!snapshot || snapshot.generation != generation || snapshot.sourceGeneration != sourceGeneration || snapshot.filteringEnabled != [self filteringEnabledForAdapter])
        return nil;
    return snapshot;
}

- (NSIndexPath *)sourceIndexPathForVisibleIndexPath:(NSIndexPath *)indexPath {
    FeedCollectionSnapshot *snapshot = [self currentSnapshot] ?: [self snapshotForCountRequest];
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)snapshot.sourceItemsBySection.count)
        return nil;
    NSArray<NSNumber *> *items = snapshot.sourceItemsBySection[(NSUInteger)indexPath.section];
    if (indexPath.item < 0 || indexPath.item >= (NSInteger)items.count)
        return nil;
    return [NSIndexPath indexPathForItem:items[(NSUInteger)indexPath.item].integerValue inSection:indexPath.section];
}

- (NSIndexPath *)visibleIndexPathForSourceIndexPath:(NSIndexPath *)indexPath {
    FeedCollectionSnapshot *snapshot = [self currentSnapshot] ?: [self snapshotForCountRequest];
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)snapshot.visibleItemsBySection.count)
        return nil;
    NSNumber *visibleItem = snapshot.visibleItemsBySection[(NSUInteger)indexPath.section][@(indexPath.item)];
    return visibleItem ? [NSIndexPath indexPathForItem:visibleItem.integerValue inSection:indexPath.section] : nil;
}

- (void)rememberNode:(id)node atSourceIndexPath:(NSIndexPath *)indexPath identifier:(NSString *)identifier {
    if (!node || !indexPath)
        return;
    NSString *sourcePath = FeedSourcePathKey(indexPath);
    NSString *sourceIdentity = [identifier isKindOfClass:[NSString class]] && identifier.length > 0 ? identifier : nil;
    BOOL nodeMovedToNewSourcePath = NO;
    BOOL sourceIdentityChanged = NO;
    id previousNodeToInvalidate = nil;
    @synchronized (self) {
        NSString *previousSourceIdentity = self.sourceIdentityByPath[sourcePath];
        sourceIdentityChanged = previousSourceIdentity.length > 0 && sourceIdentity.length > 0 &&
                                ![previousSourceIdentity isEqualToString:sourceIdentity];
        if (sourceIdentityChanged)
            [self.metadataBySourcePath removeObjectForKey:sourcePath];
        if (sourceIdentity.length > 0)
            StoreSourceIdentity(self.sourceIdentityByPath, sourcePath, sourceIdentity);
        else
            [self.sourceIdentityByPath removeObjectForKey:sourcePath];
        id previousNode = [self.nodeBySourcePath objectForKey:sourcePath];
        if (previousNode && previousNode != node) {
            [self.metadataBySourcePath removeObjectForKey:sourcePath];
            NSString *previousNodeSourcePath = [self.sourcePathByNode objectForKey:previousNode];
            if ([previousNodeSourcePath isEqualToString:sourcePath])
                [self.sourcePathByNode removeObjectForKey:previousNode];
            previousNodeToInvalidate = previousNode;
        }
        NSString *previousSourcePath = [self.sourcePathByNode objectForKey:node];
        if (previousSourcePath.length > 0 && ![previousSourcePath isEqualToString:sourcePath]) {
            id nodeAtPreviousPath = [self.nodeBySourcePath objectForKey:previousSourcePath];
            if (nodeAtPreviousPath == node) {
                [self.nodeBySourcePath removeObjectForKey:previousSourcePath];
                [self.metadataBySourcePath removeObjectForKey:previousSourcePath];
                [self.sourceIdentityByPath removeObjectForKey:previousSourcePath];
            }
            nodeMovedToNewSourcePath = YES;
        }
        [self.nodeBySourcePath setObject:node forKey:sourcePath];
        [self.sourcePathByNode setObject:sourcePath forKey:node];
    }
    if (previousNodeToInvalidate)
        [Util resetFeedVideoMetadataForNode:previousNodeToInvalidate];
    if (nodeMovedToNewSourcePath || sourceIdentityChanged)
        [Util resetFeedVideoMetadataForNode:node];
    FeedMetadataRecord *cachedMetadata = [Util cachedFeedVideoMetadataForNode:node];
    BOOL identifierIsVideoID = IsLikelyVideoIdentifier(identifier);
    if (identifierIsVideoID && cachedMetadata.videoID.length > 0 &&
        ![cachedMetadata.videoID isEqualToString:identifier]) {
        [Util resetFeedVideoMetadataForNode:node];
        cachedMetadata = nil;
    }
    NSString *effectiveIdentifier = identifierIsVideoID ? identifier : cachedMetadata.videoID;
    if (effectiveIdentifier.length == 0)
        effectiveIdentifier = [Util feedVideoIDForObject:node];
    FeedMetadataRecord *knownMetadata = [self knownMetadataAtSourceIndexPath:indexPath model:nil identifier:effectiveIdentifier];
    FeedMetadataRecord *nodeMetadata = identifierIsVideoID ? MetadataWithIdentifier(identifier, cachedMetadata) : cachedMetadata;
    FeedMetadataRecord *metadata = MergedFeedMetadata(nodeMetadata, knownMetadata);
    if (!FeedMetadataHasAllFields(metadata)) {
        nodeMetadata = [Util feedVideoMetadataFromNode:node];
        if (identifierIsVideoID)
            nodeMetadata = MetadataWithIdentifier(identifier, nodeMetadata);
        metadata = MergedFeedMetadata(nodeMetadata, metadata);
    }
    if (identifierIsVideoID)
        metadata = MetadataWithIdentifier(identifier, metadata);
    if (metadata.dictionaryRepresentation.count == 0)
        return;
    [Util rememberFeedVideoMetadata:metadata forNode:node];
    @synchronized (self) {
        StoreSourcePathMetadata(self.metadataBySourcePath, FeedSourcePathKey(indexPath), metadata);
        StoreIdentifierMetadata(self.metadataByIdentifier, effectiveIdentifier, metadata);
        if (sourceIdentity.length > 0)
            StoreSourceIdentity(self.sourceIdentityByPath, FeedSourcePathKey(indexPath), sourceIdentity);
        else
            [self.sourceIdentityByPath removeObjectForKey:FeedSourcePathKey(indexPath)];
    }
}

- (void)invalidateMetadataForNode:(id)node {
    if (!node)
        return;
    @synchronized (self) {
        NSString *sourcePath = [self.sourcePathByNode objectForKey:node];
        if (sourcePath.length > 0) {
            [self.sourcePathByNode removeObjectForKey:node];
            [self.nodeBySourcePath removeObjectForKey:sourcePath];
            [self.metadataBySourcePath removeObjectForKey:sourcePath];
            [self.sourceIdentityByPath removeObjectForKey:sourcePath];
        }
    }
    [Util resetFeedVideoMetadataForNode:node];
}

- (void)rememberMetadata:(FeedMetadataRecord *)metadata forNode:(id)node {
    if (!metadata || metadata.dictionaryRepresentation.count == 0 || !node)
        return;
    NSString *sourcePath;
    FeedMetadataRecord *mergedMetadata;
    @synchronized (self) {
        sourcePath = [self.sourcePathByNode objectForKey:node];
        if (sourcePath.length == 0)
            return;
        FeedMetadataRecord *existing = self.metadataBySourcePath[sourcePath];
        if (existing.videoID.length > 0 && metadata.videoID.length > 0 &&
            ![existing.videoID isEqualToString:metadata.videoID])
            mergedMetadata = metadata;
        else
            mergedMetadata = MergedFeedMetadata(metadata, existing);
        StoreSourcePathMetadata(self.metadataBySourcePath, sourcePath, mergedMetadata);
        StoreIdentifierMetadata(self.metadataByIdentifier, mergedMetadata.videoID, mergedMetadata);
    }
    if (!self.performingFilteredReload && [Util nodeContainsBlockedVideo:[NSNull null] metadata:mergedMetadata])
        [self queueFilteredReload];
}

- (void)storeMetadata:(FeedMetadataRecord *)metadata atSourceIndexPath:(NSIndexPath *)sourceIndexPath {
    if (!metadata || metadata.dictionaryRepresentation.count == 0 || !sourceIndexPath)
        return;
    NSString *sourcePath = FeedSourcePathKey(sourceIndexPath);
    NSString *identifier = [self sourceIdentifierAtIndexPath:sourceIndexPath];
    if (identifier.length > 0) {
        @synchronized (self) {
            NSString *previousIdentifier = self.sourceIdentityByPath[sourcePath];
            if (previousIdentifier.length > 0 && ![previousIdentifier isEqualToString:identifier])
                [self.metadataBySourcePath removeObjectForKey:sourcePath];
            StoreSourceIdentity(self.sourceIdentityByPath, sourcePath, identifier);
        }
    }
    if (IsLikelyVideoIdentifier(identifier))
        metadata = MetadataWithIdentifier(identifier, metadata);
    FeedMetadataRecord *mergedMetadata;
    @synchronized (self) {
        FeedMetadataRecord *existing = self.metadataBySourcePath[sourcePath];
        if (existing.videoID.length > 0 && metadata.videoID.length > 0 &&
            ![existing.videoID isEqualToString:metadata.videoID])
            mergedMetadata = metadata;
        else
            mergedMetadata = MergedFeedMetadata(metadata, existing);
        StoreSourcePathMetadata(self.metadataBySourcePath, sourcePath, mergedMetadata);
        StoreIdentifierMetadata(self.metadataByIdentifier, mergedMetadata.videoID, mergedMetadata);
    }
    if (!self.performingFilteredReload && [Util nodeContainsBlockedVideo:[NSNull null] metadata:mergedMetadata])
        [self queueFilteredReload];
}

- (void)rememberMetadata:(FeedMetadataRecord *)metadata forVisibleItemInCollectionView:(UICollectionView *)collectionView {
    if (!metadata || metadata.dictionaryRepresentation.count == 0 || self.collectionView != collectionView)
        return;

    NSArray<NSIndexPath *> *visibleIndexPaths = [collectionView.indexPathsForVisibleItems sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *first, NSIndexPath *second) {
        if (first.section != second.section)
            return first.section < second.section ? NSOrderedAscending : NSOrderedDescending;
        if (first.item == second.item)
            return NSOrderedSame;
        return first.item < second.item ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (visibleIndexPaths.count == 0)
        return;

    NSIndexPath *visibleIndexPath = nil;
    if ([collectionView respondsToSelector:@selector(indexPathForItemAtPoint:)]) {
        CGPoint center = CGPointMake(CGRectGetMidX(collectionView.bounds), CGRectGetMidY(collectionView.bounds));
        NSIndexPath *candidate = [collectionView indexPathForItemAtPoint:center];
        if ([visibleIndexPaths containsObject:candidate])
            visibleIndexPath = candidate;
    }
    visibleIndexPath = visibleIndexPath ?: visibleIndexPaths.firstObject;
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:visibleIndexPath];
    if (!sourceIndexPath)
        return;

    [self storeMetadata:metadata atSourceIndexPath:sourceIndexPath];
}

- (NSIndexPath *)sourceIndexPathForContentView:(UIView *)contentView collectionView:(UICollectionView *)collectionView {
    if (!contentView || self.collectionView != collectionView)
        return nil;

    UIView *view = contentView;
    for (NSUInteger depth = 0; view && depth < 16; depth++, view = view.superview) {
        if (![view isKindOfClass:[UICollectionViewCell class]])
            continue;
        NSIndexPath *visibleIndexPath = [collectionView indexPathForCell:(UICollectionViewCell *)view];
        return visibleIndexPath ? [self sourceIndexPathForVisibleIndexPath:visibleIndexPath] : nil;
    }

    if ([collectionView respondsToSelector:@selector(indexPathForItemAtPoint:)]) {
        CGPoint center = [collectionView convertPoint:CGPointMake(CGRectGetMidX(contentView.bounds), CGRectGetMidY(contentView.bounds))
                                             fromView:contentView];
        NSIndexPath *visibleIndexPath = [collectionView indexPathForItemAtPoint:center];
        if (visibleIndexPath)
            return [self sourceIndexPathForVisibleIndexPath:visibleIndexPath];
    }
    return nil;
}

- (void)rememberMetadata:(FeedMetadataRecord *)metadata forContentView:(UIView *)contentView inCollectionView:(UICollectionView *)collectionView {
    if (!metadata || metadata.dictionaryRepresentation.count == 0 || self.collectionView != collectionView)
        return;

    NSIndexPath *sourceIndexPath = [self sourceIndexPathForContentView:contentView collectionView:collectionView];
    if (!sourceIndexPath) {
        NSString *className = NSStringFromClass([collectionView class]).lowercaseString;
        if (collectionView.isPagingEnabled || [className containsString:@"short"] || [className containsString:@"reel"])
            [self rememberMetadata:metadata forVisibleItemInCollectionView:collectionView];
        return;
    }
    [self storeMetadata:metadata atSourceIndexPath:sourceIndexPath];
}

- (id)filteredNode:(id)node atSourceIndexPath:(NSIndexPath *)indexPath identifier:(NSString *)identifier {
    [self rememberNode:node atSourceIndexPath:indexPath identifier:identifier];
    if (![self filteringEnabledForAdapter])
        return node;
    FeedMetadataRecord *metadata = [self metadataForNode:node];
    BOOL blocked = [Util nodeContainsBlockedVideo:node metadata:metadata];
    if (blocked) {
        if (!self.performingFilteredReload)
            [self queueFilteredReload];
        return EmptyFeedNode() ?: node;
    }
    return node;
}

- (FeedNodeBlock)filteredBlock:(FeedNodeBlock)block sourceIndexPath:(NSIndexPath *)indexPath {
    if (!block)
        return nil;
    NSUInteger initialSourceGeneration;
    @synchronized (self) {
        initialSourceGeneration = self.sourceGeneration;
    }
    NSString *capturedIdentifier = [self sourceIdentifierAtIndexPath:indexPath];
    NSUInteger blockSourceGeneration;
    @synchronized (self) {
        blockSourceGeneration = self.sourceGeneration;
    }
    if (blockSourceGeneration != initialSourceGeneration)
        capturedIdentifier = nil;
    __weak typeof(self) weakSelf = self;
    FeedNodeBlock sourceBlock = [block copy];
    return [^id {
        id node = sourceBlock();
        FeedDataSourceAdapter *adapter = weakSelf;
        NSString *identifier = nil;
        BOOL sourceGenerationMatches = NO;
        if (adapter) {
            @synchronized (adapter) {
                sourceGenerationMatches = adapter.sourceGeneration == blockSourceGeneration;
                if (sourceGenerationMatches)
                    identifier = capturedIdentifier;
            }
        }
        if (!adapter)
            return node;
        if (!sourceGenerationMatches)
            return EmptyFeedNode() ?: node;
        return [adapter filteredNode:node atSourceIndexPath:indexPath identifier:identifier];
    } copy];
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return (NSInteger)[self snapshotForCountRequest].sourceItemsBySection.count;
}

- (NSInteger)numberOfSectionsInCollectionNode:(id)collectionNode {
    return (NSInteger)[self snapshotForCountRequest].sourceItemsBySection.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    FeedCollectionSnapshot *snapshot = [self snapshotForCountRequest];
    return section >= 0 && section < (NSInteger)snapshot.sourceItemsBySection.count ?
        (NSInteger)snapshot.sourceItemsBySection[(NSUInteger)section].count : 0;
}

- (NSInteger)collectionNode:(id)collectionNode numberOfItemsInSection:(NSInteger)section {
    FeedCollectionSnapshot *snapshot = [self snapshotForCountRequest];
    return section >= 0 && section < (NSInteger)snapshot.sourceItemsBySection.count ?
        (NSInteger)snapshot.sourceItemsBySection[(NSUInteger)section].count : 0;
}

- (id)collectionView:(UICollectionView *)collectionView nodeForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:indexPath];
    if (!sourceIndexPath)
        return ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                       @selector(collectionView:nodeForItemAtIndexPath:),
                                                       collectionView,
                                                       indexPath);
    id node = ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                       @selector(collectionView:nodeForItemAtIndexPath:),
                                                       collectionView,
                                                       sourceIndexPath);
    return [self filteredNode:node
            atSourceIndexPath:sourceIndexPath
                   identifier:[self sourceIdentifierAtIndexPath:sourceIndexPath]];
}

- (FeedNodeBlock)collectionView:(UICollectionView *)collectionView nodeBlockForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:indexPath];
    if (!sourceIndexPath)
        return ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                       @selector(collectionView:nodeBlockForItemAtIndexPath:),
                                                       collectionView,
                                                       indexPath);
    FeedNodeBlock block = ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                                  @selector(collectionView:nodeBlockForItemAtIndexPath:),
                                                                  collectionView,
                                                                  sourceIndexPath);
    return [self filteredBlock:block sourceIndexPath:sourceIndexPath];
}

- (id)collectionNode:(id)collectionNode nodeForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:indexPath];
    if (!sourceIndexPath)
        return ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                       @selector(collectionNode:nodeForItemAtIndexPath:),
                                                       collectionNode,
                                                       indexPath);
    id node = ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                       @selector(collectionNode:nodeForItemAtIndexPath:),
                                                       collectionNode,
                                                       sourceIndexPath);
    return [self filteredNode:node
            atSourceIndexPath:sourceIndexPath
                   identifier:[self sourceIdentifierAtIndexPath:sourceIndexPath]];
}

- (FeedNodeBlock)collectionNode:(id)collectionNode nodeBlockForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:indexPath];
    if (!sourceIndexPath)
        return ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                       @selector(collectionNode:nodeBlockForItemAtIndexPath:),
                                                       collectionNode,
                                                       indexPath);
    FeedNodeBlock block = ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                                  @selector(collectionNode:nodeBlockForItemAtIndexPath:),
                                                                  collectionNode,
                                                                  sourceIndexPath);
    return [self filteredBlock:block sourceIndexPath:sourceIndexPath];
}

- (id)collectionNode:(id)collectionNode nodeModelForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:indexPath];
    if (!sourceIndexPath)
        return ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                        @selector(collectionNode:nodeModelForItemAtIndexPath:),
                                                        collectionNode,
                                                        indexPath);
    id model = ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                        @selector(collectionNode:nodeModelForItemAtIndexPath:),
                                                        collectionNode,
                                                        sourceIndexPath);
    NSString *identifier = [self sourceIdentifierAtIndexPath:sourceIndexPath collectionNode:collectionNode];
    FeedMetadataRecord *metadata = [self knownMetadataAtSourceIndexPath:sourceIndexPath model:model identifier:identifier];
    if (!self.performingFilteredReload && [Util nodeContainsBlockedVideo:model metadata:metadata])
        [self queueFilteredReload];
    return model;
}

- (NSString *)modelIdentifierForElementAtIndexPath:(NSIndexPath *)indexPath inNode:(id)collectionNode {
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:indexPath];
    if (!sourceIndexPath)
        sourceIndexPath = indexPath;
    @try {
        return ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                       @selector(modelIdentifierForElementAtIndexPath:inNode:),
                                                       sourceIndexPath,
                                                       collectionNode);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (NSIndexPath *)indexPathForElementWithModelIdentifier:(NSString *)identifier inNode:(id)collectionNode {
    @try {
        NSIndexPath *sourceIndexPath = ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                                               @selector(indexPathForElementWithModelIdentifier:inNode:),
                                                                               identifier,
                                                                               collectionNode);
        return sourceIndexPath ? [self visibleIndexPathForSourceIndexPath:sourceIndexPath] : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (NSIndexPath *)presentationIndexPathForModelIndexPath:(NSIndexPath *)modelIndexPath {
    if (!modelIndexPath)
        return nil;
    NSIndexPath *sourceIndexPath = modelIndexPath;
    NSIndexPath *upstreamIndexPath = nil;
    if ([self.dataSource respondsToSelector:_cmd]) {
        @try {
            upstreamIndexPath = ((id (*)(id, SEL, id))objc_msgSend)(self.dataSource, _cmd, sourceIndexPath);
        } @catch (__unused NSException *exception) {
            upstreamIndexPath = nil;
        }
    }
    NSIndexPath *visibleIndexPath = [self visibleIndexPathForSourceIndexPath:upstreamIndexPath ?: sourceIndexPath];
    return visibleIndexPath;
}

- (NSIndexPath *)modelIndexPathForPresentationIndexPath:(NSIndexPath *)presentationIndexPath {
    if (!presentationIndexPath)
        return nil;
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:presentationIndexPath];
    if (!sourceIndexPath)
        return nil;
    if (![self.dataSource respondsToSelector:_cmd])
        return sourceIndexPath;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(self.dataSource, _cmd, sourceIndexPath) ?: sourceIndexPath;
    } @catch (__unused NSException *exception) {
        return sourceIndexPath;
    }
}

- (void)reportItemWillBecomeVisibleWithModelIndexPath:(NSIndexPath *)modelIndexPath
                                  presentationIndexPath:(NSIndexPath *)presentationIndexPath {
    NSIndexPath *sourcePresentationIndexPath = [self sourceIndexPathForVisibleIndexPath:presentationIndexPath] ?: presentationIndexPath;
    NSIndexPath *sourceModelIndexPath = [self modelIndexPathForPresentationIndexPath:presentationIndexPath] ?: modelIndexPath;
    if ([self.dataSource respondsToSelector:_cmd])
        ((void (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                  _cmd,
                                                  sourceModelIndexPath,
                                                  sourcePresentationIndexPath);
}

- (void)reportItemDidBecomeHiddenWithModelIndexPath:(NSIndexPath *)modelIndexPath {
    NSIndexPath *sourceModelIndexPath = modelIndexPath;
    if ([self.dataSource respondsToSelector:@selector(presentationIndexPathForModelIndexPath:)]) {
        @try {
            NSIndexPath *visibleIndexPath = ((id (*)(id, SEL, id))objc_msgSend)(self.dataSource,
                                                                                  @selector(presentationIndexPathForModelIndexPath:),
                                                                                  modelIndexPath);
            sourceModelIndexPath = [self modelIndexPathForPresentationIndexPath:visibleIndexPath] ?: modelIndexPath;
        } @catch (__unused NSException *exception) {
        }
    }
    if ([self.dataSource respondsToSelector:_cmd])
        ((void (*)(id, SEL, id))objc_msgSend)(self.dataSource, _cmd, sourceModelIndexPath);
}

- (BOOL)shouldReportVisibilityForItemWithModelIndexPath:(NSIndexPath *)modelIndexPath {
    if (![self.dataSource respondsToSelector:_cmd])
        return YES;
    @try {
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(self.dataSource, _cmd, modelIndexPath);
    } @catch (__unused NSException *exception) {
        return YES;
    }
}

- (NSIndexPath *)modelIndexPathForSupplementaryElementOfKind:(NSString *)elementKind
                                       atPresentationIndexPath:(NSIndexPath *)presentationIndexPath {
    if (!presentationIndexPath)
        return nil;
    NSIndexPath *sourceIndexPath = [self sourceIndexPathForVisibleIndexPath:presentationIndexPath];
    if (!sourceIndexPath)
        return nil;
    if (![self.dataSource respondsToSelector:_cmd])
        return sourceIndexPath;
    @try {
        return ((id (*)(id, SEL, id, id))objc_msgSend)(self.dataSource,
                                                       _cmd,
                                                       elementKind,
                                                       sourceIndexPath);
    } @catch (__unused NSException *exception) {
        return sourceIndexPath;
    }
}

- (BOOL)containsMetadata:(FeedMetadataRecord *)metadata {
    @synchronized (self) {
        for (FeedMetadataRecord *candidate in self.metadataBySourcePath.allValues) {
            if (FeedMetadataMatches(candidate, metadata))
                return YES;
        }
        for (FeedMetadataRecord *candidate in self.metadataByIdentifier.allValues) {
            if (FeedMetadataMatches(candidate, metadata))
                return YES;
        }
    }
    return NO;
}

- (FeedMetadataRecord *)metadataForNode:(id)node {
    FeedMetadataRecord *nodeMetadata = [Util cachedFeedVideoMetadataForNode:node];
    NSString *sourcePath;
    FeedMetadataRecord *metadata;
    @synchronized (self) {
        sourcePath = [self.sourcePathByNode objectForKey:node];
        FeedMetadataRecord *sourceMetadata = sourcePath.length > 0 ? self.metadataBySourcePath[sourcePath] : nil;
        metadata = MergedFeedMetadata(sourceMetadata, nodeMetadata);
        NSString *videoID = [Util feedVideoIDForObject:node];
        metadata = MergedFeedMetadata(metadata, videoID.length > 0 ? self.metadataByIdentifier[videoID] : nil);
    }
    return metadata;
}

- (void)queueFilteredReload {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self queueFilteredReload];
        });
        return;
    }
    if (self.reloadQueued)
        return;
    self.reloadQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.reloadQueued = NO;
        UICollectionView *collectionView = self.collectionView;
        if (!collectionView)
            return;
        if ([self filtersShortsPager])
            return;
        NSUInteger reloadToken;
        @synchronized (self) {
            self.snapshot = nil;
            reloadToken = ++self.filteredReloadToken;
            self.performingFilteredReload = YES;
        }
        __weak FeedDataSourceAdapter *weakSelf = self;
        void (^finishReload)(void) = ^{
            [weakSelf finishFilteredReloadWithToken:reloadToken];
        };
        @try {
            if ([self.dataSource respondsToSelector:@selector(reloadData)]) {
                ((void (*)(id, SEL))objc_msgSend)(self.dataSource, @selector(reloadData));
                if ([self.dataSource respondsToSelector:@selector(notifyDidReloadData)])
                    ((void (*)(id, SEL))objc_msgSend)(self.dataSource, @selector(notifyDidReloadData));
                if ([self.dataSource respondsToSelector:@selector(resetContent)])
                    ((void (*)(id, SEL))objc_msgSend)(self.dataSource, @selector(resetContent));
                finishReload();
                return;
            }
            id collectionNode = [self collectionNodeObject];
            if ([collectionNode respondsToSelector:@selector(reloadDataWithCompletion:)])
                ((void (*)(id, SEL, id))objc_msgSend)(collectionNode,
                                                       @selector(reloadDataWithCompletion:),
                                                       [finishReload copy]);
            else if ([collectionNode respondsToSelector:@selector(reloadData)]) {
                [collectionNode reloadData];
                finishReload();
            } else {
                [collectionView reloadData];
                finishReload();
            }
        } @catch (__unused NSException *exception) {
            finishReload();
        }
    });
}

- (void)finishFilteredReloadWithToken:(NSUInteger)token {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishFilteredReloadWithToken:token];
        });
        return;
    }
    @synchronized (self) {
        if (self.filteredReloadToken == token)
            self.performingFilteredReload = NO;
    }
}

- (void)upstreamWillReload {
    NSArray *nodesToInvalidate = @[];
    @synchronized (self) {
        self.sourceGeneration += 1;
        self.snapshot = nil;
        if (!self.performingFilteredReload) {
            nodesToInvalidate = [[self.sourcePathByNode keyEnumerator] allObjects];
            [self.metadataBySourcePath removeAllObjects];
            [self.metadataByIdentifier removeAllObjects];
            [self.sourcePathByNode removeAllObjects];
            [self.nodeBySourcePath removeAllObjects];
            [self.sourceIdentityByPath removeAllObjects];
        }
    }
    for (id node in nodesToInvalidate)
        [Util resetFeedVideoMetadataForNode:node];
}

@end
