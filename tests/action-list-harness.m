#import "GonerinoActionList.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface FakeAction : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@end

@implementation FakeAction
@end

static void Require(BOOL condition, NSString *message) {
    if (condition)
        return;
    NSLog(@"FAIL: %@", message);
    exit(1);
}

static FakeAction *Action(NSString *title, NSString *identifier) {
    FakeAction *action = [FakeAction new];
    action.title = title;
    action.accessibilityIdentifier = identifier;
    return action;
}

int main(void) {
    @autoreleasepool {
        FakeAction *stock = Action(@"Share", @"Share");
        FakeAction *channel = Action(@"Block channel", @"GonerinoBlockChannel");
        FakeAction *video = Action(@"Block video", @"GonerinoBlockVideo");
        FakeAction *duplicateChannel = Action(@"Block channel", @"GonerinoBlockChannel");
        FakeAction *duplicateVideo = Action(@"Block video", @"GonerinoBlockVideo");

        NSArray *normalized = GonerinoUniqueBlockActions(@[stock, channel, video, duplicateChannel, duplicateVideo]);
        Require(normalized.count == 3, @"duplicate block actions remained in normalized list");
        Require(normalized[0] == stock && normalized[1] == channel && normalized[2] == video,
                @"normalized block action order changed");

        NSArray *merged = GonerinoPrependUniqueBlockActions(@[stock, duplicateChannel], @[channel, video]);
        Require(merged.count == 3, @"duplicate block actions remained after merging sources");
        Require(merged[0] == channel && merged[1] == video && merged[2] == stock,
                @"merged block action order changed");

        NSLog(@"PASS: block action lists are unique by semantic identity");
    }
    return 0;
}
