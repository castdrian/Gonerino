#import "Util.h"

@implementation Util

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion {
    if (!completion)
        return;

    if (![node isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
        NSLog(@"[Gonerino] Error: extractVideoInfoFromNode received incorrect node type: %@",
              NSStringFromClass([node class]));
        return;
    }

    @try {
        UIView *view = [node view];
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:NSClassFromString(@"YTElementsInlineMutedPlaybackView")]) {
                YTElementsInlineMutedPlaybackView *playbackView = (YTElementsInlineMutedPlaybackView *)subview;
                YTASDPlayableEntry *playableEntry               = playbackView.asdPlayableEntry;

                if (playableEntry && playableEntry.hasNavigationEndpoint) {
                    NSString *description = [playableEntry.navigationEndpoint description];

                    if (!description)
                        return;

                    NSError *error       = nil;
                    NSString *videoId    = nil;
                    NSString *videoTitle = nil;
                    NSString *ownerName  = nil;

                    NSArray *patterns = @[
                        @"video_id: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\"",
                        @"video_title: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\"",
                        @"owner_display_name: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""
                    ];

                    for (NSString *pattern in patterns) {
                        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                               options:0
                                                                                                 error:&error];
                        if (error) {
                            NSLog(@"[Gonerino] Regex error for pattern %@: %@", pattern, error);
                            continue;
                        }

                        NSTextCheckingResult *match = [regex firstMatchInString:description
                                                                        options:0
                                                                          range:NSMakeRange(0, description.length)];

                        if (match && match.numberOfRanges > 1) {
                            NSString *value = [description substringWithRange:[match rangeAtIndex:1]];

                            value = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
                            value = [value stringByReplacingOccurrencesOfString:@"\\'" withString:@"'"];

                            if ([pattern hasPrefix:@"video_id:"]) {
                                videoId = value;
                            } else if ([pattern hasPrefix:@"video_title:"]) {
                                videoTitle = value;
                            } else if ([pattern hasPrefix:@"owner_display_name:"]) {
                                ownerName = value;
                            }
                        }
                    }

                    if (videoId || videoTitle || ownerName) {
                        completion(videoId, videoTitle, ownerName);
                    }
                    return;
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[Gonerino] Exception in extractVideoInfoFromNode: %@", exception);
    }
}

