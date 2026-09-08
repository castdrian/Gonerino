#import "Util.h"
#import "ChannelManager.h"
#import "VideoManager.h"

#import <objc/runtime.h>

NSString * const FeedFilterStateDidChangeNotification = @"FeedFilterStateDidChangeNotification";

static BOOL ObjectIsClassNamed(id object, NSString *className);
static id DirectNamedValue(id object, NSString *key);
static void AdaptShortsNode(id node, NSMutableArray<id> *objects, NSMutableSet *visited);
static void AdaptElementsFeedNode(id node, NSMutableArray<id> *objects, NSMutableSet *visited);
static void AddAdapterObjectAndChildren(NSMutableArray<id> *objects,
                                        NSMutableSet *visited,
                                        id object,
                                        NSArray<NSString *> *keys);
static void AddBoundedModelGraph(NSMutableArray<id> *objects,
                                 NSMutableSet *visited,
                                 id object,
                                 NSArray<NSString *> *keys,
                                 NSUInteger depth);
static void AddBoundedShortsSubnodes(NSMutableArray<id> *objects,
                                     NSMutableSet *visited,
                                     id node,
                                     NSUInteger depth);
static void RecordAdapterObjects(NSArray<id> *objects,
                                 NSMutableDictionary *result,
                                 NSMutableDictionary *priorities,
                                 NSMutableArray<NSString *> *textValues);
static BOOL IsShortsMetadataTitleText(NSString *text, NSString *channel);
static void RecordField(NSMutableDictionary *result,
                        NSMutableDictionary *priorities,
                        NSString *key,
                        id value);

@interface NSObject (Text)
- (NSString *)stringWithFormattingRemoved;
- (NSString *)string;
@end

@interface FeedMetadataRecord ()
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *cachedDictionaryRepresentation;
@end

@implementation FeedMetadataRecord

- (instancetype)initWithVideoID:(NSString *)videoID title:(NSString *)title channel:(NSString *)channel {
    self = [super init];
    if (self) {
        _videoID = [videoID copy] ?: @"";
        _title = [title copy] ?: @"";
        _channel = [channel copy] ?: @"";
        NSMutableDictionary<NSString *, NSString *> *dictionary = [NSMutableDictionary dictionaryWithCapacity:3];
        if (_videoID.length > 0)
            dictionary[@"id"] = _videoID;
        if (_title.length > 0)
            dictionary[@"title"] = _title;
        if (_channel.length > 0)
            dictionary[@"channel"] = _channel;
        _cachedDictionaryRepresentation = dictionary.copy;
    }
    return self;
}

- (NSDictionary<NSString *, NSString *> *)dictionaryRepresentation {
    return self.cachedDictionaryRepresentation;
}

@end

static NSMapTable *FeedMetadataCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMapTable weakToStrongObjectsMapTable];
    });
    return cache;
}

static NSMutableDictionary<NSString *, FeedMetadataRecord *> *FeedMetadataByVideoID(void) {
    static NSMutableDictionary<NSString *, FeedMetadataRecord *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static void *FeedVideoIDAssociationKey = &FeedVideoIDAssociationKey;
static void *ShortsMetadataAssociationKey = &ShortsMetadataAssociationKey;

static volatile BOOL FilteringEnabledState = YES;
static volatile BOOL PeopleWatchedState = NO;
static volatile BOOL MightLikeState = NO;

static void RefreshPreferenceSnapshot(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    FilteringEnabledState = [defaults objectForKey:@"GonerinoEnabled"] == nil || [defaults boolForKey:@"GonerinoEnabled"];
    PeopleWatchedState = [defaults boolForKey:@"GonerinoPeopleWatched"];
    MightLikeState = [defaults boolForKey:@"GonerinoMightLike"];
}

static NSString *TrimmedText(NSString *text) {
    if (![text isKindOfClass:[NSString class]])
        return nil;
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static id IvarObjectValue(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    Class objectClass = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(objectClass, [NSString stringWithFormat:@"_%@", key].UTF8String);
    if (!ivar)
        ivar = class_getInstanceVariable(objectClass, key.UTF8String);
    if (!ivar)
        return nil;

    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@')
        return nil;
    return object_getIvar(object, ivar);
}

static id DirectObjectValue(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    if ([object isKindOfClass:[NSDictionary class]])
        return [(NSDictionary *)object objectForKey:key];

    SEL selector = NSSelectorFromString(key);
    if (![object respondsToSelector:selector])
        return IvarObjectValue(object, key);

    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char *returnType = method ? method_getTypeEncoding(method) : NULL;
    if (!returnType || returnType[0] != '@')
        return nil;

    @try {
        id value = ((id (*)(id, SEL))method_getImplementation(method))(object, selector);
        return value ?: IvarObjectValue(object, key);
    } @catch (__unused NSException *exception) {
        return IvarObjectValue(object, key);
    }
}

static id DirectArgumentValue(id object, NSString *selectorName, NSString *key) {
    if (!object || selectorName.length == 0 || key.length == 0)
        return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector])
        return nil;

    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char *returnType = method ? method_getTypeEncoding(method) : NULL;
    if (!returnType || returnType[0] != '@')
        return nil;

    @try {
        return ((id (*)(id, SEL, id))method_getImplementation(method))(object, selector, key);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL HasCustomValueForKeyImplementation(id object) {
    if (!object)
        return NO;

    SEL selector = @selector(valueForKey:);
    Method objectMethod = class_getInstanceMethod(object_getClass(object), selector);
    Method baseMethod = class_getInstanceMethod([NSObject class], selector);
    if (!objectMethod)
        return NO;
    if (!baseMethod)
        return YES;
    return method_getImplementation(objectMethod) != method_getImplementation(baseMethod);
}

static id DirectNamedValue(id object, NSString *key) {
    id value = DirectObjectValue(object, key);
    if (value)
        return value;

    value = DirectArgumentValue(object, @"propertyForKey:", key);
    if (value)
        return value;
    value = DirectArgumentValue(object, @"elementForKey:", key);
    if (value)
        return value;
    value = DirectArgumentValue(object, @"safeSwiftValueForKey:", key);
    if (value)
        return value;
    value = DirectArgumentValue(object, @"safeValueForKey:", key);
    if (value)
        return value;
    value = DirectArgumentValue(object, @"inputNamed:", key);
    if (value)
        return value;
    value = DirectArgumentValue(object, @"outputNamed:", key);
    if (value)
        return value;
    return HasCustomValueForKeyImplementation(object) ? DirectArgumentValue(object, @"valueForKey:", key) : nil;
}

static NSString *TextAtom(id value) {
    if (!value)
        return nil;

    if ([value isKindOfClass:[NSString class]])
        return TrimmedText(value);
    if ([value isKindOfClass:[NSAttributedString class]])
        return TrimmedText([(NSAttributedString *)value string]);

    @try {
        if ([value respondsToSelector:@selector(stringWithFormattingRemoved)]) {
            NSString *text = [(id)value stringWithFormattingRemoved];
            if (text.length > 0)
                return TrimmedText(text);
        }
        if ([value respondsToSelector:@selector(string)]) {
            NSString *text = [(id)value string];
            if (text.length > 0)
                return TrimmedText(text);
        }
    } @catch (__unused NSException *exception) {
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"simpleText", @"text", @"label", @"title", @"name"]) {
            id candidate = [(NSDictionary *)value objectForKey:key];
            NSString *text = [candidate isKindOfClass:[NSString class]] ? TrimmedText(candidate) :
                              [candidate isKindOfClass:[NSAttributedString class]] ? TrimmedText([(NSAttributedString *)candidate string]) : nil;
            if (text.length > 0)
                return text;
        }
    }

    return nil;
}

static NSString *TextFromValue(id value) {
    NSString *directText = TextAtom(value);
    if (directText.length > 0)
        return directText;

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSArray *runs = [(NSDictionary *)value objectForKey:@"runs"];
        if ([runs isKindOfClass:[NSArray class]]) {
            NSMutableString *text = [NSMutableString string];
            NSUInteger count = 0;
            for (id run in runs) {
                if (count++ >= 32)
                    break;
                NSString *runText = TextAtom(run);
                if (runText.length > 0)
                    [text appendString:runText];
            }
            if (text.length > 0)
                return text;
        }
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableString *text = [NSMutableString string];
        NSUInteger count = 0;
        for (id item in (NSArray *)value) {
            if (count++ >= 32)
                break;
            NSString *itemText = TextAtom(item);
            if (itemText.length == 0)
                continue;
            if (text.length > 0)
                [text appendString:@" "];
            [text appendString:itemText];
        }
        if (text.length > 0)
            return text;
    }

    return nil;
}

