#import "Util.h"
#import "ChannelManager.h"
#import "VideoManager.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

@interface NSObject (Text)
- (NSString *)stringWithFormattingRemoved;
- (NSString *)string;
@end

typedef NS_ENUM(NSUInteger, FieldRole) {
    FieldRoleNone,
    FieldRoleVideoId,
    FieldRoleTitle,
    FieldRoleChannel
};

static NSMapTable *MetadataCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMapTable weakToStrongObjectsMapTable];
    });
    return cache;
}

static NSMapTable *MetadataAttemptCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMapTable weakToStrongObjectsMapTable];
    });
    return cache;
}

static NSString *NormalizedKey(NSString *key) {
    if (key.length == 0)
        return @"";

    NSMutableString *normalized = [key.lowercaseString mutableCopy];
    [normalized replaceOccurrencesOfString:@"_" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"-" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    return normalized;
}

static BOOL MetadataComplete(NSDictionary *result) {
    return [result[@"id"] length] > 0 && [result[@"title"] length] > 0 && [result[@"channel"] length] > 0;
}

static id ValueForKey(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    @try {
        if ([object isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dictionary = object;
            id value = dictionary[key];
            if (value)
                return value;

            NSString *normalizedKey = NormalizedKey(key);
            for (id dictionaryKey in dictionary.allKeys) {
                if (![dictionaryKey isKindOfClass:[NSString class]])
                    continue;
                NSString *candidate = NormalizedKey(dictionaryKey);
                if ([candidate isEqualToString:normalizedKey])
                    return dictionary[dictionaryKey];
            }
            return nil;
        }

        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector])
            return nil;

        Method method = class_getInstanceMethod(object_getClass(object), selector);
        if (!method)
            return nil;

        const char *returnType = method_getTypeEncoding(method);
        if (!returnType || returnType[0] != '@')
            return nil;

        return ((id (*)(id, SEL))method_getImplementation(method))(object, selector);
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

static id ValueForArgumentKey(id object, SEL selector, NSString *key) {
    if (!object || !selector || key.length == 0 || ![object respondsToSelector:selector])
        return nil;

    @try {
        Method method = class_getInstanceMethod(object_getClass(object), selector);
        const char *returnType = method ? method_getTypeEncoding(method) : NULL;
        if (!returnType || returnType[0] != '@')
            return nil;
        return ((id (*)(id, SEL, id))method_getImplementation(method))(object, selector, key);
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

static id ValueForNamedKey(id object, NSString *key) {
    id value = ValueForKey(object, key);
    if (value)
        return value;

    for (NSString *selectorName in @[@"propertyForKey:", @"elementForKey:", @"safeSwiftValueForKey:", @"safeSwiftStringForKey:", @"tps_safeValueForKey:", @"valueForKey:"]) {
        value = ValueForArgumentKey(object, NSSelectorFromString(selectorName), key);
        if (value)
            return value;
    }

    return nil;
}

static void RecordField(NSMutableDictionary *result, NSMutableDictionary *priorities, NSString *key, id value);

static NSString *TextFromValue(id value, NSUInteger depth) {
    if (!value || depth > 4)
        return nil;

    if ([value isKindOfClass:[NSString class]])
        return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([value isKindOfClass:[NSAttributedString class]])
        return [[value string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([value isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"simpleText", @"text", @"label", @"title", @"name"]) {
            NSString *text = TextFromValue(ValueForKey(value, key), depth + 1);
            if (text.length > 0)
                return text;
        }

        NSArray *runs = ValueForKey(value, @"runs");
        if ([runs isKindOfClass:[NSArray class]]) {
            NSMutableString *text = [NSMutableString string];
            for (id run in runs) {
                NSString *runText = TextFromValue(run, depth + 1);
                if (runText.length > 0)
                    [text appendString:runText];
            }
            return text.length > 0 ? text : nil;
        }
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableString *text = [NSMutableString string];
        for (id item in (NSArray *)value) {
            NSString *itemText = TextFromValue(item, depth + 1);
            if (itemText.length == 0)
                continue;
            if (text.length > 0)
                [text appendString:@" "];
            [text appendString:itemText];
        }
        return text.length > 0 ? text : nil;
    }

    @try {
        if ([value respondsToSelector:@selector(stringWithFormattingRemoved)]) {
            NSString *text = [(id)value stringWithFormattingRemoved];
            if (text.length > 0)
                return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }

        if ([value respondsToSelector:@selector(string)]) {
            NSString *text = [(id)value string];
            if (text.length > 0)
                return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }

        for (NSString *key in @[@"simpleText", @"text", @"label", @"title", @"name", @"runs"]) {
            NSString *text = TextFromValue(ValueForKey(value, key), depth + 1);
            if (text.length > 0)
                return text;
        }
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

static void CollectTextNodeValues(id object,
                                  NSMutableArray<NSString *> *values,
                                  NSMutableSet *visited,
                                  NSUInteger depth) {
    if (!object || !values || !visited || depth > 14 || values.count >= 256)
        return;

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return;
    [visited addObject:identity];

    NSString *className = NSStringFromClass([object class]).lowercaseString;
    BOOL isTextObject = [className containsString:@"textnode"] ||
                        [object isKindOfClass:[UILabel class]] ||
                        [className containsString:@"buttonlabel"];
    if (isTextObject) {
        for (NSString *key in @[@"text", @"attributedText", @"currentTitle", @"accessibilityLabel"]) {
            NSString *text = TextFromValue(ValueForNamedKey(object, key), 0);
            if (text.length > 0 && ![values containsObject:text])
                [values addObject:text];
        }
    }

    NSString *accessibilityLabel = TextFromValue(ValueForNamedKey(object, @"accessibilityLabel"), 0);
    if (accessibilityLabel.length > 0 && ![values containsObject:accessibilityLabel])
        [values addObject:accessibilityLabel];

    for (NSString *key in @[@"ownerText", @"shortBylineText", @"longBylineText"]) {
        NSString *text = TextFromValue(ValueForNamedKey(object, key), 0);
        if (text.length > 0 && ![values containsObject:text])
            [values addObject:text];
    }

    for (NSString *key in @[
        @"element", @"instance", @"childElements", @"subnodes", @"view", @"subviews", @"asyncdisplaykit_node", @"node",
        @"parentResponder", @"controller", @"viewController", @"closestViewController", @"context", @"properties",
        @"allProperties", @"elementEntry", @"navigationEndpoint", @"watchEndpoint", @"ownerText", @"shortBylineText", @"longBylineText"
    ]) {
        id value = ValueForNamedKey(object, key);
        if (!value || value == object)
            continue;
        if ([value isKindOfClass:[NSArray class]]) {
            for (id child in value) {
                CollectTextNodeValues(child, values, visited, depth + 1);
                if (values.count >= 256)
                    return;
            }
        } else {
            CollectTextNodeValues(value, values, visited, depth + 1);
        }
    }
}

static BOOL IsSyntheticChannelValue(NSString *text);

static BOOL IsLikelyChannelText(NSString *text, NSString *title) {
    if (text.length == 0 || text.length > 120)
        return NO;

    NSString *normalizedText = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *normalizedTitle = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalizedText.length == 0 || [normalizedText isEqualToString:normalizedTitle] ||
        (normalizedTitle.length > 0 && [normalizedText containsString:normalizedTitle]))
        return NO;

    NSString *lowercaseText = normalizedText.lowercaseString;
    if (IsSyntheticChannelValue(normalizedText) ||
        [lowercaseText containsString:@" views"] || [lowercaseText containsString:@" view"] ||
        [lowercaseText containsString:@" ago"] || [lowercaseText containsString:@" subscribers"] ||
        [lowercaseText containsString:@" sponsored"] || [lowercaseText containsString:@"subscribe"] ||
        [lowercaseText containsString:@"watch later"] || [lowercaseText containsString:@"playlist"] ||
        [lowercaseText containsString:@"share"] ||
        [lowercaseText isEqualToString:@"description"] || [lowercaseText isEqualToString:@"clear screen"] ||
        [lowercaseText isEqualToString:@"not interested"] || [lowercaseText isEqualToString:@"send feedback"] ||
        [lowercaseText isEqualToString:@"home"] || [lowercaseText isEqualToString:@"shorts"] ||
        [lowercaseText isEqualToString:@"subscriptions"] || [lowercaseText isEqualToString:@"you"] ||
        [lowercaseText isEqualToString:@"search"] || [lowercaseText isEqualToString:@"notifications"] ||
        [lowercaseText isEqualToString:@"settings"])
        return NO;

    static NSRegularExpression *metricsRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        metricsRegex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9][0-9:., ]*[kmb]?$"
                                                                      options:NSRegularExpressionCaseInsensitive
                                                                        error:nil];
    });
    if ([metricsRegex firstMatchInString:normalizedText
                                  options:0
                                    range:NSMakeRange(0, normalizedText.length)])
        return NO;

    return YES;
}

static NSString *ChannelTextFromNode(id node, NSString *title) {
    if (title.length == 0)
        return nil;

    NSMutableArray<NSString *> *values = [NSMutableArray array];
    CollectTextNodeValues(node, values, [NSMutableSet set], 0);
    NSUInteger titleIndex = NSNotFound;
    for (NSUInteger index = 0; index < values.count; index++) {
        NSString *value = values[index];
        if ([value isEqualToString:title] || (title.length > 0 && [value containsString:title])) {
            titleIndex = index;
            break;
        }
    }

    if (titleIndex == NSNotFound)
        return nil;

    NSUInteger firstCandidate = titleIndex + 1;
    for (NSUInteger index = firstCandidate; index < values.count; index++) {
        NSString *candidate = [values[index] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (IsLikelyChannelText(candidate, title))
            return candidate;
    }

    if (titleIndex != NSNotFound) {
        for (NSString *value in values) {
            NSString *candidate = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (IsLikelyChannelText(candidate, title))
                return candidate;
        }
    }

    return nil;
}

static NSString *ShortsChannelTextFromNode(id node) {
    NSString *className = NSStringFromClass([node class]).lowercaseString;
    if (![className containsString:@"short"] && ![className containsString:@"reel"])
        return nil;

    NSMutableArray<NSString *> *values = [NSMutableArray array];
    CollectTextNodeValues(node, values, [NSMutableSet set], 0);
    for (NSString *value in values) {
        NSString *candidate = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (candidate.length < 2 || candidate.length > 100 || ![candidate hasPrefix:@"@"])
            continue;
        if ([candidate rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
            continue;
        if (IsLikelyChannelText(candidate, nil))
            return candidate;
    }

    return nil;
}

static BOOL IsShortsControlText(NSString *text) {
    NSString *candidate = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lowercaseCandidate = candidate.lowercaseString;
    if (candidate.length == 0 || [candidate hasPrefix:@"@"])
        return YES;

    NSArray<NSString *> *controlPrefixes = @[
        @"subscribe to ", @"subscribed to ", @"suscribirse a ", @"suscrito a ",
        @"abonnieren ", @"abonner à ", @"abonné à ", @"iscriviti a ",
        @"assinar ", @"inscrever-se ", @"подписаться на ", @"購読"
    ];
    for (NSString *prefix in controlPrefixes) {
        if ([lowercaseCandidate hasPrefix:prefix])
            return YES;
    }

    NSArray<NSString *> *controlLabels = @[
        @"retry", @"subscribe", @"subscribed", @"share", @"remix", @"description",
        @"clear screen", @"audio track", @"abonnieren", @"suscribirse", @"abonner",
        @"iscriviti", @"assinar", @"подписаться"
    ];
    if ([controlLabels containsObject:lowercaseCandidate])
        return YES;
    return [lowercaseCandidate hasPrefix:@"captions"] || [lowercaseCandidate hasPrefix:@"quality"];
}

static BOOL IsLikelyShortsTitleText(NSString *text, NSString *channel) {
    if (text.length == 0 || text.length > 240)
        return NO;

    NSString *candidate = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (candidate.length == 0 || [candidate isEqualToString:channel] || IsShortsControlText(candidate))
        return NO;

    static NSRegularExpression *metricsRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        metricsRegex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9][0-9:., ]*[kmb]?$"
                                                                      options:NSRegularExpressionCaseInsensitive
                                                                        error:nil];
    });
    return [metricsRegex firstMatchInString:candidate options:0 range:NSMakeRange(0, candidate.length)] == nil;
}

static NSString *ShortsTitleTextFromNode(id node, NSString *channel) {
    NSString *className = NSStringFromClass([node class]).lowercaseString;
    if (![className containsString:@"short"] && ![className containsString:@"reel"])
        return nil;

    NSMutableArray<NSString *> *values = [NSMutableArray array];
    CollectTextNodeValues(node, values, [NSMutableSet set], 0);
    NSUInteger channelIndex = NSNotFound;
    for (NSUInteger index = 0; index < values.count; index++) {
        if (channel.length > 0 && [values[index] isEqualToString:channel]) {
            channelIndex = index;
            break;
        }
    }

    NSUInteger firstIndex = channelIndex == NSNotFound ? 0 : channelIndex + 1;
    for (NSUInteger index = firstIndex; index < values.count; index++) {
        NSString *candidate = [values[index] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (IsLikelyShortsTitleText(candidate, channel))
            return candidate;
    }

    return nil;
}

static NSArray<NSString *> *ChannelAccessibilityMarkers(void) {
    static NSArray<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[
            @"go to channel ", @"go to channel:", @"zum kanal ", @"zum kanal:",
            @"kanal öffnen ", @"kanal öffnen:", @"ir al canal ", @"ir al canal:",
            @"aller à la chaîne ", @"aller à la chaîne:", @"vai al canale ", @"vai al canale:",
            @"ir para o canal ", @"ir para o canal:", @"naar kanaal ", @"naar kanaal:",
            @"kanala git ", @"kanala git:", @"перейти на канал ", @"перейти на канал:",
            @"チャンネルに移動 ", @"チャンネルに移動:", @"채널로 이동 ", @"채널로 이동:",
            @"转到频道 ", @"转到频道:", @"前往频道 ", @"前往频道:"
        ];
    });
    return markers;
}

