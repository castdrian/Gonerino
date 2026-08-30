#import "Util.h"
#import "ChannelManager.h"
#import "VideoManager.h"

#import <objc/runtime.h>
#import <objc/message.h>

@interface NSObject (GonerinoText)
- (NSString *)stringWithFormattingRemoved;
- (NSString *)string;
@end

typedef NS_ENUM(NSUInteger, GonerinoFieldRole) {
    GonerinoFieldRoleNone,
    GonerinoFieldRoleVideoId,
    GonerinoFieldRoleTitle,
    GonerinoFieldRoleChannel
};

static NSMapTable *GonerinoMetadataCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMapTable weakToStrongObjectsMapTable];
    });
    return cache;
}

static NSString *GonerinoNormalizedKey(NSString *key) {
    if (key.length == 0)
        return @"";

    NSMutableString *normalized = [key.lowercaseString mutableCopy];
    [normalized replaceOccurrencesOfString:@"_" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"-" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    return normalized;
}

static BOOL GonerinoMetadataComplete(NSDictionary *result) {
    return [result[@"id"] length] > 0 && [result[@"title"] length] > 0 && [result[@"channel"] length] > 0;
}

static id GonerinoValueForKey(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    @try {
        if ([object isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dictionary = object;
            id value = dictionary[key];
            if (value)
                return value;

            NSString *normalizedKey = GonerinoNormalizedKey(key);
            for (id dictionaryKey in dictionary.allKeys) {
                if (![dictionaryKey isKindOfClass:[NSString class]])
                    continue;
                NSString *candidate = GonerinoNormalizedKey(dictionaryKey);
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

static id GonerinoValueForArgumentKey(id object, SEL selector, NSString *key) {
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

static id GonerinoValueForNamedKey(id object, NSString *key) {
    id value = GonerinoValueForKey(object, key);
    if (value)
        return value;

    for (NSString *selectorName in @[@"propertyForKey:", @"elementForKey:", @"safeSwiftValueForKey:", @"safeSwiftStringForKey:", @"tps_safeValueForKey:", @"valueForKey:"]) {
        value = GonerinoValueForArgumentKey(object, NSSelectorFromString(selectorName), key);
        if (value)
            return value;
    }

    return nil;
}

static void GonerinoRecordField(NSMutableDictionary *result, NSMutableDictionary *priorities, NSString *key, id value);

static BOOL GonerinoIsVideoIdCandidate(NSString *value) {
    if (value.length != 11)
        return NO;

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    return [value rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

static BOOL GonerinoReadVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *offset, uint64_t *value) {
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

static void GonerinoRecordVideoIdsFromProtobuf(const uint8_t *bytes,
                                               NSUInteger length,
                                               NSMutableDictionary *result,
                                               NSMutableDictionary *priorities,
                                               NSUInteger depth) {
    if (!bytes || length == 0 || depth > 8)
        return;

    for (NSUInteger index = 0; index < length; index++) {
        NSUInteger cursor = index;
        uint64_t tag = 0;
        if (!GonerinoReadVarint(bytes, length, &cursor, &tag) || tag < 8)
            continue;

        NSUInteger wireType = tag & 7;
        if (wireType == 2) {
            uint64_t valueLength = 0;
            if (!GonerinoReadVarint(bytes, length, &cursor, &valueLength) || valueLength > length - cursor)
                continue;
            NSString *value = [[NSString alloc] initWithBytes:bytes + cursor
                                                        length:(NSUInteger)valueLength
                                                      encoding:NSUTF8StringEncoding];
            if (GonerinoIsVideoIdCandidate(value))
                GonerinoRecordField(result, priorities, @"videoId", value);
            GonerinoRecordVideoIdsFromProtobuf(bytes + cursor,
                                               (NSUInteger)valueLength,
                                               result,
                                               priorities,
                                               depth + 1);
            index = cursor + (NSUInteger)valueLength - 1;
        } else if (wireType == 0) {
            GonerinoReadVarint(bytes, length, &cursor, &tag);
            index = cursor > index ? cursor - 1 : index;
        } else if (wireType == 1 && cursor + 8 <= length) {
            index = cursor + 7;
        } else if (wireType == 5 && cursor + 4 <= length) {
            index = cursor + 3;
        }
    }
}

static void GonerinoRecordVideoIdsFromData(NSMutableDictionary *result,
                                           NSMutableDictionary *priorities,
                                           NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return;

    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
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
            if (GonerinoIsVideoIdCandidate(candidate))
                GonerinoRecordField(result, priorities, @"videoId", candidate);
        }
        index = end > index ? end - 1 : index;
    }
    GonerinoRecordVideoIdsFromProtobuf(bytes, length, result, priorities, 0);
}

static void GonerinoRecordAttributedStringVideoIds(NSAttributedString *string,
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
                    GonerinoRecordVideoIdsFromData(result, priorities, value);
            }
            NSUInteger nextIndex = NSMaxRange(range);
            if (nextIndex <= index)
                break;
            index = nextIndex;
        }
    } @catch (__unused NSException *exception) {
    }
}

static NSString *GonerinoTextFromValue(id value, NSUInteger depth) {
    if (!value || depth > 4)
        return nil;

    if ([value isKindOfClass:[NSString class]])
        return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([value isKindOfClass:[NSAttributedString class]])
        return [[value string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([value isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"simpleText", @"text", @"label", @"title", @"name"]) {
            NSString *text = GonerinoTextFromValue(GonerinoValueForKey(value, key), depth + 1);
            if (text.length > 0)
                return text;
        }

        NSArray *runs = GonerinoValueForKey(value, @"runs");
        if ([runs isKindOfClass:[NSArray class]]) {
            NSMutableString *text = [NSMutableString string];
            for (id run in runs) {
                NSString *runText = GonerinoTextFromValue(run, depth + 1);
                if (runText.length > 0)
                    [text appendString:runText];
            }
            return text.length > 0 ? text : nil;
        }
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableString *text = [NSMutableString string];
        for (id item in (NSArray *)value) {
            NSString *itemText = GonerinoTextFromValue(item, depth + 1);
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
            NSString *text = GonerinoTextFromValue(GonerinoValueForKey(value, key), depth + 1);
            if (text.length > 0)
                return text;
        }
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

static NSString *GonerinoVideoIdFromText(NSString *text) {
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

static GonerinoFieldRole GonerinoRoleForKey(NSString *key, NSUInteger *priority) {
    NSString *normalized = GonerinoNormalizedKey(key);
    if ([normalized isEqualToString:@"videoid"] || [normalized isEqualToString:@"videoidentifier"] ||
        [normalized isEqualToString:@"contentvideoid"] || [normalized isEqualToString:@"youtubevideoid"] ||
        [normalized isEqualToString:@"playerresponsevideoid"] || [normalized isEqualToString:@"watchvideoid"]) {
        if (priority)
            *priority = [normalized isEqualToString:@"videoid"] ? 100 : 90;
        return GonerinoFieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"videourl"] || [normalized isEqualToString:@"watchurl"] ||
        [normalized isEqualToString:@"webpageurl"]) {
        if (priority)
            *priority = 70;
        return GonerinoFieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"videotitle"] || [normalized isEqualToString:@"contenttitle"] ||
        [normalized isEqualToString:@"videoname"]) {
        if (priority)
            *priority = 100;
        return GonerinoFieldRoleTitle;
    }

    if ([normalized isEqualToString:@"title"] || [normalized isEqualToString:@"headline"] ||
        [normalized isEqualToString:@"titletext"]) {
        if (priority)
            *priority = 80;
        return GonerinoFieldRoleTitle;
    }

    if ([normalized isEqualToString:@"ownerdisplayname"] || [normalized isEqualToString:@"ownername"] ||
        [normalized isEqualToString:@"channeldisplayname"] || [normalized isEqualToString:@"authorname"]) {
        if (priority)
            *priority = 100;
        return GonerinoFieldRoleChannel;
    }

    if ([normalized isEqualToString:@"channelname"] || [normalized isEqualToString:@"channeltitle"] ||
        [normalized isEqualToString:@"displayname"] || [normalized isEqualToString:@"channel"] ||
        [normalized isEqualToString:@"author"] || [normalized isEqualToString:@"owner"]) {
        if (priority)
            *priority = 80;
        return GonerinoFieldRoleChannel;
    }

    if ([normalized isEqualToString:@"url"]) {
        if (priority)
            *priority = 40;
        return GonerinoFieldRoleVideoId;
    }

    if (priority)
        *priority = 0;
    return GonerinoFieldRoleNone;
}

static void GonerinoRecordField(NSMutableDictionary *result, NSMutableDictionary *priorities, NSString *key, id value) {
    NSUInteger priority = 0;
    GonerinoFieldRole role = GonerinoRoleForKey(key, &priority);
    if (role == GonerinoFieldRoleNone)
        return;

    NSString *text = GonerinoTextFromValue(value, 0);
    if (role == GonerinoFieldRoleVideoId)
        text = GonerinoVideoIdFromText(text);
    if (text.length == 0)
        return;

    NSString *resultKey = role == GonerinoFieldRoleVideoId ? @"id" :
                          role == GonerinoFieldRoleTitle ? @"title" : @"channel";
    NSUInteger previousPriority = [priorities[resultKey] unsignedIntegerValue];
    if ([(NSString *)result[resultKey] length] == 0 || priority > previousPriority) {
        result[resultKey] = text;
        priorities[resultKey] = @(priority);
    }
}

static NSString *GonerinoDescriptionField(NSString *description, NSString *pattern) {
    if (description.length == 0 || pattern.length == 0)
        return nil;

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
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

static void GonerinoRecordSerializedDescription(NSMutableDictionary *result,
                                                 NSMutableDictionary *priorities,
                                                 NSString *description) {
    if (description.length == 0)
        return;

    GonerinoRecordField(result, priorities, @"videoId",
                        GonerinoDescriptionField(description,
                                                 @"(?:video_id|videoId|video_identifier)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""));
    GonerinoRecordField(result, priorities, @"videoTitle",
                        GonerinoDescriptionField(description,
                                                 @"(?:video_title|videoTitle|title)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""));
    GonerinoRecordField(result, priorities, @"ownerDisplayName",
                        GonerinoDescriptionField(description,
                                                 @"(?:owner_display_name|ownerDisplayName|channel_name|channelName)\\s*[:=]\\s*\\\"([^\\\"]+)\\\""));
}

static NSArray<NSString *> *GonerinoMetadataChildKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"controller", @"viewController", @"elementEntry", @"element", @"context", @"playbackView", @"asdPlayableEntry",
            @"playerViewController", @"shortsPlayerViewController", @"currentReel", @"reel", @"reelItem", @"reelPlayer",
            @"player", @"currentPlayer", @"videoPlayer",
            @"view", @"subviews",
            @"navigationEndpoint", @"watchEndpoint", @"browseEndpoint", @"properties", @"allProperties",
            @"contents", @"subnodes", @"yogaChildren", @"attributedText", @"accessibilityLabel",
            @"videoRenderer", @"compactVideoRenderer", @"richItemRenderer", @"reelItemRenderer",
            @"videoDetails", @"microformat", @"ownerText", @"shortBylineText", @"longBylineText",
            @"command", @"endpoint", @"playerResponse", @"protoText", @"childElements", @"currentVideo", @"videoController",
            @"watchController", @"playbackController", @"videoData", @"response", @"renderer", @"content", @"data", @"model", @"media"
        ];
    });
    return keys;
}

static NSArray<NSString *> *GonerinoMetadataFieldKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"videoId", @"videoID", @"videoIdentifier", @"contentVideoId", @"youtubeVideoId",
            @"playerResponseVideoId", @"watchVideoId", @"videoURL", @"watchURL", @"webpageURL", @"url",
            @"videoTitle", @"contentTitle", @"videoName", @"title", @"headline", @"titleText",
            @"ownerDisplayName", @"ownerName", @"channelDisplayName", @"authorName", @"channelName",
            @"channelTitle", @"displayName", @"channel", @"author", @"owner"
        ];
    });
    return keys;
}

static BOOL GonerinoShouldVisitMetadataKey(NSString *key) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet *normalizedKeys = [NSMutableSet set];
        for (NSString *candidate in GonerinoMetadataChildKeys())
            [normalizedKeys addObject:GonerinoNormalizedKey(candidate)];
        keys = [normalizedKeys copy];
    });
    return [keys containsObject:GonerinoNormalizedKey(key)];
}

