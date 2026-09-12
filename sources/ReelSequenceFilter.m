#import "ReelSequenceFilter.h"
#import "Util.h"

#import <objc/message.h>
#import <objc/runtime.h>

@interface ReelSequenceSnapshot : NSObject
@property(nonatomic, strong) NSOrderedSet *filteredReels;
@property(nonatomic) NSUInteger sourceCount;
@property(nonatomic, strong) id firstSourceReel;
@property(nonatomic, strong) id lastSourceReel;
@property(nonatomic, copy) NSArray<NSNumber *> *sourceIndexes;
@property(nonatomic, copy) NSArray<FeedMetadataRecord *> *metadata;
@property(nonatomic, copy) NSSet<NSString *> *blockedVideoIDs;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL filteringEnabled;
@end

@implementation ReelSequenceSnapshot
@end

static NSMapTable *SequenceSnapshots(void) {
    static NSMapTable *snapshots;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        snapshots = [NSMapTable weakToStrongObjectsMapTable];
    });
    return snapshots;
}

static NSHashTable *SequenceControllers(void) {
    static NSHashTable *controllers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controllers = [NSHashTable weakObjectsHashTable];
    });
    return controllers;
}

static NSMapTable *SequenceControllerDataSources(void) {
    static NSMapTable *dataSources;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dataSources = [NSMapTable weakToStrongObjectsMapTable];
    });
    return dataSources;
}

static NSObject *SequenceStoreLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static NSUInteger SequenceGeneration = 1;
static BOOL SequenceRefreshQueued = NO;

static id ReelObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0)
        return nil;
    for (Class currentClass = object_getClass(object); currentClass; currentClass = class_getSuperclass(currentClass)) {
        Ivar ivar = class_getInstanceVariable(currentClass, name.UTF8String);
        if (!ivar || ivar_getTypeEncoding(ivar)[0] != '@')
            continue;
        return object_getIvar(object, ivar);
    }
    return nil;
}

static BOOL SnapshotMatches(ReelSequenceSnapshot *snapshot,
                            NSOrderedSet *sourceReels,
                            NSUInteger generation,
                            BOOL filteringEnabled) {
    id firstSourceReel = sourceReels.count > 0 ? [sourceReels objectAtIndex:0] : nil;
    id lastSourceReel = sourceReels.count > 0 ? [sourceReels objectAtIndex:sourceReels.count - 1] : nil;
    return snapshot && snapshot.sourceCount == sourceReels.count &&
           snapshot.firstSourceReel == firstSourceReel &&
           snapshot.lastSourceReel == lastSourceReel &&
           snapshot.generation == generation &&
           snapshot.filteringEnabled == filteringEnabled;
}

static FeedMetadataRecord *MetadataForReel(id reel) {
    if (!reel || reel == [NSNull null])
        return nil;
    FeedMetadataRecord *metadata = [Util feedVideoMetadataFromModel:reel];
    NSString *videoID = metadata.videoID.length > 0 ? metadata.videoID : [Util feedVideoIDForObject:reel];
    FeedMetadataRecord *cached = videoID.length > 0 ? [Util cachedFeedVideoMetadataForVideoID:videoID] : nil;
    if (!metadata)
        return cached;
    if (!cached)
        return metadata;
    return [[FeedMetadataRecord alloc] initWithVideoID:metadata.videoID.length > 0 ? metadata.videoID : cached.videoID
                                                 title:metadata.title.length > 0 ? metadata.title : cached.title
                                               channel:metadata.channel.length > 0 ? metadata.channel : cached.channel];
}

static ReelSequenceSnapshot *BuildSnapshot(id dataSource, NSOrderedSet *sourceReels) {
    BOOL filteringEnabled = [Util filteringEnabled];
    NSUInteger generation;
    @synchronized (SequenceStoreLock()) {
        generation = SequenceGeneration;
        ReelSequenceSnapshot *cached = [SequenceSnapshots() objectForKey:dataSource];
        if (SnapshotMatches(cached, sourceReels, generation, filteringEnabled))
            return cached;
    }

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:sourceReels.count];
    NSMutableArray<NSNumber *> *sourceIndexes = [NSMutableArray arrayWithCapacity:sourceReels.count];
    NSMutableArray<FeedMetadataRecord *> *metadata = [NSMutableArray arrayWithCapacity:sourceReels.count];
    NSMutableSet<NSString *> *blockedVideoIDs = [NSMutableSet set];
    for (NSUInteger index = 0; index < sourceReels.count; index++) {
        id reel = [sourceReels objectAtIndex:index];
        FeedMetadataRecord *record = MetadataForReel(reel);
        BOOL blocked = filteringEnabled && record && [Util nodeContainsBlockedVideo:[NSNull null] metadata:record];
        if (blocked) {
            if (record.videoID.length > 0)
                [blockedVideoIDs addObject:record.videoID];
            continue;
        }
        [filtered addObject:reel ?: [NSNull null]];
        [sourceIndexes addObject:@(index)];
        [metadata addObject:record ?: [[FeedMetadataRecord alloc] initWithVideoID:nil title:nil channel:nil]];
    }

    ReelSequenceSnapshot *snapshot = [ReelSequenceSnapshot new];
    snapshot.filteredReels = [NSOrderedSet orderedSetWithArray:filtered];
    snapshot.sourceCount = sourceReels.count;
    snapshot.firstSourceReel = sourceReels.count > 0 ? [sourceReels objectAtIndex:0] : nil;
    snapshot.lastSourceReel = sourceReels.count > 0 ? [sourceReels objectAtIndex:sourceReels.count - 1] : nil;
    snapshot.sourceIndexes = sourceIndexes.copy;
    snapshot.metadata = metadata.copy;
    snapshot.blockedVideoIDs = blockedVideoIDs.copy;
    snapshot.generation = generation;
    snapshot.filteringEnabled = filteringEnabled;
    @synchronized (SequenceStoreLock()) {
        if (SequenceGeneration == generation && [Util filteringEnabled] == filteringEnabled) {
            [SequenceSnapshots() setObject:snapshot forKey:dataSource];
        }
    }
    return snapshot;
}