static NSString *ChannelFromAccessibleText(NSString *text) {
    if (text.length == 0)
        return nil;

    for (NSString *marker in ChannelAccessibilityMarkers()) {
        NSRange range = [text rangeOfString:marker options:NSCaseInsensitiveSearch];
        if (range.location == NSNotFound)
            continue;

        NSUInteger start = NSMaxRange(range);
        if (start >= text.length)
            continue;
        NSString *candidate = [text substringFromIndex:start];
        NSRange separator = [candidate rangeOfString:@" - "];
        if (separator.location != NSNotFound)
            candidate = [candidate substringToIndex:separator.location];
        candidate = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (IsLikelyChannelText(candidate, nil))
            return candidate;
    }

    NSArray<NSString *> *liveSuffixes = @[
        @" channel", @" kanal", @" canal", @" chaîne", @" canale", @" kanaal"
    ];
    for (NSString *suffix in liveSuffixes) {
        NSRange suffixRange = [text rangeOfString:suffix options:NSCaseInsensitiveSearch | NSBackwardsSearch];
        if (suffixRange.location == NSNotFound || NSMaxRange(suffixRange) != text.length)
            continue;

        NSString *prefix = [text substringToIndex:suffixRange.location];
        NSRange separator = [prefix rangeOfString:@"," options:NSBackwardsSearch];
        if (separator.location == NSNotFound)
            continue;

        NSString *candidate = [[prefix substringFromIndex:NSMaxRange(separator)]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (IsLikelyChannelText(candidate, nil))
            return candidate;
    }

    return nil;
}

static BOOL IsFeedDurationText(NSString *text) {
    NSString *candidate = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    if (candidate.length == 0)
        return NO;

    static NSRegularExpression *durationRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        durationRegex = [NSRegularExpression regularExpressionWithPattern:
                         @"^[0-9][0-9:., ]*(seconds?|minutes?|hours?|sekunden?|minuten?|stunden?|segundos?|minutos?|horas?|秒|分|時間)"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    });
    if ([durationRegex firstMatchInString:candidate options:0 range:NSMakeRange(0, candidate.length)])
        return YES;

    static NSRegularExpression *clockRegex;
    static dispatch_once_t clockOnceToken;
    dispatch_once(&clockOnceToken, ^{
        clockRegex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(?::[0-9]{2}){1,2}$"
                                                                    options:0
                                                                      error:nil];
    });
    return [clockRegex firstMatchInString:candidate options:0 range:NSMakeRange(0, candidate.length)] != nil;
}