static void GonerinoCollectElementTreeMetadata(id object,
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
    @try {
        objectDescription = [object debugDescription] ?: @"";
    } @catch (__unused NSException *exception) {
    }
    if ([className containsString:@"textnode"]) {
        NSAttributedString *attributedText = GonerinoValueForKey(object, @"attributedText");
        NSString *text = GonerinoTextFromValue(attributedText, 0);
        if ([objectDescription containsString:@"channel_name"] && text.length > 0)
            GonerinoRecordField(result, priorities, @"ownerDisplayName", text);
        if ([objectDescription containsString:@"shorts-video-title"] && text.length > 0) {
            GonerinoRecordField(result, priorities, @"videoTitle", text);
            GonerinoRecordAttributedStringVideoIds(attributedText, result, priorities);
        }
    }

    NSArray *keyCandidates = @[
        @"videoId", @"video_id", @"videoIdentifier", @"contentVideoId", @"youtubeVideoId",
        @"playerResponseVideoId", @"watchVideoId", @"videoURL", @"watchURL", @"webpageURL",
        @"contentId", @"entityId", @"navigationEndpoint", @"watchEndpoint", @"endpoint",
        @"command", @"playerResponse", @"videoDetails", @"title", @"channelName", @"ownerName"
    ];
    id element = GonerinoValueForKey(object, @"element");
    id context = GonerinoValueForKey(object, @"context");
    for (id candidate in @[element ?: [NSNull null], context ?: [NSNull null]]) {
        if (candidate == [NSNull null])
            continue;
        for (NSString *key in keyCandidates) {
            id value = GonerinoValueForNamedKey(candidate, key);
            if (!value)
                continue;
            GonerinoRecordField(result, priorities, key, value);
            if (value != candidate && ![value isKindOfClass:[NSString class]] &&
                ![value isKindOfClass:[NSNumber class]])
                GonerinoCollectElementTreeMetadata(value, result, priorities, visited, depth + 1);
        }
    }

    NSArray *subnodes = GonerinoValueForKey(object, @"subnodes");
    if ([subnodes isKindOfClass:[NSArray class]]) {
        for (id subnode in subnodes)
            GonerinoCollectElementTreeMetadata(subnode, result, priorities, visited, depth + 1);
    }
}

