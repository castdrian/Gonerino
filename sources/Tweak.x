#import "Tweak.h"
#import "FeedDataSourceAdapter.h"
#import "Localization.h"
#import "GonerinoActionList.h"
#import "ReelSequenceFilter.h"
#import "UpdateChecker.h"
#import <objc/runtime.h>
#import <objc/message.h>

static id ValueForObjectKey(id object, NSString *key);
static id DirectObjectIvar(id object, NSString *key);
static id ExplicitObjectValue(id object, NSString *key);
static UIViewController *ViewControllerForObject(id object);
static id ShortsPlayerForObject(id object);
static __weak id CurrentShortsPlayer;
static void *FeedDataSourceAdapterKey = &FeedDataSourceAdapterKey;
static void *ActionSheetSourceViewKey = &ActionSheetSourceViewKey;
static void *ActionSheetBlockingActionsKey = &ActionSheetBlockingActionsKey;
static void *ShortsResponseMetadataKey = &ShortsResponseMetadataKey;
static void *BottomSheetBlockingActionsKey = &BottomSheetBlockingActionsKey;
static void *ActionMetadataKey = &ActionMetadataKey;
static void *MDCBlockingActionsKey = &MDCBlockingActionsKey;
static NSDictionary *CachedActionVideoInfo(id sheet, UIView *sourceView, id sourceNode);
static NSDictionary *FreshActionVideoInfo(id sheet, UIView *sourceView, id sourceNode);
static void AddBlockingActions(id sheet, YTActionSheetAction *originalAction);
static void InsertStoredBlockingActions(id sheet);

static BOOL IsShortsDataSourceOrView(id view, id dataSource) {
    Class reelDataSourceClass = NSClassFromString(@"YTReelDataSource");
    if (reelDataSourceClass && [dataSource isKindOfClass:reelDataSourceClass])
        return YES;
    NSString *viewClass = NSStringFromClass([view class]).lowercaseString;
    NSString *dataSourceClass = NSStringFromClass([dataSource class]).lowercaseString;
    NSString *classes = [NSString stringWithFormat:@"%@ %@", viewClass, dataSourceClass];
    return [classes containsString:@"short"] || [classes containsString:@"reel"] || [classes containsString:@"scrollablepage"];
}

