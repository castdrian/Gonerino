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
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            NSLog(@"[Gonerino] Block action handler called");
            NSLog(@"[Gonerino] Sheet controller: %@", strongSelf);
            
            // Try to get sourceView and examine it
            UIView *sourceView = nil;
            @try {
                sourceView = [strongSelf valueForKey:@"sourceView"];
                if ([sourceView isKindOfClass:NSClassFromString(@"_ASDisplayView")]) {
                    NSLog(@"[Gonerino] Found _ASDisplayView: %@", sourceView);
                    
                    // Try to get the node
                    if ([sourceView respondsToSelector:@selector(asyncdisplaykit_node)]) {
                        id node = [sourceView performSelector:@selector(asyncdisplaykit_node)];
                        NSLog(@"[Gonerino] Node: %@", node);
                        NSLog(@"[Gonerino] Node class: %@", [node class]);
                        
                        // Try to find YTVideoWithContextNode in the view hierarchy
                        NSMutableArray *viewsToCheck = [NSMutableArray arrayWithObject:sourceView];
                        while (viewsToCheck.count > 0) {
                            UIView *currentView = viewsToCheck.firstObject;
                            [viewsToCheck removeObjectAtIndex:0];
                            
                            // Check if this view is an _ASDisplayView
                            if ([currentView isKindOfClass:NSClassFromString(@"_ASDisplayView")]) {
                                id currentNode = [currentView performSelector:@selector(asyncdisplaykit_node)];
                                NSLog(@"[Gonerino] Checking node: %@ (%@)", currentNode, [currentNode class]);
                                
                                // Check if this is a video context node
                                if ([currentNode isKindOfClass:NSClassFromString(@"YTVideoWithContextNode")]) {
                                    NSLog(@"[Gonerino] Found video context node: %@", currentNode);
                                    
                                    // Try to get video
                                    if ([currentNode respondsToSelector:@selector(video)]) {
                                        id video = [currentNode performSelector:@selector(video)];
                                        NSLog(@"[Gonerino] Video: %@", video);
                                        
                                        if ([video respondsToSelector:@selector(channelName)]) {
                                            NSString *channelName = [video performSelector:@selector(channelName)];
                                            if (channelName) {
                                                NSLog(@"[Gonerino] Found channel name: %@", channelName);
                                                [[ChannelManager sharedInstance] addBlockedChannel:channelName];
                                                [strongSelf dismiss];
                                                return;
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // Add subviews to check
                            [viewsToCheck addObjectsFromArray:currentView.subviews];
                        }
                        
                        // If we didn't find it in the view hierarchy, try the parent view
                        UIView *parentView = sourceView.superview;
                        while (parentView) {
                            if ([parentView isKindOfClass:NSClassFromString(@"_ASDisplayView")]) {
                                id parentNode = [parentView performSelector:@selector(asyncdisplaykit_node)];
                                NSLog(@"[Gonerino] Checking parent node: %@ (%@)", parentNode, [parentNode class]);
                                
                                if ([parentNode isKindOfClass:NSClassFromString(@"YTVideoWithContextNode")]) {
                                    NSLog(@"[Gonerino] Found video context node in parent: %@", parentNode);
                                    
                                    // Log video context node methods
                                    unsigned int methodCount;
                                    Method *methods = class_copyMethodList([parentNode class], &methodCount);
                                    NSMutableArray *methodNames = [NSMutableArray array];
                                    
                                    for (unsigned int i = 0; i < methodCount; i++) {
                                        Method method = methods[i];
                                        SEL selector = method_getName(method);
                                        NSString *methodName = NSStringFromSelector(selector);
                                        [methodNames addObject:methodName];
                                    }
                                    
                                    free(methods);
                                    NSLog(@"[Gonerino] Video context node methods: %@", methodNames);
                                    
                                    // Try to get element
                                    if ([parentNode respondsToSelector:@selector(element)]) {
                                        @try {
                                            NSMethodSignature *elementSig = [parentNode methodSignatureForSelector:@selector(element)];
                                            NSInvocation *elementInvocation = [NSInvocation invocationWithMethodSignature:elementSig];
                                            [elementInvocation setTarget:parentNode];
                                            [elementInvocation setSelector:@selector(element)];
                                            [elementInvocation invoke];
                                            
                                            __unsafe_unretained id element = nil;
                                            [elementInvocation getReturnValue:&element];
                                            
                                            if (element) {
                                                NSLog(@"[Gonerino] Element: %@", element);
                                                NSLog(@"[Gonerino] Element class: %@", [element class]);
                                                
                                                // Log element methods
                                                unsigned int elementMethodCount;
                                                Method *elementMethods = class_copyMethodList([element class], &elementMethodCount);
                                                NSMutableArray *elementMethodNames = [NSMutableArray array];
                                                
                                                for (unsigned int i = 0; i < elementMethodCount; i++) {
                                                    Method method = elementMethods[i];
                                                    SEL selector = method_getName(method);
                                                    NSString *methodName = NSStringFromSelector(selector);
                                                    [elementMethodNames addObject:methodName];
                                                }
                                                
                                                free(elementMethods);
                                                NSLog(@"[Gonerino] Element methods: %@", elementMethodNames);
                                                
                                                // Try to get properties
                                                unsigned int propertyCount;
                                                objc_property_t *properties = class_copyPropertyList([element class], &propertyCount);
                                                NSMutableArray *propertyNames = [NSMutableArray array];
                                                
                                                for (unsigned int i = 0; i < propertyCount; i++) {
                                                    objc_property_t property = properties[i];
                                                    NSString *propertyName = @(property_getName(property));
                                                    [propertyNames addObject:propertyName];
                                                }
                                                
                                                free(properties);
                                                NSLog(@"[Gonerino] Element properties: %@", propertyNames);
                                                
                                                // Try to get video data directly from element
                                                SEL selectors[] = {
                                                    @selector(videoData),
                                                    @selector(video),
                                                    @selector(metadata),
                                                    @selector(channelName),
                                                    @selector(ownerName),
                                                    @selector(author)
                                                };
                                                
                                                for (int i = 0; i < sizeof(selectors)/sizeof(SEL); i++) {
                                                    if ([element respondsToSelector:selectors[i]]) {
                                                        NSMethodSignature *sig = [element methodSignatureForSelector:selectors[i]];
                                                        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
                                                        [invocation setTarget:element];
                                                        [invocation setSelector:selectors[i]];
                                                        [invocation invoke];
                                                        
                                                        __unsafe_unretained id result = nil;
                                                        [invocation getReturnValue:&result];
                                                        
                                                        NSLog(@"[Gonerino] Element result for %@: %@", NSStringFromSelector(selectors[i]), result);
                                                        
                                                        if ([result isKindOfClass:[NSString class]]) {
                                                            NSLog(@"[Gonerino] Found channel name: %@", result);
                                                            [[ChannelManager sharedInstance] addBlockedChannel:result];
                                                            [strongSelf dismiss];
                                                            return;
                                                        }
                                                    }
                                                }
                                                
                                                // Only try instance if we haven't found the channel name yet
                                                if ([element respondsToSelector:@selector(instance)]) {
                                                    // ... rest of the instance code ...
                                                }
                                            }
                                        } @catch (NSException *e) {
                                            NSLog(@"[Gonerino] Error accessing element: %@", e);
                                        }
                                    }
                                }
                            }
                            parentView = parentView.superview;
                        }
                    }
                }
            } @catch (NSException *e) {
                // Ignore property access errors
            }
        } @catch (NSException *e) {
            NSLog(@"[Gonerino] Error in block action handler: %@", e);
        }
    }];

    [blockChannelAction setValue:newActionIdentifier forKey:@"_accessibilityIdentifier"];
    %orig(blockChannelAction);
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