static NSString *NormalizedKey(NSString *key) {
    if (key.length == 0)
        return @"";

    NSMutableString *normalized = [key.lowercaseString mutableCopy];
    [normalized replaceOccurrencesOfString:@"_" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"-" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    return normalized;
}

static NSString *VideoIdFromText(NSString *text) {
    NSString *trimmed = TrimmedText(text);
    if (trimmed.length == 0)
        return nil;

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

static BOOL IsSyntheticChannelValue(NSString *text) {
    NSString *normalized = TrimmedText(text).lowercaseString;
    return [normalized isEqualToString:@"action menu"] || [normalized isEqualToString:@"more actions"] ||
           [normalized isEqualToString:@"live"] || [normalized isEqualToString:@"sponsored"] ||
           [normalized isEqualToString:@"verified"] || [normalized isEqualToString:@"premiere"];
}

static NSString *NormalizedChannelText(NSString *text) {
    NSString *candidate = TrimmedText(text);
    if (candidate.length == 0)
        return nil;

    for (NSString *suffix in @[
        @", official artist channel",
        @", official channel",
        @", verified",
        @" - official artist channel",
        @" - official channel",
        @" - verified"
    ]) {
        if ([candidate.lowercaseString hasSuffix:suffix]) {
            candidate = TrimmedText([candidate substringToIndex:candidate.length - suffix.length]);
            break;
        }
    }
    return candidate;
}

static BOOL IsShortsControlText(NSString *text) {
    NSString *candidate = TrimmedText(text);
    NSString *lowercaseCandidate = candidate.lowercaseString;
    if (candidate.length == 0 || [candidate hasPrefix:@"@"])
        return YES;

    for (NSString *prefix in @[
        @"subscribe to ", @"subscribed to ", @"suscribirse a ", @"suscrito a ",
        @"abonnieren ", @"abonner à ", @"abonné à ", @"iscriviti a ",
        @"assinar ", @"inscrever-se ", @"подписаться на ", @"購読", @"tap to retry",
        @"press to retry"
    ]) {
        if ([lowercaseCandidate hasPrefix:prefix])
            return YES;
    }

    for (NSString *label in @[
        @"retry", @"subscribe", @"subscribed", @"share", @"remix", @"description",
        @"clear screen", @"audio track", @"abonnieren", @"suscribirse", @"abonner",
        @"iscriviti", @"assinar", @"подписаться", @"back", @"home", @"search", @"shorts",
        @"subscriptions", @"you", @"like", @"comment", @"save", @"previous video",
        @"next video"
    ]) {
        if ([lowercaseCandidate isEqualToString:label])
            return YES;
    }
    return [lowercaseCandidate hasPrefix:@"captions"] || [lowercaseCandidate hasPrefix:@"quality"];
}

static BOOL IsLikelyChannelText(NSString *text, NSString *title) {
    NSString *candidate = TrimmedText(text);
    NSString *normalizedTitle = TrimmedText(title);
    if (candidate.length == 0 || candidate.length > 120 || [candidate isEqualToString:normalizedTitle] ||
        (normalizedTitle.length > 0 && [candidate containsString:normalizedTitle]) ||
        IsSyntheticChannelValue(candidate))
        return NO;

    NSString *lowercaseCandidate = candidate.lowercaseString;
    for (NSString *excluded in @[
        @" views", @" view", @" ago", @" subscribers", @" sponsored", @"subscribe",
        @"watch later", @"playlist", @"share", @"description", @"clear screen",
        @"not interested", @"send feedback", @"home", @"shorts", @"subscriptions",
        @"you", @"search", @"notifications", @"settings"
    ]) {
        if ([lowercaseCandidate containsString:excluded] || [lowercaseCandidate isEqualToString:excluded])
            return NO;
    }

    static NSRegularExpression *metricsRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        metricsRegex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9][0-9:., ]*[kmb]?$"
                                                                      options:NSRegularExpressionCaseInsensitive
                                                                        error:nil];
    });
    return [metricsRegex firstMatchInString:candidate options:0 range:NSMakeRange(0, candidate.length)] == nil;
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
        NSRange markerRange = [text rangeOfString:marker options:NSCaseInsensitiveSearch];
        if (markerRange.location == NSNotFound)
            continue;

        NSString *candidate = [text substringFromIndex:NSMaxRange(markerRange)];
        NSRange separator = [candidate rangeOfString:@" - "];
        if (separator.location != NSNotFound)
            candidate = [candidate substringToIndex:separator.location];
        candidate = TrimmedText(candidate);
        if (IsLikelyChannelText(candidate, nil))
            return candidate;
    }

    for (NSString *suffix in @[@" channel", @" kanal", @" canal", @" chaîne", @" canale", @" kanaal"]) {
        NSRange suffixRange = [text rangeOfString:suffix options:NSCaseInsensitiveSearch | NSBackwardsSearch];
        if (suffixRange.location == NSNotFound || NSMaxRange(suffixRange) != text.length)
            continue;

        NSString *prefix = [text substringToIndex:suffixRange.location];
        NSRange separator = [prefix rangeOfString:@"," options:NSBackwardsSearch];
        if (separator.location == NSNotFound)
            continue;

        NSString *candidate = TrimmedText([prefix substringFromIndex:NSMaxRange(separator)]);
        if (IsLikelyChannelText(candidate, nil))
            return candidate;
    }

    return nil;
}

static BOOL IsFeedDurationText(NSString *text) {
    NSString *candidate = TrimmedText(text).lowercaseString;
    if (candidate.length == 0)
        return NO;

    static NSRegularExpression *durationRegex;
    static NSRegularExpression *clockRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        durationRegex = [NSRegularExpression regularExpressionWithPattern:
                         @"^[0-9][0-9:., ]*(seconds?|minutes?|hours?|sekunden?|minuten?|stunden?|segundos?|minutos?|horas?|秒|分|時間)"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
        clockRegex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(?::[0-9]{2}){1,2}$"
                                                                    options:0
                                                                      error:nil];
    });
    return [durationRegex firstMatchInString:candidate options:0 range:NSMakeRange(0, candidate.length)] != nil ||
           [clockRegex firstMatchInString:candidate options:0 range:NSMakeRange(0, candidate.length)] != nil;
}

static NSString *TitleFromAccessibleText(NSString *text) {
    if (text.length == 0)
        return nil;

    NSRange liveSeparator = [text rangeOfString:@" -  -  - "];
    if (liveSeparator.location != NSNotFound) {
        NSString *title = TrimmedText([text substringToIndex:liveSeparator.location]);
        if (title.length > 0)
            return title;
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
        return TrimmedText([titleComponents componentsJoinedByString:@" - "]);
    }
    return nil;
}

static NSString *ChannelFromFeedAccessibleText(NSString *text, NSString *title) {
    if (text.length == 0)
        return nil;

    NSArray<NSString *> *components = [text componentsSeparatedByString:@" - "];
    if (components.count < 3)
        return nil;

    NSUInteger durationIndex = NSNotFound;
    for (NSUInteger index = 1; index < components.count; index++) {
        if (IsFeedDurationText(components[index])) {
            durationIndex = index;
            break;
        }
    }
    if (durationIndex == NSNotFound)
        return nil;

    NSUInteger candidateLimit = MIN(components.count, durationIndex + 4);
    for (NSUInteger index = durationIndex + 1; index < candidateLimit; index++) {
        NSString *candidate = TrimmedText(components[index]);
        if (candidate.length == 0 || [candidate.lowercaseString containsString:@" views"] ||
            [candidate.lowercaseString containsString:@" view"] ||
            [candidate.lowercaseString containsString:@" ago"] ||
            [candidate.lowercaseString containsString:@" subscribers"] ||
            [candidate isEqualToString:title])
            continue;
        if (IsLikelyChannelText(candidate, title))
            return candidate;
    }
    return nil;
}

static BOOL IsFeedStatsText(NSString *text) {
    NSString *candidate = TrimmedText(text).lowercaseString;
    if (candidate.length == 0)
        return NO;
    for (NSString *marker in @[
        @" views", @" view", @" ago", @" subscribers", @" aufrufe", @" vor ",
        @" visualizaciones", @" visualizações", @" hace ", @" hace", @"播放", @" مشاهدة"
    ]) {
        if ([candidate containsString:marker])
            return YES;
    }
    return [candidate hasPrefix:@"play "] || [candidate hasPrefix:@"video "] ||
           [candidate hasPrefix:@"short "] || [candidate isEqualToString:@"verified"];
}

static NSString *ChannelFromElementsAccessibleText(NSString *text, NSString *title) {
    NSString *candidateText = TrimmedText(text);
    if (candidateText.length == 0)
        return nil;

    NSArray<NSString *> *components = [candidateText componentsSeparatedByString:@" - "];
    for (NSUInteger index = 1; index + 1 < components.count; index++) {
        NSString *candidate = TrimmedText(components[index]);
        if (!IsLikelyChannelText(candidate, title))
            continue;
        for (NSUInteger followingIndex = index + 1; followingIndex < components.count; followingIndex++) {
            if (IsFeedStatsText(components[followingIndex]))
                return candidate;
        }
    }
    return nil;
}

static NSString *DirectShortsVideoID(id object) {
    if (!object)
        return nil;
    for (NSString *key in @[@"videoId", @"videoID", @"videoIdentifier", @"contentVideoId", @"contentVideoID"]) {
        NSString *videoID = VideoIdFromText(TextAtom(DirectNamedValue(object, key)));
        if (videoID.length > 0)
            return videoID;
    }
    return nil;
}

