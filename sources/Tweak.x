#import "Tweak.h"
#import "Localization.h"
#import <objc/runtime.h>

static id ValueForObjectKey(id object, NSString *key);
static UIViewController *ViewControllerForObject(id object);
static __weak YTShortsPlayerViewController *CurrentShortsPlayer;

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

static BOOL NodeLooksLikeVideo(id node) {
    if (!node)
        return NO;

    NSString *nodeClassName = NSStringFromClass([node class]);
    NSString *normalizedClassName = nodeClassName.lowercaseString;
    if ([normalizedClassName containsString:@"collection"] ||
        [normalizedClassName containsString:@"reorderable"] ||
        [normalizedClassName containsString:@"scrollablepage"] ||
        [normalizedClassName containsString:@"shelf"] ||
        [normalizedClassName containsString:@"section"])
        return NO;

    BOOL isVideoLike = [normalizedClassName containsString:@"video"] ||
                       [normalizedClassName containsString:@"short"] ||
                       [normalizedClassName containsString:@"reel"];
    BOOL isContentNode = [normalizedClassName containsString:@"node"] ||
                         [normalizedClassName containsString:@"item"];
    if (isVideoLike && isContentNode)
        return YES;

    return NO;
}

static BOOL NodeLooksLikeActionVideo(id node) {
    if (!node)
        return NO;

    if (NodeLooksLikeVideo(node))
        return YES;

    NSString *className = NSStringFromClass([node class]).lowercaseString;
    if ([className containsString:@"shorts"] &&
        ([className containsString:@"node"] || [className containsString:@"item"] ||
         [className containsString:@"player"]))
        return YES;

    return NO;
}

static id VideoNodeFromView(UIView *view, NSUInteger depth) {
    if (![view isKindOfClass:[UIView class]] || depth > 16)
        return nil;

    id node = ValueForObjectKey(view, @"asyncdisplaykit_node");
    if (NodeLooksLikeActionVideo(node))
        return node;

    for (UIView *subview in view.subviews) {
        node = VideoNodeFromView(subview, depth + 1);
        if (node)
            return node;
    }

    return nil;
}

static id ActionMetadataNodeFromObject(id object, NSUInteger depth) {
    if (!object || depth > 3)
        return nil;

    if (NodeLooksLikeActionVideo(object))
        return object;

    if ([object isKindOfClass:[UIView class]]) {
        id node = ValueForObjectKey(object, @"asyncdisplaykit_node");
        if (node && node != object) {
            id videoNode = ActionMetadataNodeFromObject(node, depth + 1);
            if (videoNode)
                return videoNode;
        }
    }

    for (NSString *key in @[@"cellNode", @"node", @"_node", @"videoNode", @"_videoNode",
                            @"playerNode", @"_playerNode", @"currentVideo", @"activeVideo",
                            @"shortsPlayerViewController", @"currentPlayer"]) {
        id candidate = ValueForObjectKey(object, key);
        if (!candidate || candidate == object)
            continue;
        id videoNode = ActionMetadataNodeFromObject(candidate, depth + 1);
        if (videoNode)
            return videoNode;
    }

    return nil;
}

static UIView *ActionSheetSourceView(id sheet) {
    id source = ValueForObjectKey(sheet, @"sourceView");
    if (!source)
        source = ValueForObjectKey(sheet, @"_sourceView");
    if ([source isKindOfClass:[UIView class]])
        return source;
    if ([source isKindOfClass:[UIViewController class]])
        return ((UIViewController *)source).view;
    return nil;
}

static id ActionSheetNodeCandidate(id candidate) {
    if (!candidate)
        return nil;
    if ([candidate isKindOfClass:[UIView class]]) {
        id node = VideoNodeFromView(candidate, 0);
        if (node)
            return node;
        return ActionMetadataNodeFromObject(candidate, 0);
    }
    if ([candidate isKindOfClass:[UIViewController class]]) {
        id node = VideoNodeFromView(((UIViewController *)candidate).view, 0);
        if (node)
            return node;
        return ActionMetadataNodeFromObject(candidate, 0);
    }

    id node = ActionMetadataNodeFromObject(candidate, 0);
    if (node)
        return node;

    NSString *className = NSStringFromClass([candidate class]).lowercaseString;
    if (NodeLooksLikeActionVideo(candidate) ||
        [className containsString:@"shorts"] ||
        [className containsString:@"reel"] ||
        [className containsString:@"video"] ||
        [className containsString:@"player"])
        return candidate;
    return nil;
}

static id VideoNodeForSheet(id sheet) {
    UIView *sourceView = ActionSheetSourceView(sheet);
    NSUInteger depth = 0;
    while (sourceView && depth++ < 8) {
        id node = ActionSheetNodeCandidate(sourceView);
        if (node)
            return node;
        sourceView = sourceView.superview;
    }

    for (NSString *key in @[
        @"sourceNode", @"_sourceNode", @"videoNode", @"_videoNode", @"playerNode", @"_playerNode",
        @"node", @"_node", @"playerViewController", @"shortsPlayerViewController", @"currentVideo",
        @"videoController", @"watchController", @"parentResponder", @"cellNode", @"elementEntry",
        @"controller", @"viewController", @"model", @"data", @"item", @"entry", @"renderer"
    ]) {
        id node = ActionSheetNodeCandidate(ValueForObjectKey(sheet, key));
        if (node)
            return node;
    }

    return nil;
}

static void AppendActionCandidate(NSMutableArray *candidates, NSMutableSet *visited, id candidate) {
    if (!candidate || candidate == [NSNull null] || candidates.count >= 24)
        return;

    NSValue *identity = [NSValue valueWithNonretainedObject:candidate];
    if ([visited containsObject:identity])
        return;
    [visited addObject:identity];
    [candidates addObject:candidate];
}

static UICollectionViewCell *FeedCellForSourceView(UIView *sourceView);

