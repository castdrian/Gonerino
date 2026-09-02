#import "Tweak.h"
#import "Localization.h"
#import <objc/runtime.h>

static id ValueForObjectKey(id object, NSString *key);

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

    @try {
        return [[node debugDescription] containsString:@"YTShortsPlayerViewController"];
    } @catch (__unused NSException *exception) {
    }

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
    if (!object || depth > 8)
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

    for (NSString *key in @[
        @"cellNode", @"parentResponder", @"parentNode", @"owningNode", @"supernode", @"superNode",
        @"containerNode", @"node", @"_node", @"element", @"nodeModel", @"materializedInstance",
        @"elementEntry", @"controller", @"viewController", @"closestViewController", @"context",
        @"instance", @"properties", @"allProperties", @"model", @"data", @"item", @"entry",
        @"renderer", @"videoRenderer", @"compactVideoRenderer", @"richItemRenderer", @"reelItemRenderer",
        @"player", @"activeVideo", @"currentPlayer", @"videoPlayer", @"navigationEndpoint", @"watchEndpoint"
    ]) {
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
        }
        return [info copy];
    } @catch (__unused NSException *exception) {
        return @{};
    }
}

static void RemoveBlockedFeedItem(UIView *sourceView,
                                  UICollectionViewCell *knownCell,
                                  YTAsyncCollectionView *knownCollectionView,
                                  NSString *videoId);
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
        CGSize iconSize = CGSizeMake(24.0, 24.0);

        YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
            actionWithTitle:LocalizedString(@"Block channel")
                  iconImage:[Util createBlockChannelIconWithSize:iconSize]
                          style:0
                         handler:^(__unused YTActionSheetAction *selectedAction) {
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
                                                     RemoveBlockedFeedItem(feedSourceView, sourceCell, sourceCollectionView, info[@"id"]);
                                                 } @catch (__unused NSException *exception) {
                                                     SendToast(weakSheet, LocalizedString(@"Could not block this channel"));
                                                 }
                                             });
                  }];

        YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
            actionWithTitle:LocalizedString(@"Block video")
                  iconImage:[Util createBlockVideoIconWithSize:iconSize]
                          style:0
                         handler:^(__unused YTActionSheetAction *selectedAction) {
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
                                                     RemoveBlockedFeedItem(feedSourceView, sourceCell, sourceCollectionView, videoId);
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

static void RefreshVisibleFeeds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (!keyWindow)
            keyWindow = [UIApplication sharedApplication].windows.firstObject;

        NSMutableArray *pendingViews = [NSMutableArray arrayWithObject:keyWindow ?: [NSNull null]];
        while (pendingViews.count > 0) {
            id object = pendingViews.lastObject;
            [pendingViews removeLastObject];
            if (![object isKindOfClass:[UIView class]])
                continue;

            UIView *view = object;
            if ([view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")]) {
                [view setNeedsLayout];
                FilterVisibleCells((YTAsyncCollectionView *)view);
            }
            [pendingViews addObjectsFromArray:view.subviews];
        }
    });
}

static BOOL CollectionViewIsScrolling(YTAsyncCollectionView *collectionView) {
    return collectionView.isDragging || collectionView.isDecelerating || collectionView.isTracking;
}

static void *BlockedCellKey = &BlockedCellKey;
static void *DirectBlockedVideoIDKey = &DirectBlockedVideoIDKey;
static void *CollapsedLayoutKey = &CollapsedLayoutKey;
static void *ShortsTransitionKey = &ShortsTransitionKey;