static NSString *TitleFromElementsAccessibleText(NSString *text, NSString *channel) {
    NSString *candidateText = TrimmedText(text);
    if (candidateText.length == 0)
        return nil;

    if (channel.length > 0) {
        NSString *channelMarker = [NSString stringWithFormat:@", %@ - ", channel];
        NSRange markerRange = [candidateText rangeOfString:channelMarker options:NSCaseInsensitiveSearch];
        if (markerRange.location != NSNotFound) {
            NSString *title = TrimmedText([candidateText substringToIndex:markerRange.location]);
            if ([Util isUsableVideoTitle:title])
                return title;
        }

        NSArray<NSString *> *components = [candidateText componentsSeparatedByString:@" - "];
        for (NSUInteger index = 1; index < components.count; index++) {
            if ([components[index] caseInsensitiveCompare:channel] != NSOrderedSame)
                continue;
            NSMutableArray<NSString *> *titleComponents = [NSMutableArray arrayWithCapacity:index];
            for (NSUInteger titleIndex = 0; titleIndex < index; titleIndex++)
                [titleComponents addObject:components[titleIndex]];
            NSString *title = TrimmedText([titleComponents componentsJoinedByString:@" - "]);
            if ([Util isUsableVideoTitle:title])
                return title;
        }
    }

    NSArray<NSString *> *components = [candidateText componentsSeparatedByString:@" - "];
    if (components.count < 2)
        return nil;
    NSMutableArray<NSString *> *titleComponents = [NSMutableArray array];
    for (NSString *component in components) {
        if (IsFeedStatsText(component) || [component.lowercaseString hasPrefix:@"play "])
            break;
        if (titleComponents.count > 0 && IsLikelyChannelText(component, nil))
            break;
        [titleComponents addObject:component];
    }
    NSString *title = TrimmedText([titleComponents componentsJoinedByString:@" - "]);
    return [Util isUsableVideoTitle:title] ? title : nil;
}

static void RecordShortsAccessibleText(NSString *text,
                                       NSMutableDictionary *result,
                                       NSMutableDictionary *priorities) {
    NSString *candidate = TrimmedText(text);
    if (candidate.length == 0)
        return;

    static NSRegularExpression *handleRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handleRegex = [NSRegularExpression regularExpressionWithPattern:@"(^|\\s)(@[A-Za-z0-9._-]{2,80})(?=\\s|$)"
                                                                       options:0
                                                                         error:nil];
    });

    NSTextCheckingResult *match = [handleRegex firstMatchInString:candidate
                                                            options:0
                                                              range:NSMakeRange(0, candidate.length)];
    if (!match || match.numberOfRanges < 3)
        return;

    NSString *channel = TrimmedText([candidate substringWithRange:[match rangeAtIndex:2]]);
    NSString *title = TrimmedText([candidate substringToIndex:match.range.location]);
    if (title.length == 0 || !IsShortsMetadataTitleText(title, channel))
        return;

    RecordField(result, priorities, @"ownerDisplayName", channel);
    RecordField(result, priorities, @"videoTitle", title);
}

static NSString *TextFromAccessibilityValue(id value) {
    NSString *text = TextFromValue(value);
    if (text.length > 0)
        return text;

    if (![value isKindOfClass:[NSObject class]])
        return nil;

    NSString *className = NSStringFromClass([value class]).lowercaseString;
    if (![className containsString:@"attributedstring"] &&
        ![className containsString:@"accessibility"])
        return nil;

    text = TrimmedText([value description]);
    return text.length > 0 ? text : nil;
}

static BOOL IsShortsMetadataTitleText(NSString *text, NSString *channel) {
    NSString *candidate = TrimmedText(text);
    NSString *lowercaseCandidate = candidate.lowercaseString;
    if (candidate.length < 3 || candidate.length > 240 || [candidate hasPrefix:@"@"] ||
        [candidate caseInsensitiveCompare:channel] == NSOrderedSame || IsShortsControlText(candidate) ||
        IsSyntheticChannelValue(candidate) || IsFeedStatsText(candidate))
        return NO;

    for (NSString *prefix in @[
        @"search what you see", @"subscribe", @"subscribed", @"captions", @"audio track",
        @"quality", @"clear screen", @"not interested", @"send feedback", @"play next",
        @"play last", @"save", @"share", @"remix", @"description", @"report", @"tap to retry",
        @"press to retry"
    ]) {
        if ([lowercaseCandidate hasPrefix:prefix])
            return NO;
    }
    return YES;
}

static FeedMetadataRecord *ShortsMetadataFromContentView(id contentView) {
    if (!contentView)
        return nil;

    FeedMetadataRecord *record = objc_getAssociatedObject(contentView, ShortsMetadataAssociationKey);
    id contentNode = [contentView isKindOfClass:[UIView class]] ? DirectObjectValue(contentView, @"asyncdisplaykit_node") : contentView;
    FeedMetadataRecord *nodeRecord = [Util cachedFeedVideoMetadataForNode:contentNode];
    if (!record)
        record = nodeRecord;
    else if (nodeRecord)
        record = [[FeedMetadataRecord alloc] initWithVideoID:record.videoID.length > 0 ? record.videoID : nodeRecord.videoID
                                                       title:record.title.length > 0 ? record.title : nodeRecord.title
                                                     channel:record.channel.length > 0 ? record.channel : nodeRecord.channel];
    if (!record)
        return nil;

    NSString *currentVideoID = DirectShortsVideoID(contentView) ?: DirectShortsVideoID(contentNode);
    if (currentVideoID.length > 0 && record.videoID.length > 0 && ![currentVideoID isEqualToString:record.videoID])
        return nil;
    return record;
}

typedef NS_ENUM(NSUInteger, MetadataFieldRole) {
    MetadataFieldRoleNone,
    MetadataFieldRoleVideoId,
    MetadataFieldRoleTitle,
    MetadataFieldRoleChannel
};

static MetadataFieldRole MetadataRoleForKey(NSString *key, NSUInteger *priority) {
    NSString *normalized = NormalizedKey(key);
    if ([normalized isEqualToString:@"videoid"] || [normalized isEqualToString:@"videoidentifier"] ||
        [normalized isEqualToString:@"contentvideoid"] || [normalized isEqualToString:@"youtubevideoid"] ||
        [normalized isEqualToString:@"playerresponsevideoid"] || [normalized isEqualToString:@"watchvideoid"]) {
        if (priority)
            *priority = [normalized isEqualToString:@"videoid"] ? 100 : 90;
        return MetadataFieldRoleVideoId;
    }
    if ([normalized isEqualToString:@"contentid"] || [normalized isEqualToString:@"entityid"]) {
        if (priority)
            *priority = 60;
        return MetadataFieldRoleVideoId;
    }
    if ([normalized isEqualToString:@"videourl"] || [normalized isEqualToString:@"watchurl"] ||
        [normalized isEqualToString:@"webpageurl"] || [normalized isEqualToString:@"url"]) {
        if (priority)
            *priority = [normalized isEqualToString:@"url"] ? 40 : 70;
        return MetadataFieldRoleVideoId;
    }
    if ([normalized isEqualToString:@"videotitle"] || [normalized isEqualToString:@"contenttitle"] ||
        [normalized isEqualToString:@"videoname"]) {
        if (priority)
            *priority = 100;
        return MetadataFieldRoleTitle;
    }
    if ([normalized isEqualToString:@"title"] || [normalized isEqualToString:@"headline"] ||
        [normalized isEqualToString:@"titletext"]) {
        if (priority)
            *priority = 80;
        return MetadataFieldRoleTitle;
    }
    if ([normalized isEqualToString:@"ownerdisplayname"] || [normalized isEqualToString:@"ownername"] ||
        [normalized isEqualToString:@"channeldisplayname"] || [normalized isEqualToString:@"authorname"] ||
        [normalized isEqualToString:@"ownertext"] || [normalized isEqualToString:@"shortbylinetext"] ||
        [normalized isEqualToString:@"longbylinetext"]) {
        if (priority)
            *priority = [normalized isEqualToString:@"ownertext"] ? 75 : 100;
        return MetadataFieldRoleChannel;
    }
    if ([normalized isEqualToString:@"channelname"] || [normalized isEqualToString:@"channeltitle"] ||
        [normalized isEqualToString:@"displayname"] || [normalized isEqualToString:@"channel"] ||
        [normalized isEqualToString:@"author"] || [normalized isEqualToString:@"owner"]) {
        if (priority)
            *priority = 80;
        return MetadataFieldRoleChannel;
    }
    if (priority)
        *priority = 0;
    return MetadataFieldRoleNone;
}

