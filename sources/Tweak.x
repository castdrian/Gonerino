#import "Tweak.h"
#import <objc/runtime.h>

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
    if (!object || depth > 5)
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
        @"containerNode", @"node", @"_node", @"element", @"nodeModel", @"materializedInstance"
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
        @"videoController", @"watchController", @"parentResponder"
    ]) {
        id node = ActionSheetNodeCandidate(ValueForObjectKey(sheet, key));
        if (node)
            return node;
    }

    return nil;
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

static NSDictionary *MergedVideoInfo(NSDictionary *current, NSDictionary *fallback) {
    NSMutableDictionary *result = [fallback mutableCopy] ?: [NSMutableDictionary dictionary];
    [current enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        if ([value isKindOfClass:[NSString class]] && value.length > 0)
            result[key] = value;
    }];
    return [result copy];
}

static NSDictionary *ActionVideoInfo(id presentationNode, id presentationSourceNode, UIView *sourceView) {
    @try {
        NSDictionary *presentationInfo = [Util freshVideoInfoFromNode:presentationNode];
        NSDictionary *info = MergedVideoInfo(presentationInfo, nil);
        NSDictionary *sourceInfo = nil;
        if (presentationSourceNode && presentationSourceNode != presentationNode) {
            sourceInfo = [Util freshVideoInfoFromNode:presentationSourceNode];
            info = MergedVideoInfo(sourceInfo, info);

            id sourceMetadataNode = ActionMetadataNodeFromObject(presentationSourceNode, 0);
            if (sourceMetadataNode && sourceMetadataNode != presentationNode && sourceMetadataNode != presentationSourceNode) {
                NSDictionary *sourceMetadataInfo = [Util freshVideoInfoFromNode:sourceMetadataNode];
                sourceInfo = MergedVideoInfo(sourceMetadataInfo, sourceInfo);
                info = MergedVideoInfo(sourceMetadataInfo, info);
            }
        }

        id fallbackNode = VideoNodeFromView(sourceView, 0);
        NSDictionary *fallbackInfo = nil;
        if (fallbackNode && fallbackNode != presentationNode && fallbackNode != presentationSourceNode) {
            fallbackInfo = [Util freshVideoInfoFromNode:fallbackNode];
            info = MergedVideoInfo(fallbackInfo, info);
        }
        return info;
    } @catch (__unused NSException *exception) {
        return @{};
    }
}

static void RemoveBlockedFeedItem(UIView *sourceView, NSString *videoId);