static NSArray *ActionVideoCandidates(id sheet,
                                      id presentationNode,
                                      id presentationSourceNode,
                                      UIView *sourceView) {
    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];

    UICollectionViewCell *sourceCell = FeedCellForSourceView(sourceView);
    if (sourceCell) {
        id cellNode = ValueForObjectKey(sourceCell, @"node");
        AppendActionCandidate(candidates, visited, ActionSheetNodeCandidate(cellNode) ?: cellNode);
        id cellAsyncNode = ValueForObjectKey(sourceCell, @"asyncdisplaykit_node");
        AppendActionCandidate(candidates, visited, ActionSheetNodeCandidate(cellAsyncNode) ?: cellAsyncNode);
        id cellVideoNode = VideoNodeFromView(sourceCell, 0);
        AppendActionCandidate(candidates, visited, cellVideoNode);
    }

    AppendActionCandidate(candidates, visited, presentationNode);
    AppendActionCandidate(candidates, visited, presentationSourceNode);

    id presentationMetadataNode = ActionMetadataNodeFromObject(presentationNode, 0);
    AppendActionCandidate(candidates, visited, presentationMetadataNode);
    id sourceMetadataNode = ActionMetadataNodeFromObject(presentationSourceNode, 0);
    AppendActionCandidate(candidates, visited, sourceMetadataNode);

    UIView *view = sourceView;
    NSUInteger depth = 0;
    while (view && depth++ < 8 && candidates.count < 24) {
        id node = ValueForObjectKey(view, @"asyncdisplaykit_node");
        AppendActionCandidate(candidates, visited, node);
        view = view.superview;
    }

    for (NSString *key in @[
        @"sourceNode", @"_sourceNode", @"videoNode", @"_videoNode", @"playerNode", @"_playerNode",
        @"currentVideo", @"playerViewController", @"shortsPlayerViewController", @"currentPlayer"
    ]) {
        id candidate = ValueForObjectKey(sheet, key);
        id node = ActionSheetNodeCandidate(candidate);
        AppendActionCandidate(candidates, visited, node ?: candidate);
    }
    return candidates;
}