static void RecordField(NSMutableDictionary *result, NSMutableDictionary *priorities, NSString *key, id value) {
    NSUInteger priority = 0;
    MetadataFieldRole role = MetadataRoleForKey(key, &priority);
    if (role == MetadataFieldRoleNone)
        return;

    NSString *text = TextFromValue(value);
    if (role == MetadataFieldRoleVideoId)
        text = VideoIdFromText(text);
    if (role == MetadataFieldRoleChannel)
        text = NormalizedChannelText(text);
    if (role == MetadataFieldRoleChannel && IsSyntheticChannelValue(text))
        return;
    if (role == MetadataFieldRoleTitle && IsShortsControlText(text))
        return;
    if (text.length == 0)
        return;

    NSString *resultKey = role == MetadataFieldRoleVideoId ? @"id" : role == MetadataFieldRoleTitle ? @"title" : @"channel";
    NSUInteger previousPriority = [priorities[resultKey] unsignedIntegerValue];
    if ([result[resultKey] length] == 0 || priority > previousPriority) {
        result[resultKey] = text;
        priorities[resultKey] = @(priority);
    }
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

static void RecordRendererTextValue(NSMutableDictionary *result,
                                    NSMutableDictionary *priorities,
                                    NSString *text) {
    NSString *candidate = TrimmedText(text);
    if (candidate.length == 0)
        return;

    RecordField(result, priorities, @"videoTitle", TitleFromAccessibleText(candidate));
    RecordField(result, priorities, @"ownerDisplayName", ChannelFromAccessibleText(candidate));
    RecordField(result, priorities, @"ownerDisplayName", ChannelFromFeedAccessibleText(candidate, result[@"title"]));
    RecordField(result, priorities, @"ownerDisplayName", ChannelFromElementsAccessibleText(candidate, result[@"title"]));
    if ([candidate hasPrefix:@"@"] && IsLikelyChannelText(candidate, nil))
        RecordField(result, priorities, @"ownerDisplayName", candidate);
}

static void RecordRendererTextInMessage(NSMutableDictionary *result,
                                        NSMutableDictionary *priorities,
                                        const uint8_t *bytes,
                                        NSUInteger length,
                                        NSUInteger depth,
                                        NSUInteger *budget) {
    if (!bytes || length == 0 || depth > 8 || !budget || *budget == 0)
        return;

    NSUInteger offset = 0;
    while (offset < length && *budget > 0) {
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
            if (length - offset < 8)
                return;
            offset += 8;
            continue;
        }
        if (wireType == 5) {
            if (length - offset < 4)
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
        (*budget)--;
        if (IsPrintableUTF8Data(valueBytes, valueSize)) {
            NSString *value = [[NSString alloc] initWithBytes:valueBytes length:valueSize encoding:NSUTF8StringEncoding];
            RecordRendererTextValue(result, priorities, value);
        } else if (depth < 8) {
            RecordRendererTextInMessage(result, priorities, valueBytes, valueSize, depth + 1, budget);
        }
        offset += valueSize;
        if ([(NSString *)result[@"id"] length] > 0 &&
            [(NSString *)result[@"title"] length] > 0 &&
            [(NSString *)result[@"channel"] length] > 0)
            return;
    }
}

static void RecordRendererExtensionText(NSMutableDictionary *result,
                                         NSMutableDictionary *priorities,
                                         const uint8_t *bytes,
                                         NSUInteger length) {
    static const uint64_t extensionPath[] = {172660663, 1, 168777401, 5, 232954548, 18};
    const NSUInteger pathLength = sizeof(extensionPath) / sizeof(extensionPath[0]);
    const uint8_t *currentBytes = bytes;
    NSUInteger currentLength = length;
    for (NSUInteger pathIndex = 0; pathIndex < pathLength; pathIndex++) {
        NSUInteger offset = 0;
        BOOL found = NO;
        while (offset < currentLength) {
            uint64_t tag = 0;
            if (!ReadVarint(currentBytes, currentLength, &offset, &tag))
                return;
            uint64_t fieldNumber = tag >> 3;
            uint64_t wireType = tag & 7;
            if (fieldNumber == 0)
                return;
            if (wireType == 0) {
                uint64_t ignored = 0;
                if (!ReadVarint(currentBytes, currentLength, &offset, &ignored))
                    return;
                continue;
            }
            if (wireType == 1) {
                if (currentLength - offset < 8)
                    return;
                offset += 8;
                continue;
            }
            if (wireType == 5) {
                if (currentLength - offset < 4)
                    return;
                offset += 4;
                continue;
            }
            if (wireType != 2)
                return;
            uint64_t valueLength = 0;
            if (!ReadVarint(currentBytes, currentLength, &offset, &valueLength) || valueLength > currentLength - offset)
                return;
            const uint8_t *valueBytes = currentBytes + offset;
            NSUInteger valueSize = (NSUInteger)valueLength;
            if (fieldNumber == extensionPath[pathIndex]) {
                if (pathIndex + 1 == pathLength) {
                    NSUInteger budget = 128;
                    RecordRendererTextInMessage(result, priorities, valueBytes, valueSize, 0, &budget);
                    return;
                }
                currentBytes = valueBytes;
                currentLength = valueSize;
                found = YES;
                break;
            }
            offset += valueSize;
        }
        if (!found && pathIndex + 1 < pathLength)
            return;
    }
}

static void RecordElementRendererData(NSMutableDictionary *result,
                                      NSMutableDictionary *priorities,
                                      NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return;

    NSUInteger limit = MIN(data.length, (NSUInteger)65536);
    const uint8_t *bytes = data.bytes;
    static const char imagePrefix[] = "https://i.ytimg.com/vi/";
    static const char imageWebpPrefix[] = "https://i.ytimg.com/vi_webp/";
    NSUInteger imagePrefixLength = sizeof(imagePrefix) - 1;
    NSUInteger imageWebpPrefixLength = sizeof(imageWebpPrefix) - 1;
    for (NSUInteger index = 0; index + imagePrefixLength + 11 <= limit; index++) {
        NSUInteger identifierOffset = 0;
        if (memcmp(bytes + index, imagePrefix, imagePrefixLength) == 0)
            identifierOffset = index + imagePrefixLength;
        else if (index + imageWebpPrefixLength + 11 <= limit &&
                 memcmp(bytes + index, imageWebpPrefix, imageWebpPrefixLength) == 0)
            identifierOffset = index + imageWebpPrefixLength;
        if (identifierOffset == 0)
            continue;
        NSString *identifier = [[NSString alloc] initWithBytes:bytes + identifierOffset length:11 encoding:NSUTF8StringEncoding];
        RecordField(result, priorities, @"videoId", identifier);
    }

    RecordRendererExtensionText(result, priorities, bytes, limit);
    if ([(NSString *)result[@"id"] length] > 0 &&
        [(NSString *)result[@"title"] length] > 0 &&
        [(NSString *)result[@"channel"] length] > 0)
        return;

    NSMutableArray<NSArray *> *pending = [NSMutableArray arrayWithObject:@[[NSValue valueWithBytes:&bytes objCType:"^v"], @(limit), @0]];
    NSUInteger pendingIndex = 0;
    while (pendingIndex < pending.count && pending.count <= 32) {
        NSArray *entry = pending[pendingIndex++];
        const uint8_t *entryBytes = NULL;
        [entry[0] getValue:&entryBytes];
        NSUInteger entryLength = [entry[1] unsignedIntegerValue];
        NSUInteger depth = [entry[2] unsignedIntegerValue];
        if (!entryBytes || entryLength == 0 || depth > 4)
            continue;

        NSUInteger offset = 0;
        while (offset < entryLength) {
            uint64_t tag = 0;
            if (!ReadVarint(entryBytes, entryLength, &offset, &tag))
                break;
            uint64_t fieldNumber = tag >> 3;
            uint64_t wireType = tag & 7;
            if (fieldNumber == 0)
                break;
            if (wireType == 0) {
                uint64_t ignored = 0;
                if (!ReadVarint(entryBytes, entryLength, &offset, &ignored))
                    break;
                continue;
            }
            if (wireType == 1) {
                if (entryLength - offset < 8)
                    break;
                offset += 8;
                continue;
            }
            if (wireType == 5) {
                if (entryLength - offset < 4)
                    break;
                offset += 4;
                continue;
            }
            if (wireType != 2)
                break;

            uint64_t valueLength = 0;
            if (!ReadVarint(entryBytes, entryLength, &offset, &valueLength) || valueLength > entryLength - offset)
                break;
            NSUInteger valueSize = (NSUInteger)valueLength;
            const uint8_t *valueBytes = entryBytes + offset;
            if (IsPrintableUTF8Data(valueBytes, valueSize)) {
                NSString *value = [[NSString alloc] initWithBytes:valueBytes length:valueSize encoding:NSUTF8StringEncoding];
                if (fieldNumber == 36)
                    RecordField(result, priorities, @"videoTitle", value);
                else if (fieldNumber == 37)
                    RecordField(result, priorities, @"ownerDisplayName", value);
                RecordRendererTextValue(result, priorities, value);
            } else if (depth < 4 && !IsPrintableUTF8Data(valueBytes, valueSize) && valueSize <= 65536 && pending.count < 32) {
                [pending addObject:@[[NSValue valueWithBytes:&valueBytes objCType:"^v"], @(valueSize), @(depth + 1)]];
            }
            offset += valueSize;
        }
    }
}

static void RecordPlayableEntryDescription(NSMutableDictionary *result,
                                           NSMutableDictionary *priorities,
                                           id object) {
    NSString *className = NSStringFromClass([object class]).lowercaseString;
    if (![className containsString:@"playableentry"] &&
        ![className containsString:@"playbackplayerdescriptor"])
        return;

    id endpoint = DirectObjectValue(object, @"navigationEndpoint");
    NSString *description = TextFromValue(DirectObjectValue(endpoint, @"description"));
    if (description.length == 0)
        description = TextFromValue(DirectObjectValue(object, @"description"));
    if (description.length == 0)
        return;

    static NSArray<NSArray *> *patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *compiledPatterns = [NSMutableArray arrayWithCapacity:3];
        for (NSArray<NSString *> *pattern in @[
            @[@"video_id: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\"", @"videoId"],
            @[@"video_title: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\"", @"videoTitle"],
            @[@"owner_display_name: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\"", @"ownerDisplayName"]
        ]) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern[0]
                                                                                         options:0
                                                                                           error:nil];
            if (regex)
                [compiledPatterns addObject:@[regex, pattern[1]]];
        }
        patterns = compiledPatterns.copy;
    });

    for (NSArray *pattern in patterns) {
        NSRegularExpression *regex = pattern[0];
        NSTextCheckingResult *match = [regex firstMatchInString:description
                                                        options:0
                                                          range:NSMakeRange(0, description.length)];
        if (match.numberOfRanges < 2)
            continue;
        NSString *value = [description substringWithRange:[match rangeAtIndex:1]];
        value = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        value = [value stringByReplacingOccurrencesOfString:@"\\'" withString:@"'"];
        RecordField(result, priorities, pattern[1], value);
    }
}

