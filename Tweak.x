#import "Tweak.h"

%hook YTAsyncCollectionView

- (void)layoutSubviews {
    %orig;

    __weak typeof(self) weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        @try {
            NSArray *visibleCells              = [strongSelf visibleCells];
            NSMutableArray *indexPathsToRemove = [NSMutableArray array];

            for (UICollectionViewCell *cell in visibleCells) {
                if (![cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
                    continue;
                }

                _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
                if (![asCell respondsToSelector:@selector(node)]) {
                    continue;
                }

                id node = [asCell node];
                if (![node isKindOfClass:NSClassFromString(@"YTVideoWithContextNode")]) {
                    continue;
                }

                if ([Util nodeContainsBlockedVideo:node]) {
                    NSIndexPath *indexPath = [strongSelf indexPathForCell:cell];
                    if (indexPath) {
                        [indexPathsToRemove addObject:indexPath];
                    }
                }
            }

            if (indexPathsToRemove.count > 0) {
                [strongSelf
                    performBatchUpdates:^{ [strongSelf deleteItemsAtIndexPaths:indexPathsToRemove]; }
                             completion:nil];
            }
        } @catch (NSException *exception) {
            NSLog(@"[Gonerino] Exception in removeOffendingCells: %@", exception);
        }
    });
}

%new
- (void)removeOffendingCells {
    NSArray *visibleCells              = [self visibleCells];
    NSMutableArray *indexPathsToRemove = [NSMutableArray array];

    for (UICollectionViewCell *cell in visibleCells) {
        if ([cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
            _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
            if ([asCell respondsToSelector:@selector(node)]) {
                id node = [asCell node];
                if ([Util nodeContainsBlockedVideo:node]) {
                    NSIndexPath *indexPath = [self indexPathForCell:cell];
                    if (indexPath) {
                        [indexPathsToRemove addObject:indexPath];
                    }
                }
            }
        }
    }

    if (indexPathsToRemove.count > 0) {
        [self performBatchUpdates:^{ [self deleteItemsAtIndexPaths:indexPathsToRemove]; } completion:nil];
    }
}

%end

%hook YTDefaultSheetController

- (void)addAction:(YTActionSheetAction *)action {
    %orig;

    static void *blockActionKey = &blockActionKey;
    if (objc_getAssociatedObject(self, blockActionKey)) {
        return;
    }

    UIView *sourceView         = [self valueForKey:@"sourceView"];
    id node                    = [sourceView valueForKey:@"asyncdisplaykit_node"];
    NSString *debugDescription = [node debugDescription];

    if (![debugDescription containsString:@"YTVideoWithContextNode"]) {
        return;
    }

    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"cellNode = <YTVideoWithContextNode: (0x[0-9a-f]+)>"
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:debugDescription
                                                    options:0
                                                      range:NSMakeRange(0, debugDescription.length)];

    if (!match) {
        return;
    }

    if (![action.title isEqualToString:@"Share"] && ![action.title isEqualToString:@"Don't recommend channel"]) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    UIImage *blockIcon           = [self createBlockIconWithOriginalAction:action];

    YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block Channel"
              iconImage:blockIcon
                  style:0
                handler:^(YTActionSheetAction *action) {
                    __strong typeof(self) strongSelf = weakSelf;
                    @try {
                        UIView *sourceView = [strongSelf valueForKey:@"sourceView"];
                        id node            = [sourceView valueForKey:@"asyncdisplaykit_node"];

                        if ([node respondsToSelector:@selector(subnodes)]) {
                            for (id subnode in [node subnodes]) {
                                if ([subnode isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
                                    [Util extractVideoInfoFromNode:subnode
                                                        completion:^(NSString *videoId, NSString *videoTitle,
                                                                     NSString *ownerName) {
                                                            if (ownerName) {
                                                                [[ChannelManager sharedInstance]
                                                                    addBlockedChannel:ownerName];
                                                                UIViewController *viewController =
                                                                    (UIViewController *)strongSelf;
                                                                [[%c(YTToastResponderEvent)
                                                                    eventWithMessage:[NSString
                                                                                         stringWithFormat:@"Blocked %@",
                                                                                                          ownerName]
                                                                      firstResponder:viewController] send];
                                                            }
                                                        }];
                                    break;
                                }
                            }
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[Gonerino] Exception in block action: %@", e);
                    }
                }];

    YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block Video"
              iconImage:blockIcon
                  style:0
                handler:^(YTActionSheetAction *action) {
                    __strong typeof(self) strongSelf = weakSelf;
                    @try {
                        UIView *sourceView = [strongSelf valueForKey:@"sourceView"];
                        id node            = [sourceView valueForKey:@"asyncdisplaykit_node"];

                        if ([node respondsToSelector:@selector(subnodes)]) {
                            for (id subnode in [node subnodes]) {
                                if ([subnode isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
                                    [Util
                                        extractVideoInfoFromNode:subnode
                                                      completion:^(NSString *videoId, NSString *videoTitle,
                                                                   NSString *ownerName) {
                                                          if (videoId) {
                                                              [[VideoManager sharedInstance] addBlockedVideo:videoId
                                                                                                       title:videoTitle
                                                                                                     channel:ownerName];
                                                              UIViewController *viewController =
                                                                  (UIViewController *)strongSelf;
                                                              [[%c(YTToastResponderEvent)
                                                                  eventWithMessage:
                                                                      [NSString stringWithFormat:@"Blocked video: %@",
                                                                                                 videoTitle ?: videoId]
                                                                    firstResponder:viewController] send];
                                                              if ([strongSelf respondsToSelector:@selector(dismiss)]) {
                                                                  [strongSelf dismiss];
                                                              }
                                                          }
                                                      }];
                                    break;
                                }
                            }
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[Gonerino] Exception in block action: %@", e);
                    }
                }];

    objc_setAssociatedObject(self, blockActionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addAction:blockChannelAction];
    [self addAction:blockVideoAction];
}

%new
- (UIViewController *)findViewControllerForView:(UIView *)view {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = [responder nextResponder];
    }
    return nil;
}

%new
- (UIImage *)createBlockIconWithOriginalAction:(YTActionSheetAction *)originalAction {
    @try {
        CGSize targetSize = CGSizeMake(24, 24);
        if (originalAction) {
            UIImage *originalIcon = [originalAction valueForKey:@"_iconImage"];
            if (originalIcon) {
                targetSize = originalIcon.size;
            }
        }

        UIGraphicsBeginImageContextWithOptions(targetSize, NO, [UIScreen mainScreen].scale);
        if (!UIGraphicsGetCurrentContext()) {
            NSLog(@"[Gonerino] Failed to create graphics context");
            return nil;
        }

        UIBezierPath *circlePath =
            [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, targetSize.width - 4, targetSize.height - 4)];
        circlePath.lineWidth = 1.5;

        UIBezierPath *linePath = [UIBezierPath bezierPath];
        [linePath moveToPoint:CGPointMake(6, 6)];
        [linePath addLineToPoint:CGPointMake(targetSize.width - 6, targetSize.height - 6)];
        linePath.lineWidth = 1.5;

        [[UIColor whiteColor] setStroke];
        [circlePath stroke];
        [linePath stroke];

        UIImage *blockIcon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        return [blockIcon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    } @catch (NSException *exception) {
        NSLog(@"[Gonerino] Exception in createBlockIconWithOriginalAction: %@", exception);
        return nil;
    }
}

%end
