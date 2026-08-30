#import "Tweak.h"
#import <objc/runtime.h>

#if 0
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

static id GonerinoValueForArgumentKeyName(id object, NSString *key) {
    for (NSString *selectorName in @[@"propertyForKey:", @"elementForKey:", @"safeSwiftValueForKey:", @"safeSwiftStringForKey:", @"tps_safeValueForKey:", @"valueForKey:"]) {
        id value = GonerinoValueForArgumentKey(object, NSSelectorFromString(selectorName), key);
        if (value)
            return value;
    }
    return nil;
}
#endif

static id GonerinoValueForObjectKey(id object, NSString *key) {
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

static NSString * __attribute__((unused)) GonerinoDebugString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static BOOL GonerinoNodeLooksLikeVideo(id node) {
    if (!node)
        return NO;

    NSString *nodeClassName = NSStringFromClass([node class]);
    NSString *normalizedClassName = nodeClassName.lowercaseString;
    if ([normalizedClassName containsString:@"collection"] ||
        [normalizedClassName containsString:@"reorderable"] ||
        [normalizedClassName containsString:@"scrollablepage"])
        return NO;
    id controller = GonerinoValueForObjectKey(node, @"controller");
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

static id GonerinoVideoNodeFromView(UIView *view, NSUInteger depth) {
    if (!view || depth > 60)
        return nil;

    id node = GonerinoValueForObjectKey(view, @"asyncdisplaykit_node");
    if (GonerinoNodeLooksLikeVideo(node))
        return node;

    for (UIView *subview in view.subviews) {
        node = GonerinoVideoNodeFromView(subview, depth + 1);
        if (node)
            return node;
    }

    return nil;
}

#if 0
static id GonerinoObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0)
        return nil;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static void GonerinoWriteRuntimeDiagnostics(id node) {
    if (!node || [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoRuntimeDiagnostics4"])
        return;

    NSMutableArray *objects = [NSMutableArray array];
    id element = GonerinoValueForObjectKey(node, @"element");
    id controller = GonerinoValueForObjectKey(node, @"controller");
    id context = GonerinoValueForObjectKey(node, @"context");
    NSArray *candidateObjects = @[node ?: [NSNull null], element ?: [NSNull null], controller ?: [NSNull null],
                                  context ?: [NSNull null], GonerinoObjectIvar(node, @"_context") ?: [NSNull null],
                                  GonerinoObjectIvar(node, @"_nodeContext") ?: [NSNull null],
                                  GonerinoObjectIvar(controller, @"_context") ?: [NSNull null],
                                  GonerinoObjectIvar(controller, @"_treeLocalContext") ?: [NSNull null]];
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

static void __attribute__((unused)) GonerinoCollectSheetDiagnostics(UIView *view, NSMutableArray *entries, NSUInteger depth) {
    if (!view || depth > 30 || entries.count >= 4096)
        return;

    id node = GonerinoValueForObjectKey(view, @"asyncdisplaykit_node");
    NSString *nodeDescription = @"";
    @try {
        nodeDescription = [node debugDescription] ?: @"";
    } @catch (__unused NSException *exception) {
    }
    if (nodeDescription.length > 1500)
        nodeDescription = [nodeDescription substringToIndex:1500];

    NSMutableArray *subnodeClasses = [NSMutableArray array];
    for (id subnode in GonerinoValueForObjectKey(node, @"subnodes")) {
        if (subnodeClasses.count >= 16)
            break;
        [subnodeClasses addObject:NSStringFromClass([subnode class]) ?: @""];
    }

    [entries addObject:@{
        @"viewClass": NSStringFromClass([view class]) ?: @"",
        @"nodeClass": NSStringFromClass([node class]) ?: @"",
        @"nodeDescription": nodeDescription,
        @"subnodeClasses": subnodeClasses,
        @"elementClass": NSStringFromClass([GonerinoValueForObjectKey(node, @"element") class]) ?: @"",
        @"contextClass": NSStringFromClass([GonerinoValueForObjectKey(node, @"context") class]) ?: @"",
        @"controllerClass": NSStringFromClass([GonerinoValueForObjectKey(node, @"controller") class]) ?: @""
    }];

    for (UIView *subview in view.subviews)
        GonerinoCollectSheetDiagnostics(subview, entries, depth + 1);
}
#endif

static id GonerinoVideoNodeForSheet(id sheet) {
    UIView *sourceView = GonerinoValueForObjectKey(sheet, @"sourceView");
    if (!sourceView)
        sourceView = GonerinoValueForObjectKey(sheet, @"_sourceView");

    while (sourceView) {
        id node = GonerinoVideoNodeFromView(sourceView, 0);
        if (node)
            return node;
        sourceView = sourceView.superview;
    }

    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        id node = GonerinoVideoNodeFromView(window, 0);
        if (node)
            return node;
    }

    return nil;
}

static UIViewController *GonerinoViewControllerForObject(id object) {
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

static void GonerinoSendToast(UIViewController *viewController, NSString *message) {
    if (!viewController || message.length == 0)
        return;

    Class toastClass = NSClassFromString(@"YTToastResponderEvent");
    if ([toastClass respondsToSelector:@selector(eventWithMessage:firstResponder:)])
        [[toastClass eventWithMessage:message firstResponder:viewController] send];
}

#if 0
static void __attribute__((unused)) GonerinoShowMetadataAlert(UIViewController *viewController, NSDictionary *info) {
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

static NSDictionary *GonerinoMergedVideoInfo(NSDictionary *current, NSDictionary *fallback) {
    NSMutableDictionary *result = [fallback mutableCopy] ?: [NSMutableDictionary dictionary];
    [current enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        if ([value isKindOfClass:[NSString class]] && value.length > 0)
            result[key] = value;
    }];
    return [result copy];
}

#if 0
static void __attribute__((unused)) GonerinoWriteDebugMetadata(NSString *stage, id node, NSDictionary *info) {
    NSString *description = @"";
    NSMutableArray *subviewDescriptions = [NSMutableArray array];
    NSMutableArray *subnodeDescriptions = [NSMutableArray array];
    NSMutableArray *playbackDiagnostics = [NSMutableArray array];
    NSMutableArray *objectDiagnostics = [NSMutableArray array];
    @try {
        description = [node debugDescription] ?: [node description] ?: @"";
        id rootElement = GonerinoValueForObjectKey(node, @"element");
        for (NSString *key in @[@"videoId", @"video_id", @"videoIdentifier", @"contentVideoId", @"contentId", @"id", @"url", @"navigationEndpoint", @"watchEndpoint", @"endpoint", @"command", @"title", @"channelName", @"ownerName"]) {
            id value = GonerinoValueForArgumentKeyName(rootElement, key);
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
        id playbackView = GonerinoValueForObjectKey(node, @"playbackView");
        id nodeView = GonerinoValueForObjectKey(node, @"view");
        NSMutableArray *playbackCandidates = [NSMutableArray array];
        if (playbackView)
            [playbackCandidates addObject:playbackView];
        if (nodeView)
            [playbackCandidates addObjectsFromArray:[nodeView subviews]];
        for (id candidate in playbackCandidates) {
            id playableEntry = GonerinoValueForObjectKey(candidate, @"asdPlayableEntry");
            id navigationEndpoint = GonerinoValueForObjectKey(playableEntry, @"navigationEndpoint");
            [playbackDiagnostics addObject:@{
                @"class": NSStringFromClass([candidate class]) ?: @"",
                @"hasEntry": @(playableEntry != nil),
                @"entryClass": NSStringFromClass([playableEntry class]) ?: @"",
                @"entryDescription": GonerinoDebugString(GonerinoValueForObjectKey(playableEntry, @"description")),
                @"endpointClass": NSStringFromClass([navigationEndpoint class]) ?: @"",
                @"endpointDescription": GonerinoDebugString(GonerinoValueForObjectKey(navigationEndpoint, @"description"))
            }];
        }
        UIView *view = GonerinoValueForObjectKey(node, @"view");
        for (UIView *subview in view.subviews) {
            NSString *subviewDescription = [NSString stringWithFormat:@"%@ %@",
                                            NSStringFromClass([subview class]),
                                            [subview debugDescription] ?: @""];
            [subviewDescriptions addObject:subviewDescription];
        }
        NSArray *subnodes = GonerinoValueForObjectKey(node, @"subnodes");
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
                id value = GonerinoValueForObjectKey(object, key);
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
                    id value = GonerinoValueForArgumentKeyName(object, key);
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

static void GonerinoRefreshVisibleFeeds(void) {
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

static void GonerinoScaleActionIcons(UIView *view) {
    if (!view)
        return;

    static void *iconMarker = &iconMarker;
    static void *scaledMarker = &scaledMarker;
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage *image = [(UIImageView *)view image];
        if (image && objc_getAssociatedObject(image, iconMarker) && !objc_getAssociatedObject(view, scaledMarker)) {
            objc_setAssociatedObject(view, scaledMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.clipsToBounds = NO;
            view.superview.clipsToBounds = NO;
            view.transform = CGAffineTransformMakeScale(1.5, 1.5);
        }
    }

    for (UIView *subview in view.subviews)
        GonerinoScaleActionIcons(subview);
}

static void GonerinoMarkActionIcon(UIImage *image) {
    if (!image)
        return;

    static void *iconMarker = &iconMarker;
    objc_setAssociatedObject(image, iconMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL GonerinoCollectionViewIsScrolling(YTAsyncCollectionView *collectionView) {
    return collectionView.isDragging || collectionView.isDecelerating || collectionView.isTracking;
}

static void GonerinoFilterVisibleCells(YTAsyncCollectionView *collectionView) {
    if (!collectionView || GonerinoCollectionViewIsScrolling(collectionView))
        return;

    if (collectionView.gonerinoFiltering)
        return;

    collectionView.gonerinoFiltering = YES;
    collectionView.gonerinoLastFilterTime = CFAbsoluteTimeGetCurrent();
    @try {
        for (UICollectionViewCell *cell in collectionView.visibleCells) {
            if (![cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")])
                continue;

            _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
            id node = [asCell respondsToSelector:@selector(node)] ? [asCell node] : nil;
            if (!GonerinoNodeLooksLikeVideo(node))
                continue;

            BOOL blocked = [Util nodeContainsBlockedVideo:node];
            cell.hidden = blocked;
            cell.alpha = blocked ? 0.0 : 1.0;
            cell.userInteractionEnabled = !blocked;
            cell.accessibilityElementsHidden = blocked;
        }
    } @catch (__unused NSException *exception) {
    }
    collectionView.gonerinoFiltering = NO;
}

%hook YTAsyncCollectionView

%property(nonatomic, assign) BOOL gonerinoFiltering;
%property(nonatomic, assign) BOOL gonerinoFilterScheduled;
%property(nonatomic, assign) NSTimeInterval gonerinoLastFilterTime;

%new
- (void)gonerinoScheduleFiltering {
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] != nil &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"])
        return;
    if (self.gonerinoFilterScheduled || GonerinoCollectionViewIsScrolling(self))
        return;
    if (CFAbsoluteTimeGetCurrent() - self.gonerinoLastFilterTime < 0.35)
        return;

    self.gonerinoFilterScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf.gonerinoFilterScheduled = NO;
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] != nil &&
            ![[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"])
            return;
        GonerinoFilterVisibleCells(strongSelf);
    });
}

- (void)layoutSubviews {
    %orig;
    [self gonerinoScheduleFiltering];
}

- (void)reloadData {
    %orig;
    [self gonerinoScheduleFiltering];
}

- (void)didMoveToWindow {
    %orig;
    if (self.window)
        [self gonerinoScheduleFiltering];
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

    id node = GonerinoVideoNodeForSheet(self);
    if (!node)
        return;
    NSDictionary *metadataAtPresentation = [Util videoInfoFromNode:node] ?: @{};
    objc_setAssociatedObject(self, injectionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, injectionInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak typeof(self) weakSelf = self;
    CGSize iconSize = CGSizeMake(16, 16);
    UIImage *channelIcon = [Util createBlockChannelIconWithSize:iconSize];
    UIImage *videoIcon = [Util createBlockVideoIconWithSize:iconSize];
    GonerinoMarkActionIcon(channelIcon);
    GonerinoMarkActionIcon(videoIcon);

    YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block channel"
              iconImage:channelIcon
                  style:0
                handler:^(__unused YTActionSheetAction *selectedAction) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    id selectedNode = GonerinoVideoNodeForSheet(strongSelf);
                    NSDictionary *info = GonerinoMergedVideoInfo([Util videoInfoFromNode:selectedNode], metadataAtPresentation);
                    NSString *channel = info[@"channel"];
                    UIViewController *viewController = GonerinoViewControllerForObject(strongSelf);
                    if (channel.length == 0) {
                        GonerinoSendToast(viewController, @"Could not read the channel for this video");
                        return;
                    }

                    [[ChannelManager sharedInstance] addBlockedChannel:channel];
                    GonerinoSendToast(viewController, [NSString stringWithFormat:@"Blocked %@", channel]);
                    if ([strongSelf respondsToSelector:@selector(dismiss)])
                        [strongSelf dismiss];
                    GonerinoRefreshVisibleFeeds();
                }];

    YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block video"
              iconImage:videoIcon
                  style:0
                handler:^(__unused YTActionSheetAction *selectedAction) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    id selectedNode = GonerinoVideoNodeForSheet(strongSelf);
                    NSDictionary *info = GonerinoMergedVideoInfo([Util videoInfoFromNode:selectedNode], metadataAtPresentation);
                    NSString *videoId = info[@"id"];
                    UIViewController *viewController = GonerinoViewControllerForObject(strongSelf);
                    if (videoId.length == 0) {
                        GonerinoSendToast(viewController, @"Could not read the video for this item");
                        return;
                    }

                    [[VideoManager sharedInstance] addBlockedVideo:videoId
                                                             title:info[@"title"]
                                                           channel:info[@"channel"]];
                    GonerinoSendToast(viewController,
                                      [NSString stringWithFormat:@"Blocked video: %@", info[@"title"] ?: videoId]);
                    if ([strongSelf respondsToSelector:@selector(dismiss)])
                        [strongSelf dismiss];
                    GonerinoRefreshVisibleFeeds();
                }];

    blockChannelAction.shouldDismissOnAction = YES;
    blockVideoAction.shouldDismissOnAction = YES;

    objc_setAssociatedObject(self, injectionInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addAction:blockChannelAction];
    [self addAction:blockVideoAction];

    __weak UIViewController *weakViewController = GonerinoViewControllerForObject(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *viewController = weakViewController;
        GonerinoScaleActionIcons(viewController.view);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GonerinoScaleActionIcons(weakViewController.view);
        });
    });
}

%new
- (UIViewController *)findViewControllerForView:(UIView *)view {
    return GonerinoViewControllerForObject(view);
}

%end

%hook YTRightNavigationButtons
%property(retain, nonatomic) YTQTMButton *gonerinoButton;

- (NSMutableArray *)buttons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    BOOL showButton = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                          ? YES
                          : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];

    [result removeObject:self.gonerinoButton];
    [self.gonerinoButton removeFromSuperview];
    if (!showButton)
        return result;

    if (!self.gonerinoButton) {
        self.gonerinoButton = [%c(YTQTMButton) iconButton];
        if ([self.gonerinoButton respondsToSelector:@selector(enableNewTouchFeedback)])
            [self.gonerinoButton enableNewTouchFeedback];
        self.gonerinoButton.frame = CGRectMake(0, 0, 40, 40);
        [self.gonerinoButton addTarget:self action:@selector(gonerinoButtonPressed:)
                      forControlEvents:UIControlEventTouchUpInside];
    }

    NSInteger pageStyle = 0;
    Class pageStyleClass = %c(YTPageStyleController);
    if ([pageStyleClass respondsToSelector:@selector(pageStyle)])
        pageStyle = [pageStyleClass pageStyle];
    else {
        YTAppDelegate *delegate = (YTAppDelegate *)[UIApplication sharedApplication].delegate;
        YTAppViewControllerImpl *appViewController = GonerinoValueForObjectKey(delegate, @"_appViewController");
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
    [self.gonerinoButton setImage:image forState:UIControlStateNormal];
    [self addSubview:self.gonerinoButton];
    [result insertObject:self.gonerinoButton atIndex:0];
    return result;
}

- (NSMutableArray *)visibleButtons {
    NSMutableArray *result = %orig.mutableCopy ?: [NSMutableArray array];
    BOOL showButton = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                          ? YES
                          : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];
    [result removeObject:self.gonerinoButton];
    if (showButton && self.gonerinoButton)
        [result insertObject:self.gonerinoButton atIndex:0];
    return result;
}

%new
- (void)gonerinoButtonPressed:(UIButton *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isEnabled = [defaults objectForKey:@"GonerinoEnabled"] == nil ? YES : [defaults boolForKey:@"GonerinoEnabled"];
    BOOL newState = !isEnabled;
    [defaults setBool:newState forKey:@"GonerinoEnabled"];
    [defaults synchronize];

    [self buttons];
    GonerinoRefreshVisibleFeeds();
    UIViewController *viewController = GonerinoViewControllerForObject(self);
    GonerinoSendToast(viewController, [NSString stringWithFormat:@"Gonerino %@", newState ? @"enabled" : @"disabled"]);
}

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[@"GonerinoDebugMetadata", @"GonerinoSheetDiagnostics", @"GonerinoRuntimeDiagnostics", @"GonerinoRuntimeDiagnostics2", @"GonerinoRuntimeDiagnostics3", @"GonerinoRuntimeDiagnostics4"])
        [defaults removeObjectForKey:key];
    [defaults synchronize];
    %init;
}