static BOOL RendererDataObject(id object) {
    NSString *className = NSStringFromClass([object class]).lowercaseString;
    return [className containsString:@"elementrenderer"] || [className containsString:@"elemententry"] ||
           [className containsString:@"videoelement"];
}

static void RecordDirectMetadataFields(id object,
                                       NSMutableDictionary *result,
                                       NSMutableDictionary *priorities) {
    if (!object)
        return;

    RecordField(result, priorities, @"videoId", objc_getAssociatedObject(object, FeedVideoIDAssociationKey));

    static NSArray<NSString *> *videoKeys;
    static NSArray<NSString *> *titleKeys;
    static NSArray<NSString *> *channelKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoKeys = @[
            @"videoId", @"videoID", @"videoIdentifier", @"contentVideoId", @"contentVideoID",
            @"youtubeVideoId", @"youtubeVideoID", @"playerResponseVideoId", @"playerResponseVideoID",
            @"watchVideoId", @"watchVideoID", @"videoURL", @"watchURL", @"webpageURL", @"url"
        ];
        titleKeys = @[
            @"videoTitle", @"contentTitle", @"videoName", @"title", @"headline", @"titleText",
            @"video_title", @"content_title", @"video_name", @"title_text"
        ];
        channelKeys = @[
            @"ownerDisplayName", @"ownerName", @"channelDisplayName", @"channelName", @"channelTitle",
            @"authorName", @"displayName", @"channel", @"author", @"owner", @"ownerText",
            @"shortBylineText", @"longBylineText", @"owner_display_name", @"owner_name",
            @"channel_display_name", @"author_name", @"channel_name", @"channel_title", @"display_name"
        ];
    });

    for (NSString *key in videoKeys)
        RecordField(result, priorities, key, DirectNamedValue(object, key));
    for (NSString *key in titleKeys)
        RecordField(result, priorities, key, DirectNamedValue(object, key));
    for (NSString *key in channelKeys)
        RecordField(result, priorities, key, DirectNamedValue(object, key));

    RecordPlayableEntryDescription(result, priorities, object);
}

static void RecordDirectTextMetadata(id object,
                                     NSMutableDictionary *result,
                                     NSMutableDictionary *priorities,
                                     NSMutableArray<NSString *> *textValues) {
    if (!object)
        return;

    NSString *className = NSStringFromClass([object class]).lowercaseString;
    NSString *identifier = TextFromValue(DirectObjectValue(object, @"accessibilityIdentifier")).lowercaseString;
    NSArray *values = @[
        DirectObjectValue(object, @"text") ?: [NSNull null],
        DirectObjectValue(object, @"attributedText") ?: [NSNull null],
        DirectObjectValue(object, @"currentTitle") ?: [NSNull null],
        DirectObjectValue(object, @"accessibilityLabel") ?: [NSNull null],
        DirectObjectValue(object, @"label") ?: [NSNull null]
    ];
    for (id value in values) {
        if (value == [NSNull null])
            continue;
        NSString *text = TextFromAccessibilityValue(value);
        if (text.length == 0)
            continue;
        if (textValues.count < 64 && ![textValues containsObject:text])
            [textValues addObject:text];
        RecordShortsAccessibleText(text, result, priorities);
        if ([identifier containsString:@"channel"] || [identifier containsString:@"owner"] ||
            [className containsString:@"channel"] || [className containsString:@"owner"])
            RecordField(result, priorities, @"ownerDisplayName", text);
        if ([identifier containsString:@"title"] || [identifier containsString:@"headline"] ||
            [className containsString:@"title"] || [className containsString:@"headline"])
            RecordField(result, priorities, @"videoTitle", text);
        if ([text hasPrefix:@"@"] && IsLikelyChannelText(text, nil))
            RecordField(result, priorities, @"ownerDisplayName", text);
        RecordField(result, priorities, @"videoTitle", TitleFromAccessibleText(text));
        RecordField(result, priorities, @"ownerDisplayName", ChannelFromAccessibleText(text));
        RecordField(result, priorities, @"ownerDisplayName",
                   ChannelFromFeedAccessibleText(text, result[@"title"]));
        RecordField(result, priorities, @"ownerDisplayName",
                   ChannelFromElementsAccessibleText(text, result[@"title"]));
        RecordField(result, priorities, @"videoTitle",
                   TitleFromElementsAccessibleText(text, result[@"channel"]));
    }
}

static void AddAdapterObject(NSMutableArray<id> *objects,
                             NSMutableSet *visited,
                             id object) {
    if (!object || object == [NSNull null] || [object isKindOfClass:[NSString class]] ||
        [object isKindOfClass:[NSNumber class]] || objects.count >= 64)
        return;

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return;
    [visited addObject:identity];
    [objects addObject:object];
}

static void AddAdapterObjectAndChildren(NSMutableArray<id> *objects,
                                        NSMutableSet *visited,
                                        id object,
                                        NSArray<NSString *> *keys) {
    AddAdapterObject(objects, visited, object);
    if (!object)
        return;

    for (NSString *key in keys) {
        id value = DirectNamedValue(object, key);
        if (!value || value == object)
            continue;
        if ([value isKindOfClass:[NSArray class]]) {
            NSUInteger count = 0;
            for (id child in (NSArray *)value) {
                if (count++ >= 16)
                    break;
                AddAdapterObject(objects, visited, child);
            }
        } else {
            AddAdapterObject(objects, visited, value);
        }
    }
}

static void AddBoundedModelGraph(NSMutableArray<id> *objects,
                                 NSMutableSet *visited,
                                 id object,
                                 NSArray<NSString *> *keys,
                                 NSUInteger depth) {
    if (!object || objects.count >= 64)
        return;

    NSUInteger countBefore = objects.count;
    AddAdapterObject(objects, visited, object);
    if (objects.count == countBefore || depth >= 3)
        return;

    for (NSString *key in keys) {
        id value = DirectNamedValue(object, key);
        if (!value || value == object)
            continue;
        if ([value isKindOfClass:[NSArray class]]) {
            NSUInteger childCount = 0;
            for (id child in (NSArray *)value) {
                if (childCount++ >= 16 || objects.count >= 64)
                    break;
                AddBoundedModelGraph(objects, visited, child, keys, depth + 1);
            }
        } else {
            AddBoundedModelGraph(objects, visited, value, keys, depth + 1);
        }
        if (objects.count >= 64)
            break;
    }
}

static void AdaptInlinePlaybackNode(id node, NSMutableArray<id> *objects, NSMutableSet *visited) {
    AddAdapterObjectAndChildren(objects, visited, node,
                                @[@"element", @"context", @"playbackView", @"asdPlayableEntry"]);
    id playbackView = DirectNamedValue(node, @"playbackView");
    AddAdapterObjectAndChildren(objects, visited, playbackView, @[@"asdPlayableEntry"]);
    id playableEntry = DirectNamedValue(playbackView, @"asdPlayableEntry");
    AddAdapterObjectAndChildren(objects, visited, playableEntry, @[@"navigationEndpoint"]);
    AddAdapterObjectAndChildren(objects, visited,
                                DirectNamedValue(node, @"element"),
                                @[@"instance", @"properties", @"allProperties", @"context"]);

}