+ (BOOL)nodeContainsBlockedVideo:(id)node {
    __block BOOL isBlocked = NO;

    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")]) {
        NSAttributedString *attributedText = [(ASTextNode *)node attributedText];
        NSString *text = [attributedText string];

        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoPeopleWatched"] &&
            [text isEqualToString:@"People also watched this video"]) {
            NSLog(@"[Gonerino] Blocking 'People also watched' section");
            return YES;
        }

        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoMightLike"] &&
            [text isEqualToString:@"You might also like this"]) {
            NSLog(@"[Gonerino] Blocking 'You might also like' section");
            return YES;
        }
    }

    if ([node isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
        [self
            extractVideoInfoFromNode:node
                          completion:^(NSString *videoId, NSString *videoTitle, NSString *ownerName) {
                              if ([[VideoManager sharedInstance] isVideoBlocked:videoId]) {
                                  isBlocked = YES;
                                  NSLog(@"[Gonerino] Blocking video with id: %@", videoId);
                              }
                              if ([[ChannelManager sharedInstance] isChannelBlocked:ownerName]) {
                                  isBlocked = YES;
                                  NSLog(@"[Gonerino] Blocking video with id %@: Channel %@ is blocked", videoId,
                                        ownerName);
                              }
                              if ([[WordManager sharedInstance] isWordBlocked:videoTitle]) {
                                  isBlocked = YES;
                                  NSLog(@"[Gonerino] Blocking video with id %@: title contains blocked word", videoId);
                              }
                              if ([[WordManager sharedInstance] isWordBlocked:ownerName]) {
                                  isBlocked = YES;
                                  NSLog(@"[Gonerino] Blocking video with id %@: channel name contains blocked word",
                                        videoId);
                              }
                          }];
        return isBlocked;
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

+ (UIImage *)createBlockChannelIconWithSize:(CGSize)size {
    @try {
        UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) {
            NSLog(@"[Gonerino] Failed to create graphics context");
            return nil;
        }

        CGContextSetShouldAntialias(context, YES);
        CGContextSetAllowsAntialiasing(context, YES);
        CGContextSetShouldSmoothFonts(context, NO);

        [[UIColor whiteColor] setStroke];

        CGFloat noSymbolRadius   = size.width * 0.45;
        CGPoint center           = CGPointMake(size.width / 2, size.height / 2);
        UIBezierPath *circlePath = [UIBezierPath bezierPathWithArcCenter:center
                                                                  radius:noSymbolRadius
                                                              startAngle:0
                                                                endAngle:2 * M_PI
                                                               clockwise:YES];

        CGFloat bodyRadius     = size.width * 0.3;
        CGPoint bodyCenter     = CGPointMake(size.width / 2, size.height * 0.85);
        UIBezierPath *bodyPath = [UIBezierPath bezierPathWithArcCenter:bodyCenter
                                                                radius:bodyRadius
                                                            startAngle:M_PI
                                                              endAngle:2 * M_PI
                                                             clockwise:YES];

        CGFloat headRadius     = size.width * 0.15;
        CGPoint headCenter     = CGPointMake(size.width / 2, size.height * 0.35);
        UIBezierPath *headPath = [UIBezierPath bezierPathWithArcCenter:headCenter
                                                                radius:headRadius
                                                            startAngle:0
                                                              endAngle:2 * M_PI
                                                             clockwise:YES];

        UIBezierPath *linePath = [UIBezierPath bezierPath];
        CGFloat offset         = noSymbolRadius * 0.7071;
        [linePath moveToPoint:CGPointMake(center.x - offset, center.y - offset)];
        [linePath addLineToPoint:CGPointMake(center.x + offset, center.y + offset)];

        CGFloat lineWidth    = 1.5;
        circlePath.lineWidth = lineWidth;
        headPath.lineWidth   = lineWidth;
        bodyPath.lineWidth   = lineWidth;
        linePath.lineWidth   = lineWidth;

        [circlePath stroke];
        [bodyPath stroke];
        [headPath stroke];
        [linePath stroke];

        UIImage *icon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    } @catch (NSException *exception) {
        NSLog(@"[Gonerino] Exception in createBlockChannelIcon: %@", exception);
        return nil;
    }
}

+ (UIImage *)createBlockVideoIconWithSize:(CGSize)size {
    @try {
        UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) {
            NSLog(@"[Gonerino] Failed to create graphics context");
            return nil;
        }

        CGContextSetShouldAntialias(context, YES);
        CGContextSetAllowsAntialiasing(context, YES);
        CGContextSetShouldSmoothFonts(context, NO);

        [[UIColor whiteColor] setStroke];
        [[UIColor whiteColor] setFill];

        CGPoint center = CGPointMake(size.width / 2, size.height / 2);

        UIBezierPath *rectPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(size.width * 0.2, size.height * 0.3,
                                                                                    size.width * 0.6, size.height * 0.4)
                                                            cornerRadius:3.0];

        UIBezierPath *trianglePath = [UIBezierPath bezierPath];
        CGFloat triangleSize       = size.width * 0.2;
        CGPoint triangleCenter     = center;

        [trianglePath
            moveToPoint:CGPointMake(triangleCenter.x - triangleSize / 2, triangleCenter.y - triangleSize / 2)];
        [trianglePath addLineToPoint:CGPointMake(triangleCenter.x + triangleSize / 2, triangleCenter.y)];
        [trianglePath
            addLineToPoint:CGPointMake(triangleCenter.x - triangleSize / 2, triangleCenter.y + triangleSize / 2)];
        [trianglePath closePath];

        CGFloat noSymbolRadius   = size.width * 0.45;
        UIBezierPath *circlePath = [UIBezierPath bezierPathWithArcCenter:center
                                                                  radius:noSymbolRadius
                                                              startAngle:0
                                                                endAngle:2 * M_PI
                                                               clockwise:YES];

        UIBezierPath *linePath = [UIBezierPath bezierPath];
        CGFloat offset         = noSymbolRadius * 0.7071;
        [linePath moveToPoint:CGPointMake(center.x - offset, center.y - offset)];
        [linePath addLineToPoint:CGPointMake(center.x + offset, center.y + offset)];

        CGFloat lineWidth      = 1.5;
        rectPath.lineWidth     = lineWidth;
        trianglePath.lineWidth = lineWidth;
        circlePath.lineWidth   = lineWidth;
        linePath.lineWidth     = lineWidth;

        [rectPath stroke];
        [trianglePath fill];
        [circlePath stroke];
        [linePath stroke];

        UIImage *icon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    } @catch (NSException *exception) {
        NSLog(@"[Gonerino] Exception in createBlockVideoIcon: %@", exception);
        return nil;
    }
}

@end
