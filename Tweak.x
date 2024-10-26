#import "Tweak.h"

%hook YTAsyncCollectionView

- (void)layoutSubviews {
    %orig;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self removeOffendingCells];
    });
}

%new

- (void)removeOffendingCells {
    NSArray *visibleCells = [self visibleCells];
    NSMutableArray *indexPathsToRemove = [NSMutableArray array];

    for (UICollectionViewCell *cell in visibleCells) {
        if ([cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
            _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
            if ([asCell respondsToSelector:@selector(node)]) {
                id node = [asCell node];
                if ([self nodeContainsBlockedChannelName:node]) {
                    NSIndexPath *indexPath = [self indexPathForCell:cell];
                    if (indexPath) {
                        [indexPathsToRemove addObject:indexPath];
                    }
                }
            }
        }
    }

    if (indexPathsToRemove.count > 0) {
        [self performBatchUpdates:^{
            [self deleteItemsAtIndexPaths:indexPathsToRemove];
        } completion:nil];
    }
}

%new

- (BOOL)nodeContainsBlockedChannelName:(id)node {
    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")]) {
        NSAttributedString *attributedText = [(ASTextNode *)node attributedText];
        NSString *text = [attributedText string];
        for (NSString *channelName in [[ChannelManager sharedInstance] blockedChannels]) {
            if ([text containsString:channelName]) {
                return YES;
            }
        }
    }

    if ([node respondsToSelector:@selector(channelName)]) {
        NSString *nodeChannelName = [node channelName];
        if ([[ChannelManager sharedInstance] isChannelBlocked:nodeChannelName]) {
            return YES;
        }
    }
    if ([node respondsToSelector:@selector(ownerName)]) {
        NSString *nodeOwnerName = [node ownerName];
        if ([[ChannelManager sharedInstance] isChannelBlocked:nodeOwnerName]) {
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
    return NO;
}

%end

%hook YTDefaultSheetController

- (void)addAction:(YTActionSheetAction *)action {
    %orig;

    NSString *newActionIdentifier = @"gonerino_block_channel";

    NSArray *currentActions = [self valueForKey:@"_actions"];
    for (YTActionSheetAction *existingAction in currentActions) {
        if ([[existingAction valueForKey:@"_accessibilityIdentifier"] isEqualToString:newActionIdentifier]) {
            return;
        }
    }

    NSNumber *styleNumber = [action valueForKey:@"_style"];
    NSInteger style = styleNumber ? [styleNumber integerValue] : 0;

    UIImage *blockIcon = [self createBlockIconWithOriginalAction:action];

    __weak typeof(self) weakSelf = self;
    YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction) actionWithTitle:@"Block Channel"
                                                                             iconImage:blockIcon
                                                                                 style:style
                                                                              handler:^{
        @try {
            id contextElement = [weakSelf valueForKey:@"_contextElement"];
            UIViewController *parentVC = [weakSelf valueForKey:@"_parentResponder"];

            if (!contextElement) {
                return;
            }

            NSString *channelName = nil;
            if ([contextElement respondsToSelector:@selector(channelName)]) {
                channelName = [contextElement channelName];
            }
            else if ([contextElement respondsToSelector:@selector(ownerName)]) {
                channelName = [contextElement ownerName];
            }
            else if ([contextElement respondsToSelector:@selector(videoCreatorName)]) {
                channelName = [contextElement valueForKey:@"videoCreatorName"];
            }

            if (!channelName) {
                YTWatchController *watchController = [weakSelf valueForKey:@"_watchController"];
                if (watchController) {
                    id videoController = [watchController valueForKey:@"_singleVideoController"];
                    if (videoController) {
                        channelName = [videoController valueForKey:@"_channelName"];
                    }
                }
            }

            if (!channelName) {
                return;
            }

            [[ChannelManager sharedInstance] addBlockedChannel:channelName];

            [weakSelf dismiss];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (parentVC) {
                    [[%c(YTToastResponderEvent) eventWithMessage:[NSString stringWithFormat:@"Blocked channel: %@", channelName]
                                                firstResponder:parentVC] send];
                }
            });

        } @catch (NSException *e) {
            NSLog(@"[Gonerino] Error in block action handler: %@", e);
        }
    }];

    [blockChannelAction setValue:newActionIdentifier forKey:@"_accessibilityIdentifier"];
    %orig(blockChannelAction);
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
        
        UIBezierPath *circlePath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, targetSize.width - 4, targetSize.height - 4)];
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