static NSString *TitleFromAccessibleText(NSString *text) {
    if (text.length == 0)
        return nil;

    NSRange liveSeparator = [text rangeOfString:@" -  -  - "];
    if (liveSeparator.location != NSNotFound) {
        NSString *liveTitle = [[text substringToIndex:liveSeparator.location]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (liveTitle.length > 0)
            return liveTitle;
    }

    NSArray<NSString *> *components = [text componentsSeparatedByString:@" - "];
    if (components.count < 2)
        return nil;

    for (NSUInteger index = 1; index < components.count; index++) {
        if (!IsFeedDurationText(components[index]))
            continue;

        NSMutableArray<NSString *> *titleComponents = [NSMutableArray arrayWithCapacity:index];
        for (NSUInteger titleIndex = 0; titleIndex < index; titleIndex++)
            [titleComponents addObject:components[titleIndex]];
        NSString *title = [titleComponents componentsJoinedByString:@" - "];
        if (title.length > 0)
            return [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    return nil;
}

static NSDictionary *FeedMetadataFromView(UIView *view) {
    if (![view isKindOfClass:[UIView class]])
        return nil;

    NSMutableArray<NSString *> *values = [NSMutableArray array];
    CollectTextNodeValues(view, values, [NSMutableSet set], 0);
    NSString *title = nil;
    NSString *channel = nil;
    for (NSString *value in values) {
        if (channel.length == 0)
            channel = ChannelFromAccessibleText(value);
        if (title.length == 0)
            title = TitleFromAccessibleText(value);
        if (title.length > 0 && channel.length > 0)
            break;
    }

    if (channel.length == 0 && title.length > 0) {
        NSString *fallback = ChannelTextFromNode(view, title);
        if (IsLikelyChannelText(fallback, title))
            channel = fallback;
        else
            channel = ChannelFromAccessibleText(fallback);
    }

    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    if (title.length > 0)
        metadata[@"title"] = title;
    if (channel.length > 0)
        metadata[@"channel"] = channel;
    return metadata.count > 0 ? metadata : nil;
}

static NSString *VideoIdFromText(NSString *text) {
    if (text.length == 0)
        return nil;

    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
                     @"(?:[?&]v=|youtu\\.be/|/shorts/|/embed/|i\\.ytimg\\.com/vi(?:_webp)?/)([A-Za-z0-9_-]{11})(?:[^A-Za-z0-9_-]|$)"
                                                               options:0
                                                                 error:nil];
    });
    NSTextCheckingResult *match = [regex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    if (match.numberOfRanges > 1)
        return [trimmed substringWithRange:[match rangeAtIndex:1]];

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                                                                  @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    if (trimmed.length == 11 && [trimmed rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound)
        return trimmed;

    return nil;
}

static BOOL ReadVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *offset, uint64_t *value) {
    if (!bytes || !offset || !value)
        return NO;

    uint64_t result = 0;
    for (NSUInteger shift = 0; *offset < length && shift <= 63; shift += 7) {
        uint8_t byte = bytes[(*offset)++];
        result |= ((uint64_t)(byte & 0x7f)) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
    }

    return NO;
}

static BOOL IsPrintableUTF8Data(const uint8_t *bytes, NSUInteger length) {
    if (!bytes || length == 0 || length > 4096)
        return NO;

    NSString *text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (text.length == 0)
        return NO;

    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character < 0x20 && character != '\n' && character != '\r' && character != '\t')
            return NO;
    }
    return YES;
}

static void RecordElementRendererFields(const uint8_t *bytes,
                                        NSUInteger length,
                                        NSMutableDictionary *result,
                                        NSMutableDictionary *priorities,
                                        NSUInteger depth) {
    if (!bytes || length == 0 || depth > 8)
        return;

    NSUInteger offset = 0;
    while (offset < length) {
        uint64_t tag = 0;
        if (!ReadVarint(bytes, length, &offset, &tag))
            return;

        uint64_t fieldNumber = tag >> 3;
        uint64_t wireType = tag & 7;
        if (fieldNumber == 0)
            return;

        if (wireType == 0) {
            uint64_t ignored = 0;
            if (!ReadVarint(bytes, length, &offset, &ignored))
                return;
            continue;
        }

        if (wireType == 1) {
            if (offset > length || length - offset < 8)
                return;
            offset += 8;
            continue;
        }

        if (wireType == 5) {
            if (offset > length || length - offset < 4)
                return;
            offset += 4;
            continue;
        }

        if (wireType != 2)
            return;

        uint64_t valueLength = 0;
        if (!ReadVarint(bytes, length, &offset, &valueLength) || valueLength > length - offset)
            return;

        const uint8_t *valueBytes = bytes + offset;
        NSUInteger valueSize = (NSUInteger)valueLength;
        if (fieldNumber == 36 && IsPrintableUTF8Data(valueBytes, valueSize)) {
            NSString *title = [[NSString alloc] initWithBytes:valueBytes length:valueSize encoding:NSUTF8StringEncoding];
            RecordField(result, priorities, @"videoTitle", title);
        } else if (fieldNumber == 37 && IsPrintableUTF8Data(valueBytes, valueSize)) {
            NSString *channel = [[NSString alloc] initWithBytes:valueBytes length:valueSize encoding:NSUTF8StringEncoding];
            RecordField(result, priorities, @"ownerDisplayName", channel);
        }

        if (!IsPrintableUTF8Data(valueBytes, valueSize))
            RecordElementRendererFields(valueBytes, valueSize, result, priorities, depth + 1);
        offset += valueSize;
    }
}