static ReelSequenceSnapshot *CurrentSnapshot(id dataSource) {
    if (!dataSource)
        return nil;
    @synchronized (SequenceStoreLock()) {
        ReelSequenceSnapshot *snapshot = [SequenceSnapshots() objectForKey:dataSource];
        if (snapshot && snapshot.generation == SequenceGeneration &&
            snapshot.filteringEnabled == [Util filteringEnabled])
            return snapshot;
    }
    return nil;
}

static NSInteger SourceIndexForVisibleIndex(ReelSequenceSnapshot *snapshot, NSInteger visibleIndex) {
    if (!snapshot || visibleIndex < 0 || visibleIndex >= (NSInteger)snapshot.sourceIndexes.count)
        return NSNotFound;
    return snapshot.sourceIndexes[(NSUInteger)visibleIndex].integerValue;
}

static NSInteger VisibleIndexForSourceIndex(ReelSequenceSnapshot *snapshot, NSInteger sourceIndex) {
    if (!snapshot || sourceIndex < 0)
        return NSNotFound;
    for (NSUInteger index = 0; index < snapshot.sourceIndexes.count; index++) {
        if (snapshot.sourceIndexes[index].integerValue == sourceIndex)
            return (NSInteger)index;
    }
    return NSNotFound;
}

static void RefreshSequenceController(id controller) {
    @try {
        id dataSource = nil;
        @synchronized (SequenceStoreLock()) {
            dataSource = [SequenceControllerDataSources() objectForKey:controller];
        }
        NSOrderedSet *filteredReels = nil;
        if ([dataSource respondsToSelector:@selector(reels)]) {
            @try {
                filteredReels = ((id (*)(id, SEL))objc_msgSend)(dataSource, @selector(reels));
            } @catch (__unused NSException *exception) {
                filteredReels = nil;
            }
        }
        if ([filteredReels isKindOfClass:[NSOrderedSet class]] && filteredReels.count == 0) {
            if ([dataSource respondsToSelector:@selector(softRefreshModel)])
                ((void (*)(id, SEL))objc_msgSend)(dataSource, @selector(softRefreshModel));
            else if ([dataSource respondsToSelector:@selector(refreshModel)])
                ((void (*)(id, SEL))objc_msgSend)(dataSource, @selector(refreshModel));
            return;
        }
        BOOL hasCurrentIndex = NO;
        NSUInteger currentIndex = 0;
        if ([controller respondsToSelector:@selector(currentReelIndex)]) {
            currentIndex = ((NSUInteger (*)(id, SEL))objc_msgSend)(controller, @selector(currentReelIndex));
            hasCurrentIndex = YES;
        }
        id pageController = ReelObjectIvar(controller, @"_scrollablePageViewController") ?: ReelObjectIvar(controller, @"_pageViewController");
        id pageAdapter = ReelObjectIvar(controller, @"_scrollablePageViewControllerAdapter");
        if (!pageAdapter)
            pageAdapter = ReelObjectIvar(pageController, @"_dataSourceAdapter") ?: ReelObjectIvar(pageController, @"_dataSource");
        NSUInteger targetIndex = hasCurrentIndex && filteredReels.count > 0 ? MIN(currentIndex, filteredReels.count - 1) : 0;
        BOOL reboundPageController = NO;
        if (pageController && pageAdapter &&
            [pageController respondsToSelector:@selector(setDataSourceAdapter:initialIndex:)]) {
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(pageController,
                                                               @selector(setDataSourceAdapter:initialIndex:),
                                                               pageAdapter,
                                                               (NSInteger)targetIndex);
            reboundPageController = YES;
        } else if ([pageAdapter respondsToSelector:@selector(resetDataSource)]) {
            ((void (*)(id, SEL))objc_msgSend)(pageAdapter, @selector(resetDataSource));
        }
        if (!reboundPageController && [controller respondsToSelector:@selector(refreshContent)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(refreshContent));
        } else if (!reboundPageController && [controller respondsToSelector:@selector(reloadForSectionsWithGroup:)]) {
            ((BOOL (*)(id, SEL, id))objc_msgSend)(controller, @selector(reloadForSectionsWithGroup:), nil);
        } else if (!reboundPageController && [controller respondsToSelector:@selector(reloadPreviousAndNextViewControllers)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(reloadPreviousAndNextViewControllers));
        }
    } @catch (__unused NSException *exception) {
    }
}

