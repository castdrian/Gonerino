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
        [normalizedClassName containsString:@"scrollablepage"])
        return NO;
    id controller = ValueForObjectKey(node, @"controller");
    NSString *controllerClassName = NSStringFromClass([controller class]).lowercaseString;
    if ([controllerClassName containsString:@"shortsplayerviewcontroller"])
        return YES;
    NSString *nodeDescription = [node debugDescription];
    if ([nodeDescription containsString:@"YTShortsPlayerViewController"])
        return YES;
    if ([nodeClassName rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        [nodeClassName rangeOfString:@"node" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;

    return NO;
}

static id VideoNodeFromView(UIView *view, NSUInteger depth) {
    if (!view || depth > 60)
        return nil;

    id node = ValueForObjectKey(view, @"asyncdisplaykit_node");
    if (NodeLooksLikeVideo(node))
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

static id VideoNodeForSheet(id sheet) {
    UIView *sourceView = ValueForObjectKey(sheet, @"sourceView");
    if (!sourceView)
        sourceView = ValueForObjectKey(sheet, @"_sourceView");

    while (sourceView) {
        id node = VideoNodeFromView(sourceView, 0);
        if (node)
            return node;
        sourceView = sourceView.superview;
    }

    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        id node = VideoNodeFromView(window, 0);
        if (node)
            return node;
    }

    return nil;
}

static UIViewController *ViewControllerForObject(id object) {
    if ([object isKindOfClass:[UIViewController class]])
        return object;

    if ([object isKindOfClass:[UIView class]]) {
        UIResponder *responder = object;
        while (responder) {
            if ([responder isKindOfClass:[UIViewController class]])
                return (UIViewController *)responder;
            responder = [responder nextResponder];
        }
    }

    return nil;
}

static void SendToast(UIViewController *viewController, NSString *message) {
    if (!viewController || message.length == 0)
        return;

    Class toastClass = NSClassFromString(@"YTToastResponderEvent");
    if ([toastClass respondsToSelector:@selector(eventWithMessage:firstResponder:)])
        [[toastClass eventWithMessage:message firstResponder:viewController] send];
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
            [(UICollectionView *)view reloadData];
        [pendingViews addObjectsFromArray:view.subviews];
    }
}

static void CollectSubviewsOfClass(UIView *view, Class viewClass, NSMutableArray *result) {
    if (!view)
        return;
    if ([view isKindOfClass:viewClass])
        [result addObject:view];
    for (UIView *subview in view.subviews)
        CollectSubviewsOfClass(subview, viewClass, result);
}

static NSString *ActionTitleForView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = [(UILabel *)view text];
        if (text.length > 0)
            return text;
    }
    return view.accessibilityLabel;
}

static NSArray *ApplicationWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        [windows addObjectsFromArray:[(UIWindowScene *)scene windows]];
    }
    if (windows.count == 0)
        [windows addObjectsFromArray:[UIApplication sharedApplication].windows];
    return windows;
}

static void NormalizeActionLayout(UIView *view) {
    NSMutableArray *views = [NSMutableArray array];
    CollectSubviewsOfClass(view, [UIView class], views);
    BOOL isLongForm = NO;
    for (UIView *candidate in views) {
        if ([ActionTitleForView(candidate) isEqualToString:@"Thanks"]) {
            isLongForm = YES;
            break;
        }
    }

    for (UIView *row in views) {
        NSString *identifier = row.accessibilityIdentifier;
        BOOL injectedAction = [identifier isEqualToString:@"BlockChannel"] || [identifier isEqualToString:@"BlockVideo"];
        if (!injectedAction)
            continue;
        row.clipsToBounds = NO;
        for (UIView *subview in row.subviews) {
            if ([subview isKindOfClass:[UIImageView class]]) {
                subview.clipsToBounds = NO;
                subview.transform = CGAffineTransformMake(1.2, 0, 0, 1.2, isLongForm ? 29.5 : 8.0, 0);
            } else if ([NSStringFromClass([subview class]) isEqualToString:@"UIButtonLabel"]) {
                CGRect frame = subview.frame;
                frame.origin.x = isLongForm ? 52.0 : 64.0;
                subview.frame = frame;
            }
        }
    }
}

