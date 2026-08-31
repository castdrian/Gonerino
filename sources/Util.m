#import "Util.h"
#import "ChannelManager.h"
#import "VideoManager.h"

#import <objc/runtime.h>
#import <objc/message.h>

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

static BOOL IsVideoIdCandidate(NSString *value) {
    if (value.length != 11)
        return NO;

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    return [value rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
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

static void RecordVideoIdsFromProtobuf(const uint8_t *bytes,
                                               NSUInteger length,
                                               NSMutableDictionary *result,
                                               NSMutableDictionary *priorities,
                                               NSUInteger depth) {
    if (!bytes || length == 0 || depth > 6)
        return;

    length = MIN(length, (NSUInteger)65536);

    for (NSUInteger index = 0; index < length; index++) {
        NSUInteger cursor = index;
        uint64_t tag = 0;
        if (!ReadVarint(bytes, length, &cursor, &tag) || tag < 8)
            continue;

        NSUInteger wireType = tag & 7;
        if (wireType == 2) {
            uint64_t valueLength = 0;
            if (!ReadVarint(bytes, length, &cursor, &valueLength) || valueLength > length - cursor)
                continue;
            NSString *value = [[NSString alloc] initWithBytes:bytes + cursor
                                                        length:(NSUInteger)valueLength
                                                      encoding:NSUTF8StringEncoding];
            if (IsVideoIdCandidate(value))
                RecordField(result, priorities, @"url", value);
            RecordVideoIdsFromProtobuf(bytes + cursor,
                                               MIN((NSUInteger)valueLength, (NSUInteger)65536),
                                               result,
                                               priorities,
                                               depth + 1);
            index = cursor + (NSUInteger)valueLength - 1;
        } else if (wireType == 0) {
            ReadVarint(bytes, length, &cursor, &tag);
            index = cursor > index ? cursor - 1 : index;
        } else if (wireType == 1 && cursor + 8 <= length) {
            index = cursor + 7;
        } else if (wireType == 5 && cursor + 4 <= length) {
            index = cursor + 3;
        }
    }
}

static void RecordVideoIdsFromData(NSMutableDictionary *result,
                                           NSMutableDictionary *priorities,
                                           NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return;

    const uint8_t *bytes = data.bytes;
    NSUInteger length = MIN(data.length, (NSUInteger)262144);
    for (NSUInteger index = 0; index + 11 <= length; index++) {
        NSUInteger end = index;
        while (end < length && ((bytes[end] >= 'a' && bytes[end] <= 'z') ||
                                (bytes[end] >= 'A' && bytes[end] <= 'Z') ||
                                (bytes[end] >= '0' && bytes[end] <= '9') ||
                                bytes[end] == '_' || bytes[end] == '-'))
            end++;
        if (end - index == 11) {
            NSString *candidate = [[NSString alloc] initWithBytes:bytes + index
                                                            length:11
                                                          encoding:NSUTF8StringEncoding];
            if (IsVideoIdCandidate(candidate))
                RecordField(result, priorities, @"url", candidate);
        }
        index = end > index ? end - 1 : index;
    }
    RecordVideoIdsFromProtobuf(bytes, length, result, priorities, 0);
}

static void RecordAttributedStringVideoIds(NSAttributedString *string,
                                                    NSMutableDictionary *result,
                                                    NSMutableDictionary *priorities) {
    if (![string isKindOfClass:[NSAttributedString class]] || string.length == 0)
        return;

    @try {
        NSUInteger index = 0;
        while (index < string.length) {
            NSRange range = NSMakeRange(0, 0);
            NSDictionary *attributes = [string attributesAtIndex:index effectiveRange:&range];
            for (id value in attributes.allValues) {
                if ([value isKindOfClass:[NSData class]])
                    RecordVideoIdsFromData(result, priorities, value);
            }
            NSUInteger nextIndex = NSMaxRange(range);
            if (nextIndex <= index)
                break;
            index = nextIndex;
        }
    } @catch (__unused NSException *exception) {
    }
}

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

static NSString *VideoIdFromText(NSString *text) {
    if (text.length == 0)
        return nil;

    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
                     @"(?:[?&]v=|youtu\\.be/|/shorts/|/embed/)([A-Za-z0-9_-]{11})(?:[^A-Za-z0-9_-]|$)"
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

static FieldRole RoleForKey(NSString *key, NSUInteger *priority) {
    NSString *normalized = NormalizedKey(key);
    if ([normalized isEqualToString:@"videoid"] || [normalized isEqualToString:@"videoidentifier"] ||
        [normalized isEqualToString:@"contentvideoid"] || [normalized isEqualToString:@"youtubevideoid"] ||
        [normalized isEqualToString:@"playerresponsevideoid"] || [normalized isEqualToString:@"watchvideoid"]) {
        if (priority)
            *priority = [normalized isEqualToString:@"videoid"] ? 100 : 90;
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
            @"element", @"context", @"instance", @"properties", @"allProperties", @"childElements", @"subnodes",
            @"elementEntry", @"controller", @"viewController", @"closestViewController", @"playbackView", @"asdPlayableEntry",
            @"playerViewController", @"shortsPlayerViewController", @"currentReel", @"reel", @"reelItem", @"reelPlayer",
            @"player", @"activeVideo", @"currentPlayer", @"videoPlayer", @"navigationEndpoint", @"watchEndpoint", @"browseEndpoint",
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
            @"videoURL", @"watchURL", @"webpageURL", @"url",
            @"videoTitle", @"contentTitle", @"videoName", @"title", @"headline", @"titleText",
            @"ownerDisplayName", @"ownerName", @"channelDisplayName", @"authorName", @"channelName",
            @"channelTitle", @"displayName", @"channel", @"author", @"owner"
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
            RecordAttributedStringVideoIds(attributedText, result, priorities);
        }
    }

    static NSArray<NSString *> *keyCandidates;
    static dispatch_once_t keyOnceToken;
    dispatch_once(&keyOnceToken, ^{
        keyCandidates = @[
            @"videoId", @"videoID", @"video_id", @"videoIdentifier", @"contentVideoId", @"contentVideoID", @"youtubeVideoId",
            @"youtubeVideoID", @"playerResponseVideoId", @"playerResponseVideoID", @"watchVideoId", @"watchVideoID", @"videoURL", @"watchURL", @"webpageURL",
            @"contentId", @"entityId", @"navigationEndpoint", @"watchEndpoint", @"endpoint",
            @"command", @"playerResponse", @"videoDetails", @"title", @"channelName", @"ownerName"
        ];
    });
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
            RecordField(result, priorities, key, value);
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

    if ([object isKindOfClass:[NSData class]]) {
        RecordVideoIdsFromData(result, priorities, object);
        return;
    }

    if ([object isKindOfClass:[NSAttributedString class]]) {
        RecordAttributedStringVideoIds(object, result, priorities);
        return;
    }

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return;
    [visited addObject:identity];
    (*budget)--;

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
        CollectLegacyInlinePlaybackMetadata(node, result, priorities);
        CollectInlinePlaybackMetadata(node, result, priorities);
        CollectElementTreeMetadata(node, result, priorities, elementVisited, 0);
        CollectObject(node, result, priorities, visited, &budget, 0);
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
    });
}

+ (NSDictionary *)videoInfoFromNode:(id)node {
    return VideoInfoFromNode(node, NO);
}

+ (NSDictionary *)freshVideoInfoFromNode:(id)node {
    if (!node)
        return nil;
    [MetadataAttemptCache() removeObjectForKey:node];
    return VideoInfoFromNode(node, YES);
}

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion {
    if (!completion)
        return;

    NSDictionary *info = [self videoInfoFromNode:node];
    completion(info[@"id"], info[@"title"], info[@"channel"]);
}

+ (BOOL)nodeContainsBlockedVideo:(id)node {
    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                         ? YES
                         : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"];
    if (!isEnabled)
        return NO;

    NSDictionary *info = [self videoInfoFromNode:node];
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