static UIViewController *ViewControllerForObject(id object) {
    if ([object isKindOfClass:[UIViewController class]])
        return object;

    UIView *sourceView = [object isKindOfClass:[UIView class]] ? object : ValueForObjectKey(object, @"sourceView");
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

static void SendToast(id object, NSString *message) {
    UIView *view = [object isKindOfClass:[UIView class]] ? object : ValueForObjectKey(object, @"sourceView");
    if (![view isKindOfClass:[UIView class]])
        view = nil;
    [Util showToast:message fromView:view];
}

static YTAsyncCollectionView *AsyncCollectionViewInView(UIView *view, NSUInteger depth) {
    if (![view isKindOfClass:[UIView class]] || depth > 10)
        return nil;
    if ([view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")])
        return (YTAsyncCollectionView *)view;
    for (UIView *subview in view.subviews) {
        YTAsyncCollectionView *collectionView = AsyncCollectionViewInView(subview, depth + 1);
        if (collectionView)
            return collectionView;
    }
    return nil;
}

static void MergeAvailableVideoInfo(NSMutableDictionary *result, NSDictionary *candidate) {
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

static YTShortsPlayerViewController *FindShortsPlayerInViewController(UIViewController *viewController,
                                                                        NSMutableSet *visited,
                                                                        NSUInteger depth) {
    Class shortsClass = NSClassFromString(@"YTShortsPlayerViewController");
    if (!viewController || !shortsClass || depth > 8)
        return nil;

    NSValue *identity = [NSValue valueWithNonretainedObject:viewController];
    if ([visited containsObject:identity])
        return nil;
    [visited addObject:identity];

    if ([viewController isKindOfClass:shortsClass])
        return (YTShortsPlayerViewController *)viewController;

    NSMutableArray<UIViewController *> *priorityControllers = [NSMutableArray arrayWithCapacity:5];
    if (viewController.presentedViewController)
        [priorityControllers addObject:viewController.presentedViewController];
    if (viewController.presentingViewController)
        [priorityControllers addObject:viewController.presentingViewController];
    if (viewController.navigationController.visibleViewController)
        [priorityControllers addObject:viewController.navigationController.visibleViewController];
    if (viewController.tabBarController.selectedViewController)
        [priorityControllers addObject:viewController.tabBarController.selectedViewController];
    if (viewController.parentViewController)
        [priorityControllers addObject:viewController.parentViewController];
    for (UIViewController *candidate in priorityControllers) {
        YTShortsPlayerViewController *player = FindShortsPlayerInViewController(candidate, visited, depth + 1);
        if (player)
            return player;
    }

    for (UIViewController *child in viewController.childViewControllers.reverseObjectEnumerator) {
        YTShortsPlayerViewController *player = FindShortsPlayerInViewController(child, visited, depth + 1);
        if (player)
            return player;
    }
    return nil;
}

static YTShortsPlayerViewController *VisibleShortsPlayer(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (!window.windowScene || window.hidden || window.alpha <= 0.01)
            continue;
        YTShortsPlayerViewController *player = FindShortsPlayerInViewController(window.rootViewController,
                                                                                  [NSMutableSet set],
                                                                                  0);
        if (player)
            return player;
    }
    return nil;
}

static BOOL ObjectLooksLikeShorts(id object) {
    if (!object)
        return NO;

    NSString *className = NSStringFromClass([object class]).lowercaseString;
    if ([className containsString:@"short"] || [className containsString:@"reel"])
        return YES;

    if ([object isKindOfClass:[UIView class]]) {
        UIView *view = object;
        NSUInteger depth = 0;
        while (view && depth++ < 10) {
            NSString *viewClassName = NSStringFromClass([view class]).lowercaseString;
            if ([viewClassName containsString:@"short"] || [viewClassName containsString:@"reel"])
                return YES;
            view = view.superview;
        }
    }

    UIViewController *viewController = ViewControllerForObject(object);
    while (viewController) {
        NSString *viewControllerClassName = NSStringFromClass([viewController class]).lowercaseString;
        if ([viewControllerClassName containsString:@"short"] || [viewControllerClassName containsString:@"reel"])
            return YES;
        viewController = viewController.parentViewController;
    }
    return NO;
}

static YTShortsPlayerViewController *ShortsPlayerForObject(id object) {
    if (!object)
        return nil;

    Class shortsClass = NSClassFromString(@"YTShortsPlayerViewController");
    if (shortsClass && [object isKindOfClass:shortsClass])
        return (YTShortsPlayerViewController *)object;

    UIViewController *viewController = ViewControllerForObject(object);
    if (viewController) {
        YTShortsPlayerViewController *player = FindShortsPlayerInViewController(viewController,
                                                                                  [NSMutableSet set],
                                                                                  0);
        if (player)
            return player;
    }

    for (NSString *key in @[@"controller", @"closestViewController", @"viewController",
                            @"playerViewController", @"shortsPlayerViewController", @"parentViewController"]) {
        id candidate = ValueForObjectKey(object, key);
        if (!candidate || candidate == object)
            continue;
        if (shortsClass && [candidate isKindOfClass:shortsClass])
            return (YTShortsPlayerViewController *)candidate;
        viewController = ViewControllerForObject(candidate);
        if (!viewController)
            continue;
        YTShortsPlayerViewController *player = FindShortsPlayerInViewController(viewController,
                                                                                  [NSMutableSet set],
                                                                                  0);
        if (player)
            return player;
    }
    return nil;
}

static UICollectionViewCell *VisibleFeedCellForVideoID(NSString *videoId,
                                                       YTAsyncCollectionView *preferredCollectionView,
                                                       UIView *sourceView);
static YTAsyncCollectionView *CollectionViewForFeedCell(UICollectionViewCell *cell);

static NSDictionary *ActionVideoInfo(id sheet,
                                     id presentationNode,
                                     id presentationSourceNode,
                                     UIView *sourceView,
                                     BOOL requiresChannel) {
    @try {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        UICollectionViewCell *sourceCell = FeedCellForSourceView(sourceView);
        for (id candidate in ActionVideoCandidates(sheet, presentationNode, presentationSourceNode, sourceView)) {
            NSDictionary *candidateInfo = [Util freshVideoInfoFromNode:candidate
                                                              sourceView:sourceCell ?: sourceView];
            if (![candidateInfo isKindOfClass:[NSDictionary class]])
                continue;
            MergeAvailableVideoInfo(info, candidateInfo);
            if ([info[@"id"] length] > 0 &&
                (!requiresChannel || [info[@"channel"] length] > 0) &&
                [Util isUsableVideoTitle:info[@"title"]])
                break;
        }
        NSString *videoId = info[@"id"];
        NSString *channel = info[@"channel"];
        if (videoId.length > 0 && channel.length == 0) {
            YTAsyncCollectionView *preferredCollectionView = CollectionViewForFeedCell(sourceCell);
            UICollectionViewCell *metadataCell = VisibleFeedCellForVideoID(videoId, preferredCollectionView, sourceView);
            if (metadataCell) {
                id metadataNode = nil;
                if ([metadataCell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
                    _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)metadataCell;
                    metadataNode = [asCell respondsToSelector:@selector(node)] ? [asCell node] : nil;
                }
                metadataNode = metadataNode ?: VideoNodeFromView(metadataCell, 0);
                NSDictionary *cellInfo = [Util freshVideoInfoFromNode:metadataNode sourceView:metadataCell];
                MergeAvailableVideoInfo(info, cellInfo);
            }
        }
        return [info copy];
    } @catch (__unused NSException *exception) {
        return @{};
    }
}

static void RemoveBlockedFeedItem(UIView *sourceView,
                                  UICollectionViewCell *knownCell,
                                  YTAsyncCollectionView *knownCollectionView,
                                  NSString *videoId,
                                  BOOL isShorts,
                                  YTShortsPlayerViewController *shortsPlayer);
static UICollectionViewCell *FeedCellForMetadataObject(id object);
static YTAsyncCollectionView *CollectionViewForFeedCell(UICollectionViewCell *cell);

static void ResolveActionVideoInfo(id sheet,
                                   id presentationNode,
                                   id presentationSourceNode,
                                   UIView *sourceView,
                                   BOOL requiresChannel,
                                   NSUInteger attempt,
                                   void (^completion)(NSDictionary *info)) {
    if (!completion)
        return;

    UIView *currentSourceView = sourceView ?: ActionSheetSourceView(sheet);
    NSDictionary *info = ActionVideoInfo(sheet,
                                         presentationNode,
                                         presentationSourceNode,
                                         currentSourceView,
                                         requiresChannel);
    BOOL hasUsableTitle = [Util isUsableVideoTitle:info[@"title"]];
    BOOL resolved = requiresChannel ? [info[@"channel"] length] > 0 :
                                      ([info[@"id"] length] > 0 && (hasUsableTitle || attempt >= 7));
    if (resolved || attempt >= 7) {
        completion(info);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ResolveActionVideoInfo(sheet,
                               presentationNode,
                               presentationSourceNode,
                               sourceView,
                               requiresChannel,
                               attempt + 1,
                               completion);
    });
}

static void AddBlockingActions(id sheet, YTActionSheetAction *originalAction) {
    static void *injectionKey = &injectionKey;
    static void *injectionInProgressKey = &injectionInProgressKey;
    if (!sheet || !originalAction || objc_getAssociatedObject(sheet, injectionInProgressKey) ||
        objc_getAssociatedObject(sheet, injectionKey))
        return;

    @try {
        UIView *sourceView = ActionSheetSourceView(sheet);
        id sourceNode = ValueForObjectKey(sourceView, @"asyncdisplaykit_node");
        id node = VideoNodeForSheet(sheet);
        if (!node)
            return;

        objc_setAssociatedObject(sheet, injectionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, injectionInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        __weak id weakSheet = sheet;
        id presentationNode = node;
        id presentationSourceNode = sourceNode;
        UICollectionViewCell *sourceCell = FeedCellForSourceView(sourceView);
        if (!sourceCell)
            sourceCell = FeedCellForMetadataObject(node);
        UIView *feedSourceView = sourceView;
        if (!sourceCell) {
            id nodeView = ValueForObjectKey(node, @"view");
            if ([nodeView isKindOfClass:[UIView class]]) {
                sourceCell = FeedCellForSourceView(nodeView);
                if (sourceCell)
                    feedSourceView = nodeView;
            }
        }
        YTAsyncCollectionView *sourceCollectionView = CollectionViewForFeedCell(sourceCell);
        YTShortsPlayerViewController *shortsPlayer = ShortsPlayerForObject(sourceView);
        BOOL isShorts = shortsPlayer != nil || ObjectLooksLikeShorts(sourceView) || ObjectLooksLikeShorts(node);
        if (!shortsPlayer && isShorts)
            shortsPlayer = VisibleShortsPlayer();
        if (shortsPlayer)
            CurrentShortsPlayer = shortsPlayer;
        CGSize iconSize = CGSizeMake(24.0, 24.0);

        YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
            actionWithTitle:LocalizedString(@"Block channel")
                  iconImage:[Util createBlockChannelIconWithSize:iconSize]
             secondaryIconImage:nil
         accessibilityIdentifier:nil
                handler:^ {
                      ResolveActionVideoInfo(weakSheet,
                                             presentationNode,
                                             presentationSourceNode,
                                             sourceView,
                                             YES,
                                             0,
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
                                                     RemoveBlockedFeedItem(feedSourceView,
                                                                           sourceCell,
                                                                           sourceCollectionView,
                                                                           info[@"id"],
                                                                           isShorts,
                                                                           shortsPlayer);
                                                 } @catch (__unused NSException *exception) {
                                                     SendToast(weakSheet, LocalizedString(@"Could not block this channel"));
                                                 }
                                             });
                  }];

        YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
            actionWithTitle:LocalizedString(@"Block video")
                  iconImage:[Util createBlockVideoIconWithSize:iconSize]
             secondaryIconImage:nil
         accessibilityIdentifier:nil
                handler:^ {
                      ResolveActionVideoInfo(weakSheet,
                                             presentationNode,
                                             presentationSourceNode,
                                             sourceView,
                                             NO,
                                             0,
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
                                                     RemoveBlockedFeedItem(feedSourceView,
                                                                           sourceCell,
                                                                           sourceCollectionView,
                                                                           videoId,
                                                                           isShorts,
                                                                           shortsPlayer);
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
        [sheet addAction:blockChannelAction];
        [sheet addAction:blockVideoAction];
        objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        objc_setAssociatedObject(sheet, injectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static id MetadataNodeForView(UIView *view, NSUInteger depth, BOOL bypassCache, UIView *sourceView);
static void FilterVisibleCells(YTAsyncCollectionView *collectionView);
static void CollapseBlockedCellGaps(YTAsyncCollectionView *collectionView);
static void RevealFeedContentAfterRemoval(YTAsyncCollectionView *collectionView,
                                          UICollectionViewCell *removedCell,
                                          CGRect removedFrame);
static BOOL CollectionViewIsEligibleForFiltering(YTAsyncCollectionView *collectionView);
static void RequestFiltering(YTAsyncCollectionView *collectionView);
static void ScheduleMetadataRetry(YTAsyncCollectionView *collectionView);

static void *BlockedCellKey = &BlockedCellKey;
static void *DirectBlockedVideoIDKey = &DirectBlockedVideoIDKey;
static void *GapCollapsePendingKey = &GapCollapsePendingKey;
static void *ShortsTransitionKey = &ShortsTransitionKey;
static void *FilterMetadataKey = &FilterMetadataKey;
static void *FilterNeedsRefreshKey = &FilterNeedsRefreshKey;
static void *FilterWaitingForIdleKey = &FilterWaitingForIdleKey;
static void *FilterRetryScheduledKey = &FilterRetryScheduledKey;
static void *FilterRetryCountKey = &FilterRetryCountKey;
static void *VisibleCellsKey = &VisibleCellsKey;

static NSMapTable *FeedCellsByVideoID(void) {
    static NSMapTable *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [NSMapTable strongToWeakObjectsMapTable];
    });
    return map;
}

static NSHashTable *TrackedFeedCollectionViews(void) {
    static NSHashTable *views;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        views = [NSHashTable weakObjectsHashTable];
    });
    return views;
}

static BOOL FilterMetadataIsComplete(NSDictionary *info) {
    return [info[@"id"] length] > 0 && [info[@"title"] length] > 0 && [info[@"channel"] length] > 0;
}

static void ClearFilterMetadata(UICollectionViewCell *cell) {
    if (cell)
        objc_setAssociatedObject(cell, FilterMetadataKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSDictionary *FilterMetadataForCell(UICollectionViewCell *cell, id node, BOOL isPagingCollection) {
    if (!cell || !node)
        return nil;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSDictionary *cached = objc_getAssociatedObject(cell, FilterMetadataKey);
    if (cached[@"node"] == node) {
        NSDictionary *info = cached[@"info"];
        NSTimeInterval age = now - [cached[@"timestamp"] doubleValue];
        NSTimeInterval validFor = FilterMetadataIsComplete(info) ? (isPagingCollection ? 4.0 : 3.0) : (isPagingCollection ? 1.0 : 1.2);
        if (age >= 0.0 && age < validFor)
            return info;
    }

    NSDictionary *info = [Util videoInfoFromNode:node] ?: @{};
    BOOL shouldReadRenderedView = isPagingCollection;
    if (!isPagingCollection && cached[@"node"] == node) {
        NSNumber *freshTimestamp = cached[@"freshTimestamp"];
        shouldReadRenderedView = !freshTimestamp || now - freshTimestamp.doubleValue >= 2.5;
    }
    NSNumber *freshTimestamp = nil;
    if (!FilterMetadataIsComplete(info) && shouldReadRenderedView) {
        NSDictionary *freshInfo = [Util freshVideoInfoFromNode:node sourceView:cell];
        if (freshInfo.count > 0)
            info = freshInfo;
        freshTimestamp = @(now);
    }
    NSMutableDictionary *cacheEntry = [@{ @"node": node, @"info": info, @"timestamp": @(now) } mutableCopy];
    if (freshTimestamp)
        cacheEntry[@"freshTimestamp"] = freshTimestamp;
    objc_setAssociatedObject(cell, FilterMetadataKey, cacheEntry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return info;
}

static void RefreshVisibleFeeds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (YTAsyncCollectionView *collectionView in TrackedFeedCollectionViews().allObjects) {
            if (!collectionView.window || !CollectionViewIsEligibleForFiltering(collectionView))
                continue;
            collectionView.lastFilterTime = 0.0;
            [collectionView setNeedsLayout];
            RequestFiltering(collectionView);
        }
    });
}

static BOOL CollectionViewIsScrolling(YTAsyncCollectionView *collectionView) {
    return collectionView.isDragging || collectionView.isDecelerating || collectionView.isTracking;
}

static BOOL CollectionViewIsHorizontallyArranged(YTAsyncCollectionView *collectionView) {
    if (!collectionView || collectionView.pagingEnabled || collectionView.bounds.size.width <= 0.0)
        return NO;

    CGFloat width = collectionView.bounds.size.width;
    CGFloat height = collectionView.bounds.size.height;
    NSArray<UICollectionViewCell *> *visibleCells = collectionView.visibleCells;
    for (NSUInteger firstIndex = 0; firstIndex < visibleCells.count; firstIndex++) {
        CGRect firstFrame = visibleCells[firstIndex].frame;
        for (NSUInteger secondIndex = firstIndex + 1; secondIndex < visibleCells.count; secondIndex++) {
            CGRect secondFrame = visibleCells[secondIndex].frame;
            CGFloat verticalDistance = fabs(CGRectGetMidY(firstFrame) - CGRectGetMidY(secondFrame));
            CGFloat horizontalDistance = fabs(CGRectGetMidX(firstFrame) - CGRectGetMidX(secondFrame));
            if (verticalDistance < MAX(24.0, height * 0.2) && horizontalDistance > width * 0.2)
                return YES;
        }
    }

    CGSize contentSize = collectionView.contentSize;
    return contentSize.width > width + 48.0 &&
           contentSize.width > MAX(contentSize.height * 1.25, width * 1.25);
}

static BOOL CollectionViewIsEligibleForFiltering(YTAsyncCollectionView *collectionView) {
    if (!collectionView || !collectionView.window || collectionView.visibleCells.count == 0)
        return NO;
    if (collectionView.pagingEnabled)
        return YES;
    return !CollectionViewIsHorizontallyArranged(collectionView);
}

static BOOL CollectionViewHasFilterableCells(YTAsyncCollectionView *collectionView) {
    if (!collectionView)
        return NO;
    if (collectionView.pagingEnabled)
        return collectionView.visibleCells.count > 0;

    Class asyncCellClass = NSClassFromString(@"_ASCollectionViewCell");
    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        if (![cell isKindOfClass:asyncCellClass])
            continue;
        _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
        if ([asCell respondsToSelector:@selector(node)] && [asCell node])
            return YES;
    }
    return NO;
}