static void RecordVideoIdFromElementRendererData(NSMutableDictionary *result,
                                                 NSMutableDictionary *priorities,
                                                 NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return;

    const uint8_t *bytes = data.bytes;
    NSUInteger length = MIN(data.length, (NSUInteger)262144);
    static const char imagePrefix[] = "https://i.ytimg.com/vi/";
    static const char imageWebpPrefix[] = "https://i.ytimg.com/vi_webp/";
    const NSUInteger imagePrefixLength = sizeof(imagePrefix) - 1;
    const NSUInteger imageWebpPrefixLength = sizeof(imageWebpPrefix) - 1;
    for (NSUInteger index = 0; index + imagePrefixLength + 11 <= length; index++) {
        NSUInteger identifierOffset = 0;
        if (memcmp(bytes + index, imagePrefix, imagePrefixLength) == 0)
            identifierOffset = index + imagePrefixLength;
        else if (index + imageWebpPrefixLength + 11 <= length &&
                 memcmp(bytes + index, imageWebpPrefix, imageWebpPrefixLength) == 0)
            identifierOffset = index + imageWebpPrefixLength;
        if (identifierOffset == 0)
            continue;

        NSString *identifier = [[NSString alloc] initWithBytes:bytes + identifierOffset
                                                        length:11
                                                      encoding:NSUTF8StringEncoding];
        RecordField(result, priorities, @"videoId", identifier);
    }

    RecordElementRendererFields(bytes, length, result, priorities, 0);
}

static BOOL IsElementRendererObject(id object) {
    NSString *className = NSStringFromClass([object class]).lowercaseString;
    return [className containsString:@"elementrenderer"];
}

static void CollectElementRendererMetadata(id object,
                                           NSMutableDictionary *result,
                                           NSMutableDictionary *priorities) {
    if (!IsElementRendererObject(object))
        return;

    for (NSString *key in @[
        @"videoId", @"videoID", @"contentVideoId", @"contentVideoID", @"videoURL", @"watchURL", @"url",
        @"videoTitle", @"contentTitle", @"title", @"ownerDisplayName", @"ownerName", @"channelName",
        @"channelTitle", @"authorName", @"channel"
    ])
        RecordField(result, priorities, key, ValueForNamedKey(object, key));

    NSData *data = ValueForNamedKey(object, @"data");
    if (![data isKindOfClass:[NSData class]])
        data = ValueForNamedKey(object, @"elementData");
    RecordVideoIdFromElementRendererData(result, priorities, data);
}

static BOOL IsSyntheticChannelValue(NSString *text) {
    NSString *normalized = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    return [normalized isEqualToString:@"action menu"] || [normalized isEqualToString:@"more actions"] ||
           [normalized isEqualToString:@"live"] || [normalized isEqualToString:@"sponsored"] ||
           [normalized isEqualToString:@"verified"] || [normalized isEqualToString:@"premiere"];
}

static FieldRole RoleForKey(NSString *key, NSUInteger *priority) {
    NSString *normalized = NormalizedKey(key);
    if ([normalized isEqualToString:@"videoid"] || [normalized isEqualToString:@"videoidentifier"] ||
        [normalized isEqualToString:@"contentvideoid"] || [normalized isEqualToString:@"youtubevideoid"] ||
        [normalized isEqualToString:@"playerresponsevideoid"] || [normalized isEqualToString:@"watchvideoid"]) {
        if (priority)
            *priority = [normalized isEqualToString:@"videoid"] ? 100 : 90;
        return FieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"contentid"]) {
        if (priority)
            *priority = 85;
        return FieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"entityid"]) {
        if (priority)
            *priority = 60;
        return FieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"videourl"] || [normalized isEqualToString:@"watchurl"] ||
        [normalized isEqualToString:@"webpageurl"]) {
        if (priority)
            *priority = 70;
        return FieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"videotitle"] || [normalized isEqualToString:@"contenttitle"] ||
        [normalized isEqualToString:@"videoname"]) {
        if (priority)
            *priority = 100;
        return FieldRoleTitle;
    }

    if ([normalized isEqualToString:@"title"] || [normalized isEqualToString:@"headline"] ||
        [normalized isEqualToString:@"titletext"]) {
        if (priority)
            *priority = 80;
        return FieldRoleTitle;
    }

    if ([normalized isEqualToString:@"ownerdisplayname"] || [normalized isEqualToString:@"ownername"] ||
        [normalized isEqualToString:@"channeldisplayname"] || [normalized isEqualToString:@"authorname"]) {
        if (priority)
            *priority = 100;
        return FieldRoleChannel;
    }

    if ([normalized isEqualToString:@"channelname"] || [normalized isEqualToString:@"channeltitle"] ||
        [normalized isEqualToString:@"displayname"] || [normalized isEqualToString:@"channel"] ||
        [normalized isEqualToString:@"author"] || [normalized isEqualToString:@"owner"]) {
        if (priority)
            *priority = 80;
        return FieldRoleChannel;
    }

    if ([normalized isEqualToString:@"url"]) {
        if (priority)
            *priority = 40;
        return FieldRoleVideoId;
    }

    if (priority)
        *priority = 0;
    return FieldRoleNone;
}

static void RecordField(NSMutableDictionary *result, NSMutableDictionary *priorities, NSString *key, id value) {
    NSUInteger priority = 0;
    FieldRole role = RoleForKey(key, &priority);
    if (role == FieldRoleNone)
        return;

    NSString *text = TextFromValue(value, 0);
    if (role == FieldRoleVideoId)
        text = VideoIdFromText(text);
    if (role == FieldRoleChannel && IsSyntheticChannelValue(text))
        return;
    if (text.length == 0)
        return;

    NSString *resultKey = role == FieldRoleVideoId ? @"id" :
                          role == FieldRoleTitle ? @"title" : @"channel";
    NSUInteger previousPriority = [priorities[resultKey] unsignedIntegerValue];
    if ([(NSString *)result[resultKey] length] == 0 || priority > previousPriority) {
        result[resultKey] = text;
        priorities[resultKey] = @(priority);
    }
}

