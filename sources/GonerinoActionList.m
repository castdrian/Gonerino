#import "GonerinoActionList.h"

static NSString *ActionStringValue(id action, NSString *key) {
    if (!action || key.length == 0)
        return nil;
    @try {
        id value = [action valueForKey:key];
        return [value isKindOfClass:[NSString class]] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *BlockActionKey(id action) {
    NSString *identifier = ActionStringValue(action, @"accessibilityIdentifier");
    if ([identifier isEqualToString:@"GonerinoBlockChannel"])
        return @"channel";
    if ([identifier isEqualToString:@"GonerinoBlockVideo"])
        return @"video";

    NSString *title = ActionStringValue(action, @"title").lowercaseString;
    if ([title isEqualToString:@"block channel"])
        return @"channel";
    if ([title isEqualToString:@"block video"])
        return @"video";
    return nil;
}

NSArray *GonerinoUniqueBlockActions(NSArray *actions) {
    if (![actions isKindOfClass:[NSArray class]])
        return @[];

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:actions.count];
    NSMutableSet *seenKeys = [NSMutableSet setWithCapacity:2];
    for (id action in actions) {
        NSString *key = BlockActionKey(action);
        if (key && [seenKeys containsObject:key])
            continue;
        if (key)
            [seenKeys addObject:key];
        [result addObject:action];
    }
    return result.copy;
}

NSArray *GonerinoPrependUniqueBlockActions(NSArray *actions, NSArray *blockActions) {
    NSMutableArray *result = [NSMutableArray arrayWithArray:blockActions ?: @[]];
    [result addObjectsFromArray:actions ?: @[]];
    return GonerinoUniqueBlockActions(result);
}