static void InstallFeedDataSourceAdapter(UICollectionView *collectionView, id dataSource) {
    FeedDataSourceAdapter *existingAdapter = objc_getAssociatedObject(collectionView, FeedDataSourceAdapterKey);
    if (!dataSource)
        return;
    if ([FeedDataSourceAdapter isAdapter:dataSource])
        return;
    if (existingAdapter) {
        [existingAdapter replaceDataSource:dataSource];
        return;
    }
    FeedDataSourceAdapter *adapter = [FeedDataSourceAdapter adapterWithCollectionView:collectionView dataSource:dataSource];
    objc_setAssociatedObject(collectionView, FeedDataSourceAdapterKey, adapter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void PrepareFeedDataSourceForReload(UICollectionView *collectionView) {
    FeedDataSourceAdapter *adapter = objc_getAssociatedObject(collectionView, FeedDataSourceAdapterKey);
    [adapter upstreamWillReload];
}

static void PrepareCollectionNodeForReload(id collectionNode) {
    id collectionView = ExplicitObjectValue(collectionNode, @"collectionView");
    if (![collectionView isKindOfClass:[UICollectionView class]])
        collectionView = ExplicitObjectValue(collectionNode, @"view");
    if ([collectionView isKindOfClass:[UICollectionView class]])
        PrepareFeedDataSourceForReload(collectionView);
}

static id ValueForObjectKey(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    @try {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector])
            return nil;

        Method method = class_getInstanceMethod(object_getClass(object), selector);
        if (!method)
            return nil;

        const char *returnType = method_getTypeEncoding(method);
        if (!returnType || returnType[0] != '@')
            return nil;

        return ((id (*)(id, SEL))method_getImplementation(method))(object, selector);
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static id DirectObjectIvar(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    for (Class currentClass = object_getClass(object); currentClass; currentClass = class_getSuperclass(currentClass)) {
        Ivar ivar = class_getInstanceVariable(currentClass, [NSString stringWithFormat:@"_%@", key].UTF8String);
        if (!ivar)
            continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@')
            return nil;
        return object_getIvar(object, ivar);
    }

    return nil;
}

static id ExplicitObjectValue(id object, NSString *key) {
    return ValueForObjectKey(object, key) ?: DirectObjectIvar(object, key);
}

static FeedMetadataRecord *CombinedShortsMetadata(FeedMetadataRecord *first, FeedMetadataRecord *second) {
    if (!first)
        return second;
    if (!second)
        return first;
    NSString *videoID = first.videoID.length > 0 ? first.videoID : second.videoID;
    NSString *title = first.title.length > 0 ? first.title : second.title;
    NSString *channel = first.channel.length > 0 ? first.channel : second.channel;
    return [[FeedMetadataRecord alloc] initWithVideoID:videoID title:title channel:channel];
}

static UICollectionView *ShortsCollectionViewForPlayer(id player) {
    id provider = ExplicitObjectValue(player, @"reelHeaderUpdaterProvider");
    id collectionView = ExplicitObjectValue(provider, @"scrollView");
    return [collectionView isKindOfClass:[UICollectionView class]] ? collectionView : nil;
}

static void RememberShortsMetadataForPlayer(id player, FeedMetadataRecord *metadata) {
    if (!player || metadata.dictionaryRepresentation.count == 0)
        return;

    id model = ExplicitObjectValue(player, @"model") ?: ExplicitObjectValue(player, @"contentModel") ?: ExplicitObjectValue(player, @"itemModel");
    id contentView = ExplicitObjectValue(player, @"shortsContentView") ?: ExplicitObjectValue(player, @"contentView");
    if (model)
        [Util rememberFeedVideoMetadata:metadata forNode:model];
    if (contentView)
        [Util rememberFeedVideoMetadata:metadata forNode:contentView];

}

static void CaptureCurrentShortsMetadata(id player) {
    if (!player)
        return;

    static void *ShortsMetadataModelKey = &ShortsMetadataModelKey;
    id model = ExplicitObjectValue(player, @"model") ?: ExplicitObjectValue(player, @"contentModel") ?: ExplicitObjectValue(player, @"itemModel");
    if (model && objc_getAssociatedObject(player, ShortsMetadataModelKey) == model) {
        FeedMetadataRecord *cachedMetadata = [Util cachedFeedVideoMetadataForNode:model];
        if (cachedMetadata.videoID.length > 0 && cachedMetadata.title.length > 0 && cachedMetadata.channel.length > 0)
            return;
    }

    id contentView = ExplicitObjectValue(player, @"shortsContentView") ?: ExplicitObjectValue(player, @"contentView");
    FeedMetadataRecord *modelMetadata = [Util feedVideoMetadataFromModel:model];
    FeedMetadataRecord *contentMetadata = [Util cachedFeedVideoMetadataForNode:contentView];
    FeedMetadataRecord *metadata = CombinedShortsMetadata(modelMetadata, contentMetadata);
    if (metadata.dictionaryRepresentation.count == 0)
        return;

    RememberShortsMetadataForPlayer(player, metadata);
    if (model)
        objc_setAssociatedObject(player, ShortsMetadataModelKey, model, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void AssociateVideoIDWithNode(id node, NSString *videoID) {
    if (!node || videoID.length == 0)
        return;

    NSString *existingVideoID = [Util feedVideoIDForObject:node];
    if (existingVideoID.length > 0 && ![existingVideoID isEqualToString:videoID])
        [Util resetFeedVideoMetadataForNode:node];
    FeedMetadataRecord *metadata = [[FeedMetadataRecord alloc] initWithVideoID:videoID
                                                                            title:nil
                                                                          channel:nil];
    [Util setFeedVideoID:videoID forObject:node];
    [Util rememberFeedVideoMetadata:metadata forNode:node];
    [FeedDataSourceAdapter rememberMetadata:metadata forNode:node];
}

static UIView *ActionSheetSourceView(id sheet) {
    UIView *associatedSourceView = objc_getAssociatedObject(sheet, ActionSheetSourceViewKey);
    if ([associatedSourceView isKindOfClass:[UIView class]])
        return associatedSourceView;
    id source = ExplicitObjectValue(sheet, @"sourceView");
    if ([source isKindOfClass:[UIView class]])
        return source;
    if ([source isKindOfClass:[UIViewController class]])
        return ((UIViewController *)source).view;
    return nil;
}

static UICollectionViewCell *FeedCellForSourceView(UIView *sourceView);

static UICollectionView *FeedCollectionViewForSourceView(UIView *sourceView) {
    UIView *view = sourceView;
    for (NSUInteger depth = 0; view && depth < 16; depth++, view = view.superview) {
        if ([view isKindOfClass:[UICollectionView class]])
            return (UICollectionView *)view;
    }
    return nil;
}

static id FeedNodeForSourceView(UIView *sourceView) {
    UICollectionViewCell *sourceCell = FeedCellForSourceView(sourceView);
    if (sourceCell) {
        id cellNode = ExplicitObjectValue(sourceCell, @"node");
        if (cellNode)
            return cellNode;
        cellNode = ExplicitObjectValue(sourceCell, @"asyncdisplaykit_node");
        if (cellNode)
            return cellNode;
    }
    return ExplicitObjectValue(sourceView, @"asyncdisplaykit_node");
}

static id ActionSheetSourceNode(id sheet, UIView *sourceView) {
    id node = FeedNodeForSourceView(sourceView);
    if (node)
        return node;

    for (NSString *key in @[@"sourceNode", @"videoNode", @"currentVideo", @"contentView", @"node", @"playerViewController", @"shortsPlayerViewController", @"parentResponder", @"elementEntry", @"model", @"data", @"item", @"entry", @"renderer"]) {
        id candidate = ExplicitObjectValue(sheet, key);
        if ([candidate isKindOfClass:[UIViewController class]])
            candidate = ((UIViewController *)candidate).view;
        if ([candidate isKindOfClass:[UIView class]])
            candidate = ExplicitObjectValue(candidate, @"asyncdisplaykit_node");
        if (candidate)
            return candidate;
    }
    return nil;
}

static UIViewController *ViewControllerForObject(id object) {
    if ([object isKindOfClass:[UIViewController class]])
        return object;

    UIView *sourceView = [object isKindOfClass:[UIView class]] ? object : ExplicitObjectValue(object, @"sourceView");
    if (sourceView) {
        UIResponder *responder = sourceView;
        while (responder) {
            if ([responder isKindOfClass:[UIViewController class]])
                return (UIViewController *)responder;
            responder = [responder nextResponder];
        }
    }

    return nil;
}

static id ShortsPlayerForObject(id object) {
    UIView *view = [object isKindOfClass:[UIView class]] ? object : ExplicitObjectValue(object, @"view");
    NSMutableArray *pending = [NSMutableArray array];
    if (view)
        [pending addObject:view];
    id parentResponder = ExplicitObjectValue(object, @"parentResponder");
    if (parentResponder)
        [pending addObject:parentResponder];
    NSMutableSet *visited = [NSMutableSet set];
    NSUInteger index = 0;
    while (index < pending.count && index < 32) {
        id candidate = pending[index++];
        if (!candidate || candidate == [NSNull null])
            continue;
        NSValue *identity = [NSValue valueWithNonretainedObject:candidate];
        if ([visited containsObject:identity])
            continue;
        [visited addObject:identity];
        NSString *className = NSStringFromClass([candidate class]).lowercaseString;
        if ([className containsString:@"shortsplayer"] || [className containsString:@"reelplayer"])
            return candidate;
        if ([candidate isKindOfClass:[UIView class]]) {
            UIView *candidateView = candidate;
            if (candidateView.superview && pending.count < 32)
                [pending addObject:candidateView.superview];
            UIResponder *responder = candidateView.nextResponder;
            if (responder && pending.count < 32)
                [pending addObject:responder];
        } else {
            id nextResponder = ExplicitObjectValue(candidate, @"nextResponder");
            if (nextResponder && pending.count < 32)
                [pending addObject:nextResponder];
            id relatedParent = ExplicitObjectValue(candidate, @"parentResponder");
            if (relatedParent && pending.count < 32)
                [pending addObject:relatedParent];
        }
    }
    return nil;
}

static void SendToast(id object, NSString *message) {
    UIView *view = [object isKindOfClass:[UIView class]] ? object : ExplicitObjectValue(object, @"sourceView");
    if (![view isKindOfClass:[UIView class]])
        view = nil;
    [Util showToast:message fromView:view];
}

static void MergeAvailableVideoInfo(NSMutableDictionary *result, NSDictionary *candidate) {
    NSString *candidateVideoID = candidate[@"id"];
    NSString *existingVideoID = result[@"id"];
    if (candidateVideoID.length > 0 && existingVideoID.length > 0 &&
        ![candidateVideoID isEqualToString:existingVideoID])
        return;

    for (NSString *key in @[@"id", @"title", @"channel"]) {
        NSString *value = candidate[key];
        if (![value isKindOfClass:[NSString class]] || value.length == 0)
            continue;
        if ([key isEqualToString:@"title"] && ![Util isUsableVideoTitle:value])
            continue;

        NSString *existingValue = result[key];
        BOOL replacePlaceholder = [key isEqualToString:@"title"] &&
                                  ![Util isUsableVideoTitle:existingValue];
        if (existingValue.length == 0 || replacePlaceholder)
            result[key] = value;
    }
}

static void MergeCachedVideoInfo(NSMutableDictionary *result) {
    NSString *videoId = result[@"id"];
    if (videoId.length == 0)
        return;

    NSDictionary *cachedInfo = [[Util cachedFeedVideoMetadataForVideoID:videoId] dictionaryRepresentation];
    MergeAvailableVideoInfo(result, cachedInfo);
}

static void MergeCachedMetadataForObject(NSMutableDictionary *info, id object) {
    FeedMetadataRecord *metadata = [Util cachedFeedVideoMetadataForNode:object];
    NSString *associatedVideoID = [Util feedVideoIDForObject:object];
    MergeAvailableVideoInfo(info, metadata.dictionaryRepresentation);
    if (associatedVideoID.length > 0)
        MergeAvailableVideoInfo(info, [[Util cachedFeedVideoMetadataForVideoID:associatedVideoID] dictionaryRepresentation]);
    MergeCachedVideoInfo(info);
}

static void MergeModelMetadata(NSMutableDictionary *result, id object) {
    if (!object || object == [NSNull null] || [object isKindOfClass:[UIView class]])
        return;
    MergeAvailableVideoInfo(result, [[Util feedVideoMetadataFromModel:object] dictionaryRepresentation]);
}

static void MergeCachedMenuContextMetadata(NSMutableDictionary *result, id renderers, id entry) {
    MergeCachedMetadataForObject(result, entry);
    if ([renderers isKindOfClass:[NSArray class]]) {
        NSUInteger count = 0;
        for (id renderer in (NSArray *)renderers) {
            if (count++ >= 8)
                break;
            MergeCachedMetadataForObject(result, renderer);
            if (result[@"id"] && result[@"title"] && result[@"channel"])
                break;
        }
    } else {
        MergeCachedMetadataForObject(result, renderers);
    }
}

static void RememberActionMetadata(NSDictionary *metadata, UIView *sourceView, id sourceNode) {
    if (metadata.count == 0)
        return;
    FeedMetadataRecord *actionMetadata = [[FeedMetadataRecord alloc] initWithVideoID:metadata[@"id"]
                                                                                  title:metadata[@"title"]
                                                                                channel:metadata[@"channel"]];
    if (sourceNode) {
        [Util rememberFeedVideoMetadata:actionMetadata forNode:sourceNode];
        [FeedDataSourceAdapter rememberMetadata:actionMetadata forNode:sourceNode];
    }
    id shortsPlayer = ShortsPlayerForObject(sourceView);
    if (!shortsPlayer && !sourceView)
        shortsPlayer = CurrentShortsPlayer;
    if (shortsPlayer)
        RememberShortsMetadataForPlayer(shortsPlayer, actionMetadata);
    if (!sourceNode && sourceView)
        [Util rememberFeedVideoMetadata:actionMetadata forNode:sourceView];
}

static NSArray *MenuBlockingActions(NSDictionary *metadata,
                                    YTActionSheetAction *originalAction,
                                    UIView *sourceView) {
    if (![metadata[@"id"] isKindOfClass:[NSString class]] ||
        ![metadata[@"channel"] isKindOfClass:[NSString class]] ||
        [metadata[@"id"] length] == 0 ||
        [metadata[@"channel"] length] == 0)
        return @[];

    UIImage *originalIcon = ExplicitObjectValue(originalAction, @"iconImage");
    CGSize iconSize = originalIcon.size;
    if (iconSize.width <= 0.0 || iconSize.height <= 0.0)
        iconSize = CGSizeMake(24.0, 24.0);
    NSString *videoID = [metadata[@"id"] copy];
    NSString *videoTitle = [Util isUsableVideoTitle:metadata[@"title"]] ? [metadata[@"title"] copy] : @"";
    NSString *channel = [metadata[@"channel"] copy];
    __weak UIView *weakSourceView = sourceView;

    YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
        actionWithTitle:LocalizedString(@"Block channel")
              iconImage:[Util createBlockChannelIconWithSize:iconSize]
         secondaryIconImage:nil
     accessibilityIdentifier:@"GonerinoBlockChannel"
                handler:^ {
                    [[ChannelManager sharedInstance] addBlockedChannel:channel];
                    SendToast(weakSourceView,
                              [NSString stringWithFormat:LocalizedString(@"Blocked %@"), channel]);
                }];

    YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
        actionWithTitle:LocalizedString(@"Block video")
              iconImage:[Util createBlockVideoIconWithSize:iconSize]
         secondaryIconImage:nil
     accessibilityIdentifier:@"GonerinoBlockVideo"
                handler:^ {
                    [[VideoManager sharedInstance] addBlockedVideo:videoID title:videoTitle channel:channel];
                    SendToast(weakSourceView,
                              [NSString stringWithFormat:LocalizedString(@"Blocked video: %@"),
                                                         videoTitle.length > 0 ? videoTitle : videoID]);
                }];

    if (!blockChannelAction || !blockVideoAction)
        return @[];
    blockChannelAction.shouldDismissOnAction = YES;
    blockVideoAction.shouldDismissOnAction = YES;
    return @[blockChannelAction, blockVideoAction];
}

static NSArray *MDCBlockingActionsForSheet(id sheet, NSArray *actions) {
    if (![actions isKindOfClass:[NSArray class]])
        return actions;
    NSArray *normalizedActions = GonerinoUniqueBlockActions(actions);
    if (!CurrentShortsPlayer || normalizedActions.count == 0)
        return normalizedActions;
    NSArray *associatedActions = objc_getAssociatedObject(sheet, MDCBlockingActionsKey);
    if (associatedActions)
        return GonerinoPrependUniqueBlockActions(normalizedActions, associatedActions);

    UIView *sourceView = ActionSheetSourceView(sheet);
    if (!sourceView && [CurrentShortsPlayer isKindOfClass:[UIViewController class]])
        sourceView = ((UIViewController *)CurrentShortsPlayer).view;
    NSDictionary *metadata = CachedActionVideoInfo(sheet, sourceView, nil);
    if (![metadata[@"id"] isKindOfClass:[NSString class]] ||
        ![metadata[@"channel"] isKindOfClass:[NSString class]] ||
        [(NSString *)metadata[@"id"] length] == 0 ||
        [(NSString *)metadata[@"channel"] length] == 0)
        return normalizedActions;

    Class actionClass = NSClassFromString(@"MDCActionSheetAction");
    if (!actionClass)
        return normalizedActions;

    UIImage *originalImage = ExplicitObjectValue(actions.firstObject, @"image");
    CGSize iconSize = originalImage.size;
    if (iconSize.width <= 0.0 || iconSize.height <= 0.0)
        iconSize = CGSizeMake(24.0, 24.0);
    NSString *videoID = [metadata[@"id"] copy];
    NSString *videoTitle = [Util isUsableVideoTitle:metadata[@"title"]] ? [metadata[@"title"] copy] : @"";
    NSString *channel = [metadata[@"channel"] copy];
    __weak UIView *weakSourceView = sourceView;
    __weak id weakSheet = sheet;

    void (^channelHandler)(id) = ^(__unused id action) {
        [[ChannelManager sharedInstance] addBlockedChannel:channel];
        SendToast(weakSourceView,
                  [NSString stringWithFormat:LocalizedString(@"Blocked %@"), channel]);
        id strongSheet = weakSheet;
        if ([strongSheet respondsToSelector:@selector(dismissViewControllerAnimated:completion:)])
            [strongSheet dismissViewControllerAnimated:YES completion:nil];
    };
    void (^videoHandler)(id) = ^(__unused id action) {
        [[VideoManager sharedInstance] addBlockedVideo:videoID title:videoTitle channel:channel];
        SendToast(weakSourceView,
                  [NSString stringWithFormat:LocalizedString(@"Blocked video: %@"),
                                             videoTitle.length > 0 ? videoTitle : videoID]);
        id strongSheet = weakSheet;
        if ([strongSheet respondsToSelector:@selector(dismissViewControllerAnimated:completion:)])
            [strongSheet dismissViewControllerAnimated:YES completion:nil];
    };
    SEL initializer = NSSelectorFromString(@"initWithTitle:image:handler:");
    id blockChannelAction = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        [actionClass alloc],
        initializer,
        LocalizedString(@"Block channel"),
        [Util createBlockChannelIconWithSize:iconSize],
        channelHandler);
    id blockVideoAction = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        [actionClass alloc],
        initializer,
        LocalizedString(@"Block video"),
        [Util createBlockVideoIconWithSize:iconSize],
        videoHandler);
    if (!blockChannelAction || !blockVideoAction)
        return normalizedActions;

    if ([blockChannelAction respondsToSelector:@selector(setAccessibilityIdentifier:)])
        [blockChannelAction setAccessibilityIdentifier:@"GonerinoBlockChannel"];
    if ([blockVideoAction respondsToSelector:@selector(setAccessibilityIdentifier:)])
        [blockVideoAction setAccessibilityIdentifier:@"GonerinoBlockVideo"];
    NSArray *blockingActions = @[blockChannelAction, blockVideoAction];
    objc_setAssociatedObject(sheet, MDCBlockingActionsKey, blockingActions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return GonerinoPrependUniqueBlockActions(normalizedActions, blockingActions);
}

static void InjectShortsBottomSheetActions(id contentViewController) {
    if (!contentViewController)
        return;

    id actionSheetController = DirectObjectIvar(contentViewController, @"actionsController") ?: contentViewController;
    id actionOwner = DirectObjectIvar(actionSheetController, @"delegate") ?: contentViewController;
    NSMutableArray *actions = DirectObjectIvar(actionOwner, @"actions");
    if (!CurrentShortsPlayer || objc_getAssociatedObject(actionOwner, BottomSheetBlockingActionsKey))
        return;
    if (![actions isKindOfClass:[NSMutableArray class]] || actions.count == 0)
        return;

    UIView *sourceView = [CurrentShortsPlayer isKindOfClass:[UIViewController class]] ?
        ((UIViewController *)CurrentShortsPlayer).view : nil;
    NSDictionary *metadata = CachedActionVideoInfo(actionOwner, sourceView, nil);
    NSArray *blockingActions = MenuBlockingActions(metadata, actions.firstObject, sourceView);
    if (blockingActions.count == 0)
        return;

    objc_setAssociatedObject(actionOwner,
                             BottomSheetBlockingActionsKey,
                             blockingActions,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [actions setArray:GonerinoPrependUniqueBlockActions(actions, blockingActions)];
    if ([actionOwner respondsToSelector:@selector(relayoutActionSheet)])
        [actionOwner performSelector:@selector(relayoutActionSheet)];
    if ([actionSheetController respondsToSelector:@selector(updateDialogToPreferredContentSize)])
        [actionSheetController performSelector:@selector(updateDialogToPreferredContentSize)];
}

static NSArray *MenuActionsWithBlockingActions(NSArray *actions, UIView *sourceView, id renderers, id entry) {
    if (![actions isKindOfClass:[NSArray class]])
        return @[];
    id sourceNode = FeedNodeForSourceView(sourceView);
    NSMutableDictionary *metadata = [CachedActionVideoInfo(nil, sourceView, sourceNode) mutableCopy] ?: [NSMutableDictionary dictionaryWithCapacity:3];
    MergeCachedMenuContextMetadata(metadata, renderers, entry);
    RememberActionMetadata(metadata, sourceView, sourceNode);
    NSArray *normalizedActions = GonerinoUniqueBlockActions(actions);
    if (normalizedActions.count == 0)
        return normalizedActions;
    if (metadata.count == 0)
        return normalizedActions;
    NSArray *blockingActions = MenuBlockingActions(metadata, normalizedActions.firstObject, sourceView);
    return blockingActions.count > 0
        ? GonerinoPrependUniqueBlockActions(normalizedActions, blockingActions)
        : normalizedActions;
}

static void PrepareMenuControllerSheet(id menuController, UIView *sourceView) {
    id sheet = ExplicitObjectValue(menuController, @"actionSheetController");
    if (!sheet)
        return;
    if (sourceView)
        objc_setAssociatedObject(sheet, ActionSheetSourceViewKey, sourceView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSDictionary *metadata = CachedActionVideoInfo(sheet, sourceView, nil);
    if (metadata.count > 0)
        objc_setAssociatedObject(sheet, ActionMetadataKey, metadata, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSArray *actions = [sheet respondsToSelector:@selector(actions)] ? [[sheet actions] copy] : @[];
    if (actions.count > 0 && [sheet respondsToSelector:@selector(addAction:)])
        AddBlockingActions(sheet, actions.firstObject);
    InsertStoredBlockingActions(sheet);
}

static void InsertStoredBlockingActions(id sheet) {
    NSMutableArray *storedActions = DirectObjectIvar(sheet, @"actions");
    NSArray *blockingActions = objc_getAssociatedObject(sheet, ActionSheetBlockingActionsKey);
    if (![storedActions isKindOfClass:[NSMutableArray class]] || blockingActions.count == 0)
        return;

    NSArray *normalizedActions = GonerinoPrependUniqueBlockActions(storedActions, blockingActions);
    BOOL changed = normalizedActions.count != storedActions.count;
    if (!changed) {
        for (NSUInteger index = 0; index < normalizedActions.count; index++) {
            if (normalizedActions[index] != storedActions[index]) {
                changed = YES;
                break;
            }
        }
    }
    if (!changed)
        return;
    [storedActions setArray:normalizedActions];
    if ([sheet respondsToSelector:@selector(relayoutActionSheet)])
        [sheet performSelector:@selector(relayoutActionSheet)];
}

static void *ScrollablePageDataSourceKey = &ScrollablePageDataSourceKey;
static void *RootReelDataSourceKey = &RootReelDataSourceKey;

static id ScrollablePageReelDataSource(id adapter) {
    id dataSource = objc_getAssociatedObject(adapter, ScrollablePageDataSourceKey);
    Class reelDataSourceClass = NSClassFromString(@"YTReelDataSource");
    if (reelDataSourceClass && [dataSource isKindOfClass:reelDataSourceClass])
        return dataSource;
    id nestedDataSource = ExplicitObjectValue(dataSource, @"reelsDataSource") ?: objc_getAssociatedObject(dataSource, RootReelDataSourceKey);
    if (reelDataSourceClass && [nestedDataSource isKindOfClass:reelDataSourceClass])
        return nestedDataSource;
    return nil;
}

static NSDictionary *CachedActionVideoInfo(id sheet, UIView *sourceView, id sourceNode) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:3];
    NSDictionary *associatedMetadata = objc_getAssociatedObject(sheet, ActionMetadataKey);
    if ([associatedMetadata isKindOfClass:[NSDictionary class]])
        MergeAvailableVideoInfo(info, associatedMetadata);
    MergeCachedMetadataForObject(info, sourceNode);
    MergeCachedMetadataForObject(info, sourceView);

    id actionPlayer = ShortsPlayerForObject(sourceView);
    if (!actionPlayer && !sourceView)
        actionPlayer = CurrentShortsPlayer;
    if (actionPlayer) {
        CurrentShortsPlayer = actionPlayer;
        id contentView = ExplicitObjectValue(actionPlayer, @"shortsContentView") ?: ExplicitObjectValue(actionPlayer, @"contentView");
        id model = ExplicitObjectValue(actionPlayer, @"model") ?: ExplicitObjectValue(actionPlayer, @"contentModel") ?: ExplicitObjectValue(actionPlayer, @"itemModel");
        MergeCachedMetadataForObject(info, contentView);
        MergeCachedMetadataForObject(info, model);
        MergeAvailableVideoInfo(info, [objc_getAssociatedObject(actionPlayer, ShortsResponseMetadataKey) dictionaryRepresentation]);
    }
    return info.copy;
}

static NSDictionary *FreshActionVideoInfo(id sheet, UIView *sourceView, id sourceNode) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:3];
    UICollectionView *sourceCollectionView = FeedCollectionViewForSourceView(sourceView);
    MergeAvailableVideoInfo(info,
                            [[FeedDataSourceAdapter cachedMetadataForContentView:sourceView
                                                                  inCollectionView:sourceCollectionView] dictionaryRepresentation]);
    MergeAvailableVideoInfo(info, [[FeedDataSourceAdapter cachedMetadataForNode:sourceNode] dictionaryRepresentation]);
    MergeCachedMetadataForObject(info, sourceNode);
    MergeCachedMetadataForObject(info, sourceView);
    MergeModelMetadata(info, sourceNode);
    MergeModelMetadata(info, sourceView);
    for (NSString *key in @[@"entry", @"elementEntry", @"renderer", @"model", @"data", @"item"]) {
        id context = ExplicitObjectValue(sheet, key);
        MergeCachedMetadataForObject(info, context);
        MergeModelMetadata(info, context);
    }

    id actionPlayer = ShortsPlayerForObject(sourceView) ?: CurrentShortsPlayer;
    if (actionPlayer) {
        CurrentShortsPlayer = actionPlayer;
        id contentView = ExplicitObjectValue(actionPlayer, @"shortsContentView") ?: ExplicitObjectValue(actionPlayer, @"contentView");
        id model = ExplicitObjectValue(actionPlayer, @"model") ?: ExplicitObjectValue(actionPlayer, @"contentModel") ?: ExplicitObjectValue(actionPlayer, @"itemModel");
        MergeCachedMetadataForObject(info, contentView);
        MergeCachedMetadataForObject(info, model);
        if ([contentView isKindOfClass:[UIView class]])
            MergeAvailableVideoInfo(info, [[FeedDataSourceAdapter cachedMetadataForContentView:(UIView *)contentView
                                                                               inCollectionView:ShortsCollectionViewForPlayer(actionPlayer)] dictionaryRepresentation]);
        MergeAvailableVideoInfo(info, [objc_getAssociatedObject(actionPlayer, ShortsResponseMetadataKey) dictionaryRepresentation]);
        MergeCachedVideoInfo(info);
    }
    return info.copy;
}