static NSString *DescriptionField(NSString *description, NSString *pattern) {
    if (description.length == 0 || pattern.length == 0)
        return nil;

    static NSRegularExpression *videoIdRegex;
    static NSRegularExpression *videoTitleRegex;
    static NSRegularExpression *channelRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoIdRegex = [NSRegularExpression regularExpressionWithPattern:
                           @"(?:video_id|videoId|video_identifier)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""
                                                                         options:0
                                                                           error:nil];
        videoTitleRegex = [NSRegularExpression regularExpressionWithPattern:
                              @"(?:video_title|videoTitle|title)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""
                                                                            options:0
                                                                              error:nil];
        channelRegex = [NSRegularExpression regularExpressionWithPattern:
                          @"(?:owner_display_name|ownerDisplayName|channel_name|channelName)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""
                                                                                options:0
                                                                                  error:nil];
    });
    NSRegularExpression *regex = [pattern containsString:@"video_id"] || [pattern containsString:@"videoId"]
                                      ? videoIdRegex
                                  : [pattern containsString:@"video_title"] || [pattern containsString:@"videoTitle"]
                                      ? videoTitleRegex
                                      : channelRegex;
    NSTextCheckingResult *match = [regex firstMatchInString:description
                                                     options:0
                                                       range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges < 2)
        return nil;

    NSString *value = [description substringWithRange:[match rangeAtIndex:1]];
    value = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
    value = [value stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void RecordSerializedDescription(NSMutableDictionary *result,
                                                 NSMutableDictionary *priorities,
                                                 NSString *description) {
    if (description.length == 0)
        return;

    RecordField(result, priorities, @"videoId",
                        DescriptionField(description,
                                                 @"(?:video_id|videoId|video_identifier)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""));
    RecordField(result, priorities, @"videoTitle",
                        DescriptionField(description,
                                                 @"(?:video_title|videoTitle|title)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""));
    RecordField(result, priorities, @"ownerDisplayName",
                        DescriptionField(description,
                                                 @"(?:owner_display_name|ownerDisplayName|channel_name|channelName)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""));
}

static NSArray<NSString *> *MetadataFieldKeys(void);

static id InlinePlaybackNodeFromObject(id object, NSUInteger depth) {
    if (!object || depth > 12)
        return nil;

    if ([NSStringFromClass([object class]) isEqualToString:@"YTInlinePlaybackPlayerNode"])
        return object;

    NSArray *subnodes = ValueForKey(object, @"subnodes");
    if (![subnodes isKindOfClass:[NSArray class]])
        return nil;
    NSUInteger childCount = 0;
    for (id subnode in subnodes) {
        if (childCount++ >= 48)
            break;
        id inlineNode = InlinePlaybackNodeFromObject(subnode, depth + 1);
        if (inlineNode)
            return inlineNode;
    }

    return nil;
}

static void CollectLegacyInlinePlaybackMetadata(id node,
                                                NSMutableDictionary *result,
                                                NSMutableDictionary *priorities) {
    id inlineNode = InlinePlaybackNodeFromObject(node, 0);
    if (!inlineNode)
        return;

    UIView *view = ValueForKey(inlineNode, @"view");
    if (![view isKindOfClass:[UIView class]])
        return;
    for (UIView *subview in view.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        if ([className rangeOfString:@"YTElementsInlineMutedPlaybackView"].location == NSNotFound)
            continue;

        id playableEntry = ValueForKey(subview, @"asdPlayableEntry");
        for (NSString *key in MetadataFieldKeys())
            RecordField(result, priorities, key, ValueForNamedKey(playableEntry, key));

        id navigationEndpoint = ValueForNamedKey(playableEntry, @"navigationEndpoint");
        for (NSString *key in MetadataFieldKeys())
            RecordField(result, priorities, key, ValueForNamedKey(navigationEndpoint, key));

        RecordSerializedDescription(result, priorities,
                                    TextFromValue(ValueForNamedKey(navigationEndpoint, @"description"), 0));
        if (MetadataComplete(result))
            return;
    }
}

static NSArray<NSString *> *MetadataChildKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"entry", @"nodeModel", @"parentResponder", @"materializedInstance", @"owningNode", @"cellNode", @"parentNode", @"supernode", @"superNode", @"containerNode", @"node", @"children",
            @"element", @"context", @"instance", @"properties", @"allProperties", @"childElements", @"subnodes",
            @"elementEntry", @"collectionElement", @"controller", @"viewController", @"closestViewController", @"playbackView", @"asdPlayableEntry",
            @"playerViewController", @"shortsPlayerViewController", @"currentReel", @"reel", @"reelItem", @"reelPlayer",
            @"player", @"activeVideo", @"currentPlayer", @"videoPlayer", @"navigationEndpoint", @"watchEndpoint", @"browseEndpoint",
            @"store", @"fromView", @"rangedDataCellContext", @"byteStore",
            @"proto", @"protobuf", @"message", @"payload", @"rawValue", @"value", @"object", @"contents", @"yogaChildren",
            @"attributedText", @"accessibilityLabel",
            @"videoRenderer", @"compactVideoRenderer", @"richItemRenderer", @"reelItemRenderer",
            @"videoDetails", @"microformat", @"ownerText", @"shortBylineText", @"longBylineText",
            @"command", @"endpoint", @"playerResponse", @"protoText", @"currentVideo", @"videoController",
            @"watchController", @"playbackController", @"videoData", @"response", @"renderer", @"content", @"data", @"model", @"media"
        ];
    });
    return keys;
}

static NSArray<NSString *> *MetadataFieldKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"videoId", @"videoID", @"videoIdentifier", @"contentVideoId", @"contentVideoID", @"youtubeVideoId",
            @"youtubeVideoID", @"playerResponseVideoId", @"playerResponseVideoID", @"watchVideoId", @"watchVideoID",
            @"video_id", @"video_identifier", @"content_video_id", @"youtube_video_id", @"player_response_video_id", @"watch_video_id",
            @"videoURL", @"watchURL", @"webpageURL", @"url",
            @"videoTitle", @"contentTitle", @"videoName", @"title", @"headline", @"titleText",
            @"video_title", @"content_title", @"video_name", @"title_text",
            @"ownerDisplayName", @"ownerName", @"channelDisplayName", @"authorName", @"channelName",
            @"channelTitle", @"displayName", @"channel", @"author", @"owner",
            @"owner_display_name", @"owner_name", @"channel_display_name", @"author_name", @"channel_name",
            @"channel_title", @"display_name"
        ];
    });
    return keys;
}

static BOOL ShouldVisitMetadataKey(NSString *key) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet *normalizedKeys = [NSMutableSet set];
        for (NSString *candidate in MetadataChildKeys())
            [normalizedKeys addObject:NormalizedKey(candidate)];
        keys = [normalizedKeys copy];
    });
    return [keys containsObject:NormalizedKey(key)];
}