static void GonerinoCollectObject(id object, NSMutableDictionary *result, NSMutableDictionary *priorities,
                                  NSMutableSet *visited, NSUInteger *budget, NSUInteger depth);

static void GonerinoCollectObject(id object, NSMutableDictionary *result, NSMutableDictionary *priorities,
                                  NSMutableSet *visited, NSUInteger *budget, NSUInteger depth) {
    if (!object || !budget || *budget == 0 || depth > 8)
        return;

    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] ||
        [object isKindOfClass:[NSAttributedString class]])
        return;

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return;
    [visited addObject:identity];
    (*budget)--;

    NSString *className = NSStringFromClass([object class]).lowercaseString;
    NSString *objectDescription = @"";
    @try {
        objectDescription = [object debugDescription] ?: @"";
    } @catch (__unused NSException *exception) {
    }
    GonerinoRecordSerializedDescription(result, priorities, objectDescription);
    if ([className containsString:@"textnode"]) {
        NSAttributedString *attributedText = GonerinoValueForKey(object, @"attributedText");
        NSString *text = GonerinoTextFromValue(attributedText, 0);
        if ([objectDescription containsString:@"channel_name"] && text.length > 0)
            GonerinoRecordField(result, priorities, @"channelName", text);
        if ([objectDescription containsString:@"shorts-video-title"] && text.length > 0) {
            GonerinoRecordField(result, priorities, @"videoTitle", text);
            GonerinoRecordAttributedStringVideoIds(attributedText, result, priorities);
        }
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id key in [(NSDictionary *)object allKeys]) {
            id value = [(NSDictionary *)object objectForKey:key];
            if ([key isKindOfClass:[NSString class]]) {
                GonerinoRecordField(result, priorities, key, value);
                if (GonerinoShouldVisitMetadataKey(key))
                    GonerinoCollectObject(value, result, priorities, visited, budget, depth + 1);
            }
            if (GonerinoMetadataComplete(result))
                return;
        }
        return;
    }

    if ([object isKindOfClass:[NSArray class]] || [object isKindOfClass:[NSSet class]]) {
        NSUInteger childCount = 0;
        for (id value in object) {
            if (childCount++ >= 24)
                break;
            GonerinoCollectObject(value, result, priorities, visited, budget, depth + 1);
            if (GonerinoMetadataComplete(result))
                return;
        }
        return;
    }

    if ([object isKindOfClass:[UIView class]]) {
        id node = GonerinoValueForKey(object, @"asyncdisplaykit_node");
        if (node)
            GonerinoCollectObject(node, result, priorities, visited, budget, depth + 1);
        for (NSString *key in GonerinoMetadataChildKeys()) {
            if ([key isEqualToString:@"view"] || [key isEqualToString:@"subviews"])
                continue;
            id value = GonerinoValueForNamedKey(object, key);
            if (!value)
                continue;
            GonerinoRecordField(result, priorities, key, value);
            GonerinoCollectObject(value, result, priorities, visited, budget, depth + 1);
            if (GonerinoMetadataComplete(result))
                return;
            if (*budget == 0)
                return;
        }
        for (UIView *subview in [(UIView *)object subviews])
            GonerinoCollectObject(subview, result, priorities, visited, budget, depth + 1);
        return;
    }

    for (NSString *key in GonerinoMetadataFieldKeys()) {
        id value = GonerinoValueForNamedKey(object, key);
        if (value)
            GonerinoRecordField(result, priorities, key, value);
        if (GonerinoMetadataComplete(result))
            return;
    }

    if ([className containsString:@"endpoint"] || [className containsString:@"playable"] ||
        [className containsString:@"playback"] || [className containsString:@"video"] ||
        [className containsString:@"element"]) {
        NSString *description = GonerinoTextFromValue(GonerinoValueForKey(object, @"description"), 0);
        GonerinoRecordSerializedDescription(result, priorities, description);
        if (GonerinoMetadataComplete(result))
            return;
    }

    for (NSString *key in GonerinoMetadataChildKeys()) {
        id value = GonerinoValueForNamedKey(object, key);
        if (!value)
            continue;
        GonerinoRecordField(result, priorities, key, value);
        if (GonerinoMetadataComplete(result))
            return;
        if (value != object)
            GonerinoCollectObject(value, result, priorities, visited, budget, depth + 1);
        if (GonerinoMetadataComplete(result))
            return;
        if (*budget == 0)
            return;
    }
}

