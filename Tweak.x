#import "Tweak.h"

static BOOL isShaking                               = NO;
static NSTimeInterval shakeStartTime                = 0;
static UIImpactFeedbackGenerator *feedbackGenerator = nil;

static void triggerHapticFeedback(void) {
    if (!feedbackGenerator) {
        feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    }
    [feedbackGenerator prepare];
    [feedbackGenerator impactOccurred];
}

static void toggleGonerinoStatus() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isEnabled = [defaults objectForKey:@"GonerinoEnabled"] == nil ? YES : [defaults boolForKey:@"GonerinoEnabled"];
    [defaults setBool:!isEnabled forKey:@"GonerinoEnabled"];
    [defaults synchronize];

    UIViewController *topVC = nil;

    UIWindow *window                  = nil;
    NSSet<UIScene *> *connectedScenes = UIApplication.sharedApplication.connectedScenes;
    for (UIScene *scene in connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *w in windowScene.windows) {
                if (w.isKeyWindow) {
                    window = w;
                    break;
                }
            }
            if (window)
                break;
        }
    }

    if (window) {
        UIView *frontView = window.subviews.firstObject;
        if (frontView) {
            UIResponder *responder = frontView;
            while (responder) {
                if ([responder isKindOfClass:[UIViewController class]]) {
                    topVC = (UIViewController *)responder;
                    break;
                }
                responder = [responder nextResponder];
            }
        }
    }

    if (topVC) {
        [[%c(YTToastResponderEvent)
            eventWithMessage:[NSString stringWithFormat:@"Gonerino %@", !isEnabled ? @"activated" : @"deactivated"]
              firstResponder:topVC] send];
    }
}

%hook UIWindow

- (void)becomeKeyWindow {
    %orig;
}

- (void)motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        isShaking      = YES;
        shakeStartTime = [[NSDate date] timeIntervalSince1970];
    }
    %orig;
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake && isShaking) {
        NSTimeInterval currentTime   = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval shakeDuration = currentTime - shakeStartTime;

        if (shakeDuration >= 0.5 && shakeDuration <= 2.0) {
            triggerHapticFeedback();
            dispatch_async(dispatch_get_main_queue(), ^{ toggleGonerinoStatus(); });
        }
        isShaking = NO;
    }
    %orig;
}

%end

%hook YTAsyncCollectionView

- (void)layoutSubviews {
    %orig;
    [self removeOffendingCells];
}

%new
- (void)removeOffendingCells {
    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_main_queue(), ^{
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

%end

%hook YTDefaultSheetController

- (void)addAction:(YTActionSheetAction *)action {
    %orig;

    static void *blockActionKey = &blockActionKey;
    if (objc_getAssociatedObject(self, blockActionKey)) {
        return;
    }

    UIView *sourceView = [self valueForKey:@"sourceView"];
    id node            = [sourceView valueForKey:@"asyncdisplaykit_node"];

    if (!node || ![node debugDescription] || ![[node debugDescription] containsString:@"YTVideoWithContextNode"]) {
        return;
    }

    NSInteger currentActionsCount = 3;
    if ([self respondsToSelector:@selector(actions)]) {
        currentActionsCount = [[self actions] count];
    }

    if (currentActionsCount < 3) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    CGSize iconSize              = CGSizeMake(24, 24);
    if (action) {
        UIImage *originalIcon = [action valueForKey:@"_iconImage"];
        if (originalIcon) {
            iconSize = originalIcon.size;
        }
    }

    YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block channel"
              iconImage:[Util createBlockChannelIconWithSize:iconSize]
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
        actionWithTitle:@"Block video"
              iconImage:[Util createBlockVideoIconWithSize:iconSize]
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

%end