static void AdaptLongFormVideoNode(id node, NSMutableArray<id> *objects, NSMutableSet *visited) {
    AddAdapterObjectAndChildren(objects, visited, node,
                                @[@"element", @"context", @"parentResponder", @"controller", @"video", @"videoDetails", @"entry", @"subnodes"]);
    id context = DirectNamedValue(node, @"context");
    AddAdapterObjectAndChildren(objects, visited, context, @[@"parentResponder", @"elementEntry", @"entry", @"model", @"data", @"properties"]);
    AddAdapterObjectAndChildren(objects, visited, DirectNamedValue(context, @"parentResponder"), @[@"elementEntry", @"entry", @"model", @"data", @"properties", @"renderer", @"videoRenderer"]);
    id element = DirectNamedValue(node, @"element");
    AddAdapterObjectAndChildren(objects, visited, element, @[@"instance", @"properties", @"allProperties", @"context", @"data", @"renderer", @"videoRenderer", @"elementData", @"model"]);
    AddAdapterObjectAndChildren(objects, visited, DirectNamedValue(element, @"instance"), @[@"properties", @"allProperties", @"data", @"elementData", @"renderer", @"videoRenderer", @"model", @"video", @"videoDetails"]);
    id parentResponder = DirectNamedValue(node, @"parentResponder");
    AddAdapterObjectAndChildren(objects, visited, parentResponder, @[@"elementEntry", @"entry", @"cell", @"parentResponder"]);
    id controller = DirectNamedValue(node, @"controller");
    id elementEntry = DirectNamedValue(parentResponder, @"elementEntry") ?: DirectNamedValue(parentResponder, @"entry") ?: DirectNamedValue(controller, @"elementEntry");
    AddAdapterObjectAndChildren(objects, visited, elementEntry,
                                @[@"renderer", @"videoRenderer", @"navigationEndpoint", @"watchEndpoint", @"data", @"elementData", @"video", @"videoDetails"]);
    NSArray *subnodes = DirectNamedValue(node, @"subnodes");
    NSUInteger subnodeCount = 0;
    for (id subnode in subnodes) {
        if (subnodeCount++ >= 16)
            break;
        AddAdapterObjectAndChildren(objects, visited, subnode,
                                    @[@"playbackView", @"asdPlayableEntry", @"navigationEndpoint", @"watchEndpoint", @"element", @"context", @"video", @"videoDetails"]);
        NSString *subnodeClassName = NSStringFromClass([subnode class]).lowercaseString;
        if ([subnodeClassName containsString:@"inlineplayback"])
            AdaptInlinePlaybackNode(subnode, objects, visited);
        else if ([subnodeClassName containsString:@"elm"])
            AdaptElementsFeedNode(subnode, objects, visited);
    }

}

static void AdaptElementsFeedNode(id node, NSMutableArray<id> *objects, NSMutableSet *visited) {
    AddAdapterObjectAndChildren(objects, visited, node,
                                @[@"element", @"context", @"controller", @"parentResponder", @"elementEntry", @"entry", @"subnodes"]);
    id context = DirectNamedValue(node, @"context");
    AddAdapterObjectAndChildren(objects, visited, context, @[@"parentResponder", @"elementEntry", @"entry", @"model", @"data", @"properties"]);
    AddAdapterObjectAndChildren(objects, visited, DirectNamedValue(context, @"parentResponder"), @[@"elementEntry", @"entry", @"model", @"data", @"properties", @"renderer", @"videoRenderer"]);
    id element = DirectNamedValue(node, @"element");
    AddAdapterObjectAndChildren(objects, visited, element, @[@"instance", @"properties", @"allProperties", @"context", @"data", @"renderer", @"videoRenderer", @"elementData", @"model"]);
    AddAdapterObjectAndChildren(objects, visited, DirectNamedValue(element, @"instance"), @[@"properties", @"allProperties", @"data", @"elementData", @"renderer", @"videoRenderer", @"model", @"video", @"videoDetails"]);
    id controller = DirectNamedValue(node, @"controller");
    AddAdapterObjectAndChildren(objects, visited, controller, @[@"elementEntry", @"entry"]);
    id parentResponder = DirectNamedValue(node, @"parentResponder");
    AddAdapterObjectAndChildren(objects, visited, parentResponder, @[@"elementEntry", @"entry", @"cell", @"parentResponder"]);
    AddAdapterObjectAndChildren(objects, visited,
                                DirectNamedValue(controller, @"elementEntry") ?: DirectNamedValue(controller, @"entry") ?: DirectNamedValue(parentResponder, @"elementEntry") ?: DirectNamedValue(parentResponder, @"entry"),
                                @[@"renderer", @"videoRenderer", @"navigationEndpoint", @"watchEndpoint", @"data", @"elementData", @"video", @"videoDetails"]);
    NSArray *subnodes = DirectNamedValue(node, @"subnodes");
    NSUInteger subnodeCount = 0;
    for (id subnode in subnodes) {
        if (subnodeCount++ >= 16)
            break;
        AddAdapterObjectAndChildren(objects, visited, subnode,
                                    @[@"element", @"context", @"properties", @"allProperties", @"data", @"renderer", @"videoRenderer", @"elementData", @"subnodes", @"text", @"attributedText", @"accessibilityLabel"]);
        if ([NSStringFromClass([subnode class]).lowercaseString containsString:@"inlineplayback"])
            AdaptInlinePlaybackNode(subnode, objects, visited);
        NSArray *nestedSubnodes = DirectNamedValue(subnode, @"subnodes");
        NSUInteger nestedSubnodeCount = 0;
        for (id nestedSubnode in nestedSubnodes) {
            if (nestedSubnodeCount++ >= 16)
                break;
            AddAdapterObjectAndChildren(objects, visited, nestedSubnode,
                                        @[@"element", @"context", @"properties", @"allProperties", @"data", @"renderer", @"videoRenderer", @"elementData", @"text", @"attributedText", @"accessibilityLabel"]);
            if ([NSStringFromClass([nestedSubnode class]).lowercaseString containsString:@"inlineplayback"])
                AdaptInlinePlaybackNode(nestedSubnode, objects, visited);
        }
    }

}

static void AdaptShortsNode(id node, NSMutableArray<id> *objects, NSMutableSet *visited) {
    NSArray<NSString *> *rootKeys = @[
        @"currentVideo", @"reelItem", @"reel", @"content", @"player", @"navigationEndpoint",
        @"watchEndpoint", @"element", @"parentResponder", @"video", @"videoDetails", @"videoData",
        @"singleVideo", @"metadata", @"watchModel", @"reelModel", @"playerResponse", @"channel",
        @"channelName", @"channelTitle", @"channelHandle", @"channelNavigationEndpoint", @"owner",
        @"ownerName", @"ownerDisplayName", @"ownerNavigationEndpoint", @"author", @"authorName",
        @"creator", @"byline", @"subnodes", @"text", @"attributedText", @"accessibilityLabel",
        @"accessibilityIdentifier", @"properties", @"allProperties", @"context"
    ];
    AddAdapterObjectAndChildren(objects, visited, node, rootKeys);
    AddBoundedShortsSubnodes(objects, visited, node, 0);
    for (NSString *key in @[@"currentVideo", @"reelItem", @"reel", @"content", @"player", @"navigationEndpoint", @"watchEndpoint", @"videoData", @"singleVideo", @"metadata", @"watchModel", @"reelModel"]) {
        id child = DirectNamedValue(node, key);
        AddAdapterObjectAndChildren(objects, visited, child,
                                    @[@"video", @"videoDetails", @"metadata", @"renderer", @"navigationEndpoint",
                                      @"watchEndpoint", @"content", @"reelItem", @"element", @"properties", @"allProperties",
                                      @"videoData", @"singleVideo", @"channel", @"channelName", @"channelTitle", @"channelHandle",
                                      @"channelNavigationEndpoint", @"owner", @"ownerName", @"ownerDisplayName",
                                      @"ownerNavigationEndpoint", @"author", @"authorName", @"creator", @"byline", @"playerResponse",
                                      @"subnodes", @"text", @"attributedText", @"accessibilityLabel", @"accessibilityIdentifier"]);
    }
}

static void AdaptShortsWatchResponse(id response,
                                     NSMutableArray<id> *objects,
                                     NSMutableSet *visited) {
    id overlay = DirectNamedValue(response, @"overlay");
    id overlayRenderer = DirectNamedValue(overlay, @"reelPlayerOverlayRenderer");
    id supportedRenderers = DirectNamedValue(overlayRenderer, @"reelPlayerHeaderSupportedRenderers");
    id headerRenderer = DirectNamedValue(supportedRenderers, @"reelPlayerHeaderRenderer");
    id accessibility = DirectNamedValue(headerRenderer, @"accessibility");
    id accessibilityData = DirectNamedValue(accessibility, @"accessibilityData");

    AddAdapterObject(objects, visited, overlay);
    AddAdapterObject(objects, visited, overlayRenderer);
    AddAdapterObject(objects, visited, supportedRenderers);
    AddAdapterObject(objects, visited, headerRenderer);
    AddAdapterObject(objects, visited, accessibility);
    AddAdapterObject(objects, visited, accessibilityData);
}

static void AddBoundedShortsSubnodes(NSMutableArray<id> *objects,
                                     NSMutableSet *visited,
                                     id node,
                                     NSUInteger depth) {
    if (!node || depth >= 3 || objects.count >= 64)
        return;

    NSArray *subnodes = DirectNamedValue(node, @"subnodes");
    if (![subnodes isKindOfClass:[NSArray class]])
        return;

    NSArray<NSString *> *keys = @[
        @"currentVideo", @"reelItem", @"reel", @"content", @"player", @"navigationEndpoint", @"watchEndpoint",
        @"video", @"videoDetails", @"videoData", @"singleVideo", @"metadata", @"watchModel", @"reelModel",
        @"element", @"properties", @"allProperties", @"context", @"channel", @"channelName", @"channelTitle",
        @"channelHandle", @"owner", @"ownerName", @"ownerDisplayName", @"author", @"authorName", @"creator",
        @"byline", @"text", @"attributedText", @"accessibilityLabel", @"accessibilityIdentifier"
    ];
    NSUInteger count = 0;
    for (id subnode in subnodes) {
        if (count++ >= 16 || objects.count >= 64)
            break;
        AddAdapterObjectAndChildren(objects, visited, subnode, keys);
        AddBoundedShortsSubnodes(objects, visited, subnode, depth + 1);
    }
}