static void CollapseBlockedCellGaps(YTAsyncCollectionView *collectionView) {
    if (!collectionView || collectionView.pagingEnabled || objc_getAssociatedObject(collectionView, CollapsedLayoutKey))
        return;

    if (collectionView.bounds.size.height <= 0.0 ||
        collectionView.contentSize.height <= collectionView.bounds.size.height)
        return;

    NSMutableArray<UICollectionViewCell *> *cells = [NSMutableArray array];
    NSMutableArray<NSValue *> *blockedFrames = [NSMutableArray array];
    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        if (![cell isKindOfClass:[UICollectionViewCell class]])
            continue;
        [cells addObject:cell];
        if (objc_getAssociatedObject(cell, BlockedCellKey))
            [blockedFrames addObject:[NSValue valueWithCGRect:cell.frame]];
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
            if (below && overlapsHorizontally)
                offset += CGRectGetHeight(blockedFrame);
        }
        if (offset > 0.0) {
            frame.origin.y -= offset;
            cell.frame = frame;
        }
    }
    objc_setAssociatedObject(collectionView, CollapsedLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    if (!collectionView || CollectionViewIsScrolling(collectionView))
        return;

    if (collectionView.pagingEnabled && collectionView.bounds.size.height > 0.0 &&
        objc_getAssociatedObject(collectionView, ShortsTransitionKey))
        return;

    if (collectionView.filtering)
        return;

    collectionView.filtering = YES;
    collectionView.lastFilterTime = CFAbsoluteTimeGetCurrent();
    @try {
        BOOL isPagingCollection = collectionView.pagingEnabled;
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

            NSDictionary *info = isPagingCollection ? [Util freshVideoInfoFromNode:node sourceView:cell]
                                                    : [Util videoInfoFromNode:node];
            if (!NodeLooksLikeActionVideo(node) && !(isPagingCollection && info.count > 0)) {
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

            NSString *currentVideoId = info[@"id"];
            if (directVideoId.length > 0 && currentVideoId.length > 0 &&
                ![directVideoId isEqualToString:currentVideoId]) {
                objc_setAssociatedObject(cell, DirectBlockedVideoIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(cell, BlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                directVideoId = nil;
                directlyBlocked = NO;
            }
            BOOL blocked = directlyBlocked || [Util nodeContainsBlockedVideo:node videoInfo:isPagingCollection ? info : nil];
            if (directVideoId.length > 0)
                blocked = YES;
            objc_setAssociatedObject(cell, BlockedCellKey, blocked ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.hidden = blocked;
            cell.alpha = blocked ? 0.0 : 1.0;
            cell.userInteractionEnabled = !blocked;
            cell.accessibilityElementsHidden = blocked;
        }
        CollapseBlockedCellGaps(collectionView);
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
        id node = MetadataNodeForView(cell, 0, YES, cell);
        NSDictionary *info = [Util freshVideoInfoFromNode:node];
        if ([info[@"id"] isEqualToString:videoId])
            return cell;
    }

    return nil;
}

static BOOL IsShortsCollectionView(YTAsyncCollectionView *collectionView) {
    return collectionView.pagingEnabled && collectionView.bounds.size.height > 0;
}

static __weak YTShortsPlayerViewController *CurrentShortsPlayer;

static BOOL AdvanceShortsPlayer(void) {
    YTShortsPlayerViewController *player = CurrentShortsPlayer;
    BOOL responds = [player respondsToSelector:@selector(reelContentViewRequestsAdvanceToNextVideo:)];
    if (!player || !responds)
        return NO;

    @try {
        id contentView = ValueForObjectKey(player, @"shortsContentView");
        if (!contentView)
            contentView = ValueForObjectKey(player, @"contentView");
        if (!contentView)
            return NO;
        [player reelContentViewRequestsAdvanceToNextVideo:contentView];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void AdvanceShortsCollection(YTAsyncCollectionView *collectionView, NSString *videoId) {
    if (!IsShortsCollectionView(collectionView))
        return;

    [collectionView layoutIfNeeded];
    if (AdvanceShortsPlayer()) {
        return;
    }

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
            return;
        }
    }

    CGFloat pageHeight = MAX(collectionView.bounds.size.height, 1.0);
    CGFloat targetOffset = collectionView.contentOffset.y + pageHeight;
    [collectionView setContentOffset:CGPointMake(collectionView.contentOffset.x, targetOffset) animated:YES];
}

static void RemoveBlockedFeedItem(UIView *sourceView,
                                  UICollectionViewCell *knownCell,
                                  YTAsyncCollectionView *knownCollectionView,
                                  NSString *videoId) {
    void (^remove)(void) = ^{
        UICollectionViewCell *cell = knownCell ?: FeedCellForSourceView(sourceView);
        YTAsyncCollectionView *collectionView = knownCollectionView ?: CollectionViewForFeedCell(cell);
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
        if (IsShortsCollectionView(collectionView)) {
            objc_setAssociatedObject(collectionView, ShortsTransitionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            AdvanceShortsCollection(collectionView, videoId);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(collectionView, ShortsTransitionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [collectionView setNeedsLayout];
                FilterVisibleCells(collectionView);
            });
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
            [collectionView.collectionViewLayout invalidateLayout];
            [collectionView setNeedsLayout];
            FilterVisibleCells(collectionView);
            CollapseBlockedCellGaps(collectionView);
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
    if (self.filterScheduled || CollectionViewIsScrolling(self))
        return;
    if (CFAbsoluteTimeGetCurrent() - self.lastFilterTime < 0.35)
        return;

    self.filterScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf.filterScheduled = NO;
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] != nil &&
            ![[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"])
            return;
        FilterVisibleCells(strongSelf);
    });
}

- (void)layoutSubviews {
    objc_setAssociatedObject(self, CollapsedLayoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    [self scheduleFiltering];
}

- (void)reloadData {
    objc_setAssociatedObject(self, CollapsedLayoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    [self scheduleFiltering];
}

- (void)didMoveToWindow {
    %orig;
    if (self.window)
        [self scheduleFiltering];
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