static void CollectElementTreeMetadata(id object,
                                                NSMutableDictionary *result,
                                                NSMutableDictionary *priorities,
                                                NSMutableSet *visited,
                                                NSUInteger depth) {
    if (!object || depth > 16)
        return;

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return;
    [visited addObject:identity];

    NSString *className = NSStringFromClass([object class]).lowercaseString;
    CollectElementRendererMetadata(object, result, priorities);
    if (MetadataComplete(result))
        return;

    NSString *objectDescription = @"";
    if ([className containsString:@"textnode"]) {
        @try {
            objectDescription = [object debugDescription] ?: @"";
        } @catch (__unused NSException *exception) {
        }
        NSAttributedString *attributedText = ValueForKey(object, @"attributedText");
        NSString *text = TextFromValue(attributedText, 0);
        if ([objectDescription containsString:@"channel_name"] && text.length > 0)
            RecordField(result, priorities, @"ownerDisplayName", text);
        if ([objectDescription containsString:@"shorts-video-title"] && text.length > 0) {
            RecordField(result, priorities, @"videoTitle", text);
        }
    }

    static NSArray<NSString *> *keyCandidates;
    static dispatch_once_t keyOnceToken;
    dispatch_once(&keyOnceToken, ^{
        keyCandidates = @[
            @"videoId", @"videoID", @"video_id", @"videoIdentifier", @"contentVideoId", @"contentVideoID", @"youtubeVideoId",
            @"youtubeVideoID", @"playerResponseVideoId", @"playerResponseVideoID", @"watchVideoId", @"watchVideoID", @"videoURL", @"watchURL", @"webpageURL",
            @"contentId", @"entityId", @"id", @"navigationEndpoint", @"watchEndpoint", @"endpoint",
            @"command", @"playerResponse", @"videoDetails", @"protoText", @"videoTitle", @"title", @"channelName", @"ownerName",
            @"ownerDisplayName", @"channelDisplayName", @"authorName", @"channelTitle", @"displayName", @"channel", @"author", @"owner"
        ];
    });
    BOOL allowsGenericIdentifier = [className containsString:@"video"] || [className containsString:@"short"] ||
                                    [className containsString:@"reel"];
    id element = ValueForKey(object, @"element");
    id context = ValueForKey(object, @"context");
    id instance = ValueForKey(element, @"instance");
    id properties = ValueForKey(element, @"properties");
    id allProperties = ValueForKey(element, @"allProperties");
    NSArray *containers = @[
        object ?: [NSNull null],
        element ?: [NSNull null],
        context ?: [NSNull null],
        instance ?: [NSNull null],
        properties ?: [NSNull null],
        allProperties ?: [NSNull null]
    ];
    for (id container in containers) {
        if (container == [NSNull null])
            continue;
        for (NSString *key in keyCandidates) {
            id value = ValueForNamedKey(container, key);
            if (!value)
                continue;
            if ([key isEqualToString:@"id"]) {
                if (!allowsGenericIdentifier)
                    continue;
                NSString *identifier = VideoIdFromText(TextFromValue(value, 0));
                if (identifier.length > 0 && [priorities[@"id"] unsignedIntegerValue] < 50) {
                    result[@"id"] = identifier;
                    priorities[@"id"] = @50;
                }
            } else if ([key isEqualToString:@"protoText"]) {
                RecordSerializedDescription(result, priorities, TextFromValue(value, 0));
            } else {
                RecordField(result, priorities, key, value);
            }
            if (value != container && ![value isKindOfClass:[NSString class]] &&
                ![value isKindOfClass:[NSNumber class]])
                CollectElementTreeMetadata(value, result, priorities, visited, depth + 1);
        }
        if (MetadataComplete(result))
            return;
    }

    NSArray *childElements = ValueForNamedKey(element, @"childElements");
    if ([childElements isKindOfClass:[NSArray class]]) {
        NSUInteger childElementCount = 0;
        for (id childElement in childElements) {
            if (childElementCount++ >= 48)
                break;
            CollectElementTreeMetadata(childElement, result, priorities, visited, depth + 1);
            if (MetadataComplete(result))
                return;
        }
    }

    NSArray *subnodes = ValueForKey(object, @"subnodes");
    if ([subnodes isKindOfClass:[NSArray class]]) {
        NSUInteger subnodeCount = 0;
        for (id subnode in subnodes) {
            if (subnodeCount++ >= 48)
                break;
            CollectElementTreeMetadata(subnode, result, priorities, visited, depth + 1);
            if (MetadataComplete(result))
                return;
        }
    }
}

static void CollectObject(id object, NSMutableDictionary *result, NSMutableDictionary *priorities,
                                  NSMutableSet *visited, NSUInteger *budget, NSUInteger depth);

static void CollectObject(id object, NSMutableDictionary *result, NSMutableDictionary *priorities,
                                  NSMutableSet *visited, NSUInteger *budget, NSUInteger depth) {
    if (!object || !budget || *budget == 0 || depth > 7)
        return;

    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]])
        return;

    if ([object isKindOfClass:[NSData class]] || [object isKindOfClass:[NSAttributedString class]])
        return;

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return;
    [visited addObject:identity];
    (*budget)--;

    CollectElementRendererMetadata(object, result, priorities);
    if (MetadataComplete(result))
        return;

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSUInteger keyCount = 0;
        for (id key in [(NSDictionary *)object allKeys]) {
            if (keyCount++ >= 48)
                break;
            id value = [(NSDictionary *)object objectForKey:key];
            if ([key isKindOfClass:[NSString class]]) {
                RecordField(result, priorities, key, value);
                if (ShouldVisitMetadataKey(key))
                    CollectObject(value, result, priorities, visited, budget, depth + 1);
            }
            if (MetadataComplete(result))
                return;
        }
        return;
    }

    if ([object isKindOfClass:[NSArray class]] || [object isKindOfClass:[NSSet class]]) {
        NSUInteger childCount = 0;
        for (id value in object) {
            if (childCount++ >= 24)
                break;
            CollectObject(value, result, priorities, visited, budget, depth + 1);
            if (MetadataComplete(result))
                return;
        }
        return;
    }

    if ([object isKindOfClass:[UIView class]]) {
        id node = ValueForKey(object, @"asyncdisplaykit_node");
        if (node && node != object)
            CollectObject(node, result, priorities, visited, budget, depth + 1);
        return;
    }

    for (NSString *key in MetadataFieldKeys()) {
        id value = ValueForNamedKey(object, key);
        if (value)
            RecordField(result, priorities, key, value);
        if (MetadataComplete(result))
            return;
    }

    for (NSString *key in MetadataChildKeys()) {
        id value = ValueForNamedKey(object, key);
        if (!value)
            continue;
        if ([NormalizedKey(key) isEqualToString:@"prototext"])
            RecordSerializedDescription(result, priorities, TextFromValue(value, 0));
        else
            RecordField(result, priorities, key, value);
        if (MetadataComplete(result))
            return;
        if (value != object && ![value isKindOfClass:[UIView class]])
            CollectObject(value, result, priorities, visited, budget, depth + 1);
        if (MetadataComplete(result))
            return;
        if (*budget == 0)
            return;
    }
}

static NSString *TextForNode(id node) {
    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")]) {
        NSString *text = TextFromValue(ValueForKey(node, @"attributedText"), 0);
        if (text.length > 0)
            return text;
    }

    NSString *accessibilityLabel = TextFromValue(ValueForKey(node, @"accessibilityLabel"), 0);
    return accessibilityLabel.length > 0 ? accessibilityLabel : nil;
}

static void CollectInlinePlaybackMetadata(id node,
                                                   NSMutableDictionary *result,
                                                   NSMutableDictionary *priorities) {
    if (!node)
        return;

    @try {
        NSMutableArray *playbackViews = [NSMutableArray array];
        id playbackView = ValueForKey(node, @"playbackView");
        if (playbackView)
            [playbackViews addObject:playbackView];

        UIView *view = ValueForKey(node, @"view");
        if ([view isKindOfClass:[UIView class]])
            [playbackViews addObjectsFromArray:view.subviews];

        for (id candidate in playbackViews) {
            NSString *className = NSStringFromClass([candidate class]);
            if ([className rangeOfString:@"YTElementsInlineMutedPlaybackView"].location == NSNotFound)
                continue;

            id playableEntry = ValueForKey(candidate, @"asdPlayableEntry");
            for (NSString *key in MetadataFieldKeys())
                RecordField(result, priorities, key, ValueForKey(playableEntry, key));

            id navigationEndpoint = ValueForKey(playableEntry, @"navigationEndpoint");
            for (NSString *key in MetadataFieldKeys())
                RecordField(result, priorities, key, ValueForKey(navigationEndpoint, key));

            NSString *entryDescription = TextFromValue(ValueForKey(playableEntry, @"description"), 0);
            NSString *endpointDescription = TextFromValue(ValueForKey(navigationEndpoint, @"description"), 0);
            RecordSerializedDescription(result, priorities, entryDescription);
            RecordSerializedDescription(result, priorities, endpointDescription);
            if (MetadataComplete(result))
                return;
        }
    } @catch (__unused NSException *exception) {
    }
}