static void RecordAdapterObjects(NSArray<id> *objects,
                                 NSMutableDictionary *result,
                                 NSMutableDictionary *priorities,
                                 NSMutableArray<NSString *> *textValues) {
    for (id object in objects) {
        RecordDirectMetadataFields(object, result, priorities);
        if ([(NSString *)result[@"id"] length] > 0 &&
            [(NSString *)result[@"title"] length] > 0 &&
            [(NSString *)result[@"channel"] length] > 0)
            return;
    }
    for (id object in objects) {
        if ([(NSString *)result[@"id"] length] > 0 &&
            [(NSString *)result[@"title"] length] > 0 &&
            [(NSString *)result[@"channel"] length] > 0)
            break;
        RecordDirectTextMetadata(object, result, priorities, textValues);
        if (RendererDataObject(object)) {
            NSData *data = DirectObjectValue(object, @"data");
            if (![data isKindOfClass:[NSData class]])
                data = DirectObjectValue(object, @"elementData");
            RecordElementRendererData(result, priorities, data);
        }
    }
}

static BOOL ObjectIsClassNamed(id object, NSString *className) {
    Class objectClass = NSClassFromString(className);
    return objectClass && [object isKindOfClass:objectClass];
}

static NSDictionary *FastVideoInfoFromNode(id node) {
    if (!node)
        return nil;

    NSString *className = NSStringFromClass([node class]).lowercaseString;
    BOOL isLongForm = ObjectIsClassNamed(node, @"YTVideoWithContextNode") || ObjectIsClassNamed(node, @"YTVideoNode");
    BOOL isShorts = [className containsString:@"short"] || [className containsString:@"reel"];
    BOOL isInlinePlayback = [className containsString:@"inlineplayback"];
    BOOL isElements = ObjectIsClassNamed(node, @"ELMCellNode") ||
                      ObjectIsClassNamed(node, @"ELMContainerNode") ||
                      ObjectIsClassNamed(node, @"ELMCollectionNode");
    NSMutableArray<id> *objects = [NSMutableArray arrayWithCapacity:24];
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:3];
    NSMutableDictionary *priorities = [NSMutableDictionary dictionaryWithCapacity:3];
    NSMutableArray<NSString *> *textValues = [NSMutableArray arrayWithCapacity:16];

    if (isLongForm)
        AdaptLongFormVideoNode(node, objects, visited);
    else if (isShorts)
        AdaptShortsNode(node, objects, visited);
    else if (isInlinePlayback)
        AdaptInlinePlaybackNode(node, objects, visited);
    else if (isElements)
        AdaptElementsFeedNode(node, objects, visited);
    else if (ObjectIsClassNamed(node, @"ASTextNode"))
        return @{};
    else {
#if DEBUG
        NSLog(@"Unrecognized feed renderer: %@", NSStringFromClass([node class]));
#endif
        return nil;
    }

    RecordAdapterObjects(objects, result, priorities, textValues);

    if (isShorts && !IsShortsMetadataTitleText(result[@"title"], result[@"channel"])) {
        [result removeObjectForKey:@"title"];
        [priorities removeObjectForKey:@"title"];
    }
    if ([(NSString *)result[@"title"] length] == 0) {
        for (NSString *text in textValues) {
            NSString *title = isShorts ?
                (IsShortsMetadataTitleText(text, result[@"channel"]) ? text : nil) :
                TitleFromAccessibleText(text) ?: TitleFromElementsAccessibleText(text, result[@"channel"]);
            if (title.length > 0) {
                RecordField(result, priorities, @"videoTitle", title);
                break;
            }
        }
    }
    if ([(NSString *)result[@"channel"] length] == 0) {
        for (NSString *text in textValues) {
            NSString *channel = [text hasPrefix:@"@"] && IsLikelyChannelText(text, nil) ? text : ChannelFromAccessibleText(text);
            if (channel.length > 0) {
                RecordField(result, priorities, @"ownerDisplayName", channel);
                break;
            }
        }
    }
    if ([result[@"title"] isEqualToString:result[@"channel"]])
        [result removeObjectForKey:@"channel"];

    return result.count > 0 ? result.copy : nil;
}

static NSDictionary *FastVideoInfoFromModel(id model) {
    if (!model)
        return nil;

    NSString *className = NSStringFromClass([model class]).lowercaseString;
    BOOL knownModelClass = [className containsString:@"ytvideo"] ||
                           [className containsString:@"videomodel"] ||
                           [className containsString:@"watchmodel"] ||
                           [className containsString:@"reelmodel"] ||
                           [className containsString:@"reelitem"] ||
                           [className containsString:@"elementrenderer"] ||
                           [className containsString:@"elemententry"] ||
                           [className containsString:@"videoelement"] ||
                           [className containsString:@"short"] ||
                           [className containsString:@"reel"];
    BOOL knownRendererClass = ObjectIsClassNamed(model, @"YTVideoNode") ||
                              ObjectIsClassNamed(model, @"YTVideoWithContextNode") ||
                              ObjectIsClassNamed(model, @"ELMCellNode") ||
                              ObjectIsClassNamed(model, @"ELMContainerNode") ||
                              ObjectIsClassNamed(model, @"ELMCollectionNode") ||
                              [className containsString:@"short"] ||
                              [className containsString:@"reel"] ||
                              [className containsString:@"inlineplayback"];
    if (knownRendererClass) {
        NSDictionary *nodeInfo = FastVideoInfoFromNode(model);
        if (nodeInfo.count > 0)
            return nodeInfo;
    }
    if (!knownModelClass && [model isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"videoId", @"videoID", @"contentVideoId", @"renderer", @"videoRenderer", @"watchModel", @"reelModel", @"reelItem"]) {
            if (DirectNamedValue(model, key)) {
                knownModelClass = YES;
                break;
            }
        }
    }
    if (!knownModelClass)
        return nil;

    NSMutableArray<id> *objects = [NSMutableArray arrayWithCapacity:16];
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:3];
    NSMutableDictionary *priorities = [NSMutableDictionary dictionaryWithCapacity:3];
    NSMutableArray<NSString *> *textValues = [NSMutableArray arrayWithCapacity:8];
    AddBoundedModelGraph(objects,
                         visited,
                         model,
                         @[@"renderer", @"videoRenderer", @"navigationEndpoint", @"watchEndpoint",
                           @"video", @"videoDetails", @"content", @"reelItem", @"element",
                           @"properties", @"allProperties", @"data", @"elementData", @"currentVideo",
                           @"videoData", @"singleVideo", @"metadata", @"watchModel", @"reelModel",
                           @"playerResponse", @"response", @"channel", @"channelName", @"channelTitle", @"channelHandle",
                           @"channelNavigationEndpoint", @"owner", @"ownerName", @"ownerDisplayName",
                           @"ownerNavigationEndpoint", @"author", @"authorName", @"creator", @"byline",
                           @"overlay", @"reelPlayerOverlayRenderer", @"reelWatchEndpoint", @"header",
                           @"reelPlayerHeaderSupportedRenderers", @"reelPlayerHeaderRenderer", @"accessibility",
                           @"accessibilityData", @"label", @"contents", @"headerContent", @"supportedRenderers",
                           @"renderers", @"items"],
                         0);
    if ([className containsString:@"watchresponse"])
        AdaptShortsWatchResponse(model, objects, visited);
    RecordAdapterObjects(objects, result, priorities, textValues);
    if (([className containsString:@"short"] || [className containsString:@"reel"]) &&
        !IsShortsMetadataTitleText(result[@"title"], result[@"channel"]))
        [result removeObjectForKey:@"title"];
    if ([result[@"title"] isEqualToString:result[@"channel"]])
        [result removeObjectForKey:@"channel"];
    return result.count > 0 ? result.copy : nil;
}

static NSString *DirectNodeText(id node) {
    NSString *text = TextFromValue(DirectObjectValue(node, @"attributedText"));
    if (text.length > 0)
        return text;
    return TextFromValue(DirectObjectValue(node, @"accessibilityLabel"));
}

static FeedMetadataRecord *MergedMetadataRecord(FeedMetadataRecord *current,
                                                FeedMetadataRecord *stable) {
    if (!current)
        return stable;
    if (!stable)
        return current;

    return [[FeedMetadataRecord alloc]
        initWithVideoID:current.videoID.length > 0 ? current.videoID : stable.videoID
                 title:current.title.length > 0 ? current.title : stable.title
               channel:current.channel.length > 0 ? current.channel : stable.channel];
}

static FeedMetadataRecord *MetadataRecordByCombining(FeedMetadataRecord *first,
                                                      FeedMetadataRecord *second) {
    if (!first)
        return second;
    if (!second)
        return first;

    return [[FeedMetadataRecord alloc]
        initWithVideoID:first.videoID.length > 0 ? first.videoID : second.videoID
                 title:first.title.length > 0 ? first.title : second.title
               channel:first.channel.length > 0 ? first.channel : second.channel];
}

@implementation Util

+ (void)initialize {
    if (self != [Util class])
        return;
    RefreshPreferenceSnapshot();
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:[NSUserDefaults standardUserDefaults]
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification *notification) {
        RefreshPreferenceSnapshot();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:FeedFilterStateDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification *notification) {
        RefreshPreferenceSnapshot();
    }];
}

+ (BOOL)filteringEnabled {
    return FilteringEnabledState;
}

