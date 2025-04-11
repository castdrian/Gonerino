#import "Tweak.h"

static BOOL isShaking                               = NO;
static NSTimeInterval shakeStartTime                = 0;
static UIImpactFeedbackGenerator *feedbackGenerator = nil;
static UILabel *statusOverlayLabel                  = nil;

static void updateStatusOverlay() {
    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                         ? YES
                         : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!statusOverlayLabel) {
            statusOverlayLabel                     = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
            statusOverlayLabel.textColor           = [UIColor redColor];
            statusOverlayLabel.backgroundColor     = [UIColor colorWithWhite:0 alpha:0.7];
            statusOverlayLabel.textAlignment       = NSTextAlignmentCenter;
            statusOverlayLabel.layer.cornerRadius  = 10;
            statusOverlayLabel.layer.masksToBounds = YES;
            statusOverlayLabel.font                = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            statusOverlayLabel.alpha               = 0.0;

            UIWindow *keyWindow = nil;
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }

            if (keyWindow) {
                statusOverlayLabel.frame =
                    CGRectMake((keyWindow.bounds.size.width - 150) / 2, keyWindow.safeAreaInsets.top + 5, 150, 30);
                [keyWindow addSubview:statusOverlayLabel];
            }
        }

        statusOverlayLabel.text = @"GONERINO DISABLED";

        [UIView animateWithDuration:0.3
                         animations:^{ statusOverlayLabel.alpha = isEnabled ? 0.0 : 1.0; }
                         completion:nil];
    });
}

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
    BOOL newState  = !isEnabled;
    [defaults setBool:newState forKey:@"GonerinoEnabled"];
    [defaults synchronize];

    updateStatusOverlay();

    UIViewController *topVC = nil;

    NSSet<UIScene *> *connectedScenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *scene in connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.rootViewController) {
                    topVC = window.rootViewController;
                    while (topVC.presentedViewController) {
                        topVC = topVC.presentedViewController;
                    }
                    break;
                }
            }
            if (topVC)
                break;
        }
    }

    if (topVC) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[%c(YTToastResponderEvent)
                eventWithMessage:[NSString stringWithFormat:@"Gonerino %@", !isEnabled ? @"activated" : @"deactivated"]
                  firstResponder:topVC] send];
        });
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

%hook UIApplication

- (void)applicationDidBecomeActive:(id)arg1 {
    %orig;
    updateStatusOverlay();
}

%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                   ^{ updateStatusOverlay(); });
}