static NSString *GonerinoTextForNode(id node) {
    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")]) {
        NSString *text = GonerinoTextFromValue(GonerinoValueForKey(node, @"attributedText"), 0);
        if (text.length > 0)
            return text;
    }

    NSString *accessibilityLabel = GonerinoTextFromValue(GonerinoValueForKey(node, @"accessibilityLabel"), 0);
    return accessibilityLabel.length > 0 ? accessibilityLabel : nil;
}

static void GonerinoCollectInlinePlaybackMetadata(id node,
                                                   NSMutableDictionary *result,
                                                   NSMutableDictionary *priorities) {
    if (!node)
        return;

    @try {
        NSMutableArray *playbackViews = [NSMutableArray array];
        id playbackView = GonerinoValueForKey(node, @"playbackView");
        if (playbackView)
            [playbackViews addObject:playbackView];

        UIView *view = GonerinoValueForKey(node, @"view");
        if (view)
            [playbackViews addObjectsFromArray:view.subviews];

        for (id candidate in playbackViews) {
            NSString *className = NSStringFromClass([candidate class]);
            if ([className rangeOfString:@"YTElementsInlineMutedPlaybackView"].location == NSNotFound)
                continue;

            id playableEntry = GonerinoValueForKey(candidate, @"asdPlayableEntry");
            for (NSString *key in GonerinoMetadataFieldKeys())
                GonerinoRecordField(result, priorities, key, GonerinoValueForKey(playableEntry, key));

            id navigationEndpoint = GonerinoValueForKey(playableEntry, @"navigationEndpoint");
            for (NSString *key in GonerinoMetadataFieldKeys())
                GonerinoRecordField(result, priorities, key, GonerinoValueForKey(navigationEndpoint, key));

            NSString *entryDescription = GonerinoTextFromValue(GonerinoValueForKey(playableEntry, @"description"), 0);
            NSString *endpointDescription = GonerinoTextFromValue(GonerinoValueForKey(navigationEndpoint, @"description"), 0);
            GonerinoRecordSerializedDescription(result, priorities, entryDescription);
            GonerinoRecordSerializedDescription(result, priorities, endpointDescription);
            if (GonerinoMetadataComplete(result))
                return;
        }
    } @catch (__unused NSException *exception) {
    }
}

