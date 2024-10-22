#import "Tweak.h"

#define TARGET_CHANNEL_NAME @"test"

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
                if ([self node:node containsChannelName:TARGET_CHANNEL_NAME]) {
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

- (BOOL)node:(id)node containsChannelName:(NSString *)channelName {
    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")]) {
        NSAttributedString *attributedText = [(ASTextNode *)node attributedText];
        NSString *text = [attributedText string];
        if ([text containsString:channelName]) {
            return YES;
        }
    }

    if ([node respondsToSelector:@selector(channelName)]) {
        NSString *nodeChannelName = [node channelName];
        if ([nodeChannelName isEqualToString:channelName]) {
            return YES;
        }
    }
    if ([node respondsToSelector:@selector(ownerName)]) {
        NSString *nodeOwnerName = [node ownerName];
        if ([nodeOwnerName isEqualToString:channelName]) {
            return YES;
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        NSArray *subnodes = [node subnodes];
        for (id subnode in subnodes) {
            if ([self node:subnode containsChannelName:channelName]) {
                return YES;
            }
        }
    }
    return NO;
}

%end