static NSDictionary *VideoInfoFromNode(id node, BOOL bypassCache) {
    if (!node)
        return nil;

    if (!bypassCache) {
        NSDictionary *cached = [MetadataCache() objectForKey:node];
        if (cached)
            return cached;

        NSDictionary *attempt = [MetadataAttemptCache() objectForKey:node];
        NSNumber *timestamp = attempt[@"timestamp"];
        if (timestamp && CFAbsoluteTimeGetCurrent() - timestamp.doubleValue < 0.75)
            return attempt[@"metadata"];
        if (attempt)
            [MetadataAttemptCache() removeObjectForKey:node];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableDictionary *priorities = [NSMutableDictionary dictionary];
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableSet *elementVisited = [NSMutableSet set];
    NSUInteger budget = 48;

    @try {
        id parentResponder = ValueForNamedKey(node, @"parentResponder");
        id elementEntry = ValueForNamedKey(parentResponder, @"elementEntry");
        CollectElementRendererMetadata(elementEntry, result, priorities);
        CollectElementTreeMetadata(node, result, priorities, elementVisited, 0);
        CollectObject(node, result, priorities, visited, &budget, 0);
        id context = ValueForNamedKey(node, @"context");
        if (context) {
            NSUInteger contextBudget = 48;
            CollectObject(context, result, priorities, [NSMutableSet set], &contextBudget, 0);
        }
        id store = ValueForNamedKey(context, @"store");
        if (store) {
            for (NSString *key in MetadataFieldKeys())
                RecordField(result, priorities, key, ValueForNamedKey(store, key));
            NSUInteger storeBudget = 96;
            CollectObject(store, result, priorities, [NSMutableSet set], &storeBudget, 0);
        }
        NSString *nodeClassName = NSStringFromClass([node class]).lowercaseString;
        if ([nodeClassName containsString:@"short"] || [nodeClassName containsString:@"reel"]) {
            UIView *nodeView = ValueForNamedKey(node, @"view");
            id viewNode = ValueForNamedKey(nodeView, @"asyncdisplaykit_node");
            if (viewNode && viewNode != node) {
                CollectElementTreeMetadata(viewNode, result, priorities, elementVisited, 0);
                NSUInteger viewBudget = 96;
                CollectObject(viewNode, result, priorities, [NSMutableSet set], &viewBudget, 0);
            }
        }
        CollectLegacyInlinePlaybackMetadata(node, result, priorities);
        CollectInlinePlaybackMetadata(node, result, priorities);
        BOOL isShortsNode = [nodeClassName containsString:@"short"] || [nodeClassName containsString:@"reel"];
        if (isShortsNode && IsShortsControlText(result[@"title"])) {
            [result removeObjectForKey:@"title"];
            [priorities removeObjectForKey:@"title"];
        }
        NSString *title = result[@"title"];
        NSString *channel = result[@"channel"];
        NSString *lowercaseTitle = title.lowercaseString;
        NSString *lowercaseChannel = channel.lowercaseString;
        if (title.length > 0 && channel.length > 0 &&
            ([channel isEqualToString:title] ||
             [lowercaseChannel containsString:lowercaseTitle])) {
            [result removeObjectForKey:@"channel"];
            [priorities removeObjectForKey:@"channel"];
        }
        if ([result[@"channel"] length] == 0) {
            NSString *channel = ChannelTextFromNode(node, result[@"title"]);
            if (channel.length > 0)
                RecordField(result, priorities, @"ownerDisplayName", channel);
        }
        NSString *shortsChannel = ShortsChannelTextFromNode(node);
        if (shortsChannel.length > 0)
            RecordField(result, priorities, @"ownerDisplayName", shortsChannel);
        if ([result[@"title"] length] == 0) {
            NSString *shortsTitle = ShortsTitleTextFromNode(node, result[@"channel"]);
            if (shortsTitle.length > 0)
                RecordField(result, priorities, @"videoTitle", shortsTitle);
        }
    } @catch (__unused NSException *exception) {
    }

    if (result.count == 0) {
        if (!bypassCache)
            [MetadataAttemptCache() setObject:@{ @"metadata": @{}, @"timestamp": @(CFAbsoluteTimeGetCurrent()) }
                                       forKey:node];
        return nil;
    }
    NSDictionary *metadata = [result copy];
    if (MetadataComplete(metadata)) {
        [MetadataCache() setObject:metadata forKey:node];
        [MetadataAttemptCache() removeObjectForKey:node];
    } else if (!bypassCache) {
        [MetadataAttemptCache() setObject:@{ @"metadata": metadata, @"timestamp": @(CFAbsoluteTimeGetCurrent()) }
                                   forKey:node];
    }
    return metadata;
}

@implementation Util

+ (void)showToast:(NSString *)message fromView:(UIView *)view {
    if (message.length == 0)
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = view.window;
        if (!window) {
            for (UIWindow *candidate in [UIApplication sharedApplication].windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
        }
        if (!window)
            window = [UIApplication sharedApplication].windows.firstObject;
        if (!window)
            return;

        static void *toastKey = &toastKey;
        UIView *previousToast = objc_getAssociatedObject(window, toastKey);
        [previousToast removeFromSuperview];

        UILabel *label = [UILabel new];
        label.text = message;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;

        UIView *toast = [UIView new];
        toast.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.86];
        toast.layer.cornerRadius = 10.0;
        toast.userInteractionEnabled = NO;
        [toast addSubview:label];
        [window addSubview:toast];

        CGFloat maximumWidth = MAX(120.0, window.bounds.size.width - 40.0);
        CGSize labelSize = [label sizeThatFits:CGSizeMake(maximumWidth - 28.0, CGFLOAT_MAX)];
        CGSize toastSize = CGSizeMake(MIN(maximumWidth, labelSize.width + 28.0), labelSize.height + 18.0);
        toast.bounds = (CGRect){CGPointZero, toastSize};
        label.frame = (CGRect){CGPointMake(14.0, 9.0), CGSizeMake(toastSize.width - 28.0, toastSize.height - 18.0)};
        CGFloat bottomInset = MAX(window.safeAreaInsets.bottom + 24.0, 72.0);
        toast.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetHeight(window.bounds) - bottomInset);
        toast.alpha = 0.0;
        objc_setAssociatedObject(window, toastKey, toast, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [UIView animateWithDuration:0.18 animations:^{
            toast.alpha = 1.0;
        } completion:^(__unused BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (objc_getAssociatedObject(window, toastKey) != toast)
                    return;
                [UIView animateWithDuration:0.18 animations:^{
                    toast.alpha = 0.0;
                } completion:^(__unused BOOL finished) {
                    [toast removeFromSuperview];
                    objc_setAssociatedObject(window, toastKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }];
            });
        }];
    });
}