static void ResolveActionVideoInfo(id presentationNode,
                                   id presentationSourceNode,
                                   UIView *sourceView,
                                   BOOL requiresChannel,
                                   NSUInteger attempt,
                                   void (^completion)(NSDictionary *info)) {
    if (!completion)
        return;

    NSDictionary *info = ActionVideoInfo(presentationNode, presentationSourceNode, sourceView);
    BOOL resolved = requiresChannel ? [info[@"channel"] length] > 0 : [info[@"id"] length] > 0;
    if (resolved || attempt >= 2) {
        completion(info);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ResolveActionVideoInfo(presentationNode,
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
        CGSize iconSize = CGSizeMake(24.0, 24.0);

        YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
            actionWithTitle:@"Block channel"
                  iconImage:[Util createBlockChannelIconWithSize:iconSize]
             secondaryIconImage:nil
         accessibilityIdentifier:nil
                  handler:^{
                      ResolveActionVideoInfo(presentationNode,
                                             presentationSourceNode,
                                             sourceView,
                                             YES,
                                             0,
                                             ^(NSDictionary *info) {
                                                 @try {
                                                     NSString *channel = info[@"channel"];
                                                     if (channel.length == 0) {
                                                         SendToast(weakSheet, @"Could not read the channel for this video");
                                                         return;
                                                     }

                                                     [[ChannelManager sharedInstance] addBlockedChannel:channel];
                                                     if (![[ChannelManager sharedInstance] isChannelBlocked:channel]) {
                                                         SendToast(weakSheet, @"Could not read a valid channel for this video");
                                                         return;
                                                     }
                                                     SendToast(weakSheet, [NSString stringWithFormat:@"Blocked %@", channel]);
                                                     RemoveBlockedFeedItem(sourceView, info[@"id"]);
                                                     if ([weakSheet respondsToSelector:@selector(dismiss)])
                                                         [weakSheet dismiss];
                                                 } @catch (__unused NSException *exception) {
                                                     SendToast(weakSheet, @"Could not block this channel");
                                                 }
                                             });
                  }];

        YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
            actionWithTitle:@"Block video"
                  iconImage:[Util createBlockVideoIconWithSize:iconSize]
             secondaryIconImage:nil
         accessibilityIdentifier:nil
                  handler:^{
                      ResolveActionVideoInfo(presentationNode,
                                             presentationSourceNode,
                                             sourceView,
                                             NO,
                                             0,
                                             ^(NSDictionary *info) {
                                                 @try {
                                                     NSString *videoId = info[@"id"];
                                                     if (videoId.length == 0) {
                                                         SendToast(weakSheet, @"Could not read the video for this item");
                                                         return;
                                                     }

                                                     [[VideoManager sharedInstance] addBlockedVideo:videoId
                                                                                               title:info[@"title"]
                                                                                             channel:info[@"channel"]];
                                                     SendToast(weakSheet,
                                                               [NSString stringWithFormat:@"Blocked video: %@",
                                                                                          info[@"title"] ?: videoId]);
                                                     RemoveBlockedFeedItem(sourceView, videoId);
                                                     if ([weakSheet respondsToSelector:@selector(dismiss)])
                                                         [weakSheet dismiss];
                                                 } @catch (__unused NSException *exception) {
                                                     SendToast(weakSheet, @"Could not block this video");
                                                 }
                                             });
                  }];

        if (!blockChannelAction || !blockVideoAction) {
            objc_setAssociatedObject(sheet, injectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        [sheet addAction:blockChannelAction];
        [sheet addAction:blockVideoAction];
        objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        objc_setAssociatedObject(sheet, injectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static id MetadataNodeForView(UIView *view, NSUInteger depth);
static void FilterVisibleCells(YTAsyncCollectionView *collectionView);

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

static void RefreshCollectionViewForSourceView(UIView *sourceView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = sourceView;
        while (view && ![view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")])
            view = view.superview;
        if ([view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")]) {
            [view setNeedsLayout];
            FilterVisibleCells((YTAsyncCollectionView *)view);
        } else {
            RefreshVisibleFeeds();
        }
    });
}

static BOOL CollectionViewIsScrolling(YTAsyncCollectionView *collectionView) {
    return collectionView.isDragging || collectionView.isDecelerating || collectionView.isTracking;
}

static void *BlockedCellKey = &BlockedCellKey;
static void *DirectBlockedVideoIDKey = &DirectBlockedVideoIDKey;
static void FilterVisibleCells(YTAsyncCollectionView *collectionView) {
    if (!collectionView || CollectionViewIsScrolling(collectionView))
        return;

    if (collectionView.filtering)
        return;

    collectionView.filtering = YES;
    collectionView.lastFilterTime = CFAbsoluteTimeGetCurrent();
    @try {
        for (UICollectionViewCell *cell in collectionView.visibleCells) {
            id node = nil;
            if ([cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
                _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
                node = [asCell respondsToSelector:@selector(node)] ? [asCell node] : nil;
            } else if (collectionView.pagingEnabled) {
                node = MetadataNodeForView(cell, 0);
            }
            if (!node)
                continue;

            NSDictionary *info = [Util videoInfoFromNode:node];
            if (!NodeLooksLikeActionVideo(node) && !(collectionView.pagingEnabled && info.count > 0)) {
                objc_setAssociatedObject(cell, BlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(cell, DirectBlockedVideoIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                cell.hidden = NO;
                cell.alpha = 1.0;
                cell.userInteractionEnabled = YES;
                cell.accessibilityElementsHidden = NO;
                continue;
            }

            NSString *directVideoId = objc_getAssociatedObject(cell, DirectBlockedVideoIDKey);
            NSString *currentVideoId = info[@"id"];
            if (directVideoId.length > 0 && currentVideoId.length > 0 &&
                ![directVideoId isEqualToString:currentVideoId]) {
                objc_setAssociatedObject(cell, DirectBlockedVideoIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                directVideoId = nil;
            }
            BOOL blocked = [Util nodeContainsBlockedVideo:node];
            if (directVideoId.length > 0)
                blocked = YES;
            objc_setAssociatedObject(cell, BlockedCellKey, blocked ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.hidden = blocked;
            cell.alpha = blocked ? 0.0 : 1.0;
            cell.userInteractionEnabled = !blocked;
            cell.accessibilityElementsHidden = blocked;
        }
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

static YTAsyncCollectionView *CollectionViewForFeedCell(UICollectionViewCell *cell) {
    UIView *view = cell;
    while (view) {
        if ([view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")])
            return (YTAsyncCollectionView *)view;
        view = view.superview;
    }
    return nil;
}

static id MetadataNodeForView(UIView *view, NSUInteger depth) {
    if (![view isKindOfClass:[UIView class]] || depth > 20)
        return nil;

    id node = ValueForObjectKey(view, @"asyncdisplaykit_node");
    if (node) {
        NSDictionary *info = [Util videoInfoFromNode:node];
        if (info[@"id"] || info[@"title"] || info[@"channel"])
            return node;
    }

    for (UIView *subview in view.subviews) {
        node = MetadataNodeForView(subview, depth + 1);
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
        id node = MetadataNodeForView(cell, 0);
        NSDictionary *info = [Util freshVideoInfoFromNode:node];
        if ([info[@"id"] isEqualToString:videoId])
            return cell;
    }

    return nil;
}

static BOOL IsShortsCollectionView(YTAsyncCollectionView *collectionView) {
    return collectionView.pagingEnabled && collectionView.bounds.size.height > 0;
}

static void AdvanceShortsCollection(YTAsyncCollectionView *collectionView, NSString *videoId) {
    if (!IsShortsCollectionView(collectionView))
        return;

    UICollectionViewCell *cell = CellForVideoID(collectionView, videoId);
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
    CGFloat maximumOffset = MAX(collectionView.contentSize.height - pageHeight, 0.0);
    CGFloat targetOffset = MIN(collectionView.contentOffset.y + pageHeight, maximumOffset);
    [collectionView setContentOffset:CGPointMake(collectionView.contentOffset.x, targetOffset) animated:YES];
}

static void DeleteFeedCell(UICollectionViewCell *cell, YTAsyncCollectionView *collectionView) {
    if (!cell || !collectionView)
        return;

    NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
    if (!indexPath || indexPath.section >= [collectionView numberOfSections] ||
        indexPath.item >= [collectionView numberOfItemsInSection:indexPath.section])
        return;

    @try {
        [collectionView performBatchUpdates:^{
            [collectionView deleteItemsAtIndexPaths:@[indexPath]];
        } completion:nil];
    } @catch (__unused NSException *exception) {
    }
}

static void RemoveBlockedFeedItem(UIView *sourceView, NSString *videoId) {
    void (^remove)(void) = ^{
        UICollectionViewCell *cell = FeedCellForSourceView(sourceView);
        YTAsyncCollectionView *collectionView = CollectionViewForFeedCell(cell);
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
            AdvanceShortsCollection(collectionView, videoId);
            return;
        }
        if (cell && collectionView) {
            if (videoId.length > 0)
                objc_setAssociatedObject(cell, DirectBlockedVideoIDKey, videoId, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(cell, BlockedCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.hidden = YES;
            cell.alpha = 0.0;
            cell.userInteractionEnabled = NO;
            cell.accessibilityElementsHidden = YES;
            DeleteFeedCell(cell, collectionView);
            [collectionView setNeedsLayout];
        }
        RefreshCollectionViewForSourceView(sourceView);
        RefreshVisibleFeeds();
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
    %orig;
    [self scheduleFiltering];
}

- (void)reloadData {
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
    SendToast(viewController, [NSString stringWithFormat:@"Gonerino %@", newState ? @"enabled" : @"disabled"]);
}

%end

%ctor {
    %init;
}
