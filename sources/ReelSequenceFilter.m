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
    return [Util feedVideoMetadataFromModel:reel];
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

static id ObjectIvarValue(id object, NSString *name) {
    if (!object || name.length == 0)
        return nil;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    if (!ivar || ivar_getTypeEncoding(ivar)[0] != '@')
        return nil;
    return object_getIvar(object, ivar);
}

static void SetObjectIvarValue(id object, NSString *name, id value) {
    if (!object || name.length == 0)
        return;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    if (!ivar || ivar_getTypeEncoding(ivar)[0] != '@')
        return;
    object_setIvar(object, ivar, value);
}

static id PageViewControllerForSequenceController(id controller) {
    if (!controller)
        return nil;
    id scrollablePageViewController = ObjectIvarValue(controller, @"_scrollablePageViewController");
    if (scrollablePageViewController)
        return scrollablePageViewController;
    if ([controller respondsToSelector:@selector(pageViewController)])
        return ((id (*)(id, SEL))objc_msgSend)(controller, @selector(pageViewController));
    return ObjectIvarValue(controller, @"_pageViewController");
}

static id PageDataSourceAdapterForPageViewController(id pageViewController) {
    if (!pageViewController)
        return nil;
    return ObjectIvarValue(pageViewController, @"_dataSourceAdapter") ?: ObjectIvarValue(pageViewController, @"_dataSource");
}

static void ResetPageControllerCache(id controller) {
    id pageViewController = PageViewControllerForSequenceController(controller);
    id adapter = ObjectIvarValue(controller, @"_scrollablePageViewControllerAdapter") ?:
                 PageDataSourceAdapterForPageViewController(pageViewController);
    if (!pageViewController || !adapter)
        return;
    NSInteger currentIndex = [pageViewController respondsToSelector:@selector(currentViewControllerIndex)]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(pageViewController, @selector(currentViewControllerIndex))
        : NSNotFound;
    SetObjectIvarValue(adapter, @"_staticWindowViewControllers", @[]);
    SetObjectIvarValue(adapter, @"_dynamicForwardViewControllers", [NSMutableArray array]);
    SetObjectIvarValue(pageViewController, @"_currentViewController", nil);
    SetObjectIvarValue(pageViewController, @"_visibleViewControllers", [NSMutableSet set]);
    if ([adapter respondsToSelector:@selector(reloadPreviousAndNextControllers)])
        ((void (*)(id, SEL))objc_msgSend)(adapter, @selector(reloadPreviousAndNextControllers));
    if ([pageViewController respondsToSelector:@selector(reloadForSectionsWithGroup:)])
        ((BOOL (*)(id, SEL, id))objc_msgSend)(pageViewController, @selector(reloadForSectionsWithGroup:), nil);
    if (currentIndex != NSNotFound &&
        [pageViewController respondsToSelector:@selector(scrollToControllerAtIndex:animated:completion:)])
        ((void (*)(id, SEL, NSInteger, BOOL, id))objc_msgSend)(pageViewController,
                                                                @selector(scrollToControllerAtIndex:animated:completion:),
                                                                currentIndex,
                                                                NO,
                                                                nil);
    if ([controller respondsToSelector:@selector(currentReelIndex)] &&
        [controller respondsToSelector:@selector(transitionToReelAtIndex:transitionType:animated:)]) {
        NSUInteger reelIndex = ((NSUInteger (*)(id, SEL))objc_msgSend)(controller, @selector(currentReelIndex));
        ((void (*)(id, SEL, NSUInteger, NSUInteger, BOOL))objc_msgSend)(controller,
                                                                          @selector(transitionToReelAtIndex:transitionType:animated:),
                                                                          reelIndex,
                                                                          0,
                                                                          NO);
    }
}

static void RefreshSequenceController(id controller) {
    ResetPageControllerCache(controller);
    if ([controller respondsToSelector:@selector(refreshContent)]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(refreshContent));
        return;
    }
    if ([controller respondsToSelector:@selector(reloadForSectionsWithGroup:)]) {
        ((BOOL (*)(id, SEL, id))objc_msgSend)(controller, @selector(reloadForSectionsWithGroup:), nil);
        return;
    }
    if ([controller respondsToSelector:@selector(currentReelIndex)] &&
        [controller respondsToSelector:@selector(transitionToReelAtIndex:transitionType:animated:)]) {
        NSUInteger index = ((NSUInteger (*)(id, SEL))objc_msgSend)(controller, @selector(currentReelIndex));
        ((void (*)(id, SEL, NSUInteger, NSUInteger, BOOL))objc_msgSend)(controller,
                                                                          @selector(transitionToReelAtIndex:transitionType:animated:),
                                                                          index,
                                                                          0,
                                                                          NO);
        return;
    }
    if ([controller respondsToSelector:@selector(reloadPreviousAndNextViewControllers)]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(reloadPreviousAndNextViewControllers));
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
    if (!snapshot || ![sourceVideoIDs isKindOfClass:[NSSet class]] || ![Util filteringEnabled])
        return sourceVideoIDs ?: [NSSet set];
    NSMutableSet *filtered = [sourceVideoIDs mutableCopy];
    [filtered minusSet:snapshot.blockedVideoIDs];
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