static BOOL CollectionViewIsScrolling(YTAsyncCollectionView *collectionView) {
    return collectionView.isDragging || collectionView.isDecelerating || collectionView.isTracking;
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

            _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
            id node = [asCell respondsToSelector:@selector(node)] ? [asCell node] : nil;
            if (!NodeLooksLikeVideo(node))
                continue;

            BOOL blocked = [Util nodeContainsBlockedVideo:node];
            cell.hidden = blocked;
            cell.alpha = blocked ? 0.0 : 1.0;
            cell.userInteractionEnabled = !blocked;
            cell.accessibilityElementsHidden = blocked;
        }
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
    %orig;
    [self scheduleFiltering];
}

- (void)reloadData {
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
    static void *injectionKey = &injectionKey;
    static void *injectionInProgressKey = &injectionInProgressKey;
    BOOL injectionInProgress = objc_getAssociatedObject(self, injectionInProgressKey) != nil;

    %orig;

    if (injectionInProgress || objc_getAssociatedObject(self, injectionKey))
        return;

    id node = VideoNodeForSheet(self);
    if (!node)
        return;
    NSDictionary *metadataAtPresentation = [Util videoInfoFromNode:node] ?: @{};
    objc_setAssociatedObject(self, injectionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, injectionInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak typeof(self) weakSelf = self;
    CGSize iconSize = CGSizeMake(24, 24);
    UIImage *channelIcon = [Util createBlockChannelIconWithSize:iconSize];
    UIImage *videoIcon = [Util createBlockVideoIconWithSize:iconSize];

    YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block channel"
              iconImage:channelIcon
     secondaryIconImage:nil
 accessibilityIdentifier:@"BlockChannel"
                handler:^ {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    id selectedNode = VideoNodeForSheet(strongSelf);
                    NSDictionary *info = MergedVideoInfo([Util videoInfoFromNode:selectedNode], metadataAtPresentation);
                    NSString *channel = info[@"channel"];
                    UIViewController *viewController = ViewControllerForObject(strongSelf);
                    if (channel.length == 0) {
                        SendToast(viewController, @"Could not read the channel for this video");
                        return;
                    }

                    [[ChannelManager sharedInstance] addBlockedChannel:channel];
                    SendToast(viewController, [NSString stringWithFormat:@"Blocked %@", channel]);
                    if ([strongSelf respondsToSelector:@selector(dismiss)])
                        [strongSelf dismiss];
                    RefreshVisibleFeeds();
                }];

    YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block video"
              iconImage:videoIcon
     secondaryIconImage:nil
 accessibilityIdentifier:@"BlockVideo"
                handler:^ {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    id selectedNode = VideoNodeForSheet(strongSelf);
                    NSDictionary *info = MergedVideoInfo([Util videoInfoFromNode:selectedNode], metadataAtPresentation);
                    NSString *videoId = info[@"id"];
                    UIViewController *viewController = ViewControllerForObject(strongSelf);
                    if (videoId.length == 0) {
                        SendToast(viewController, @"Could not read the video for this item");
                        return;
                    }

                    [[VideoManager sharedInstance] addBlockedVideo:videoId
                                                             title:info[@"title"]
                                                           channel:info[@"channel"]];
                    SendToast(viewController,
                                      [NSString stringWithFormat:@"Blocked video: %@", info[@"title"] ?: videoId]);
                    if ([strongSelf respondsToSelector:@selector(dismiss)])
                        [strongSelf dismiss];
                    RefreshVisibleFeeds();
                }];

    blockChannelAction.shouldDismissOnAction = YES;
    blockVideoAction.shouldDismissOnAction = YES;

    objc_setAssociatedObject(self, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addAction:blockChannelAction];
    [self addAction:blockVideoAction];

    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in ApplicationWindows())
            NormalizeActionLayout(window);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIWindow *window in ApplicationWindows())
                NormalizeActionLayout(window);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIWindow *window in ApplicationWindows())
                NormalizeActionLayout(window);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIWindow *window in ApplicationWindows())
                NormalizeActionLayout(window);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIWindow *window in ApplicationWindows())
                NormalizeActionLayout(window);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIWindow *window in ApplicationWindows())
                NormalizeActionLayout(window);
        });
    });
}

%new
- (UIViewController *)findViewControllerForView:(UIView *)view {
    return ViewControllerForObject(view);
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
    for (NSString *key in @[@"GonerinoDebugMetadata", @"GonerinoSheetDiagnostics", @"GonerinoRuntimeDiagnostics", @"GonerinoRuntimeDiagnostics2", @"GonerinoRuntimeDiagnostics3", @"GonerinoRuntimeDiagnostics4"])
        [defaults removeObjectForKey:key];
    [defaults synchronize];
    %init;
}
