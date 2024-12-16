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

                if ([strongSelf nodeContainsBlockedChannelName:node] || [strongSelf nodeContainsBlockedVideo:node]) {
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
                if ([self nodeContainsBlockedChannelName:node] || [self nodeContainsBlockedVideo:node]) {
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

%new
- (BOOL)nodeContainsBlockedVideo:(id)node {
    if ([node respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *accessibilityLabel = [node accessibilityLabel];
        if (accessibilityLabel) {
            if ([[WordManager sharedInstance] isWordBlocked:accessibilityLabel]) {
                NSLog(@"[Gonerino] Removed video with blocked word in title: %@", accessibilityLabel);
                return YES;
            }

            NSArray *components = [accessibilityLabel componentsSeparatedByString:@" - "];
            if (components.count >= 4) {
                NSInteger goToChannelIndex = -1;
                for (NSInteger i = 0; i < components.count; i++) {
                    if ([components[i] isEqualToString:@"Go to channel"]) {
                        goToChannelIndex = i;
                        break;
                    }
                }

                if (goToChannelIndex > 1) {
                    NSArray *titleComponents = [components subarrayWithRange:NSMakeRange(0, goToChannelIndex - 1)];
                    NSString *videoTitle     = [titleComponents componentsJoinedByString:@" - "];
                    if ([[VideoManager sharedInstance] isVideoBlocked:videoTitle]) {
                        NSLog(@"[Gonerino] Removed blocked video: %@", videoTitle);
                        return YES;
                    }
                }
            }
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        NSArray *subnodes = [node subnodes];
        for (id subnode in subnodes) {
            if ([self nodeContainsBlockedVideo:subnode]) {
                return YES;
            }
        }
    }

    return NO;
}

%new
- (BOOL)nodeContainsBlockedChannelName:(id)node {
    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")]) {
        NSAttributedString *attributedText = [(ASTextNode *)node attributedText];
        NSString *text = [attributedText string];
        
        if ([[WordManager sharedInstance] isWordBlocked:text]) {
            NSLog(@"[Gonerino] Removed content with blocked word: %@", text);
            return YES;
        }
        
        if ([text containsString:@" · "]) {
            NSArray *components = [text componentsSeparatedByString:@" · "];
            if (components.count >= 1) {
                NSString *potentialChannelName = components[0];
                if ([[ChannelManager sharedInstance] isChannelBlocked:potentialChannelName]) {
                    NSLog(@"[Gonerino] Removed content from blocked channel: %@", potentialChannelName);
                    return YES;
                }
            }
        }
    }

    if ([node respondsToSelector:@selector(channelName)]) {
        NSString *nodeChannelName = [node channelName];
        if ([[ChannelManager sharedInstance] isChannelBlocked:nodeChannelName]) {
            NSLog(@"[Gonerino] Removed content from blocked channel: %@", nodeChannelName);
            return YES;
        }
    }
    if ([node respondsToSelector:@selector(ownerName)]) {
        NSString *nodeOwnerName = [node ownerName];
        if ([[ChannelManager sharedInstance] isChannelBlocked:nodeOwnerName]) {
            NSLog(@"[Gonerino] Removed content from blocked channel: %@", nodeOwnerName);
            return YES;
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        NSArray *subnodes = [node subnodes];
        for (id subnode in subnodes) {
            if ([self nodeContainsBlockedChannelName:subnode]) {
                return YES;
            }
        }
    }

    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")]) {
        NSAttributedString *attributedText = [(ASTextNode *)node attributedText];
        NSString *text                     = [attributedText string];

        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoPeopleWatched"] &&
            [text isEqualToString:@"People also watched this video"]) {
            NSLog(@"[Gonerino] Removed 'People also watched' section");
            return YES;
        }

        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoMightLike"] &&
            [text isEqualToString:@"You might also like this"]) {
            NSLog(@"[Gonerino] Removed 'You might also like' section");
            return YES;
        }
    }
    return NO;
}

%end

@interface NSObject (Properties)
- (NSString *)title;
- (NSString *)text;
- (NSAttributedString *)attributedText;
- (NSString *)name;
- (NSString *)channelName;
- (NSString *)ownerName;
- (id)videoDetails;
- (id)metadata;
@end

%hook YTDefaultSheetController

%new
- (void)extractChannelNameFromNode:(id)node completion:(void (^)(NSString *channelName))completion {
    if (!completion)
        return;

    if ([node isKindOfClass:NSClassFromString(@"ELMTextNode")]) {
        if ([node respondsToSelector:@selector(attributedText)]) {
            NSAttributedString *attributedText = [node attributedText];
            NSString *text                     = [attributedText string];
            if (text && [text containsString:@" · "]) {
                NSArray *components = [text componentsSeparatedByString:@" · "];
                if (components.count >= 1 && ![components[0] containsString:@":"]) {
                    completion(components[0]);
                    return;
                }
            }
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        NSArray *subnodes = [node subnodes];
        for (id subnode in subnodes) {
            void (^completionCopy)(NSString *) = [completion copy];
            [self extractChannelNameFromNode:subnode completion:completionCopy];
        }
    }
}

%new
- (NSString *)extractVideoTitleFromNode:(id)node {
    if ([node respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *accessibilityLabel = [node accessibilityLabel];
        if (accessibilityLabel) {
            NSArray *components = [accessibilityLabel componentsSeparatedByString:@" - "];
            if (components.count >= 4) {
                NSInteger goToChannelIndex = -1;
                for (NSInteger i = 0; i < components.count; i++) {
                    if ([components[i] isEqualToString:@"Go to channel"]) {
                        goToChannelIndex = i;
                        break;
                    }
                }

                if (goToChannelIndex > 1) {
                    NSArray *titleComponents = [components subarrayWithRange:NSMakeRange(0, goToChannelIndex - 1)];
                    return [titleComponents componentsJoinedByString:@" - "];
                }
            }
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        NSArray *subnodes = [node subnodes];
        for (id subnode in subnodes) {
            NSString *title = [self extractVideoTitleFromNode:subnode];
            if (title) {
                return title;
            }
        }
    }

    return nil;
}

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

                        NSString *debugDescription = [node debugDescription];
                        NSRegularExpression *regex = [NSRegularExpression
                            regularExpressionWithPattern:@"cellNode = <YTVideoWithContextNode: (0x[0-9a-f]+)>"
                                                 options:0
                                                   error:nil];
                        NSTextCheckingResult *match =
                            [regex firstMatchInString:debugDescription
                                              options:0
                                                range:NSMakeRange(0, debugDescription.length)];

                        if (match) {
                            NSString *address = [debugDescription substringWithRange:[match rangeAtIndex:1]];
                            void *videoNodePtr;
                            sscanf([address UTF8String], "%p", &videoNodePtr);
                            id videoNode = (__bridge id)videoNodePtr;

                            if ([videoNode isKindOfClass:NSClassFromString(@"YTVideoWithContextNode")]) {
                                [self extractChannelNameFromNode:videoNode
                                                      completion:^(NSString *channelName) {
                                                          if (channelName) {
                                                              [[ChannelManager sharedInstance]
                                                                  addBlockedChannel:channelName];
                                                              UIViewController *viewController =
                                                                  (UIViewController *)strongSelf;
                                                              [[%c(YTToastResponderEvent)
                                                                  eventWithMessage:[NSString
                                                                                       stringWithFormat:@"Blocked %@",
                                                                                                        channelName]
                                                                    firstResponder:viewController] send];
                                                          }
                                                      }];
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

                        NSString *debugDescription = [node debugDescription];
                        NSRegularExpression *regex = [NSRegularExpression
                            regularExpressionWithPattern:@"cellNode = <YTVideoWithContextNode: (0x[0-9a-f]+)>"
                                                 options:0
                                                   error:nil];
                        NSTextCheckingResult *match =
                            [regex firstMatchInString:debugDescription
                                              options:0
                                                range:NSMakeRange(0, debugDescription.length)];

                        if (match) {
                            NSString *address = [debugDescription substringWithRange:[match rangeAtIndex:1]];
                            void *videoNodePtr;
                            sscanf([address UTF8String], "%p", &videoNodePtr);
                            id videoNode = (__bridge id)videoNodePtr;

                            if ([videoNode isKindOfClass:NSClassFromString(@"YTVideoWithContextNode")]) {
                                NSString *videoTitle = [strongSelf extractVideoTitleFromNode:videoNode];
                                if (videoTitle) {
                                    [[VideoManager sharedInstance] addBlockedVideo:videoTitle];
                                    UIViewController *viewController = (UIViewController *)strongSelf;
                                    [[%c(YTToastResponderEvent)
                                        eventWithMessage:[NSString stringWithFormat:@"Blocked video: %@", videoTitle]
                                          firstResponder:viewController] send];
                                    [strongSelf dismiss];
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