static void RequestFiltering(YTAsyncCollectionView *collectionView) {
    if (!collectionView)
        return;
    objc_setAssociatedObject(collectionView, FilterNeedsRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [collectionView scheduleFiltering];
}

static void ScheduleFilteringAfterIdle(YTAsyncCollectionView *collectionView) {
    if (!collectionView || objc_getAssociatedObject(collectionView, FilterWaitingForIdleKey))
        return;

    objc_setAssociatedObject(collectionView, FilterWaitingForIdleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak YTAsyncCollectionView *weakCollectionView = collectionView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTAsyncCollectionView *strongCollectionView = weakCollectionView;
        if (!strongCollectionView)
            return;
        objc_setAssociatedObject(strongCollectionView, FilterWaitingForIdleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (CollectionViewIsScrolling(strongCollectionView)) {
            ScheduleFilteringAfterIdle(strongCollectionView);
            return;
        }
        strongCollectionView.lastFilterTime = 0.0;
        RequestFiltering(strongCollectionView);
    });
}

static void ScheduleMetadataRetry(YTAsyncCollectionView *collectionView) {
    if (!collectionView || objc_getAssociatedObject(collectionView, FilterRetryScheduledKey))
        return;

    NSUInteger retryCount = [objc_getAssociatedObject(collectionView, FilterRetryCountKey) unsignedIntegerValue];
    if (retryCount >= 8)
        return;

    objc_setAssociatedObject(collectionView, FilterRetryCountKey, @(retryCount + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(collectionView, FilterRetryScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak YTAsyncCollectionView *weakCollectionView = collectionView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTAsyncCollectionView *strongCollectionView = weakCollectionView;
        if (!strongCollectionView)
            return;
        objc_setAssociatedObject(strongCollectionView, FilterRetryScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!strongCollectionView.window || !CollectionViewIsEligibleForFiltering(strongCollectionView))
            return;
        strongCollectionView.lastFilterTime = 0.0;
        RequestFiltering(strongCollectionView);
    });
}

static BOOL CollectionViewHasBlockedCells(YTAsyncCollectionView *collectionView) {
    for (UIView *subview in collectionView.subviews) {
        if ([subview isKindOfClass:[UICollectionViewCell class]] &&
            objc_getAssociatedObject(subview, BlockedCellKey))
            return YES;
    }
    return NO;
}

static void CollapseBlockedCellGaps(YTAsyncCollectionView *collectionView) {
    if (!collectionView || collectionView.pagingEnabled || collectionView.bounds.size.height <= 0.0)
        return;

    NSMutableArray<UICollectionViewCell *> *cells = [NSMutableArray array];
    NSMutableArray<NSValue *> *blockedFrames = [NSMutableArray array];
    for (UIView *subview in collectionView.subviews) {
        if (![subview isKindOfClass:[UICollectionViewCell class]])
            continue;
        UICollectionViewCell *cell = (UICollectionViewCell *)subview;
        cell.transform = CGAffineTransformIdentity;
        [cells addObject:cell];
        if (objc_getAssociatedObject(cell, BlockedCellKey))
            [blockedFrames addObject:[NSValue valueWithCGRect:cell.frame]];
    }
    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        if (![cell isKindOfClass:[UICollectionViewCell class]])
            continue;
        if (![cells containsObject:cell]) {
            cell.transform = CGAffineTransformIdentity;
            [cells addObject:cell];
            if (objc_getAssociatedObject(cell, BlockedCellKey))
                [blockedFrames addObject:[NSValue valueWithCGRect:cell.frame]];
        }
    }
    if (blockedFrames.count == 0)
        return;

    for (UICollectionViewCell *cell in cells) {
        if (objc_getAssociatedObject(cell, BlockedCellKey))
            continue;

        CGRect frame = cell.frame;
        CGFloat offset = 0.0;
        for (NSValue *value in blockedFrames) {
            CGRect blockedFrame = value.CGRectValue;
            BOOL below = CGRectGetMinY(frame) >= CGRectGetMaxY(blockedFrame) - 1.0;
            BOOL overlapsHorizontally = CGRectGetMinX(frame) < CGRectGetMaxX(blockedFrame) &&
                                         CGRectGetMaxX(frame) > CGRectGetMinX(blockedFrame);
            if (!below || !overlapsHorizontally)
                continue;

            CGFloat slotHeight = CGRectGetHeight(blockedFrame);
            CGFloat nextMinY = CGFLOAT_MAX;
            for (UICollectionViewCell *candidate in cells) {
                CGRect candidateFrame = candidate.frame;
                BOOL candidateBelow = CGRectGetMinY(candidateFrame) > CGRectGetMinY(blockedFrame) + 1.0;
                BOOL candidateOverlaps = CGRectGetMinX(candidateFrame) < CGRectGetMaxX(blockedFrame) &&
                                         CGRectGetMaxX(candidateFrame) > CGRectGetMinX(blockedFrame);
                if (candidateBelow && candidateOverlaps)
                    nextMinY = MIN(nextMinY, CGRectGetMinY(candidateFrame));
            }
            if (nextMinY < CGFLOAT_MAX)
                slotHeight = MAX(slotHeight, nextMinY - CGRectGetMinY(blockedFrame));
            offset += slotHeight;
        }
        if (offset > 0.0)
            cell.transform = CGAffineTransformMakeTranslation(0.0, -offset);
    }
}

static void MarkGapCollapsePending(YTAsyncCollectionView *collectionView) {
    if (!collectionView || collectionView.pagingEnabled)
        return;
    objc_setAssociatedObject(collectionView, GapCollapsePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [collectionView setNeedsLayout];
}

static void RevealFeedContentAfterRemoval(YTAsyncCollectionView *collectionView,
                                          UICollectionViewCell *removedCell,
                                          CGRect removedFrame) {
    if (!collectionView || collectionView.pagingEnabled || removedFrame.size.height <= 0.0)
        return;

    BOOL hasVisibleUnblockedCell = NO;
    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        if (cell != removedCell && !objc_getAssociatedObject(cell, BlockedCellKey) && !cell.hidden && cell.alpha > 0.01) {
            hasVisibleUnblockedCell = YES;
            break;
        }
    }
    if (hasVisibleUnblockedCell)
        return;

    CGFloat visibleTop = collectionView.contentOffset.y + collectionView.contentInset.top;
    CGFloat visibleBottom = collectionView.contentOffset.y + collectionView.bounds.size.height - collectionView.contentInset.bottom;
    if (CGRectGetMaxY(removedFrame) < visibleTop - 1.0 || CGRectGetMinY(removedFrame) > visibleBottom + 1.0)
        return;

    CGFloat minimumOffsetY = -collectionView.contentInset.top;
    CGFloat maximumOffsetY = MAX(minimumOffsetY,
                                 collectionView.contentSize.height - collectionView.bounds.size.height + collectionView.contentInset.bottom);
    CGFloat targetOffsetY = MIN(maximumOffsetY, MAX(minimumOffsetY, collectionView.contentOffset.y + removedFrame.size.height));
    if (targetOffsetY <= collectionView.contentOffset.y + 1.0)
        return;

    [collectionView setContentOffset:CGPointMake(collectionView.contentOffset.x, targetOffsetY) animated:NO];
    [collectionView layoutIfNeeded];
}

static void FilterVisibleCells(YTAsyncCollectionView *collectionView) {
    if (!CollectionViewIsEligibleForFiltering(collectionView) || CollectionViewIsScrolling(collectionView))
        return;

    if (collectionView.pagingEnabled && collectionView.bounds.size.height > 0.0 &&
        objc_getAssociatedObject(collectionView, ShortsTransitionKey))
        return;

    if (collectionView.filtering)
        return;

    collectionView.filtering = YES;
    collectionView.lastFilterTime = CFAbsoluteTimeGetCurrent();
    objc_setAssociatedObject(collectionView, FilterNeedsRefreshKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [TrackedFeedCollectionViews() addObject:collectionView];
    @try {
        BOOL isPagingCollection = collectionView.pagingEnabled;
        BOOL hasBlockedCell = NO;
        BOOL hasIncompleteMetadata = NO;
        for (UICollectionViewCell *cell in collectionView.visibleCells) {
            NSString *directVideoId = objc_getAssociatedObject(cell, DirectBlockedVideoIDKey);
            BOOL directlyBlocked = objc_getAssociatedObject(cell, BlockedCellKey) != nil;
            id node = nil;
            if ([cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
                _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
                node = [asCell respondsToSelector:@selector(node)] ? [asCell node] : nil;
            } else if (isPagingCollection) {
                node = MetadataNodeForView(cell, 0, YES, cell);
            }
            if (!node) {
                ClearFilterMetadata(cell);
                if (directlyBlocked || directVideoId.length > 0) {
                    cell.hidden = YES;
                    cell.alpha = 0.0;
                    cell.userInteractionEnabled = NO;
                    cell.accessibilityElementsHidden = YES;
                } else {
                    objc_setAssociatedObject(cell, BlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    objc_setAssociatedObject(cell, DirectBlockedVideoIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    cell.hidden = NO;
                    cell.alpha = 1.0;
                    cell.userInteractionEnabled = YES;
                    cell.accessibilityElementsHidden = NO;
                }
                continue;
            }

            BOOL looksLikeActionVideo = NodeLooksLikeVideo(node);
            NSString *nodeClassName = NSStringFromClass([node class]).lowercaseString;
            BOOL isTextNode = [nodeClassName containsString:@"textnode"];
            if (!looksLikeActionVideo && !isPagingCollection && !isTextNode) {
                if (directlyBlocked || directVideoId.length > 0) {
                    cell.hidden = YES;
                    cell.alpha = 0.0;
                    cell.userInteractionEnabled = NO;
                    cell.accessibilityElementsHidden = YES;
                    continue;
                }
                objc_setAssociatedObject(cell, BlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(cell, DirectBlockedVideoIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                cell.hidden = NO;
                cell.alpha = 1.0;
                cell.userInteractionEnabled = YES;
                cell.accessibilityElementsHidden = NO;
                continue;
            }

            NSDictionary *info = FilterMetadataForCell(cell, node, isPagingCollection);
            if (!FilterMetadataIsComplete(info) && (looksLikeActionVideo || isPagingCollection))
                hasIncompleteMetadata = YES;
            NSString *metadataVideoId = info[@"id"];
            if (metadataVideoId.length > 0)
                [FeedCellsByVideoID() setObject:cell forKey:metadataVideoId];
            NSString *currentVideoId = info[@"id"];
            if (directVideoId.length > 0 && currentVideoId.length > 0 &&
                ![directVideoId isEqualToString:currentVideoId]) {
                objc_setAssociatedObject(cell, DirectBlockedVideoIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(cell, BlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                directVideoId = nil;
                directlyBlocked = NO;
            }
            BOOL blocked = directlyBlocked || [Util nodeContainsBlockedVideo:node videoInfo:info];
            if (directVideoId.length > 0)
                blocked = YES;
            objc_setAssociatedObject(cell, BlockedCellKey, blocked ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.hidden = blocked;
            cell.alpha = blocked ? 0.0 : 1.0;
            cell.userInteractionEnabled = !blocked;
            cell.accessibilityElementsHidden = blocked;
            hasBlockedCell = hasBlockedCell || blocked;
        }
        if (hasBlockedCell)
            MarkGapCollapsePending(collectionView);
        if (hasIncompleteMetadata)
            ScheduleMetadataRetry(collectionView);
        else
            objc_setAssociatedObject(collectionView, FilterRetryCountKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
    }
    collectionView.filtering = NO;
}

static UICollectionViewCell *FeedCellForSourceView(UIView *sourceView) {
    UIView *view = sourceView;
    while (view) {
        if ([view isKindOfClass:[UICollectionViewCell class]])
            return (UICollectionViewCell *)view;
        view = view.superview;
    }
    return nil;
}

static UICollectionViewCell *FeedCellForMetadataObject(id object) {
    for (NSString *key in @[@"view", @"displayView", @"_view"]) {
        id view = ValueForObjectKey(object, key);
        UICollectionViewCell *cell = FeedCellForSourceView(view);
        if (cell)
            return cell;
    }
    return nil;
}

static YTAsyncCollectionView *CollectionViewForFeedCell(UICollectionViewCell *cell) {
    UIView *view = cell;
    while (view) {
        if ([view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")])
            return (YTAsyncCollectionView *)view;
        view = view.superview;
    }
    return nil;
}

static id MetadataNodeForView(UIView *view, NSUInteger depth, BOOL bypassCache, UIView *sourceView) {
    if (![view isKindOfClass:[UIView class]] || depth > 20)
        return nil;

    id node = ValueForObjectKey(view, @"asyncdisplaykit_node");
    if (node) {
        BOOL looksLikeActionVideo = NodeLooksLikeVideo(node);
        NSString *nodeClassName = NSStringFromClass([node class]).lowercaseString;
        if (looksLikeActionVideo || [nodeClassName containsString:@"shorts"] ||
            [nodeClassName containsString:@"reel"])
            return node;
        NSDictionary *info = bypassCache ? [Util freshVideoInfoFromNode:node sourceView:sourceView]
                                         : [Util videoInfoFromNode:node];
        if (info[@"id"] || info[@"title"] || info[@"channel"])
            return node;
    }

    for (UIView *subview in view.subviews) {
        node = MetadataNodeForView(subview, depth + 1, bypassCache, sourceView);
        if (node)
            return node;
    }

    return nil;
}

static UICollectionViewCell *CellForVideoID(YTAsyncCollectionView *collectionView, NSString *videoId) {
    if (!collectionView)
        return nil;

    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        if (videoId.length == 0)
            return cell;
        NSDictionary *cached = objc_getAssociatedObject(cell, FilterMetadataKey);
        NSDictionary *cachedInfo = cached[@"info"];
        if ([cachedInfo[@"id"] isEqualToString:videoId])
            return cell;
        id node = MetadataNodeForView(cell, 0, YES, cell);
        NSDictionary *info = [Util videoInfoFromNode:node];
        if (![info[@"id"] isEqualToString:videoId])
            info = [Util freshVideoInfoFromNode:node sourceView:cell];
        if ([info[@"id"] isEqualToString:videoId])
            return cell;
    }

    return nil;
}

static UICollectionViewCell *VisibleFeedCellForVideoID(NSString *videoId,
                                                       YTAsyncCollectionView *preferredCollectionView,
                                                       UIView *sourceView) {
    if (videoId.length == 0)
        return nil;

    UICollectionViewCell *trackedCell = [FeedCellsByVideoID() objectForKey:videoId];
    NSDictionary *trackedMetadata = objc_getAssociatedObject(trackedCell, FilterMetadataKey);
    if (trackedCell && [trackedMetadata[@"info"][@"id"] isEqualToString:videoId])
        return trackedCell;

    NSMutableArray<YTAsyncCollectionView *> *collectionViews = [NSMutableArray array];
    if (preferredCollectionView)
        [collectionViews addObject:preferredCollectionView];
    YTAsyncCollectionView *sourceCollectionView = CollectionViewForFeedCell(FeedCellForSourceView(sourceView));
    if (sourceCollectionView && sourceCollectionView != preferredCollectionView)
        [collectionViews addObject:sourceCollectionView];

    for (YTAsyncCollectionView *collectionView in TrackedFeedCollectionViews().allObjects) {
        if (collectionView.window && ![collectionViews containsObject:collectionView])
            [collectionViews addObject:collectionView];
        if (collectionViews.count >= 6)
            break;
    }

    for (YTAsyncCollectionView *collectionView in collectionViews) {
        UICollectionViewCell *cell = CellForVideoID(collectionView, videoId);
        if (cell)
            return cell;
    }
    return nil;
}

static BOOL IsShortsCollectionView(YTAsyncCollectionView *collectionView) {
    return collectionView.pagingEnabled && collectionView.bounds.size.height > 0;
}

static BOOL AdvanceShortsPlayer(YTShortsPlayerViewController *preferredPlayer) {
    YTShortsPlayerViewController *player = preferredPlayer ?: CurrentShortsPlayer;
    if (!player)
        player = VisibleShortsPlayer();
    if (!player || ![player respondsToSelector:@selector(reelContentViewRequestsAdvanceToNextVideo:)])
        return NO;

    @try {
        CurrentShortsPlayer = player;
        [player reelContentViewRequestsAdvanceToNextVideo:nil];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL ScrollShortsCollection(YTAsyncCollectionView *collectionView, NSString *videoId) {
    if (!IsShortsCollectionView(collectionView))
        return NO;

    UICollectionViewCell *cell = CellForVideoID(collectionView, videoId);
    if (!cell)
        cell = collectionView.visibleCells.firstObject;
    NSIndexPath *indexPath = cell ? [collectionView indexPathForCell:cell] : nil;
    if (indexPath && indexPath.section < [collectionView numberOfSections]) {
        NSInteger nextItem = indexPath.item + 1;
        if (nextItem < [collectionView numberOfItemsInSection:indexPath.section]) {
            NSIndexPath *nextIndexPath = [NSIndexPath indexPathForItem:nextItem inSection:indexPath.section];
            [collectionView scrollToItemAtIndexPath:nextIndexPath
                                   atScrollPosition:UICollectionViewScrollPositionTop
                                           animated:YES];
            return YES;
        }
    }

    CGFloat pageHeight = MAX(collectionView.bounds.size.height, 1.0);
    CGFloat targetOffset = collectionView.contentOffset.y + pageHeight;
    [collectionView setContentOffset:CGPointMake(collectionView.contentOffset.x, targetOffset) animated:YES];
    return YES;
}

static void AdvanceShortsCollection(YTAsyncCollectionView *collectionView,
                                    NSString *videoId,
                                    YTShortsPlayerViewController *shortsPlayer) {
    if (!IsShortsCollectionView(collectionView))
        return;

    [collectionView layoutIfNeeded];
    if (AdvanceShortsPlayer(shortsPlayer))
        return;
    ScrollShortsCollection(collectionView, videoId);
}

static void RemoveBlockedFeedItem(UIView *sourceView,
                                  UICollectionViewCell *knownCell,
                                  YTAsyncCollectionView *knownCollectionView,
                                  NSString *videoId,
                                  BOOL isShorts,
                                  YTShortsPlayerViewController *shortsPlayer) {
    void (^remove)(void) = ^{
        UICollectionViewCell *cell = knownCell ?: FeedCellForSourceView(sourceView);
        YTAsyncCollectionView *collectionView = knownCollectionView ?: CollectionViewForFeedCell(cell);
        if (videoId.length > 0) {
            UICollectionViewCell *resolvedCell = VisibleFeedCellForVideoID(videoId, collectionView, sourceView);
            if (resolvedCell) {
                cell = resolvedCell;
                collectionView = CollectionViewForFeedCell(cell) ?: collectionView;
            }
        }
        if (!collectionView) {
            UIView *rootView = sourceView;
            while (rootView.superview) {
                NSString *className = NSStringFromClass([rootView class]).lowercaseString;
                if ([className containsString:@"reelwatchrootview"])
                    break;
                rootView = rootView.superview;
            }
            collectionView = AsyncCollectionViewInView(rootView, 0);
        }
        if (!collectionView && shortsPlayer)
            collectionView = AsyncCollectionViewInView(shortsPlayer.view, 0);
        if (videoId.length > 0 && !cell)
            cell = CellForVideoID(collectionView, videoId);
        if (isShorts || IsShortsCollectionView(collectionView)) {
            if (collectionView && IsShortsCollectionView(collectionView))
                objc_setAssociatedObject(collectionView, ShortsTransitionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BOOL advanced = AdvanceShortsPlayer(shortsPlayer);
            if (!advanced && collectionView)
                AdvanceShortsCollection(collectionView, videoId, shortsPlayer);
            if (!advanced && collectionView && IsShortsCollectionView(collectionView))
                ScrollShortsCollection(collectionView, videoId);
            if (collectionView && IsShortsCollectionView(collectionView)) {
                __weak YTAsyncCollectionView *weakCollectionView = collectionView;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    YTAsyncCollectionView *strongCollectionView = weakCollectionView;
                    if (!strongCollectionView)
                        return;
                    if (videoId.length > 0 && CellForVideoID(strongCollectionView, videoId))
                        ScrollShortsCollection(strongCollectionView, videoId);
                });
            }
            if (collectionView && IsShortsCollectionView(collectionView)) {
                __weak YTAsyncCollectionView *weakCollectionView = collectionView;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    YTAsyncCollectionView *strongCollectionView = weakCollectionView;
                    if (!strongCollectionView)
                        return;
                    objc_setAssociatedObject(strongCollectionView, ShortsTransitionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [strongCollectionView setNeedsLayout];
                    FilterVisibleCells(strongCollectionView);
                });
            }
            return;
        }
        if (cell && collectionView) {
            CGRect removedFrame = cell.frame;
            if (videoId.length > 0)
                objc_setAssociatedObject(cell, DirectBlockedVideoIDKey, videoId, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(cell, BlockedCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.hidden = YES;
            cell.alpha = 0.0;
            cell.userInteractionEnabled = NO;
            cell.accessibilityElementsHidden = YES;
            MarkGapCollapsePending(collectionView);
            [collectionView.collectionViewLayout invalidateLayout];
            [collectionView layoutIfNeeded];
            collectionView.lastFilterTime = 0.0;
            [collectionView scheduleFiltering];
            RevealFeedContentAfterRemoval(collectionView, cell, removedFrame);
        }
    };

    if (NSThread.isMainThread)
        remove();
    else
        dispatch_async(dispatch_get_main_queue(), remove);
}

%hook YTAsyncCollectionView

%property(nonatomic, assign) BOOL filtering;
%property(nonatomic, assign) BOOL filterScheduled;
%property(nonatomic, assign) NSTimeInterval lastFilterTime;

%new
- (void)scheduleFiltering {
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] != nil &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"])
        return;
    if (self.filterScheduled || objc_getAssociatedObject(self, FilterWaitingForIdleKey))
        return;
    if (!self.window || self.visibleCells.count == 0)
        return;
    if (!CollectionViewIsEligibleForFiltering(self) || !CollectionViewHasFilterableCells(self))
        return;

    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - self.lastFilterTime;
    NSTimeInterval delay = elapsed >= 0.75 ? 0.08 : MAX(0.08, 0.75 - elapsed);
    self.filterScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf.filterScheduled = NO;
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] != nil &&
            ![[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"])
            return;
        if (CollectionViewIsScrolling(strongSelf)) {
            ScheduleFilteringAfterIdle(strongSelf);
            return;
        }
        FilterVisibleCells(strongSelf);
    });
}

- (void)layoutSubviews {
    %orig;
    if (objc_getAssociatedObject(self, GapCollapsePendingKey)) {
        objc_setAssociatedObject(self, GapCollapsePendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CollapseBlockedCellGaps(self);
    }
    BOOL visibleCellsChanged = ![objc_getAssociatedObject(self, VisibleCellsKey) isEqualToArray:self.visibleCells];
    if (visibleCellsChanged) {
        objc_setAssociatedObject(self, VisibleCellsKey, self.visibleCells.copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RequestFiltering(self);
    } else if (self.visibleCells.count > 0 && CollectionViewHasBlockedCells(self)) {
        CollapseBlockedCellGaps(self);
    }
}

- (void)reloadData {
    objc_setAssociatedObject(self, FilterRetryCountKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, FilterRetryScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, VisibleCellsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    RequestFiltering(self);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        objc_setAssociatedObject(self, FilterRetryCountKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, VisibleCellsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RequestFiltering(self);
    }
}

%end

%hook _ASCollectionViewCell

- (void)prepareForReuse {
    ClearFilterMetadata(self);
    objc_setAssociatedObject(self, BlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, DirectBlockedVideoIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.transform = CGAffineTransformIdentity;
    %orig;
}

%end

%hook YTDefaultSheetController

- (void)addAction:(YTActionSheetAction *)action {
    %orig;
    AddBlockingActions(self, action);

}

%end

%hook YTActionSheetController

- (void)addAction:(YTActionSheetAction *)action {
    %orig;
    AddBlockingActions(self, action);
}

%end

%hook YTShortsPlayerViewController

- (void)viewWillAppear:(BOOL)animated {
    CurrentShortsPlayer = self;
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    CurrentShortsPlayer = self;
    %orig;
}

- (id)shortsContentView {
    CurrentShortsPlayer = self;
    id result = %orig;
    return result;
}

%end

%hook YTRightNavigationButtons
%property(retain, nonatomic) YTQTMButton *actionButton;

- (NSMutableArray *)buttons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    BOOL showButton = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                          ? YES
                          : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];

    [result removeObject:self.actionButton];
    [self.actionButton removeFromSuperview];
    if (!showButton)
        return result;

    if (!self.actionButton) {
        self.actionButton = [%c(YTQTMButton) iconButton];
        if ([self.actionButton respondsToSelector:@selector(enableNewTouchFeedback)])
            [self.actionButton enableNewTouchFeedback];
        self.actionButton.frame = CGRectMake(0, 0, 40, 40);
        [self.actionButton addTarget:self action:@selector(actionButtonPressed:)
                      forControlEvents:UIControlEventTouchUpInside];
    }

    NSInteger pageStyle = 0;
    Class pageStyleClass = %c(YTPageStyleController);
    if ([pageStyleClass respondsToSelector:@selector(pageStyle)])
        pageStyle = [pageStyleClass pageStyle];
    else {
        YTAppDelegate *delegate = (YTAppDelegate *)[UIApplication sharedApplication].delegate;
        YTAppViewControllerImpl *appViewController = ValueForObjectKey(delegate, @"_appViewController");
        if ([appViewController respondsToSelector:@selector(pageStyle)])
            pageStyle = [appViewController pageStyle];
    }

    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                         ? YES
                         : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"];
    UIColor *tintColor = pageStyle ? UIColor.whiteColor : UIColor.blackColor;
    if (!isEnabled)
        tintColor = [tintColor colorWithAlphaComponent:0.4];
    UIImage *image = [Util createBlockVideoIconWithSize:CGSizeMake(20, 20)];
    image = [%c(QTMIcon) tintImage:image color:tintColor];
    [self.actionButton setImage:image forState:UIControlStateNormal];
    [self addSubview:self.actionButton];
    [result insertObject:self.actionButton atIndex:0];
    return result;
}

- (NSMutableArray *)visibleButtons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    BOOL showButton = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                          ? YES
                          : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];
    [result removeObject:self.actionButton];
    if (showButton && self.actionButton)
        [result insertObject:self.actionButton atIndex:0];
    return result;
}

%new
- (void)actionButtonPressed:(UIButton *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isEnabled = [defaults objectForKey:@"GonerinoEnabled"] == nil ? YES : [defaults boolForKey:@"GonerinoEnabled"];
    BOOL newState = !isEnabled;
    [defaults setBool:newState forKey:@"GonerinoEnabled"];
    [defaults synchronize];

    [self buttons];
    RefreshVisibleFeeds();
    UIViewController *viewController = ViewControllerForObject(self);
    NSString *state = LocalizedString(newState ? @"enabled" : @"disabled");
    SendToast(viewController, [NSString stringWithFormat:@"%@ %@", LocalizedString(@"Gonerino"), state]);
}

%end

%ctor {
    %init;
}