static void ResolveActionVideoInfo(id sheet,
                                   BOOL requiresChannel,
                                   void (^completion)(NSDictionary *info)) {
    if (!completion)
        return;

    NSDictionary *cachedInfo = objc_getAssociatedObject(sheet, ActionMetadataKey);
    BOOL cachedInfoIsUsable = [cachedInfo isKindOfClass:[NSDictionary class]] &&
                              ((requiresChannel && [cachedInfo[@"channel"] length] > 0) ||
                               (!requiresChannel && [cachedInfo[@"id"] length] > 0));
    if (cachedInfoIsUsable) {
        completion(cachedInfo);
        return;
    }

    UIView *sourceView = ActionSheetSourceView(sheet);
    NSDictionary *refreshedInfo = FreshActionVideoInfo(sheet, sourceView, FeedNodeForSourceView(sourceView));
    if ([refreshedInfo isKindOfClass:[NSDictionary class]] && refreshedInfo.count > 0) {
        NSMutableDictionary *mergedInfo = [cachedInfo mutableCopy] ?: [NSMutableDictionary dictionaryWithCapacity:3];
        MergeAvailableVideoInfo(mergedInfo, refreshedInfo);
        refreshedInfo = mergedInfo.copy;
        objc_setAssociatedObject(sheet, ActionMetadataKey, refreshedInfo, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    BOOL refreshedInfoIsUsable = [refreshedInfo isKindOfClass:[NSDictionary class]] &&
                                 ((requiresChannel && [refreshedInfo[@"channel"] length] > 0) ||
                                  (!requiresChannel && [refreshedInfo[@"id"] length] > 0));
    completion(refreshedInfoIsUsable ? refreshedInfo : @{});
}

static void AddBlockingActions(id sheet, YTActionSheetAction *originalAction) {
    static void *injectionKey = &injectionKey;
    static void *injectionInProgressKey = &injectionInProgressKey;
    if (!sheet || !originalAction || objc_getAssociatedObject(sheet, injectionInProgressKey))
        return;
    NSString *originalTitle = originalAction.title.lowercaseString;
    if ([originalTitle isEqualToString:LocalizedString(@"block channel").lowercaseString] ||
        [originalTitle isEqualToString:LocalizedString(@"block video").lowercaseString])
        return;

    @try {
        UIView *sourceView = ActionSheetSourceView(sheet);
        id sourceNode = ActionSheetSourceNode(sheet, sourceView);
        NSDictionary *capturedMetadata = CachedActionVideoInfo(sheet, sourceView, sourceNode);
        if (capturedMetadata.count > 0) {
            FeedMetadataRecord *actionMetadata = [[FeedMetadataRecord alloc] initWithVideoID:capturedMetadata[@"id"] title:capturedMetadata[@"title"] channel:capturedMetadata[@"channel"]];
            if (sourceNode) {
                [Util rememberFeedVideoMetadata:actionMetadata forNode:sourceNode];
                [FeedDataSourceAdapter rememberMetadata:actionMetadata forNode:sourceNode];
            }
            if (!sourceNode && sourceView)
                [Util rememberFeedVideoMetadata:actionMetadata forNode:sourceView];
        }

        if (objc_getAssociatedObject(sheet, injectionKey)) {
            NSDictionary *previousMetadata = objc_getAssociatedObject(sheet, ActionMetadataKey);
            NSMutableDictionary *refreshedMetadata = [previousMetadata mutableCopy] ?: [NSMutableDictionary dictionaryWithCapacity:3];
            NSString *previousVideoID = refreshedMetadata[@"id"];
            NSString *capturedVideoID = capturedMetadata[@"id"];
            if (previousVideoID.length > 0 && capturedVideoID.length > 0 &&
                ![previousVideoID isEqualToString:capturedVideoID])
                refreshedMetadata = [capturedMetadata mutableCopy];
            else
                MergeAvailableVideoInfo(refreshedMetadata, capturedMetadata);
            objc_setAssociatedObject(sheet, ActionMetadataKey, refreshedMetadata.copy, OBJC_ASSOCIATION_COPY_NONATOMIC);
            return;
        }

        if ([capturedMetadata[@"id"] length] == 0 || [capturedMetadata[@"channel"] length] == 0)
            return;

        objc_setAssociatedObject(sheet, injectionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, injectionInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        __weak id weakSheet = sheet;
        UIImage *originalIcon = ExplicitObjectValue(originalAction, @"iconImage");
        CGSize iconSize = originalIcon.size;
        if (iconSize.width <= 0.0 || iconSize.height <= 0.0)
            iconSize = CGSizeMake(24.0, 24.0);
        objc_setAssociatedObject(sheet,
                                 ActionMetadataKey,
                                 capturedMetadata ?: @{},
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);

        YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
            actionWithTitle:LocalizedString(@"Block channel")
                  iconImage:[Util createBlockChannelIconWithSize:iconSize]
             secondaryIconImage:nil
                  accessibilityIdentifier:@"GonerinoBlockChannel"
                handler:^ {
                      ResolveActionVideoInfo(weakSheet,
                                             YES,
                                             ^(NSDictionary *info) {
                                                 @try {
                                                     NSString *channel = info[@"channel"];
                                                     if (channel.length == 0) {
                                                         SendToast(weakSheet, LocalizedString(@"Could not read the channel for this video"));
                                                         return;
                                                     }

                                                     [[ChannelManager sharedInstance] addBlockedChannel:channel];
                                                     if (![[ChannelManager sharedInstance] isChannelBlocked:channel]) {
                                                         SendToast(weakSheet, LocalizedString(@"Could not read a valid channel for this video"));
                                                         return;
                                                     }
                                                     SendToast(weakSheet, [NSString stringWithFormat:LocalizedString(@"Blocked %@"), channel]);
                                                     if ([weakSheet respondsToSelector:@selector(dismiss)])
                                                         [weakSheet dismiss];
                                                 } @catch (__unused NSException *exception) {
                                                     SendToast(weakSheet, LocalizedString(@"Could not block this channel"));
                                                 }
                                             });
                  }];

        YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
            actionWithTitle:LocalizedString(@"Block video")
                  iconImage:[Util createBlockVideoIconWithSize:iconSize]
             secondaryIconImage:nil
                  accessibilityIdentifier:@"GonerinoBlockVideo"
                handler:^ {
                      ResolveActionVideoInfo(weakSheet,
                                             NO,
                                             ^(NSDictionary *info) {
                                                 @try {
                                                     NSString *videoId = info[@"id"];
                                                     if (videoId.length == 0) {
                                                         SendToast(weakSheet, LocalizedString(@"Could not read the video for this item"));
                                                         return;
                                                     }

                                                     NSString *videoTitle = [Util isUsableVideoTitle:info[@"title"]] ? info[@"title"] : @"";
                                                     [[VideoManager sharedInstance] addBlockedVideo:videoId
                                                                                               title:videoTitle
                                                                                             channel:info[@"channel"]];
                                                     SendToast(weakSheet,
                                                               [NSString stringWithFormat:LocalizedString(@"Blocked video: %@"),
                                                                                          videoTitle.length > 0 ? videoTitle : videoId]);
                                                     if ([weakSheet respondsToSelector:@selector(dismiss)])
                                                         [weakSheet dismiss];
                                                 } @catch (__unused NSException *exception) {
                                                     SendToast(weakSheet, LocalizedString(@"Could not block this video"));
                                                 }
                                             });
                  }];

        if (!blockChannelAction || !blockVideoAction) {
            objc_setAssociatedObject(sheet, injectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        blockChannelAction.shouldDismissOnAction = YES;
        blockVideoAction.shouldDismissOnAction = YES;
        objc_setAssociatedObject(sheet,
                                 ActionSheetBlockingActionsKey,
                                 @[blockChannelAction, blockVideoAction],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        objc_setAssociatedObject(sheet, injectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void PrimeBlockingActionsForPresentation(id sheet, UIView *sourceView) {
    if (!sheet)
        return;
    if (sourceView)
        objc_setAssociatedObject(sheet, ActionSheetSourceViewKey, sourceView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *actions = [sheet respondsToSelector:@selector(actions)] ? [[sheet actions] copy] : @[];
    YTActionSheetAction *originalAction = actions.firstObject;
    if (originalAction)
        AddBlockingActions(sheet, originalAction);
}

static NSArray *ActionsWithBlockingActions(id sheet, NSArray *actions) {
    if (!sheet || !actions)
        return actions;
    NSArray *normalizedActions = GonerinoUniqueBlockActions(actions);
    NSArray *blockingActions = objc_getAssociatedObject(sheet, ActionSheetBlockingActionsKey);
    if (blockingActions.count == 0 && normalizedActions.count > 0)
        AddBlockingActions(sheet, normalizedActions.firstObject);
    blockingActions = objc_getAssociatedObject(sheet, ActionSheetBlockingActionsKey);
    if (blockingActions.count == 0)
        return normalizedActions;
    return GonerinoPrependUniqueBlockActions(normalizedActions, blockingActions);
}

static UICollectionViewCell *FeedCellForSourceView(UIView *sourceView) {
    UIView *view = sourceView;
    for (NSUInteger depth = 0; view && depth < 16; depth++, view = view.superview) {
        if ([view isKindOfClass:[UICollectionViewCell class]])
            return (UICollectionViewCell *)view;
    }
    return nil;
}

%hook ELMCellNode

- (void)setElement:(id)element {
    %orig;
    [FeedDataSourceAdapter invalidateMetadataForNode:self];
    [Util resetFeedVideoMetadataForNode:self];
}

%end

%hook ASCollectionView

- (void)setDataSource:(id)dataSource {
    %orig(dataSource);
}

- (id)asyncDataSource {
    id adapter = objc_getAssociatedObject(self, FeedDataSourceAdapterKey);
    id result = [FeedDataSourceAdapter isAdapter:adapter] ? adapter : %orig;
    return result;
}

- (void)setAsyncDataSource:(id)dataSource {
    if (IsShortsDataSourceOrView(self, dataSource)) {
        %orig(dataSource);
        return;
    }
    if (dataSource && ![FeedDataSourceAdapter isAdapter:dataSource])
        InstallFeedDataSourceAdapter((UICollectionView *)self, dataSource);
    id adaptedDataSource = dataSource ? (objc_getAssociatedObject(self, FeedDataSourceAdapterKey) ?: dataSource) : nil;
    %orig(adaptedDataSource);
}

- (void)reloadData {
    PrepareFeedDataSourceForReload(self);
    %orig;
}

%end

%hook YTAsyncCollectionView

- (void)setAsyncDataSource:(id)dataSource {
    if (IsShortsDataSourceOrView(self, dataSource)) {
        %orig(dataSource);
        return;
    }
    if (dataSource && ![FeedDataSourceAdapter isAdapter:dataSource])
        InstallFeedDataSourceAdapter((UICollectionView *)self, dataSource);
    id adaptedDataSource = dataSource ? (objc_getAssociatedObject(self, FeedDataSourceAdapterKey) ?: dataSource) : nil;
    %orig(adaptedDataSource);
}

%end

%hook ASCollectionNode

- (void)reloadData {
    PrepareCollectionNodeForReload(self);
    %orig;
}

- (void)reloadDataWithCompletion:(void (^)(void))completion {
    PrepareCollectionNodeForReload(self);
    %orig(completion);
}

%end

%hook YTReelDataSource

- (NSOrderedSet *)reels {
    NSOrderedSet *sourceReels = %orig;
    NSOrderedSet *result = [ReelSequenceFilter filteredReelsForDataSource:self sourceReels:sourceReels];
    return result;
}

- (NSSet *)reelVideoIDs {
    NSSet *sourceVideoIDs = %orig;
    return [ReelSequenceFilter filteredVideoIDsForDataSource:self sourceVideoIDs:sourceVideoIDs];
}

- (void)setReels:(NSOrderedSet *)reels {
    %orig(reels);
    [ReelSequenceFilter invalidateDataSource:self];
}

- (void)replaceModelAtIndex:(NSInteger)index withModel:(id)model {
    %orig(index, model);
    [ReelSequenceFilter invalidateDataSource:self];
}

- (NSUInteger)insertContentModel:(id)model atIndex:(NSInteger)index {
    NSUInteger result = %orig(model, index);
    [ReelSequenceFilter invalidateDataSource:self];
    return result;
}

- (NSUInteger)insertEndpoint:(id)endpoint atIndex:(NSInteger)index {
    NSUInteger result = %orig(endpoint, index);
    [ReelSequenceFilter invalidateDataSource:self];
    return result;
}

- (void)updateReelsDataSourceWithContentModels:(id)contentModels
                                     prevItems:(id)prevItems
                                     nextItems:(id)nextItems
                                  refreshItems:(id)refreshItems {
    %orig(contentModels, prevItems, nextItems, refreshItems);
    [ReelSequenceFilter invalidateDataSource:self];
}

- (void)processReelWatchSequenceResponse:(id)response withModel:(id)model {
    %orig(response, model);
    [ReelSequenceFilter invalidateDataSource:self];
}

- (void)refreshModel {
    [ReelSequenceFilter invalidateDataSource:self];
    %orig;
}

- (void)softRefreshModel {
    [ReelSequenceFilter invalidateDataSource:self];
    %orig;
}

%end

%hook YTReelSequenceViewController

- (void)setReelsDataSource:(id)dataSource {
    %orig(dataSource);
    [ReelSequenceFilter registerSequenceController:self dataSource:dataSource];
}

- (id)reelsDataSource {
    id dataSource = %orig;
    [ReelSequenceFilter registerSequenceController:self dataSource:dataSource];
    return dataSource;
}

- (void)viewDidLoad {
    %orig;
    [ReelSequenceFilter registerSequenceController:self dataSource:ExplicitObjectValue(self, @"reelsDataSource")];
}

- (void)refreshContent {
    [ReelSequenceFilter registerSequenceController:self dataSource:ExplicitObjectValue(self, @"reelsDataSource")];
    %orig;
}

- (id)pageViewController:(id)pageViewController viewControllerAtIndex:(NSInteger)index {
    id dataSource = ExplicitObjectValue(self, @"reelsDataSource");
    NSInteger sourceIndex = [ReelSequenceFilter sourceIndexForVisibleIndex:index dataSource:dataSource];
    if (sourceIndex != NSNotFound)
        index = sourceIndex;
    return %orig(pageViewController, index);
}

- (id)playbackSequentialItemControllerForIndex:(NSUInteger)index {
    id dataSource = ExplicitObjectValue(self, @"reelsDataSource");
    NSInteger sourceIndex = [ReelSequenceFilter sourceIndexForVisibleIndex:(NSInteger)index dataSource:dataSource];
    if (sourceIndex != NSNotFound)
        index = (NSUInteger)sourceIndex;
    return %orig(index);
}

%end

%hook YTScrollablePageViewControllerPagedDataSourceAdapter

- (instancetype)initWithPageViewController:(id)pageViewController dataSource:(id)dataSource {
    id result = %orig(pageViewController, dataSource);
    objc_setAssociatedObject(result, ScrollablePageDataSourceKey, dataSource, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

- (instancetype)initWithPageViewController:(id)pageViewController
                                 dataSource:(id)dataSource
                     cachedControllersCount:(NSInteger)cachedControllersCount {
    id result = %orig(pageViewController, dataSource, cachedControllersCount);
    objc_setAssociatedObject(result, ScrollablePageDataSourceKey, dataSource, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

- (id)pageViewController:(id)pageViewController viewControllerAtIndex:(NSInteger)index {
    id reelDataSource = ScrollablePageReelDataSource(self);
    NSInteger sourceIndex = [ReelSequenceFilter sourceIndexForVisibleIndex:index dataSource:reelDataSource];
    if (sourceIndex != NSNotFound)
        index = sourceIndex;
    return %orig(pageViewController, index);
}

%end

%hook YTScrollablePageViewControllerConfigurableAdapter

- (instancetype)initWithPageViewController:(id)pageViewController
                                 dataSource:(id)dataSource
                       backwardWindowLength:(NSInteger)backwardWindowLength
                        forwardWindowLength:(NSInteger)forwardWindowLength
                 dynamicForwardSwipingEnabled:(BOOL)dynamicForwardSwipingEnabled {
    id result = %orig(pageViewController,
                      dataSource,
                      backwardWindowLength,
                      forwardWindowLength,
                      dynamicForwardSwipingEnabled);
    objc_setAssociatedObject(result, ScrollablePageDataSourceKey, dataSource, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

- (id)pageViewController:(id)pageViewController viewControllerAtIndex:(NSInteger)index {
    id reelDataSource = ScrollablePageReelDataSource(self);
    NSInteger sourceIndex = [ReelSequenceFilter sourceIndexForVisibleIndex:index dataSource:reelDataSource];
    if (sourceIndex != NSNotFound)
        index = sourceIndex;
    return %orig(pageViewController, index);
}

%end

%hook YTReelWatchRootViewController

- (void)setReelsDataSource:(id)dataSource {
    %orig(dataSource);
    objc_setAssociatedObject(self, RootReelDataSourceKey, dataSource, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ReelSequenceFilter registerSequenceController:self dataSource:dataSource];
}

- (id)reelsDataSource {
    id result = %orig;
    if (result)
        objc_setAssociatedObject(self, RootReelDataSourceKey, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ReelSequenceFilter registerSequenceController:self dataSource:result];
    return result;
}

- (void)dataSource:(id)dataSource didDropAndReplaceItemsAfterIndex:(NSInteger)index {
    %orig(dataSource, index);
    [ReelSequenceFilter invalidateDataSource:dataSource];
}

- (void)dataSource:(id)dataSource didInsertModel:(id)model atIndex:(NSInteger)index {
    %orig(dataSource, model, index);
    [ReelSequenceFilter invalidateDataSource:dataSource];
}

- (void)dataSource:(id)dataSource didReplaceModelAtIndex:(NSInteger)index withModel:(id)model {
    %orig(dataSource, index, model);
    [ReelSequenceFilter invalidateDataSource:dataSource];
}

- (void)dataSource:(id)dataSource
didUpdateWithPrevItems:(id)prevItems
          nextItems:(id)nextItems
       refreshItems:(id)refreshItems {
    %orig(dataSource, prevItems, nextItems, refreshItems);
    [ReelSequenceFilter invalidateDataSource:dataSource];
}

%end

%hook YTDefaultSheetController

- (instancetype)initWithSheetStyle:(NSInteger)sheetStyle
                        headerTitle:(NSString *)headerTitle
                     headerSubtitle:(NSString *)headerSubtitle
               shouldDisableLogging:(BOOL)shouldDisableLogging
                            delegate:(id)delegate
                      parentResponder:(id)parentResponder {
    YTDefaultSheetController *result = %orig(sheetStyle,
                                               headerTitle,
                                               headerSubtitle,
                                               shouldDisableLogging,
                                               delegate,
                                               parentResponder);
    return result;
}

- (void)addActionWithView:(UIView *)view {
    %orig(view);
}

- (void)addActionWithView:(UIView *)view handler:(id)handler {
    %orig(view, handler);
}

- (void)addActionWithView:(UIView *)view size:(CGSize)size {
    %orig(view, size);
}

- (void)addActionWithView:(UIView *)view size:(CGSize)size handler:(id)handler {
    %orig(view, size, handler);
}

- (void)addActionWithView:(UIView *)view delegateAccessibility:(id)delegateAccessibility {
    %orig(view, delegateAccessibility);
}

- (void)addActionWithView:(UIView *)view size:(CGSize)size delegateAccessibility:(id)delegateAccessibility {
    %orig(view, size, delegateAccessibility);
}

- (void)addActionsContentView:(UIView *)contentView {
    InjectShortsBottomSheetActions(self);
    %orig(contentView);
    InsertStoredBlockingActions(self);
}

- (void)relayoutActionSheet {
    InjectShortsBottomSheetActions(self);
    %orig;
    InsertStoredBlockingActions(self);
}

- (void)viewDidLoad {
    %orig;
    InjectShortsBottomSheetActions(self);
    InsertStoredBlockingActions(self);
}

- (void)addAction:(YTActionSheetAction *)action {
    NSArray *blockingActions = objc_getAssociatedObject(self, ActionSheetBlockingActionsKey);
    if (blockingActions.count == 0) {
        AddBlockingActions(self, action);
        blockingActions = objc_getAssociatedObject(self, ActionSheetBlockingActionsKey);
        for (YTActionSheetAction *blockingAction in blockingActions)
            %orig(blockingAction);
    }
    %orig(action);
    InsertStoredBlockingActions(self);
}

- (NSArray *)actions {
    NSArray *originalActions = %orig;
    return ActionsWithBlockingActions(self, originalActions);
}

- (void)presentFromView:(UIView *)view {
    PrimeBlockingActionsForPresentation(self, view);
    InsertStoredBlockingActions(self);
    %orig(view);
}

- (void)presentFromView:(UIView *)view completion:(id)completion {
    PrimeBlockingActionsForPresentation(self, view);
    InsertStoredBlockingActions(self);
    %orig(view, completion);
}

%end

%hook YTActionSheetController

- (void)addAction:(YTActionSheetAction *)action {
    NSArray *blockingActions = objc_getAssociatedObject(self, ActionSheetBlockingActionsKey);
    if (blockingActions.count == 0) {
        AddBlockingActions(self, action);
        blockingActions = objc_getAssociatedObject(self, ActionSheetBlockingActionsKey);
        for (YTActionSheetAction *blockingAction in blockingActions)
            %orig(blockingAction);
    }
    %orig(action);
    InsertStoredBlockingActions(self);
}

- (NSArray *)actions {
    NSArray *originalActions = %orig;
    return ActionsWithBlockingActions(self, originalActions);
}

- (void)presentFromView:(UIView *)view {
    PrimeBlockingActionsForPresentation(self, view);
    %orig(view);
}

- (void)presentFromView:(UIView *)view completion:(id)completion {
    PrimeBlockingActionsForPresentation(self, view);
    %orig(view, completion);
}

%end

%hook MDCActionSheetController

- (NSArray *)actions {
    NSArray *originalActions = %orig;
    return MDCBlockingActionsForSheet(self, originalActions);
}

- (void)addAction:(id)action {
    %orig(action);
    [(id)self actions];
}

- (void)viewDidLoad {
    %orig;
    [(id)self actions];
}

%end

%hook YTMenuController

- (void)setActionSheetController:(id)actionSheetController {
    %orig(actionSheetController);
    PrepareMenuControllerSheet(self, nil);
}

- (void)showMenuWithMenuRenderer:(id)renderer
                       fromView:(UIView *)view
                          entry:(id)entry
                  firstResponder:(id)firstResponder {
    %orig(renderer, view, entry, firstResponder);
    PrepareMenuControllerSheet(self, view);
}

- (void)showMenuWithMenuRenderer:(id)renderer
                       fromView:(UIView *)view
                          entry:(id)entry
                skipCollapsedState:(BOOL)skipCollapsedState
                  firstResponder:(id)firstResponder {
    %orig(renderer, view, entry, skipCollapsedState, firstResponder);
    PrepareMenuControllerSheet(self, view);
}

- (void)showMenuWithMenuRenderer:(id)renderer
                       fromView:(UIView *)view
                          entry:(id)entry
                 dismissalBlock:(id)dismissalBlock
                addCancelAction:(BOOL)addCancelAction
                  firstResponder:(id)firstResponder {
    %orig(renderer, view, entry, dismissalBlock, addCancelAction, firstResponder);
    PrepareMenuControllerSheet(self, view);
}

- (void)showMenuWithMenuRenderer:(id)renderer
                       fromView:(UIView *)view
                          entry:(id)entry
                 dismissalBlock:(id)dismissalBlock
                addCancelAction:(BOOL)addCancelAction
                shouldLogItems:(BOOL)shouldLogItems
                  firstResponder:(id)firstResponder {
    %orig(renderer, view, entry, dismissalBlock, addCancelAction, shouldLogItems, firstResponder);
    PrepareMenuControllerSheet(self, view);
}

- (void)showMenuWithMenuRenderer:(id)renderer
                       fromView:(UIView *)view
                          entry:(id)entry
                 dismissalBlock:(id)dismissalBlock
                addCancelAction:(BOOL)addCancelAction
                shouldLogItems:(BOOL)shouldLogItems
                firstResponder:(id)firstResponder
                       completion:(id)completion {
    %orig(renderer, view, entry, dismissalBlock, addCancelAction, shouldLogItems, firstResponder, completion);
    PrepareMenuControllerSheet(self, view);
}

- (void)showMenuWithMenuRenderer:(id)renderer
                       fromView:(UIView *)view
                          entry:(id)entry
                 dismissalBlock:(id)dismissalBlock
                addCancelAction:(BOOL)addCancelAction
                shouldLogItems:(BOOL)shouldLogItems
                skipCollapsedState:(BOOL)skipCollapsedState
                  firstResponder:(id)firstResponder
                       completion:(id)completion {
    %orig(renderer, view, entry, dismissalBlock, addCancelAction, shouldLogItems, skipCollapsedState, firstResponder, completion);
    PrepareMenuControllerSheet(self, view);
}

- (void)showMenuWithMenuRenderer:(id)renderer
                       fromView:(UIView *)view
                          entry:(id)entry
                 dismissalBlock:(id)dismissalBlock
                  firstResponder:(id)firstResponder {
    %orig(renderer, view, entry, dismissalBlock, firstResponder);
    PrepareMenuControllerSheet(self, view);
}

- (id)newActionSheetControllerWithMessage:(NSString *)message
                                 fromView:(UIView *)view {
    id result = %orig(message, view);
    if (view)
        objc_setAssociatedObject(result, ActionSheetSourceViewKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PrepareMenuControllerSheet(self, view);
    return result;
}

- (id)newDefaultSheetControllerWithMessage:(NSString *)message
                           parentResponder:(id)parentResponder
                                  fromView:(UIView *)view
                           forcedSheetStyle:(NSInteger)forcedSheetStyle {
    id result = %orig(message, parentResponder, view, forcedSheetStyle);
    if (view)
        objc_setAssociatedObject(result, ActionSheetSourceViewKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PrepareMenuControllerSheet(self, view);
    return result;
}

- (NSArray *)actionsForRenderers:(id)renderers
                        fromView:(UIView *)view
                           entry:(id)entry
                  firstResponder:(id)firstResponder {
    NSArray *actions = %orig(renderers, view, entry, firstResponder);
    return MenuActionsWithBlockingActions(actions, view, renderers, entry);
}

- (NSArray *)actionsForRenderers:(id)renderers
                        fromView:(UIView *)view
                           entry:(id)entry
                  shouldLogItems:(BOOL)shouldLogItems
                  firstResponder:(id)firstResponder {
    NSArray *actions = %orig(renderers, view, entry, shouldLogItems, firstResponder);
    return MenuActionsWithBlockingActions(actions, view, renderers, entry);
}

%end

%hook YTBottomSheetController

- (instancetype)initWithContentViewController:(UIViewController *)contentViewController {
    YTBottomSheetController *result = %orig(contentViewController);
    InjectShortsBottomSheetActions(contentViewController);
    return result;
}

- (instancetype)initWithContentViewController:(UIViewController *)contentViewController
                              enableViewPort:(BOOL)enableViewPort {
    YTBottomSheetController *result = %orig(contentViewController, enableViewPort);
    InjectShortsBottomSheetActions(contentViewController);
    return result;
}

%end

%hook YTActionSheetDialogViewController

- (void)viewDidLoad {
    InjectShortsBottomSheetActions(self);
    %orig;
    InjectShortsBottomSheetActions(self);
    InsertStoredBlockingActions(ExplicitObjectValue(self, @"delegate"));
}

- (void)setPreferredContentSize:(CGSize)preferredContentSize {
    InjectShortsBottomSheetActions(self);
    %orig(preferredContentSize);
    InjectShortsBottomSheetActions(self);
    InsertStoredBlockingActions(ExplicitObjectValue(self, @"delegate"));
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    NSString *className = NSStringFromClass([viewControllerToPresent class]).lowercaseString;
    BOOL hasActionSheetInterface = [viewControllerToPresent respondsToSelector:@selector(actions)] &&
                                   [viewControllerToPresent respondsToSelector:@selector(addAction:)];
    if ([className containsString:@"actionsheet"] || hasActionSheetInterface)
        PrimeBlockingActionsForPresentation(viewControllerToPresent, ActionSheetSourceView(viewControllerToPresent));
    %orig(viewControllerToPresent, animated, completion);
}

%end

%hook YTShortsPlayerViewController

- (id)initWithParentResponder:(id)parentResponder
       pivotBarViewController:(id)pivotBarViewController
                        model:(id)model
      mayShowNavigationEduOverlay:(BOOL)mayShowNavigationEduOverlay {
    id result = %orig(parentResponder, pivotBarViewController, model, mayShowNavigationEduOverlay);
    if (result) {
        CurrentShortsPlayer = result;
        CaptureCurrentShortsMetadata(result);
    }
    return result;
}

- (void)viewDidAppear:(BOOL)animated {
    CurrentShortsPlayer = self;
    %orig;
    CaptureCurrentShortsMetadata(self);
}

- (void)handleReelItemWatchResponse:(id)response
                       prefetchType:(NSInteger)prefetchType
                   watchRequestIndex:(NSInteger)watchRequestIndex {
    %orig(response, prefetchType, watchRequestIndex);
    FeedMetadataRecord *responseMetadata = [Util feedVideoMetadataFromModel:response];
    CurrentShortsPlayer = self;
    if (responseMetadata.dictionaryRepresentation.count > 0) {
        id model = ExplicitObjectValue(self, @"model") ?: ExplicitObjectValue(self, @"contentModel") ?: ExplicitObjectValue(self, @"itemModel");
        id contentView = ExplicitObjectValue(self, @"shortsContentView") ?: ExplicitObjectValue(self, @"contentView");
        FeedMetadataRecord *modelMetadata = [Util feedVideoMetadataFromModel:model];
        FeedMetadataRecord *contentMetadata = [Util cachedFeedVideoMetadataForNode:contentView];
        FeedMetadataRecord *metadata = CombinedShortsMetadata(CombinedShortsMetadata(modelMetadata, responseMetadata), contentMetadata);
        objc_setAssociatedObject(self, ShortsResponseMetadataKey, metadata, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RememberShortsMetadataForPlayer(self, metadata);
    }
    CaptureCurrentShortsMetadata(self);
}

- (id)shortsContentView {
    CurrentShortsPlayer = self;
    return %orig;
}

%end

%hook YTReelPlayerViewController

- (id)sequenceController {
    return %orig;
}

- (id)model {
    return %orig;
}

- (id)initWithParentResponder:(id)parentResponder
       pivotBarViewController:(id)pivotBarViewController
                        model:(id)model
      mayShowNavigationEduOverlay:(BOOL)mayShowNavigationEduOverlay {
    id result = %orig(parentResponder, pivotBarViewController, model, mayShowNavigationEduOverlay);
    if (result) {
        CurrentShortsPlayer = result;
        CaptureCurrentShortsMetadata(result);
    }
    return result;
}

- (void)viewDidAppear:(BOOL)animated {
    CurrentShortsPlayer = self;
    %orig;
    CaptureCurrentShortsMetadata(self);
}

- (void)currentVideoDidChange {
    %orig;
    CurrentShortsPlayer = self;
    CaptureCurrentShortsMetadata(self);
}

- (id)contentView {
    CurrentShortsPlayer = self;
    return %orig;
}

- (id)currentVideo {
    CurrentShortsPlayer = self;
    id result = %orig;
    FeedMetadataRecord *metadata = [Util feedVideoMetadataFromModel:result];
    if (metadata.dictionaryRepresentation.count > 0)
        RememberShortsMetadataForPlayer(self, metadata);
    return result;
}

- (void)reelContentView:(id)contentView updateOverflowMenu:(id)menu {
    %orig(contentView, menu);
}

- (void)reelContentView:(id)contentView updateOverflowMenuWithCommand:(id)command {
    %orig(contentView, command);
}

- (void)reelContentViewDidLongPressForOverflowMenu:(id)contentView {
    %orig(contentView);
}

%end

%hook ELMImageNode

- (id)downloadImageWithURL:(NSURL *)url
                shouldRetry:(BOOL)shouldRetry
              callbackQueue:(id)queue
           downloadProgress:(id)progress
                 completion:(void (^)(id, NSError *, id, id))completion {
    NSString *videoID = [Util feedVideoIDFromThumbnailURL:url];
    if (videoID.length == 0)
        return %orig;

    AssociateVideoIDWithNode(self, videoID);
    if (!completion)
        return %orig;
    void (^wrappedCompletion)(id, NSError *, id, id) = ^(id image, NSError *error, id value3, id value4) {
        if (image)
            [Util setFeedVideoID:videoID forObject:image];
        completion(image, error, value3, value4);
    };
    return %orig(url, shouldRetry, queue, progress, wrappedCompletion);
}

- (void)cachedImageWithURL:(NSURL *)url
              callbackQueue:(id)queue
                 completion:(void (^)(id))completion {
    NSString *videoID = [Util feedVideoIDFromThumbnailURL:url];
    if (videoID.length == 0)
        return %orig;

    AssociateVideoIDWithNode(self, videoID);
    if (!completion)
        return %orig;
    void (^wrappedCompletion)(id) = ^(id image) {
        if (image)
            [Util setFeedVideoID:videoID forObject:image];
        completion(image);
    };
    %orig(url, queue, wrappedCompletion);
}

- (void)setImage:(UIImage *)image {
    NSString *videoID = [Util feedVideoIDForObject:image];
    AssociateVideoIDWithNode(self, videoID);
    %orig;
}

- (void)imageNode:(id)node didLoadImage:(UIImage *)image {
    NSString *videoID = [Util feedVideoIDForObject:image];
    AssociateVideoIDWithNode(self, videoID);
    %orig;
}

- (void)imageNode:(id)node didLoadImage:(UIImage *)image info:(id)info {
    NSString *videoID = [Util feedVideoIDForObject:image];
    AssociateVideoIDWithNode(self, videoID);
    %orig;
}

- (void)imageNodeInternal:(id)node didLoadImage:(UIImage *)image info:(id)info {
    NSString *videoID = [Util feedVideoIDForObject:image];
    AssociateVideoIDWithNode(self, videoID);
    %orig;
}

%end

%hook YTThumbnailController

- (instancetype)initWithImageView:(YTImageView *)imageView
                              URLs:(NSDictionary *)URLs
                       imageService:(id)imageService {
    NSString *videoID = nil;
    for (id value in URLs.allValues) {
        if (![value isKindOfClass:[NSURL class]])
            continue;
        videoID = [Util feedVideoIDFromThumbnailURL:value];
        if (videoID.length > 0)
            break;
    }
    id result = %orig;
    if (videoID.length > 0)
        [Util setFeedVideoID:videoID forObject:result];
    return result;
}

%end

%hook YTImageView

- (void)setImage:(UIImage *)image animated:(BOOL)animated {
    NSString *videoID = [Util feedVideoIDForObject:self.delegate];
    if (videoID.length > 0)
        [Util setFeedVideoID:videoID forObject:image];
    %orig;
}

%end

static void *NavigationButtonOwnersKey = &NavigationButtonOwnersKey;
static void *NavigationButtonImageKey = &NavigationButtonImageKey;
static void *NavigationButtonImagePageStyleKey = &NavigationButtonImagePageStyleKey;
static void *NavigationButtonStateKey = &NavigationButtonStateKey;

static NSHashTable *NavigationButtonOwners(void) {
    NSHashTable *owners = objc_getAssociatedObject([UIApplication sharedApplication], NavigationButtonOwnersKey);
    if (!owners) {
        owners = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject([UIApplication sharedApplication], NavigationButtonOwnersKey, owners, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return owners;
}

static BOOL ShouldShowNavigationButton(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:@"GonerinoShowButton"] == nil || [defaults boolForKey:@"GonerinoShowButton"];
}

static NSInteger CurrentPageStyle(YTRightNavigationButtons *owner) {
    UIUserInterfaceStyle style = owner.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified)
        style = owner.window.traitCollection.userInterfaceStyle;
    return style;
}

static void PrepareNavigationButton(YTRightNavigationButtons *owner) {
    if (!owner)
        return;
    if (![owner respondsToSelector:@selector(actionButton)] ||
        ![owner respondsToSelector:@selector(setActionButton:)])
        return;

    [NavigationButtonOwners() addObject:owner];
    if (!owner.actionButton) {
        owner.actionButton = [%c(YTQTMButton) iconButton];
        if ([owner.actionButton respondsToSelector:@selector(enableNewTouchFeedback)])
            [owner.actionButton enableNewTouchFeedback];
        owner.actionButton.frame = CGRectMake(0, 0, 40, 40);
        owner.actionButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        owner.actionButton.imageView.contentMode = UIViewContentModeCenter;
        owner.actionButton.adjustsImageWhenHighlighted = NO;
        [owner.actionButton addTarget:owner action:@selector(actionButtonPressed:)
                      forControlEvents:UIControlEventTouchUpInside];
        [owner addSubview:owner.actionButton];
    }
    owner.actionButton.hidden = !ShouldShowNavigationButton();
}

static NSArray<UIImage *> *NavigationButtonImages(YTRightNavigationButtons *owner, NSInteger pageStyle) {
    NSNumber *cachedPageStyle = objc_getAssociatedObject(owner, NavigationButtonImagePageStyleKey);
    NSArray<UIImage *> *images = objc_getAssociatedObject(owner, NavigationButtonImageKey);
    if (images && cachedPageStyle.integerValue == pageStyle)
        return images;

    UIColor *tintColor = pageStyle == UIUserInterfaceStyleDark ? UIColor.whiteColor : UIColor.blackColor;
    UIImage *baseImage = [Util createBlockVideoIconWithSize:CGSizeMake(20, 20)];
    if (!baseImage)
        return @[];

    UIImage *enabledImage = nil;
    UIImage *disabledImage = nil;
    Class iconClass = %c(QTMIcon);
    if ([iconClass respondsToSelector:@selector(tintImage:color:)]) {
        enabledImage = [iconClass tintImage:baseImage color:tintColor];
        disabledImage = [iconClass tintImage:baseImage color:[tintColor colorWithAlphaComponent:0.4]];
    }
    enabledImage = enabledImage ?: [baseImage imageWithTintColor:tintColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    disabledImage = disabledImage ?: [baseImage imageWithTintColor:[tintColor colorWithAlphaComponent:0.4]
                                                            renderingMode:UIImageRenderingModeAlwaysOriginal];
    images = @[enabledImage, disabledImage];
    objc_setAssociatedObject(owner, NavigationButtonImageKey, images, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(owner, NavigationButtonImagePageStyleKey, @(pageStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return images;
}

static void UpdateNavigationButton(YTRightNavigationButtons *owner) {
    if (!owner)
        return;
    if (![owner respondsToSelector:@selector(actionButton)] ||
        ![owner respondsToSelector:@selector(setActionButton:)])
        return;

    PrepareNavigationButton(owner);

    BOOL shouldShow = ShouldShowNavigationButton();
    BOOL isEnabled = [Util filteringEnabled];
    NSInteger pageStyle = CurrentPageStyle(owner);
    NSArray<UIImage *> *images = NavigationButtonImages(owner, pageStyle);
    NSDictionary *state = @{
        @"enabled": @(isEnabled),
        @"visible": @(shouldShow),
        @"pageStyle": @(pageStyle)
    };
    NSDictionary *previousState = objc_getAssociatedObject(owner, NavigationButtonStateKey);
    BOOL changed = ![previousState isEqualToDictionary:state];
    owner.actionButton.hidden = !shouldShow;
    if (changed) {
        UIImage *image = isEnabled ? images.firstObject : images.lastObject;
        if (image)
            [owner.actionButton setImage:image forState:UIControlStateNormal];
        owner.actionButton.tintColor = pageStyle == UIUserInterfaceStyleDark ? UIColor.whiteColor : UIColor.blackColor;
        owner.actionButton.accessibilityLabel = LocalizedString(@"Gonerino");
        owner.actionButton.accessibilityValue = LocalizedString(isEnabled ? @"Enabled" : @"Disabled");
        objc_setAssociatedObject(owner, NavigationButtonStateKey, state, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [owner.actionButton setNeedsLayout];
    }
}

static void RefreshNavigationButtons(void) {
    void (^refresh)(void) = ^{
        for (YTRightNavigationButtons *owner in NavigationButtonOwners().allObjects)
            UpdateNavigationButton(owner);
    };
    if ([NSThread isMainThread])
        refresh();
    else
        dispatch_async(dispatch_get_main_queue(), refresh);
}

%hook YTRightNavigationButtons
%property(retain, nonatomic) YTQTMButton *actionButton;

- (instancetype)initWithFrame:(CGRect)frame {
    YTRightNavigationButtons *owner = %orig;
    PrepareNavigationButton(owner);
    UpdateNavigationButton(owner);
    return owner;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    YTRightNavigationButtons *owner = %orig;
    PrepareNavigationButton(owner);
    UpdateNavigationButton(owner);
    return owner;
}

- (NSMutableArray *)buttons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    PrepareNavigationButton(self);
    if (![self respondsToSelector:@selector(actionButton)] ||
        ![self respondsToSelector:@selector(setActionButton:)])
        return result;
    if (ShouldShowNavigationButton() && self.actionButton && result.count >= 2 && ![result containsObject:self.actionButton])
        [result insertObject:self.actionButton atIndex:0];
    return result;
}

- (NSMutableArray *)visibleButtons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    PrepareNavigationButton(self);
    if (![self respondsToSelector:@selector(actionButton)] ||
        ![self respondsToSelector:@selector(setActionButton:)])
        return result;
    if (ShouldShowNavigationButton() && self.actionButton && result.count >= 2 && ![result containsObject:self.actionButton])
        [result insertObject:self.actionButton atIndex:0];
    return result;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    UpdateNavigationButton(self);
}

%new
- (void)actionButtonPressed:(UIButton *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isEnabled = [defaults objectForKey:@"GonerinoEnabled"] == nil ? YES : [defaults boolForKey:@"GonerinoEnabled"];
    BOOL newState = !isEnabled;
    [defaults setBool:newState forKey:@"GonerinoEnabled"];
    [defaults synchronize];
    [Util refreshPreferenceSnapshot];

    [[NSNotificationCenter defaultCenter] postNotificationName:FeedFilterStateDidChangeNotification object:nil];
    UpdateNavigationButton(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        RefreshNavigationButtons();
    });
    UIViewController *viewController = ViewControllerForObject(self);
    NSString *state = LocalizedString(newState ? @"enabled" : @"disabled");
    SendToast(viewController, [NSString stringWithFormat:@"%@ %@", LocalizedString(@"Gonerino"), state]);
}

%end

%ctor {
    %init;
    GonerinoStartUpdateChecker();
    [[NSNotificationCenter defaultCenter] addObserverForName:FeedFilterStateDidChangeNotification
                                                      object:nil
                                                  queue:[NSOperationQueue mainQueue]
                                              usingBlock:^(__unused NSNotification *notification) {
                                                      RefreshNavigationButtons();
                                                  }];
}
