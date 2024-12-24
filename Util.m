#import "Util.h"

@implementation Util

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion {
    if (!completion) return;
    
    if (![node isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
        NSLog(@"[Gonerino] Error: extractVideoInfoFromNode received incorrect node type: %@", NSStringFromClass([node class]));
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

@end