+ (void)refreshPreferenceSnapshot {
    RefreshPreferenceSnapshot();
}

+ (NSDictionary *)videoInfoFromNode:(id)node {
    return [[self feedVideoMetadataFromNode:node] dictionaryRepresentation];
}

+ (NSDictionary *)feedVideoInfoFromNode:(id)node {
    return [[self feedVideoMetadataFromNode:node] dictionaryRepresentation];
}

+ (FeedMetadataRecord *)feedVideoMetadataFromNode:(id)node {
    if (!node)
        return nil;

    NSMapTable *cache = FeedMetadataCache();
    @synchronized (cache) {
        FeedMetadataRecord *cached = [cache objectForKey:node];
        NSString *currentVideoID = TextAtom(DirectNamedValue(node, @"videoId"));
        if (currentVideoID.length == 0)
            currentVideoID = TextAtom(DirectNamedValue(node, @"videoID"));
        NSString *associatedVideoID = [self feedVideoIDForObject:node];
        if (currentVideoID.length > 0 && associatedVideoID.length > 0 &&
            ![currentVideoID isEqualToString:associatedVideoID])
            [self setFeedVideoID:nil forObject:node];
        if (currentVideoID.length == 0)
            currentVideoID = [self feedVideoIDForObject:node];
        if (cached && (currentVideoID.length == 0 || cached.videoID.length == 0 || [cached.videoID isEqualToString:currentVideoID]))
            return cached;
        if (cached)
            [cache removeObjectForKey:node];
    }

    NSDictionary *info = FastVideoInfoFromNode(node) ?: @{};
    FeedMetadataRecord *record = [[FeedMetadataRecord alloc] initWithVideoID:info[@"id"]
                                                                         title:info[@"title"]
                                                                       channel:info[@"channel"]];
    if (record.dictionaryRepresentation.count == 0)
        return record;
    @synchronized (cache) {
        FeedMetadataRecord *stableRecord = record.videoID.length > 0 ? FeedMetadataByVideoID()[record.videoID] : nil;
        if (stableRecord)
            record = MergedMetadataRecord(record, stableRecord);
        if (record.videoID.length > 0) {
            NSMutableDictionary *records = FeedMetadataByVideoID();
            if (records.count >= 512 && !records[record.videoID])
                [records removeObjectForKey:records.allKeys.firstObject];
            records[record.videoID] = record;
        }
        [cache setObject:record forKey:node];
    }
    return record;
}

+ (FeedMetadataRecord *)feedVideoMetadataFromModel:(id)model {
    if (!model)
        return nil;
    NSDictionary *info = FastVideoInfoFromModel(model) ?: @{};
    FeedMetadataRecord *record = [[FeedMetadataRecord alloc] initWithVideoID:info[@"id"]
                                                                         title:info[@"title"]
                                                                       channel:info[@"channel"]];
    [self rememberFeedVideoMetadata:record forNode:model];
    return [self cachedFeedVideoMetadataForNode:model] ?: record;
}

+ (FeedMetadataRecord *)feedVideoMetadataFromShortsContentView:(id)contentView {
    if (!contentView)
        return nil;
    return ShortsMetadataFromContentView(contentView);
}

+ (void)invalidateShortsMetadataForContentView:(id)contentView {
    if (!contentView)
        return;
    id contentNode = [contentView isKindOfClass:[UIView class]] ? DirectObjectValue(contentView, @"asyncdisplaykit_node") : nil;
    NSMapTable *cache = FeedMetadataCache();
    @synchronized (cache) {
        [cache removeObjectForKey:contentView];
        if (contentNode)
            [cache removeObjectForKey:contentNode];
    }
    objc_setAssociatedObject(contentView, ShortsMetadataAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (contentNode)
        [self resetFeedVideoMetadataForNode:contentNode];
}

+ (void)rememberFeedVideoMetadata:(FeedMetadataRecord *)metadata forNode:(id)node {
    if (!node || !metadata || metadata.dictionaryRepresentation.count == 0)
        return;

    NSMapTable *cache = FeedMetadataCache();
    @synchronized (cache) {
        FeedMetadataRecord *current = [cache objectForKey:node];
        if (current.videoID.length > 0 && metadata.videoID.length > 0 &&
            ![current.videoID isEqualToString:metadata.videoID])
            current = nil;
        FeedMetadataRecord *stable = nil;
        if (metadata.videoID.length > 0)
            stable = FeedMetadataByVideoID()[metadata.videoID];
        if (!stable && current.videoID.length > 0)
            stable = FeedMetadataByVideoID()[current.videoID];

        FeedMetadataRecord *record = MetadataRecordByCombining(current, metadata);
        record = MetadataRecordByCombining(stable, record);
        if (record.videoID.length > 0) {
            NSMutableDictionary *records = FeedMetadataByVideoID();
            if (records.count >= 512 && !records[record.videoID])
                [records removeObjectForKey:records.allKeys.firstObject];
            records[record.videoID] = record;
        }
        [cache setObject:record forKey:node];
    }
}

+ (FeedMetadataRecord *)cachedFeedVideoMetadataForNode:(id)node {
    if (!node)
        return nil;
    NSMapTable *cache = FeedMetadataCache();
    @synchronized (cache) {
        return [cache objectForKey:node];
    }
}

+ (FeedMetadataRecord *)cachedFeedVideoMetadataForVideoID:(NSString *)videoID {
    if (![videoID isKindOfClass:[NSString class]] || videoID.length == 0)
        return nil;

    NSMapTable *cache = FeedMetadataCache();
    @synchronized (cache) {
        return FeedMetadataByVideoID()[videoID];
    }
}

+ (NSString *)feedVideoIDFromThumbnailURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]])
        return nil;
    return VideoIdFromText(url.absoluteString);
}

+ (NSString *)feedVideoIDForObject:(id)object {
    if (!object)
        return nil;
    NSString *videoID = objc_getAssociatedObject(object, FeedVideoIDAssociationKey);
    return [videoID isKindOfClass:[NSString class]] ? videoID : nil;
}

+ (void)setFeedVideoID:(NSString *)videoID forObject:(id)object {
    if (!object)
        return;
    objc_setAssociatedObject(object,
                             FeedVideoIDAssociationKey,
                             videoID.length > 0 ? [videoID copy] : nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

+ (BOOL)isUsableVideoTitle:(NSString *)title {
    return TrimmedText(title).length > 0 && !IsShortsControlText(title);
}

+ (NSDictionary *)freshVideoInfoFromNode:(id)node {
    return [[self feedVideoMetadataFromNode:node] dictionaryRepresentation];
}

+ (NSDictionary *)freshVideoInfoFromNode:(id)node sourceView:(UIView *)sourceView {
    return [[self feedVideoMetadataFromNode:node] dictionaryRepresentation];
}

+ (void)invalidateVideoInfoForNode:(id)node {
    if (!node)
        return;
    NSMapTable *cache = FeedMetadataCache();
    @synchronized (cache) {
        [cache removeObjectForKey:node];
    }
}

+ (void)resetFeedVideoMetadataForNode:(id)node {
    if (!node)
        return;
    [self invalidateVideoInfoForNode:node];
    [self setFeedVideoID:nil forObject:node];
}

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion {
    if (!completion)
        return;
    FeedMetadataRecord *metadata = [self feedVideoMetadataFromNode:node];
    completion(metadata.videoID, metadata.title, metadata.channel);
}

+ (BOOL)nodeContainsBlockedVideo:(id)node {
    return [self nodeContainsBlockedVideo:node metadata:[self feedVideoMetadataFromNode:node]];
}

+ (BOOL)nodeContainsBlockedVideo:(id)node
                        videoInfo:(NSDictionary<NSString *, NSString *> *)videoInfo {
    FeedMetadataRecord *metadata = [[FeedMetadataRecord alloc] initWithVideoID:videoInfo[@"id"]
                                                                         title:videoInfo[@"title"]
                                                                       channel:videoInfo[@"channel"]];
    return [self nodeContainsBlockedVideo:node metadata:metadata];
}

+ (BOOL)nodeContainsBlockedVideo:(id)node metadata:(FeedMetadataRecord *)metadata {
    if (!FilteringEnabledState)
        return NO;

    BOOL videoBlocked = [VideoManager.sharedInstance isVideoBlocked:metadata.videoID];
    BOOL channelBlocked = [ChannelManager.sharedInstance isChannelBlocked:metadata.channel];
    BOOL titleBlocked = [WordManager.sharedInstance isWordBlocked:metadata.title];
    BOOL metadataChannelBlocked = [WordManager.sharedInstance isWordBlocked:metadata.channel];
    if (videoBlocked || channelBlocked || titleBlocked || metadataChannelBlocked)
        return YES;

    if (ObjectIsClassNamed(node, @"ASTextNode")) {
        NSString *text = DirectNodeText(node);
        if (PeopleWatchedState && [text isEqualToString:@"People also watched this video"])
            return YES;
        if (MightLikeState && [text isEqualToString:@"You might also like this"])
            return YES;
    }
    return NO;
}

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
        UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:center radius:radius startAngle:0 endAngle:2 * M_PI clockwise:YES];
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
        UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:center radius:radius startAngle:0 endAngle:2 * M_PI clockwise:YES];
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
