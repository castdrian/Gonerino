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
    if (![node isKindOfClass:NSClassFromString(@"YTVideoWithContextNode")])
        return NO;

    if ([node respondsToSelector:@selector(playbackView)]) {
        id playbackNode = [node playbackView];
        if ([playbackNode isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
            __block BOOL shouldBlock       = NO;
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

            [self extractVideoInfoFromNode:playbackNode
                                completion:^(NSString *videoId, NSString *videoTitle, NSString *ownerName) {
                                    if (videoId || videoTitle || ownerName) {
                                        NSLog(@"[Gonerino] Found video info - ID: %@, Title: %@, Owner: %@",
                                              videoId ?: @"nil", videoTitle ?: @"nil", ownerName ?: @"nil");

                                        // Check for blocked video
                                        if ([[VideoManager sharedInstance] isVideoBlocked:videoTitle]) {
                                            shouldBlock = YES;
                                        }

                                        // Check for blocked channel
                                        if ([[ChannelManager sharedInstance] isChannelBlocked:ownerName]) {
                                            shouldBlock = YES;
                                        }

                                        // Check for blocked words in title
                                        if ([[WordManager sharedInstance] isWordBlocked:videoTitle]) {
                                            shouldBlock = YES;
                                        }
                                    }
                                    dispatch_semaphore_signal(semaphore);
                                }];

            dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));
            return shouldBlock;
        }
    }

    return NO;
}

@end
