#import "Tweak.h"
#import "Localization.h"
#import <objc/runtime.h>

static id ValueForObjectKey(id object, NSString *key);
static UIViewController *ViewControllerForObject(id object);
static BOOL ObjectLooksLikeShorts(id object);
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

static void AssociateVideoIDWithNode(id node, NSString *videoID) {
    if (!node || videoID.length == 0)
        return;

    if ([[Util feedVideoIDForObject:node] isEqualToString:videoID])
        return;

    id current = node;
    for (NSUInteger depth = 0; depth < 8 && current; depth++) {
        [Util setFeedVideoID:videoID forObject:current];
        [Util invalidateVideoInfoForNode:current];
        id next = ValueForObjectKey(current, @"supernode");
        if (!next || next == current)
            break;
        current = next;
    }
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
    if ([candidate isKindOfClass:[UIView class]])
        return ValueForObjectKey(candidate, @"asyncdisplaykit_node");
    if ([candidate isKindOfClass:[UIViewController class]])
        return ValueForObjectKey(((UIViewController *)candidate).view, @"asyncdisplaykit_node");
    if (NodeLooksLikeActionVideo(candidate))
        return candidate;

    NSString *className = NSStringFromClass([candidate class]).lowercaseString;
    if ([className containsString:@"shorts"] ||
        [className containsString:@"reel"] ||
        [className containsString:@"video"] ||
        [className containsString:@"player"])
        return candidate;
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

static void AppendActionCandidateChildren(NSMutableArray *candidates,
                                          NSMutableSet *visited,
                                          id object) {
    if (!object || candidates.count >= 24)
        return;

    NSArray *children = ValueForObjectKey(object, @"subnodes");
    NSUInteger childCount = 0;
    for (id child in children) {
        if (childCount++ >= 16 || candidates.count >= 24)
            break;
        NSString *className = NSStringFromClass([child class]).lowercaseString;
        if (NodeLooksLikeActionVideo(child) || [className containsString:@"container"] ||
            [className containsString:@"element"] || [className containsString:@"inlineplayback"])
            AppendActionCandidate(candidates, visited, child);

        if (![className containsString:@"container"] && ![className containsString:@"element"])
            continue;
        NSArray *grandchildren = ValueForObjectKey(child, @"subnodes");
        NSUInteger grandchildCount = 0;
        for (id grandchild in grandchildren) {
            if (grandchildCount++ >= 16 || candidates.count >= 24)
                break;
            NSString *grandchildClassName = NSStringFromClass([grandchild class]).lowercaseString;
            if (NodeLooksLikeActionVideo(grandchild) || [grandchildClassName containsString:@"inlineplayback"])
                AppendActionCandidate(candidates, visited, grandchild);
        }
    }
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
        AppendActionCandidate(candidates, visited, cellNode);
        AppendActionCandidateChildren(candidates, visited, cellNode);
        id cellAsyncNode = ValueForObjectKey(sourceCell, @"asyncdisplaykit_node");
        AppendActionCandidate(candidates, visited, cellAsyncNode);
        AppendActionCandidateChildren(candidates, visited, cellAsyncNode);
    }

    UIView *ancestor = sourceView;
    NSUInteger ancestorDepth = 0;
    while (ancestor && ancestorDepth++ < 8) {
        id ancestorNode = ValueForObjectKey(ancestor, @"asyncdisplaykit_node");
        AppendActionCandidate(candidates, visited, ancestorNode);
        AppendActionCandidateChildren(candidates, visited, ancestorNode);
        ancestor = ancestor.superview;
    }

    BOOL shortsContext = ObjectLooksLikeShorts(sourceView) ||
                         ObjectLooksLikeShorts(presentationNode) ||
                         ObjectLooksLikeShorts(presentationSourceNode);
    if (shortsContext && CurrentShortsPlayer) {
        AppendActionCandidate(candidates, visited, CurrentShortsPlayer);
        id shortsContentView = ValueForObjectKey(CurrentShortsPlayer, @"shortsContentView");
        AppendActionCandidate(candidates, visited, ActionSheetNodeCandidate(shortsContentView) ?: shortsContentView);
        for (NSString *key in @[@"currentVideo", @"reelContentView", @"reelItem", @"reel", @"contentView",
                                @"videoNode", @"playerNode", @"currentPlayer", @"content"]) {
            id candidate = ValueForObjectKey(CurrentShortsPlayer, key);
            AppendActionCandidate(candidates, visited, ActionSheetNodeCandidate(candidate) ?: candidate);
        }
    }

    AppendActionCandidate(candidates, visited, presentationNode);
    AppendActionCandidate(candidates, visited, presentationSourceNode);
    AppendActionCandidate(candidates, visited, ActionSheetNodeCandidate(sourceView));

    for (NSString *key in @[
        @"sourceNode", @"_sourceNode", @"videoNode", @"_videoNode", @"playerNode", @"_playerNode",
        @"currentVideo", @"playerViewController", @"shortsPlayerViewController", @"currentPlayer",
        @"contentView", @"reelContentView"
    ]) {
        id candidate = ValueForObjectKey(sheet, key);
        id node = ActionSheetNodeCandidate(candidate);
        AppendActionCandidate(candidates, visited, node ?: candidate);
        AppendActionCandidateChildren(candidates, visited, node ?: candidate);
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

static void MergeCachedVideoInfo(NSMutableDictionary *result) {
    NSString *videoId = result[@"id"];
    if (videoId.length == 0)
        return;

    NSDictionary *cachedInfo = [[Util cachedFeedVideoMetadataForVideoID:videoId] dictionaryRepresentation];
    MergeAvailableVideoInfo(result, cachedInfo);
}

static YTShortsPlayerViewController *FindShortsPlayerInViewController(UIViewController *viewController,
                                                                        NSMutableSet *visited,
                                                                        NSUInteger depth) {
    Class shortsClass = NSClassFromString(@"YTShortsPlayerViewController");
    if (!viewController || depth > 8)
        return nil;

    NSValue *identity = [NSValue valueWithNonretainedObject:viewController];
    if ([visited containsObject:identity])
        return nil;
    [visited addObject:identity];

    NSString *viewControllerClassName = NSStringFromClass([viewController class]).lowercaseString;
    if ((shortsClass && [viewController isKindOfClass:shortsClass]) ||
        (([viewControllerClassName containsString:@"short"] || [viewControllerClassName containsString:@"reel"]) &&
         [viewController respondsToSelector:@selector(reelContentViewRequestsAdvanceToNextVideo:)]))
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

static NSDictionary *ActionVideoInfo(id sheet,
                                     id presentationNode,
                                     id presentationSourceNode,
                                     UIView *sourceView,
                                     BOOL requiresChannel) {
    @try {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        NSArray *candidates = ActionVideoCandidates(sheet, presentationNode, presentationSourceNode, sourceView);
        BOOL shortsContext = ObjectLooksLikeShorts(sourceView) ||
                             ObjectLooksLikeShorts(presentationNode) ||
                             ObjectLooksLikeShorts(presentationSourceNode);
        if (shortsContext) {
            YTShortsPlayerViewController *shortsPlayer = CurrentShortsPlayer ?: ShortsPlayerForObject(sourceView);
            id shortsContentView = ValueForObjectKey(shortsPlayer, @"shortsContentView");
            FeedMetadataRecord *shortsMetadata = [Util feedVideoMetadataFromShortsContentView:shortsContentView];
            MergeAvailableVideoInfo(info, shortsMetadata.dictionaryRepresentation);
        }

        for (id candidate in candidates) {
            FeedMetadataRecord *candidateMetadata = [Util feedVideoMetadataFromNode:candidate];
            NSDictionary *candidateInfo = [candidateMetadata dictionaryRepresentation];
            if (![candidateInfo isKindOfClass:[NSDictionary class]])
                continue;
            MergeAvailableVideoInfo(info, candidateInfo);
            MergeCachedVideoInfo(info);
            if ((requiresChannel && [info[@"channel"] length] > 0) ||
                (!requiresChannel && [info[@"id"] length] > 0))
                break;
        }
        FeedMetadataRecord *record = [[FeedMetadataRecord alloc] initWithVideoID:info[@"id"]
                                                                             title:info[@"title"]
                                                                           channel:info[@"channel"]];
        for (id candidate in candidates)
            [Util rememberFeedVideoMetadata:record forNode:candidate];
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

static void *ActionMetadataKey = &ActionMetadataKey;
static void *FeedNodeCellKey = &FeedNodeCellKey;

static void ResolveActionVideoInfo(id sheet,
                                   id presentationNode,
                                   id presentationSourceNode,
                                   UIView *sourceView,
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

    UIView *currentSourceView = sourceView ?: ActionSheetSourceView(sheet);
    NSDictionary *info = ActionVideoInfo(sheet,
                                         presentationNode,
                                         presentationSourceNode,
                                         currentSourceView,
                                         requiresChannel);
    completion(info);
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
        BOOL sourceLooksLikeShorts = ObjectLooksLikeShorts(sourceView) || ObjectLooksLikeShorts(sourceNode);
        YTShortsPlayerViewController *shortsPlayer = sourceLooksLikeShorts ? ShortsPlayerForObject(sourceView) : nil;
        if (sourceLooksLikeShorts && !shortsPlayer)
            shortsPlayer = VisibleShortsPlayer();
        if (shortsPlayer)
            CurrentShortsPlayer = shortsPlayer;
        id node = ActionVideoCandidates(sheet, nil, sourceNode, sourceView).firstObject;
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
        BOOL isShorts = shortsPlayer != nil || ObjectLooksLikeShorts(sourceView) || ObjectLooksLikeShorts(node);
        if (!shortsPlayer && isShorts)
            shortsPlayer = VisibleShortsPlayer();
        if (shortsPlayer)
            CurrentShortsPlayer = shortsPlayer;
        CGSize iconSize = CGSizeMake(24.0, 24.0);
        NSDictionary *capturedMetadata = ActionVideoInfo(sheet, presentationNode, presentationSourceNode, sourceView, YES);
        objc_setAssociatedObject(sheet,
                                 ActionMetadataKey,
                                 capturedMetadata ?: @{},
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);

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

static void RefreshVisibleFeeds(void) {
    [Util refreshFeedViews];
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
    UICollectionViewCell *associatedCell = objc_getAssociatedObject(object, FeedNodeCellKey);
    if ([associatedCell isKindOfClass:[UICollectionViewCell class]])
        return associatedCell;

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

static UICollectionViewCell *CellForVideoID(YTAsyncCollectionView *collectionView, NSString *videoId) {
    if (!collectionView)
        return nil;

    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        if (videoId.length == 0)
            return cell;
        id node = nil;
        if ([cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
            _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
            node = [asCell respondsToSelector:@selector(node)] ? [asCell node] : nil;
        }
        node = node ?: ValueForObjectKey(cell, @"asyncdisplaykit_node");
        FeedMetadataRecord *metadata = [Util feedVideoMetadataFromNode:node];
        if ([metadata.videoID isEqualToString:videoId])
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

static void RemoveBlockedFeedItem(UIView *sourceView,
                                  UICollectionViewCell *knownCell,
                                  YTAsyncCollectionView *knownCollectionView,
                                  NSString *videoId,
                                  BOOL isShorts,
                                  YTShortsPlayerViewController *shortsPlayer) {
    void (^remove)(void) = ^{
        UICollectionViewCell *cell = knownCell ?: FeedCellForSourceView(sourceView);
        YTAsyncCollectionView *collectionView = knownCollectionView ?: CollectionViewForFeedCell(cell);

        if (isShorts || IsShortsCollectionView(collectionView)) {
            AdvanceShortsPlayer(shortsPlayer);
            if (collectionView && IsShortsCollectionView(collectionView))
                ScrollShortsCollection(collectionView, videoId);
            return;
        }

        if (collectionView) {
            @try {
                [collectionView reloadData];
                return;
            } @catch (__unused NSException *exception) {
            }
        }
        [Util refreshFeedViews];
    };

    if (NSThread.isMainThread)
        remove();
    else
        dispatch_async(dispatch_get_main_queue(), remove);
}

static BOOL FilterableNode(id node) {
    if (!node)
        return NO;

    NSString *className = NSStringFromClass([node class]).lowercaseString;
    if ([className containsString:@"shelf"] || [className containsString:@"section"] ||
        [className containsString:@"collection"] || [className containsString:@"scrollablepage"])
        return NO;
    Class videoNodeClass = NSClassFromString(@"YTVideoNode");
    Class contextVideoNodeClass = NSClassFromString(@"YTVideoWithContextNode");
    Class elementCellNodeClass = NSClassFromString(@"ELMCellNode");
    Class textNodeClass = NSClassFromString(@"ASTextNode");
    return (videoNodeClass && [node isKindOfClass:videoNodeClass]) ||
           (contextVideoNodeClass && [node isKindOfClass:contextVideoNodeClass]) ||
           (elementCellNodeClass && [node isKindOfClass:elementCellNodeClass]) ||
           (textNodeClass && [node isKindOfClass:textNodeClass]) ||
           [className containsString:@"short"] || [className containsString:@"reel"];
}

static id FilteredNodeForBlockedVideo(NSIndexPath *indexPath) {
    ASCellNode *node = [NSClassFromString(@"ASCellNode") new];
    if (!node)
        return nil;
    ASLayoutElementStyle *style = [node style];
    if ([style respondsToSelector:@selector(setPreferredSize:)])
        style.preferredSize = CGSizeZero;
    return node;
}

static id FilterNodeAtCollectionBoundary(UICollectionView *collectionView,
                                         NSIndexPath *indexPath,
                                         id node) {
    if (!FilterableNode(node))
        return node;

    [Util registerFeedView:collectionView];
    FeedMetadataRecord *metadata = [Util feedVideoMetadataFromNode:node];
    BOOL blocked = [Util filteringEnabled] && [Util nodeContainsBlockedVideo:node metadata:metadata];
    if (!blocked)
        return node;

    id filteredNode = FilteredNodeForBlockedVideo(indexPath);
    return filteredNode ?: node;
}

%hook ELMCellNode

- (void)setElement:(id)element {
    %orig;
    [Util invalidateVideoInfoForNode:self];
}

%end

%hook ASCollectionView

- (id)nodeForItemAtIndexPath:(NSIndexPath *)indexPath {
    id node = %orig;
    return FilterNodeAtCollectionBoundary((UICollectionView *)self, indexPath, node);
}

- (UICollectionViewCell *)cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = %orig;
    if (!cell)
        return nil;

    id node = ValueForObjectKey(cell, @"node");
    if (!node)
        node = ValueForObjectKey(cell, @"asyncdisplaykit_node");
    if (node)
        objc_setAssociatedObject(node, FeedNodeCellKey, cell, OBJC_ASSOCIATION_ASSIGN);
    [Util registerFeedView:(UICollectionView *)self];
    return cell;
}

%end

%hook YTAsyncCollectionView

- (id)nodeForItemAtIndexPath:(NSIndexPath *)indexPath {
    id node = %orig;
    return FilterNodeAtCollectionBoundary((UICollectionView *)self, indexPath, node);
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
    if (videoID.length > 0) {
        [Util setFeedVideoID:videoID forObject:image];
        [Util invalidateVideoInfoForNode:self];
    }
    %orig;
}

%end

static void *NavigationButtonOwnersKey = &NavigationButtonOwnersKey;
static void *NavigationButtonImageKey = &NavigationButtonImageKey;
static void *NavigationButtonImagePageStyleKey = &NavigationButtonImagePageStyleKey;
static void *NavigationButtonStateKey = &NavigationButtonStateKey;
static void *NavigationButtonInstalledKey = &NavigationButtonInstalledKey;

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

static NSInteger CurrentPageStyle(void) {
    NSInteger pageStyle = 0;
    Class pageStyleClass = %c(YTPageStyleController);
    if ([pageStyleClass respondsToSelector:@selector(pageStyle)])
        return [pageStyleClass pageStyle];

    YTAppDelegate *delegate = (YTAppDelegate *)[UIApplication sharedApplication].delegate;
    YTAppViewControllerImpl *appViewController = ValueForObjectKey(delegate, @"_appViewController");
    if ([appViewController respondsToSelector:@selector(pageStyle)])
        pageStyle = [appViewController pageStyle];
    return pageStyle;
}

static void PrepareNavigationButton(YTRightNavigationButtons *owner) {
    if (!owner)
        return;

    [NavigationButtonOwners() addObject:owner];
    if (!owner.actionButton) {
        owner.actionButton = [%c(YTQTMButton) iconButton];
        if ([owner.actionButton respondsToSelector:@selector(enableNewTouchFeedback)])
            [owner.actionButton enableNewTouchFeedback];
        owner.actionButton.frame = CGRectMake(0, 0, 40, 40);
        owner.actionButton.imageView.contentMode = UIViewContentModeCenter;
        owner.actionButton.adjustsImageWhenHighlighted = NO;
        [owner.actionButton addTarget:owner action:@selector(actionButtonPressed:)
                      forControlEvents:UIControlEventTouchUpInside];
    }
    if (!objc_getAssociatedObject(owner, NavigationButtonInstalledKey)) {
        [owner addSubview:owner.actionButton];
        objc_setAssociatedObject(owner, NavigationButtonInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSArray<UIImage *> *NavigationButtonImages(YTRightNavigationButtons *owner, NSInteger pageStyle) {
    NSNumber *cachedPageStyle = objc_getAssociatedObject(owner, NavigationButtonImagePageStyleKey);
    NSArray<UIImage *> *images = objc_getAssociatedObject(owner, NavigationButtonImageKey);
    if (images && cachedPageStyle.integerValue == pageStyle)
        return images;

    UIColor *tintColor = pageStyle ? UIColor.whiteColor : UIColor.blackColor;
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

    PrepareNavigationButton(owner);

    BOOL shouldShow = ShouldShowNavigationButton();
    BOOL isEnabled = [Util filteringEnabled];
    NSInteger pageStyle = CurrentPageStyle();
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
        owner.actionButton.tintColor = pageStyle ? UIColor.whiteColor : UIColor.blackColor;
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
    return owner;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    YTRightNavigationButtons *owner = %orig;
    PrepareNavigationButton(owner);
    return owner;
}

- (NSMutableArray *)buttons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    UpdateNavigationButton(self);
    if (ShouldShowNavigationButton() && ![result containsObject:self.actionButton])
        [result insertObject:self.actionButton atIndex:0];
    return result;
}

- (NSMutableArray *)visibleButtons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    UpdateNavigationButton(self);
    if (ShouldShowNavigationButton() && ![result containsObject:self.actionButton])
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
    [Util refreshPreferenceSnapshot];

    [[NSNotificationCenter defaultCenter] postNotificationName:FeedFilterStateDidChangeNotification object:nil];
    UpdateNavigationButton(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        RefreshVisibleFeeds();
    });
    UIViewController *viewController = ViewControllerForObject(self);
    NSString *state = LocalizedString(newState ? @"enabled" : @"disabled");
    SendToast(viewController, [NSString stringWithFormat:@"%@ %@", LocalizedString(@"Gonerino"), state]);
}

%end

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter] addObserverForName:FeedFilterStateDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
                                                      RefreshNavigationButtons();
                                                  }];
}