static void RefreshRegisteredControllers(void) {
    NSArray *controllers;
    @synchronized (SequenceStoreLock()) {
        controllers = SequenceControllers().allObjects;
    }
    for (id controller in controllers)
        RefreshSequenceController(controller);
}

@implementation ReelSequenceFilter

+ (void)initialize {
    if (self != [ReelSequenceFilter class])
        return;
    [[NSNotificationCenter defaultCenter] addObserverForName:FeedFilterStateDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification *notification) {
        [self invalidateAll];
    }];
}

+ (NSOrderedSet *)filteredReelsForDataSource:(id)dataSource sourceReels:(NSOrderedSet *)sourceReels {
    if (!dataSource || ![sourceReels isKindOfClass:[NSOrderedSet class]])
        return sourceReels ?: [NSOrderedSet orderedSet];
    if (![Util filteringEnabled])
        return sourceReels;
    ReelSequenceSnapshot *snapshot = BuildSnapshot(dataSource, sourceReels);
    return snapshot.filteredReels;
}

+ (NSSet *)filteredVideoIDsForDataSource:(id)dataSource sourceVideoIDs:(NSSet *)sourceVideoIDs {
    ReelSequenceSnapshot *snapshot = CurrentSnapshot(dataSource);
    if (![sourceVideoIDs isKindOfClass:[NSSet class]] || ![Util filteringEnabled])
        return sourceVideoIDs ?: [NSSet set];
    NSMutableSet *filtered = [sourceVideoIDs mutableCopy];
    if (snapshot)
        [filtered minusSet:snapshot.blockedVideoIDs];
    for (NSString *videoID in sourceVideoIDs) {
        if (![videoID isKindOfClass:[NSString class]])
            continue;
        FeedMetadataRecord *metadata = [Util cachedFeedVideoMetadataForVideoID:videoID];
        if (metadata && [Util nodeContainsBlockedVideo:[NSNull null] metadata:metadata])
            [filtered removeObject:videoID];
    }
    return filtered.copy;
}

+ (NSInteger)visibleIndexForSourceIndex:(NSInteger)sourceIndex dataSource:(id)dataSource {
    ReelSequenceSnapshot *snapshot = CurrentSnapshot(dataSource);
    return VisibleIndexForSourceIndex(snapshot, sourceIndex);
}

+ (NSInteger)sourceIndexForVisibleIndex:(NSInteger)visibleIndex dataSource:(id)dataSource {
    ReelSequenceSnapshot *snapshot = CurrentSnapshot(dataSource);
    return SourceIndexForVisibleIndex(snapshot, visibleIndex);
}

+ (NSInteger)visibleIndexForVideoID:(NSString *)videoID dataSource:(id)dataSource {
    if (videoID.length == 0)
        return NSNotFound;
    ReelSequenceSnapshot *snapshot = CurrentSnapshot(dataSource);
    if (!snapshot)
        return NSNotFound;
    for (NSUInteger index = 0; index < snapshot.metadata.count; index++) {
        FeedMetadataRecord *record = snapshot.metadata[index];
        if ([record.videoID isEqualToString:videoID])
            return (NSInteger)index;
    }
    return NSNotFound;
}

+ (NSInteger)visibleIndexForObject:(id)object dataSource:(id)dataSource {
    if (!object)
        return NSNotFound;
    ReelSequenceSnapshot *snapshot = CurrentSnapshot(dataSource);
    if (!snapshot)
        return NSNotFound;
    NSUInteger index = [snapshot.filteredReels indexOfObject:object];
    if (index != NSNotFound)
        return (NSInteger)index;
    return NSNotFound;
}

+ (void)registerSequenceController:(id)controller dataSource:(id)dataSource {
    if (!controller || !dataSource)
        return;
    @synchronized (SequenceStoreLock()) {
        [SequenceControllers() addObject:controller];
        [SequenceControllerDataSources() setObject:dataSource forKey:controller];
    }
}

+ (void)invalidateDataSource:(id)dataSource {
    if (!dataSource)
        return;
    @synchronized (SequenceStoreLock()) {
        [SequenceSnapshots() removeObjectForKey:dataSource];
    }
}

+ (void)invalidateAll {
    void (^invalidate)(void) = ^{
        @synchronized (SequenceStoreLock()) {
            SequenceGeneration += 1;
            [SequenceSnapshots() removeAllObjects];
            if (SequenceRefreshQueued)
                return;
            SequenceRefreshQueued = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (SequenceStoreLock()) {
                SequenceRefreshQueued = NO;
            }
            RefreshRegisteredControllers();
        });
    };
    if (NSThread.isMainThread)
        invalidate();
    else
        dispatch_async(dispatch_get_main_queue(), invalidate);
}

@end
