#import "Localization.h"

#import <rootless.h>

static NSBundle *LocalizationBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"Gonerino" ofType:@"bundle"];
        bundle = [NSBundle bundleWithPath:bundlePath ?: ROOT_PATH_NS(@"/Library/Application Support/Gonerino.bundle")];
    });
    return bundle;
}

NSString *LocalizedString(NSString *key) {
    if (key.length == 0)
        return key;

    NSBundle *bundle = LocalizationBundle();
    NSString *translation = [bundle localizedStringForKey:key value:key table:nil];
    return translation.length > 0 ? translation : key;
}

NSString *LocalizedCount(NSString *singular, NSString *plural, NSUInteger count) {
    NSString *label = LocalizedString(count == 1 ? singular : plural);
    return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, label];
}