static UIViewController *GonerinoViewControllerForNode(id node) {
    UIView *view = GonerinoValueForKey(node, @"view");
    UIResponder *responder = view;
    NSUInteger depth = 0;
    while (responder && depth++ < 32) {
        if ([responder isKindOfClass:[UIViewController class]])
            return (UIViewController *)responder;
        responder = [responder nextResponder];
    }
    return nil;
}

@implementation Util

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
    if (!node)
        return nil;

    NSDictionary *cached = [GonerinoMetadataCache() objectForKey:node];
    if (cached)
        return cached;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableDictionary *priorities = [NSMutableDictionary dictionary];
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableSet *elementVisited = [NSMutableSet set];
    NSUInteger budget = 96;

    @try {
        GonerinoCollectInlinePlaybackMetadata(node, result, priorities);
        GonerinoCollectObject(GonerinoViewControllerForNode(node), result, priorities, visited, &budget, 0);
        GonerinoCollectElementTreeMetadata(node, result, priorities, elementVisited, 0);
        GonerinoCollectObject(node, result, priorities, visited, &budget, 0);
    } @catch (__unused NSException *exception) {
    }

    if (result.count == 0)
        return nil;
    NSDictionary *metadata = [result copy];
    if (GonerinoMetadataComplete(metadata))
        [GonerinoMetadataCache() setObject:metadata forKey:node];
    return metadata;
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
        NSString *text = GonerinoTextForNode(node);
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

        CGFloat radius = size.width * 0.45;
        CGPoint center = CGPointMake(size.width / 2, size.height / 2);
        UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:center
                                                                  radius:radius
                                                              startAngle:0
                                                                endAngle:2 * M_PI
                                                               clockwise:YES];
        UIBezierPath *body = [UIBezierPath bezierPathWithArcCenter:CGPointMake(size.width / 2, size.height * 0.85)
                                                              radius:size.width * 0.3
                                                          startAngle:M_PI
                                                            endAngle:2 * M_PI
                                                           clockwise:YES];
        UIBezierPath *head = [UIBezierPath bezierPathWithArcCenter:CGPointMake(size.width / 2, size.height * 0.35)
                                                              radius:size.width * 0.15
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

        CGPoint center = CGPointMake(size.width / 2, size.height / 2);
        UIBezierPath *rectangle = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(size.width * 0.2, size.height * 0.3,
                                                                                       size.width * 0.6, size.height * 0.4)
                                                               cornerRadius:3.0];
        UIBezierPath *triangle = [UIBezierPath bezierPath];
        CGFloat triangleSize = size.width * 0.2;
        [triangle moveToPoint:CGPointMake(center.x - triangleSize / 2, center.y - triangleSize / 2)];
        [triangle addLineToPoint:CGPointMake(center.x + triangleSize / 2, center.y)];
        [triangle addLineToPoint:CGPointMake(center.x - triangleSize / 2, center.y + triangleSize / 2)];
        [triangle closePath];

        CGFloat radius = size.width * 0.45;
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