+ (void)refreshFeedViews {
    static BOOL refreshQueued = NO;
    if (refreshQueued)
        return;
    refreshQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *pendingViews = [NSMutableArray array];
        for (UIWindow *window in [UIApplication sharedApplication].windows)
            [pendingViews addObject:window];

        while (pendingViews.count > 0) {
            UIView *view = pendingViews.lastObject;
            [pendingViews removeLastObject];
            if ([view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")])
                [(UICollectionView *)view reloadData];
            [pendingViews addObjectsFromArray:view.subviews];
        }
        refreshQueued = NO;
    });
}

+ (NSDictionary *)videoInfoFromNode:(id)node {
    return VideoInfoFromNode(node, NO);
}

+ (BOOL)isUsableVideoTitle:(NSString *)title {
    return title.length > 0 && !IsShortsControlText(title);
}

+ (NSDictionary *)freshVideoInfoFromNode:(id)node {
    if (!node)
        return nil;
    [MetadataAttemptCache() removeObjectForKey:node];
    return VideoInfoFromNode(node, YES);
}

+ (NSDictionary *)freshVideoInfoFromNode:(id)node sourceView:(UIView *)sourceView {
    NSMutableDictionary *metadata = [[VideoInfoFromNode(node, YES) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    NSDictionary *feedMetadata = FeedMetadataFromView(sourceView);
    for (NSString *key in @[@"title", @"channel"]) {
        NSString *value = feedMetadata[key];
        BOOL replacePlaceholder = [key isEqualToString:@"title"] &&
                                  ![self isUsableVideoTitle:metadata[key]] &&
                                  [self isUsableVideoTitle:value];
        if (([metadata[key] length] == 0 || replacePlaceholder) && value.length > 0)
            metadata[key] = value;
    }
    if (metadata.count == 0)
        return nil;
    if (MetadataComplete(metadata))
        [MetadataCache() setObject:[metadata copy] forKey:node];
    return [metadata copy];
}

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion {
    if (!completion)
        return;

    NSDictionary *info = [self videoInfoFromNode:node];
    completion(info[@"id"], info[@"title"], info[@"channel"]);
}

+ (BOOL)nodeContainsBlockedVideo:(id)node {
    return [self nodeContainsBlockedVideo:node videoInfo:nil];
}

+ (BOOL)nodeContainsBlockedVideo:(id)node
                        videoInfo:(NSDictionary<NSString *,NSString *> *)videoInfo {
    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                         ? YES
                         : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"];
    if (!isEnabled)
        return NO;

    NSDictionary *info = videoInfo ?: [self videoInfoFromNode:node];
    if ([[VideoManager sharedInstance] isVideoBlocked:info[@"id"]] ||
        [[ChannelManager sharedInstance] isChannelBlocked:info[@"channel"]] ||
        [[WordManager sharedInstance] isWordBlocked:info[@"title"]] ||
        [[WordManager sharedInstance] isWordBlocked:info[@"channel"]])
        return YES;

    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")]) {
        NSString *text = TextForNode(node);
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults boolForKey:@"GonerinoPeopleWatched"] &&
            [text isEqualToString:@"People also watched this video"])
            return YES;
        if ([defaults boolForKey:@"GonerinoMightLike"] &&
            [text isEqualToString:@"You might also like this"])
            return YES;
    }

    return NO;
}

+ (UIImage *)createBlockChannelIconWithSize:(CGSize)size {
    @try {
        UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context)
            return nil;

        CGContextSetShouldAntialias(context, YES);
        CGContextSetAllowsAntialiasing(context, YES);
        [[UIColor whiteColor] setStroke];

        CGFloat contentWidth = size.width;
        CGFloat contentHeight = size.height;

        CGFloat radius = contentWidth * 0.45;
        CGPoint center = CGPointMake(contentWidth / 2, contentHeight / 2);
        UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:center
                                                                  radius:radius
                                                              startAngle:0
                                                                endAngle:2 * M_PI
                                                               clockwise:YES];
        UIBezierPath *body = [UIBezierPath bezierPathWithArcCenter:CGPointMake(contentWidth / 2, contentHeight * 0.85)
                                                              radius:contentWidth * 0.3
                                                          startAngle:M_PI
                                                            endAngle:2 * M_PI
                                                           clockwise:YES];
        UIBezierPath *head = [UIBezierPath bezierPathWithArcCenter:CGPointMake(contentWidth / 2, contentHeight * 0.35)
                                                              radius:contentWidth * 0.15
                                                          startAngle:0
                                                            endAngle:2 * M_PI
                                                           clockwise:YES];
        UIBezierPath *line = [UIBezierPath bezierPath];
        CGFloat offset = radius * 0.7071;
        [line moveToPoint:CGPointMake(center.x - offset, center.y - offset)];
        [line addLineToPoint:CGPointMake(center.x + offset, center.y + offset)];

        circle.lineWidth = 1.5;
        body.lineWidth = 1.5;
        head.lineWidth = 1.5;
        line.lineWidth = 1.5;
        [circle stroke];
        [body stroke];
        [head stroke];
        [line stroke];

        UIImage *icon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

+ (UIImage *)createBlockVideoIconWithSize:(CGSize)size {
    @try {
        UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context)
            return nil;

        CGContextSetShouldAntialias(context, YES);
        CGContextSetAllowsAntialiasing(context, YES);
        [[UIColor whiteColor] setStroke];
        [[UIColor whiteColor] setFill];

        CGFloat contentWidth = size.width;
        CGFloat contentHeight = size.height;

        CGPoint center = CGPointMake(contentWidth / 2, contentHeight / 2);
        UIBezierPath *rectangle = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(contentWidth * 0.2, contentHeight * 0.3,
                                                                                       contentWidth * 0.6, contentHeight * 0.4)
                                                               cornerRadius:3.0];
        UIBezierPath *triangle = [UIBezierPath bezierPath];
        CGFloat triangleSize = contentWidth * 0.2;
        [triangle moveToPoint:CGPointMake(center.x - triangleSize / 2, center.y - triangleSize / 2)];
        [triangle addLineToPoint:CGPointMake(center.x + triangleSize / 2, center.y)];
        [triangle addLineToPoint:CGPointMake(center.x - triangleSize / 2, center.y + triangleSize / 2)];
        [triangle closePath];

        CGFloat radius = contentWidth * 0.45;
        UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:center
                                                                  radius:radius
                                                              startAngle:0
                                                                endAngle:2 * M_PI
                                                               clockwise:YES];
        UIBezierPath *line = [UIBezierPath bezierPath];
        CGFloat offset = radius * 0.7071;
        [line moveToPoint:CGPointMake(center.x - offset, center.y - offset)];
        [line addLineToPoint:CGPointMake(center.x + offset, center.y + offset)];

        rectangle.lineWidth = 1.5;
        triangle.lineWidth = 1.5;
        circle.lineWidth = 1.5;
        line.lineWidth = 1.5;
        [rectangle stroke];
        [triangle fill];
        [circle stroke];
        [line stroke];

        UIImage *icon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

@end
