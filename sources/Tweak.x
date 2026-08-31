#import "Tweak.h"
#import <objc/runtime.h>

#if 0
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

static id ValueForArgumentKeyName(id object, NSString *key) {
    for (NSString *selectorName in @[@"propertyForKey:", @"elementForKey:", @"safeSwiftValueForKey:", @"safeSwiftStringForKey:", @"tps_safeValueForKey:", @"valueForKey:"]) {
        id value = ValueForArgumentKey(object, NSSelectorFromString(selectorName), key);
        if (value)
            return value;
    }
    return nil;
}
#endif

static id ValueForObjectKey(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    @try {
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

static NSString * __attribute__((unused)) DebugString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static BOOL NodeLooksLikeVideo(id node) {
    if (!node)
        return NO;

    NSString *nodeClassName = NSStringFromClass([node class]);
    NSString *normalizedClassName = nodeClassName.lowercaseString;
    if ([normalizedClassName containsString:@"collection"] ||
        [normalizedClassName containsString:@"reorderable"] ||
        [normalizedClassName containsString:@"scrollablepage"] ||
        [normalizedClassName containsString:@"shelf"] ||
        [normalizedClassName containsString:@"section"])
        return NO;

    BOOL isVideoLike = [normalizedClassName containsString:@"video"] ||
                       [normalizedClassName containsString:@"short"] ||
                       [normalizedClassName containsString:@"reel"];
    BOOL isContentNode = [normalizedClassName containsString:@"node"] ||
                         [normalizedClassName containsString:@"item"];
    if (isVideoLike && isContentNode)
        return YES;

    return NO;
}

static BOOL NodeLooksLikeActionVideo(id node) {
    if (!node)
        return NO;

    if (NodeLooksLikeVideo(node))
        return YES;

    NSString *className = NSStringFromClass([node class]).lowercaseString;
    if ([className containsString:@"shorts"] &&
        ([className containsString:@"node"] || [className containsString:@"item"] ||
         [className containsString:@"player"]))
        return YES;

    @try {
        return [[node debugDescription] containsString:@"YTShortsPlayerViewController"];
    } @catch (__unused NSException *exception) {
    }

    return NO;
}

static id VideoNodeFromView(UIView *view, NSUInteger depth) {
    if (![view isKindOfClass:[UIView class]] || depth > 16)
        return nil;

    id node = ValueForObjectKey(view, @"asyncdisplaykit_node");
    if (NodeLooksLikeActionVideo(node))
        return node;

    for (UIView *subview in view.subviews) {
        node = VideoNodeFromView(subview, depth + 1);
        if (node)
            return node;
    }

    return nil;
}

#if 0
static id ObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0)
        return nil;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static void WriteRuntimeDiagnostics(id node) {
    if (!node || [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoRuntimeDiagnostics4"])
        return;

    NSMutableArray *objects = [NSMutableArray array];
    id element = ValueForObjectKey(node, @"element");
    id controller = ValueForObjectKey(node, @"controller");
    id context = ValueForObjectKey(node, @"context");
    NSArray *candidateObjects = @[node ?: [NSNull null], element ?: [NSNull null], controller ?: [NSNull null],
                                  context ?: [NSNull null], ObjectIvar(node, @"_context") ?: [NSNull null],
                                  ObjectIvar(node, @"_nodeContext") ?: [NSNull null],
                                  ObjectIvar(controller, @"_context") ?: [NSNull null],
                                  ObjectIvar(controller, @"_treeLocalContext") ?: [NSNull null]];
    for (id object in candidateObjects) {
        if (object == [NSNull null])
            continue;

        NSMutableArray *ivars = [NSMutableArray array];
        Class currentClass = [object class];
        while (currentClass) {
            unsigned int ivarCount = 0;
            Ivar *classIvars = class_copyIvarList(currentClass, &ivarCount);
            for (unsigned int index = 0; index < ivarCount; index++) {
                Ivar ivar = classIvars[index];
                const char *type = ivar_getTypeEncoding(ivar);
                if (!type || type[0] != '@')
                    continue;
                id value = object_getIvar(object, ivar);
                if (!value)
                    continue;
                NSString *description = @"";
                @try {
                    description = [value debugDescription] ?: [value description] ?: @"";
                } @catch (__unused NSException *exception) {
                }
                if (description.length > 2000)
                    description = [description substringToIndex:2000];
                [ivars addObject:@{
                    @"name": [NSString stringWithUTF8String:ivar_getName(ivar)] ?: @"",
                    @"class": NSStringFromClass([value class]) ?: @"",
                    @"description": description
                }];
            }
            free(classIvars);
            currentClass = class_getSuperclass(currentClass);
        }

        NSMutableArray *methods = [NSMutableArray array];
        for (NSString *name in @[@"instance", @"cxxSharedElement", @"viewController", @"currentVideo", @"videoId", @"videoIdentifier", @"playerResponse"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod([object class], selector);
            if (method)
                [methods addObject:@{ @"name": name, @"encoding": [NSString stringWithUTF8String:method_getTypeEncoding(method)] ?: @"" }];
        }
        NSMutableDictionary *diagnostic = [@{
            @"class": NSStringFromClass([object class]) ?: @"",
            @"ivars": ivars,
            @"methods": methods,
            @"instanceBytes": @[]
        } mutableCopy];
        [objects addObject:diagnostic];
        if ([NSStringFromClass([object class]) isEqualToString:@"ELMElement"]) {
            SEL selector = NSSelectorFromString(@"instance");
            Method method = class_getInstanceMethod([object class], selector);
            void *instance = method ? ((void *(*)(id, SEL))method_getImplementation(method))(object, selector) : NULL;
            if (instance) {
                uint8_t bytes[4096] = {0};
                vm_size_t size = sizeof(bytes);
                if (vm_read_overwrite(mach_task_self(), (vm_address_t)instance, sizeof(bytes),
                                      (vm_address_t)bytes, &size) == KERN_SUCCESS) {
                    diagnostic[@"instanceBytes"] = [[NSData dataWithBytes:bytes length:(NSUInteger)size] base64EncodedStringWithOptions:0] ?: @"";
                    NSMutableArray *addresses = [NSMutableArray arrayWithObject:[NSValue valueWithPointer:instance]];
                    NSMutableSet *visitedAddresses = [NSMutableSet set];
                    NSMutableArray *videoIds = [NSMutableArray array];
                    for (NSUInteger addressIndex = 0; addressIndex < addresses.count && addressIndex < 192; addressIndex++) {
                        NSValue *addressValue = addresses[addressIndex];
                        void *address = addressValue.pointerValue;
                        if (!address || [visitedAddresses containsObject:addressValue])
                            continue;
                        [visitedAddresses addObject:addressValue];
                        uint8_t page[4096] = {0};
                        vm_size_t pageSize = sizeof(page);
                        if (vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(page),
                                              (vm_address_t)page, &pageSize) != KERN_SUCCESS)
                            continue;
                        for (NSUInteger byteIndex = 0; byteIndex + 11 <= pageSize; byteIndex++) {
                            NSUInteger end = byteIndex;
                            while (end < pageSize && ((page[end] >= 'a' && page[end] <= 'z') ||
                                                      (page[end] >= 'A' && page[end] <= 'Z') ||
                                                      (page[end] >= '0' && page[end] <= '9') ||
                                                      page[end] == '_' || page[end] == '-'))
                                end++;
                            if (end - byteIndex == 11) {
                                NSString *candidate = [[NSString alloc] initWithBytes:page + byteIndex length:11 encoding:NSUTF8StringEncoding];
                                if (candidate.length == 11 && ![videoIds containsObject:candidate])
                                    [videoIds addObject:candidate];
                            }
                            byteIndex = end > byteIndex ? end - 1 : byteIndex;
                        }
                        for (NSUInteger byteIndex = 0; byteIndex + sizeof(uintptr_t) <= pageSize; byteIndex += sizeof(uintptr_t)) {
                            uintptr_t pointer = 0;
                            memcpy(&pointer, page + byteIndex, sizeof(pointer));
                            if (pointer > 0x100000000ULL && pointer < 0x2000000000ULL)
                                [addresses addObject:[NSValue valueWithPointer:(void *)pointer]];
                        }
                    }
                    diagnostic[@"memoryVideoIds"] = videoIds;
                }
            }
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:objects forKey:@"GonerinoRuntimeDiagnostics4"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static void __attribute__((unused)) CollectSheetDiagnostics(UIView *view, NSMutableArray *entries, NSUInteger depth) {
    if (!view || depth > 30 || entries.count >= 4096)
        return;

    id node = ValueForObjectKey(view, @"asyncdisplaykit_node");
    NSString *nodeDescription = @"";
    @try {
        nodeDescription = [node debugDescription] ?: @"";
    } @catch (__unused NSException *exception) {
    }
    if (nodeDescription.length > 1500)
        nodeDescription = [nodeDescription substringToIndex:1500];

    NSMutableArray *subnodeClasses = [NSMutableArray array];
    for (id subnode in ValueForObjectKey(node, @"subnodes")) {
        if (subnodeClasses.count >= 16)
            break;
        [subnodeClasses addObject:NSStringFromClass([subnode class]) ?: @""];
    }

    [entries addObject:@{
        @"viewClass": NSStringFromClass([view class]) ?: @"",
        @"nodeClass": NSStringFromClass([node class]) ?: @"",
        @"nodeDescription": nodeDescription,
        @"subnodeClasses": subnodeClasses,
        @"elementClass": NSStringFromClass([ValueForObjectKey(node, @"element") class]) ?: @"",
        @"contextClass": NSStringFromClass([ValueForObjectKey(node, @"context") class]) ?: @"",
        @"controllerClass": NSStringFromClass([ValueForObjectKey(node, @"controller") class]) ?: @""
    }];

    for (UIView *subview in view.subviews)
        CollectSheetDiagnostics(subview, entries, depth + 1);
}
#endif

static UIView *ActionSheetSourceView(id sheet) {
    id source = ValueForObjectKey(sheet, @"sourceView");
    if (!source)
        source = ValueForObjectKey(sheet, @"_sourceView");
    if ([source isKindOfClass:[UIView class]])
        return source;
    if ([source isKindOfClass:[UIViewController class]])
        return ((UIViewController *)source).view;
    return nil;
}

static id ActionSheetNodeCandidate(id candidate) {
    if (!candidate)
        return nil;
    if ([candidate isKindOfClass:[UIView class]])
        return VideoNodeFromView(candidate, 0);
    if ([candidate isKindOfClass:[UIViewController class]]) {
        id node = VideoNodeFromView(((UIViewController *)candidate).view, 0);
        if (node)
            return node;
    }

    NSString *className = NSStringFromClass([candidate class]).lowercaseString;
    if (NodeLooksLikeActionVideo(candidate) ||
        [className containsString:@"shorts"] ||
        [className containsString:@"reel"] ||
        [className containsString:@"video"] ||
        [className containsString:@"player"])
        return candidate;
    return nil;
}

static id VideoNodeForSheet(id sheet) {
    UIView *sourceView = ActionSheetSourceView(sheet);
    NSUInteger depth = 0;
    while (sourceView && depth++ < 8) {
        id node = ActionSheetNodeCandidate(sourceView);
        if (node)
            return node;
        sourceView = sourceView.superview;
    }

    for (NSString *key in @[
        @"sourceNode", @"_sourceNode", @"videoNode", @"_videoNode", @"playerNode", @"_playerNode",
        @"node", @"_node", @"playerViewController", @"shortsPlayerViewController", @"currentVideo",
        @"videoController", @"watchController", @"parentResponder"
    ]) {
        id node = ActionSheetNodeCandidate(ValueForObjectKey(sheet, key));
        if (node)
            return node;
    }

    return nil;
}

static UIViewController *ViewControllerForObject(id object) {
    if ([object isKindOfClass:[UIViewController class]])
        return object;

    UIView *sourceView = [object isKindOfClass:[UIView class]] ? object : ValueForObjectKey(object, @"sourceView");
    if (sourceView) {
        UIResponder *responder = sourceView;
        while (responder) {
            if ([responder isKindOfClass:[UIViewController class]])
                return (UIViewController *)responder;
            responder = [responder nextResponder];
        }
    }

    return nil;
}

static void SendToast(id object, NSString *message) {
    UIView *view = [object isKindOfClass:[UIView class]] ? object : ValueForObjectKey(object, @"sourceView");
    if (![view isKindOfClass:[UIView class]])
        view = nil;
    [Util showToast:message fromView:view];
}

#if 0
static void __attribute__((unused)) ShowMetadataAlert(UIViewController *viewController, NSDictionary *info) {
    if (!viewController) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (!window.isKeyWindow)
                continue;
            viewController = window.rootViewController;
            while (viewController.presentedViewController)
                viewController = viewController.presentedViewController;
            break;
        }
    }
    if (!viewController)
        return;

    NSString *message = [NSString stringWithFormat:@"id=%@\ntitle=%@\nchannel=%@",
                         info[@"id"] ?: @"<missing>",
                         info[@"title"] ?: @"<missing>",
                         info[@"channel"] ?: @"<missing>"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Gonerino metadata"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [viewController presentViewController:alert animated:YES completion:nil];
}
#endif

static NSDictionary *MergedVideoInfo(NSDictionary *current, NSDictionary *fallback) {
    NSMutableDictionary *result = [fallback mutableCopy] ?: [NSMutableDictionary dictionary];
    [current enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        if ([value isKindOfClass:[NSString class]] && value.length > 0)
            result[key] = value;
    }];
    return [result copy];
}

static NSDictionary *ActionVideoInfo(id presentationNode, id presentationSourceNode, UIView *sourceView) {
    @try {
        NSDictionary *info = MergedVideoInfo([Util freshVideoInfoFromNode:presentationNode], nil);
        if (presentationSourceNode && presentationSourceNode != presentationNode)
            info = MergedVideoInfo([Util freshVideoInfoFromNode:presentationSourceNode], info);

        id fallbackNode = VideoNodeFromView(sourceView, 0);
        if (fallbackNode && fallbackNode != presentationNode && fallbackNode != presentationSourceNode)
            info = MergedVideoInfo([Util freshVideoInfoFromNode:fallbackNode], info);
        return info;
    } @catch (__unused NSException *exception) {
        return @{};
    }
}

static void RefreshCollectionViewForSourceView(UIView *sourceView);

static void ResolveActionVideoInfo(id presentationNode,
                                   id presentationSourceNode,
                                   UIView *sourceView,
                                   BOOL requiresChannel,
                                   NSUInteger attempt,
                                   void (^completion)(NSDictionary *info)) {
    if (!completion)
        return;

    NSDictionary *info = ActionVideoInfo(presentationNode, presentationSourceNode, sourceView);
    BOOL resolved = requiresChannel ? [info[@"channel"] length] > 0 : [info[@"id"] length] > 0;
    if (resolved || attempt >= 2) {
        completion(info);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ResolveActionVideoInfo(presentationNode,
                               presentationSourceNode,
                               sourceView,
                               requiresChannel,
                               attempt + 1,
                               completion);
    });
}

static void AddBlockingActions(id sheet, YTActionSheetAction *originalAction) {
    static void *injectionKey = &injectionKey;
    static void *injectionInProgressKey = &injectionInProgressKey;
    if (!sheet || !originalAction || objc_getAssociatedObject(sheet, injectionInProgressKey) ||
        objc_getAssociatedObject(sheet, injectionKey))
        return;

    @try {
        UIView *sourceView = ActionSheetSourceView(sheet);
        id sourceNode = ValueForObjectKey(sourceView, @"asyncdisplaykit_node");
        id node = VideoNodeForSheet(sheet);
        if (!node)
            return;

        objc_setAssociatedObject(sheet, injectionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, injectionInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        __weak id weakSheet = sheet;
        id presentationNode = node;
        id presentationSourceNode = sourceNode;
        CGSize iconSize = CGSizeMake(24.0, 24.0);

        YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
            actionWithTitle:@"Block channel"
                  iconImage:[Util createBlockChannelIconWithSize:iconSize]
             secondaryIconImage:nil
         accessibilityIdentifier:nil
                  handler:^{
                      ResolveActionVideoInfo(presentationNode,
                                             presentationSourceNode,
                                             sourceView,
                                             YES,
                                             0,
                                             ^(NSDictionary *info) {
                                                 @try {
                                                     NSString *channel = info[@"channel"];
                                                     if (channel.length == 0) {
                                                         SendToast(weakSheet, @"Could not read the channel for this video");
                                                         return;
                                                     }

                                                     [[ChannelManager sharedInstance] addBlockedChannel:channel];
                                                     SendToast(weakSheet, [NSString stringWithFormat:@"Blocked %@", channel]);
                                                     RefreshCollectionViewForSourceView(sourceView);
                                                 } @catch (__unused NSException *exception) {
                                                     SendToast(weakSheet, @"Could not block this channel");
                                                 }
                                             });
                  }];

        YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
            actionWithTitle:@"Block video"
                  iconImage:[Util createBlockVideoIconWithSize:iconSize]
             secondaryIconImage:nil
         accessibilityIdentifier:nil
                  handler:^{
                      ResolveActionVideoInfo(presentationNode,
                                             presentationSourceNode,
                                             sourceView,
                                             NO,
                                             0,
                                             ^(NSDictionary *info) {
                                                 @try {
                                                     NSString *videoId = info[@"id"];
                                                     if (videoId.length == 0) {
                                                         SendToast(weakSheet, @"Could not read the video for this item");
                                                         return;
                                                     }

                                                     [[VideoManager sharedInstance] addBlockedVideo:videoId
                                                                                               title:info[@"title"]
                                                                                             channel:info[@"channel"]];
                                                     SendToast(weakSheet,
                                                               [NSString stringWithFormat:@"Blocked video: %@",
                                                                                          info[@"title"] ?: videoId]);
                                                     if ([weakSheet respondsToSelector:@selector(dismiss)])
                                                         [weakSheet dismiss];
                                                     RefreshCollectionViewForSourceView(sourceView);
                                                 } @catch (__unused NSException *exception) {
                                                     SendToast(weakSheet, @"Could not block this video");
                                                 }
                                             });
                  }];

        if (!blockChannelAction || !blockVideoAction) {
            objc_setAssociatedObject(sheet, injectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        [sheet addAction:blockChannelAction];
        [sheet addAction:blockVideoAction];
        objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        objc_setAssociatedObject(sheet, injectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#if 0
static void __attribute__((unused)) WriteDebugMetadata(NSString *stage, id node, NSDictionary *info) {
    NSString *description = @"";
    NSMutableArray *subviewDescriptions = [NSMutableArray array];
    NSMutableArray *subnodeDescriptions = [NSMutableArray array];
    NSMutableArray *playbackDiagnostics = [NSMutableArray array];
    NSMutableArray *objectDiagnostics = [NSMutableArray array];
    @try {
        description = [node debugDescription] ?: [node description] ?: @"";
        id rootElement = ValueForObjectKey(node, @"element");
        for (NSString *key in @[@"videoId", @"video_id", @"videoIdentifier", @"contentVideoId", @"contentId", @"id", @"url", @"navigationEndpoint", @"watchEndpoint", @"endpoint", @"command", @"title", @"channelName", @"ownerName"]) {
            id value = ValueForArgumentKeyName(rootElement, key);
            if (!value)
                continue;
            NSString *valueDescription = @"";
            @try {
                valueDescription = [value debugDescription] ?: [value description] ?: @"";
            } @catch (__unused NSException *exception) {
            }
            if (valueDescription.length > 5000)
                valueDescription = [valueDescription substringToIndex:5000];
            [objectDiagnostics addObject:@{
                @"objectClass": NSStringFromClass([rootElement class]) ?: @"",
                @"argumentKey": key,
                @"class": NSStringFromClass([value class]) ?: @"",
                @"description": valueDescription
            }];
        }
        id playbackView = ValueForObjectKey(node, @"playbackView");
        id nodeView = ValueForObjectKey(node, @"view");
        NSMutableArray *playbackCandidates = [NSMutableArray array];
        if (playbackView)
            [playbackCandidates addObject:playbackView];
        if (nodeView)
            [playbackCandidates addObjectsFromArray:[nodeView subviews]];
        for (id candidate in playbackCandidates) {
            id playableEntry = ValueForObjectKey(candidate, @"asdPlayableEntry");
            id navigationEndpoint = ValueForObjectKey(playableEntry, @"navigationEndpoint");
            [playbackDiagnostics addObject:@{
                @"class": NSStringFromClass([candidate class]) ?: @"",
                @"hasEntry": @(playableEntry != nil),
                @"entryClass": NSStringFromClass([playableEntry class]) ?: @"",
                @"entryDescription": DebugString(ValueForObjectKey(playableEntry, @"description")),
                @"endpointClass": NSStringFromClass([navigationEndpoint class]) ?: @"",
                @"endpointDescription": DebugString(ValueForObjectKey(navigationEndpoint, @"description"))
            }];
        }
        UIView *view = ValueForObjectKey(node, @"view");
        for (UIView *subview in view.subviews) {
            NSString *subviewDescription = [NSString stringWithFormat:@"%@ %@",
                                            NSStringFromClass([subview class]),
                                            [subview debugDescription] ?: @""];
            [subviewDescriptions addObject:subviewDescription];
        }
        NSArray *subnodes = ValueForObjectKey(node, @"subnodes");
        for (id subnode in subnodes) {
            NSString *subnodeDescription = [NSString stringWithFormat:@"%@ %@",
                                            NSStringFromClass([subnode class]),
                                            [subnode debugDescription] ?: @""];
            [subnodeDescriptions addObject:subnodeDescription];
        }
        NSMutableArray *objects = [NSMutableArray arrayWithObject:node];
        NSMutableSet *visitedObjects = [NSMutableSet set];
        while (objects.count > 0 && objectDiagnostics.count < 1000) {
            id object = objects.lastObject;
            [objects removeLastObject];
            NSValue *identity = [NSValue valueWithNonretainedObject:object];
            if (!object || [visitedObjects containsObject:identity])
                continue;
            [visitedObjects addObject:identity];
            for (NSString *key in @[@"element", @"context", @"controller", @"viewController", @"navigationEndpoint", @"videoDetails", @"playerResponse", @"subnodes", @"allProperties", @"properties", @"description", @"text", @"attributedText", @"protoText", @"childElements", @"instance", @"cxxSharedElement", @"currentVideo", @"videoController", @"watchController", @"playbackController", @"videoData", @"response", @"renderer", @"content", @"data", @"model", @"media"]) {
                id value = ValueForObjectKey(object, key);
                if (!value)
                    continue;
                NSString *valueDescription = @"";
                @try {
                    valueDescription = [value debugDescription] ?: [value description] ?: @"";
                } @catch (__unused NSException *exception) {
                }
                if (valueDescription.length > 5000)
                    valueDescription = [valueDescription substringToIndex:5000];
                [objectDiagnostics addObject:@{
                    @"objectClass": NSStringFromClass([object class]) ?: @"",
                    @"key": key,
                    @"class": NSStringFromClass([value class]) ?: @"",
                    @"description": valueDescription
                }];
                if ([key isEqualToString:@"attributedText"]) {
                    if ([value isKindOfClass:[NSAttributedString class]]) {
                        NSRange attributeRange = NSMakeRange(0, 0);
                        NSDictionary *attributes = [value attributesAtIndex:0 effectiveRange:&attributeRange];
                        for (id attributeKey in attributes) {
                            id attributeValue = attributes[attributeKey];
                            NSString *attributeDescription = @"";
                            @try {
                                attributeDescription = [attributeValue debugDescription] ?: [attributeValue description] ?: @"";
                            } @catch (__unused NSException *exception) {
                            }
                            if ([attributeValue isKindOfClass:[NSData class]])
                                attributeDescription = [attributeValue base64EncodedStringWithOptions:0] ?: @"";
                            if (attributeDescription.length > 12000)
                                attributeDescription = [attributeDescription substringToIndex:12000];
                            [objectDiagnostics addObject:@{
                                @"objectClass": NSStringFromClass([object class]) ?: @"",
                                @"key": @"attributedStringAttribute",
                                @"attributeKey": [attributeKey description] ?: @"",
                                @"class": NSStringFromClass([attributeValue class]) ?: @"",
                                @"description": attributeDescription
                            }];
                        }
                    }
                }
                if ([key isEqualToString:@"subnodes"] && [value isKindOfClass:[NSArray class]])
                    [objects addObjectsFromArray:value];
                if (([key isEqualToString:@"element"] || [key isEqualToString:@"context"] ||
                     [key isEqualToString:@"controller"] || [key isEqualToString:@"viewController"] ||
                     [key isEqualToString:@"instance"] || [key isEqualToString:@"cxxSharedElement"] ||
                     [key isEqualToString:@"childElements"]) && value != object)
                    [objects addObject:value];
            }
            NSString *objectClassName = NSStringFromClass([object class]).lowercaseString;
            if ([objectClassName containsString:@"contextimpl"] || [objectClassName containsString:@"nodecontroller"]) {
                NSMutableArray *methodNames = [NSMutableArray array];
                Class currentClass = [object class];
                while (currentClass && methodNames.count < 120) {
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList(currentClass, &methodCount);
                    for (unsigned int methodIndex = 0; methodIndex < methodCount && methodNames.count < 120; methodIndex++)
                        [methodNames addObject:NSStringFromSelector(method_getName(methods[methodIndex])) ?: @""];
                    free(methods);
                    currentClass = class_getSuperclass(currentClass);
                }
                [objectDiagnostics addObject:@{
                    @"objectClass": NSStringFromClass([object class]) ?: @"",
                    @"methods": methodNames
                }];
                for (NSString *key in @[@"videoId", @"video_id", @"videoIdentifier", @"contentVideoId", @"contentId", @"id", @"url", @"navigationEndpoint", @"watchEndpoint", @"endpoint", @"command", @"title", @"channelName", @"ownerName"]) {
                    id value = ValueForArgumentKeyName(object, key);
                    if (!value)
                        continue;
                    NSString *valueDescription = @"";
                    @try {
                        valueDescription = [value debugDescription] ?: [value description] ?: @"";
                    } @catch (__unused NSException *exception) {
                    }
                    if (valueDescription.length > 5000)
                        valueDescription = [valueDescription substringToIndex:5000];
                    [objectDiagnostics addObject:@{
                        @"objectClass": NSStringFromClass([object class]) ?: @"",
                        @"argumentKey": key,
                        @"class": NSStringFromClass([value class]) ?: @"",
                        @"description": valueDescription
                    }];
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
    if (description.length > 12000)
        description = [description substringToIndex:12000];
    [[NSUserDefaults standardUserDefaults] setObject:@{
        @"stage": stage ?: @"",
        @"nodeClass": NSStringFromClass([node class]) ?: @"",
        @"nodeDescription": description,
        @"playbackDiagnostics": playbackDiagnostics,
        @"objectDiagnostics": objectDiagnostics,
        @"subviewDescriptions": subviewDescriptions,
        @"subnodeDescriptions": subnodeDescriptions,
        @"id": info[@"id"] ?: @"",
        @"title": info[@"title"] ?: @"",
        @"channel": info[@"channel"] ?: @""
    } forKey:@"GonerinoDebugMetadata"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
#endif

static void RefreshVisibleFeeds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (!keyWindow)
            keyWindow = [UIApplication sharedApplication].windows.firstObject;

        NSMutableArray *pendingViews = [NSMutableArray arrayWithObject:keyWindow ?: [NSNull null]];
        while (pendingViews.count > 0) {
            id object = pendingViews.lastObject;
            [pendingViews removeLastObject];
            if (![object isKindOfClass:[UIView class]])
                continue;

            UIView *view = object;
            if ([view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")])
                [view setNeedsLayout];
            [pendingViews addObjectsFromArray:view.subviews];
        }
    });
}

static void RefreshCollectionViewForSourceView(UIView *sourceView) {
    if (![sourceView isKindOfClass:[UIView class]])
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = sourceView;
        while (view && ![view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")])
            view = view.superview;
        if ([view isKindOfClass:NSClassFromString(@"YTAsyncCollectionView")])
            [view setNeedsLayout];
    });
}

static BOOL CollectionViewIsScrolling(YTAsyncCollectionView *collectionView) {
    return collectionView.isDragging || collectionView.isDecelerating || collectionView.isTracking;
}

static void *BlockedCellKey = &BlockedCellKey;
static void *CollapsedLayoutKey = &CollapsedLayoutKey;

static void CollapseBlockedCellGaps(YTAsyncCollectionView *collectionView) {
    if (objc_getAssociatedObject(collectionView, CollapsedLayoutKey))
        return;

    UICollectionViewLayout *layout = collectionView.collectionViewLayout;
    if ([layout isKindOfClass:[UICollectionViewFlowLayout class]] &&
        [(UICollectionViewFlowLayout *)layout scrollDirection] != UICollectionViewScrollDirectionVertical)
        return;

    NSMutableArray<UICollectionViewCell *> *cells = [NSMutableArray array];
    NSMutableArray<NSValue *> *blockedFrames = [NSMutableArray array];
    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        if (![cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")])
            continue;
        [cells addObject:cell];
        if (objc_getAssociatedObject(cell, BlockedCellKey))
            [blockedFrames addObject:[NSValue valueWithCGRect:cell.frame]];
    }
    if (blockedFrames.count == 0)
        return;

    for (UICollectionViewCell *cell in cells) {
        if (objc_getAssociatedObject(cell, BlockedCellKey))
            continue;

        CGRect frame = cell.frame;
        CGFloat offset = 0.0;
        for (NSValue *value in blockedFrames) {
            CGRect blockedFrame = value.CGRectValue;
            BOOL below = CGRectGetMinY(frame) >= CGRectGetMaxY(blockedFrame) - 1.0;
            BOOL overlapsHorizontally = CGRectGetMinX(frame) < CGRectGetMaxX(blockedFrame) &&
                                         CGRectGetMaxX(frame) > CGRectGetMinX(blockedFrame);
            if (below && overlapsHorizontally)
                offset += CGRectGetHeight(blockedFrame);
        }
        if (offset > 0.0) {
            frame.origin.y -= offset;
            cell.frame = frame;
        }
    }
    objc_setAssociatedObject(collectionView, CollapsedLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void FilterVisibleCells(YTAsyncCollectionView *collectionView) {
    if (!collectionView || CollectionViewIsScrolling(collectionView))
        return;

    if (collectionView.filtering)
        return;

    collectionView.filtering = YES;
    collectionView.lastFilterTime = CFAbsoluteTimeGetCurrent();
    @try {
        for (UICollectionViewCell *cell in collectionView.visibleCells) {
            if (![cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")])
                continue;

            objc_setAssociatedObject(cell, BlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.hidden = NO;
            cell.alpha = 1.0;
            cell.userInteractionEnabled = YES;
            cell.accessibilityElementsHidden = NO;
            _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
            id node = [asCell respondsToSelector:@selector(node)] ? [asCell node] : nil;
            if (!NodeLooksLikeActionVideo(node))
                continue;

            BOOL blocked = [Util nodeContainsBlockedVideo:node];
            objc_setAssociatedObject(cell, BlockedCellKey, blocked ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.hidden = blocked;
            cell.alpha = blocked ? 0.0 : 1.0;
            cell.userInteractionEnabled = !blocked;
            cell.accessibilityElementsHidden = blocked;
        }
        CollapseBlockedCellGaps(collectionView);
    } @catch (__unused NSException *exception) {
    }
    collectionView.filtering = NO;
}

%hook YTAsyncCollectionView

%property(nonatomic, assign) BOOL filtering;
%property(nonatomic, assign) BOOL filterScheduled;
%property(nonatomic, assign) NSTimeInterval lastFilterTime;

%new
- (void)scheduleFiltering {
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] != nil &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"])
        return;
    if (self.filterScheduled || CollectionViewIsScrolling(self))
        return;
    if (CFAbsoluteTimeGetCurrent() - self.lastFilterTime < 0.35)
        return;

    self.filterScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf.filterScheduled = NO;
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] != nil &&
            ![[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"])
            return;
        FilterVisibleCells(strongSelf);
    });
}

- (void)layoutSubviews {
    objc_setAssociatedObject(self, CollapsedLayoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    [self scheduleFiltering];
}

- (void)reloadData {
    objc_setAssociatedObject(self, CollapsedLayoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    [self scheduleFiltering];
}

- (void)didMoveToWindow {
    %orig;
    if (self.window)
        [self scheduleFiltering];
}

%end

%hook YTDefaultSheetController

- (void)addAction:(YTActionSheetAction *)action {
    %orig;
    AddBlockingActions(self, action);

}

%end

%hook YTActionSheetController

- (void)addAction:(YTActionSheetAction *)action {
    %orig;
    AddBlockingActions(self, action);
}

%end

%hook YTRightNavigationButtons
%property(retain, nonatomic) YTQTMButton *actionButton;

- (NSMutableArray *)buttons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    BOOL showButton = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                          ? YES
                          : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];

    [result removeObject:self.actionButton];
    [self.actionButton removeFromSuperview];
    if (!showButton)
        return result;

    if (!self.actionButton) {
        self.actionButton = [%c(YTQTMButton) iconButton];
        if ([self.actionButton respondsToSelector:@selector(enableNewTouchFeedback)])
            [self.actionButton enableNewTouchFeedback];
        self.actionButton.frame = CGRectMake(0, 0, 40, 40);
        [self.actionButton addTarget:self action:@selector(actionButtonPressed:)
                      forControlEvents:UIControlEventTouchUpInside];
    }

    NSInteger pageStyle = 0;
    Class pageStyleClass = %c(YTPageStyleController);
    if ([pageStyleClass respondsToSelector:@selector(pageStyle)])
        pageStyle = [pageStyleClass pageStyle];
    else {
        YTAppDelegate *delegate = (YTAppDelegate *)[UIApplication sharedApplication].delegate;
        YTAppViewControllerImpl *appViewController = ValueForObjectKey(delegate, @"_appViewController");
        if ([appViewController respondsToSelector:@selector(pageStyle)])
            pageStyle = [appViewController pageStyle];
    }

    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                         ? YES
                         : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"];
    UIColor *tintColor = pageStyle ? UIColor.whiteColor : UIColor.blackColor;
    if (!isEnabled)
        tintColor = [tintColor colorWithAlphaComponent:0.4];
    UIImage *image = [Util createBlockVideoIconWithSize:CGSizeMake(20, 20)];
    image = [%c(QTMIcon) tintImage:image color:tintColor];
    [self.actionButton setImage:image forState:UIControlStateNormal];
    [self addSubview:self.actionButton];
    [result insertObject:self.actionButton atIndex:0];
    return result;
}

- (NSMutableArray *)visibleButtons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    BOOL showButton = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                          ? YES
                          : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];
    [result removeObject:self.actionButton];
    if (showButton && self.actionButton)
        [result insertObject:self.actionButton atIndex:0];
    return result;
}

%new
- (void)actionButtonPressed:(UIButton *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isEnabled = [defaults objectForKey:@"GonerinoEnabled"] == nil ? YES : [defaults boolForKey:@"GonerinoEnabled"];
    BOOL newState = !isEnabled;
    [defaults setBool:newState forKey:@"GonerinoEnabled"];
    [defaults synchronize];

    [self buttons];
    RefreshVisibleFeeds();
    UIViewController *viewController = ViewControllerForObject(self);
    SendToast(viewController, [NSString stringWithFormat:@"Gonerino %@", newState ? @"enabled" : @"disabled"]);
}

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[@"GonerinoDebugMetadata", @"GonerinoSheetDiagnostics", @"GonerinoRuntimeDiagnostics", @"GonerinoRuntimeDiagnostics2", @"GonerinoRuntimeDiagnostics3", @"GonerinoRuntimeDiagnostics4", @"GonerinoActionDiagnostics"])
        [defaults removeObjectForKey:key];
    [defaults synchronize];
    %init;
}
