//
//  FakeTouch.m
//  Pegasus
//
//  Minimal in-process touch simulation based on KIF/PTFakeTouch.
//  Synthesizes IOHIDEvent + UITouchesEvent and delivers via UIApplication.sendEvent.
//  Works on iOS 9–18+ (user-mode, no jailbreak, no XCTest needed).
//  IOHIDEvent symbols resolved via dlsym to avoid linker issues.
//

#import "FakeTouch.h"
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

#pragma mark - Terminal logging (writes to pegasus_swift.log for in-app Terminal)

static void _ftLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void _ftLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Also NSLog for Xcode console
    NSLog(@"%@", msg);

    // Write to pegasus_swift.log so it appears in Terminal tab
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *ts = [fmt stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];

    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pegasus_swift.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

#pragma mark - IOHIDEvent types

typedef struct __IOHIDEvent * IOHIDEventRef;

#define IOHIDEventFieldBase(type) (type << 16)

#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

typedef UInt32 IOOptionBits;

enum {
    kIOHIDDigitizerTransducerTypeHand = 3
};
enum {
    kIOHIDEventTypeDigitizer = 11
};
enum {
    kIOHIDDigitizerEventRange    = 0x00000001,
    kIOHIDDigitizerEventTouch    = 0x00000002,
};
enum {
    kIOHIDEventFieldDigitizerIsDisplayIntegrated = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) + 24,
};

#pragma mark - IOHIDEvent function pointers (resolved via dlsym)

typedef IOHIDEventRef (*CreateDigitizerEventFunc)(
    CFAllocatorRef, AbsoluteTime, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat,
    IOHIDFloat, IOHIDFloat,
    Boolean, Boolean, IOOptionBits);

typedef IOHIDEventRef (*CreateFingerEventFunc)(
    CFAllocatorRef, AbsoluteTime,
    uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat,
    IOHIDFloat, IOHIDFloat,
    IOHIDFloat, IOHIDFloat,
    IOHIDFloat, IOHIDFloat, IOHIDFloat,
    Boolean, Boolean, IOOptionBits);

typedef void (*AppendEventFunc)(IOHIDEventRef, IOHIDEventRef);
typedef void (*SetIntValueFunc)(IOHIDEventRef, uint32_t, int);

static CreateDigitizerEventFunc _createDigitizerEvent = NULL;
static CreateFingerEventFunc _createFingerEvent = NULL;
static AppendEventFunc _appendEvent = NULL;
static SetIntValueFunc _setIntValue = NULL;
static BOOL _resolved = NO;

static BOOL _resolveIOHIDSymbols(void) {
    if (_resolved) return (_createDigitizerEvent != NULL);

    _resolved = YES;
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!handle) {
        _ftLog(@"[FakeTouch] Failed to load IOKit: %s", dlerror());
        return NO;
    }

    _createDigitizerEvent = (CreateDigitizerEventFunc)dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    _createFingerEvent = (CreateFingerEventFunc)dlsym(handle, "IOHIDEventCreateDigitizerFingerEventWithQuality");
    _appendEvent = (AppendEventFunc)dlsym(handle, "IOHIDEventAppendEvent");
    _setIntValue = (SetIntValueFunc)dlsym(handle, "IOHIDEventSetIntegerValue");

    BOOL ok = (_createDigitizerEvent && _createFingerEvent && _appendEvent && _setIntValue);
    _ftLog(@"[FakeTouch] IOHIDEvent symbols resolved: %d (create=%p finger=%p append=%p setInt=%p)",
          ok, _createDigitizerEvent, _createFingerEvent, _appendEvent, _setIntValue);
    return ok;
}

#pragma mark - Private UIKit interfaces

@interface UITouch (PegasusPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setPhase:(UITouchPhase)phase;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setGestureView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)firstTouchForView;
- (void)_setIsTapToClick:(BOOL)isTapToClick;
- (void)_setHidEvent:(IOHIDEventRef)event;
@end

@interface UIEvent (PegasusPrivate)
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_clearTouches;
- (void)_setHIDEvent:(IOHIDEventRef)event;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
@end

@interface UIApplication (PegasusPrivate)
- (UIEvent *)_touchesEvent;
@end

#pragma mark - IOHIDEvent builder

static IOHIDEventRef _createHIDEvent(CGPoint location, BOOL isTouching) {
    if (!_resolveIOHIDSymbols()) return NULL;

    uint64_t abTime = mach_absolute_time();
    AbsoluteTime ts;
    ts.hi = (UInt32)(abTime >> 32);
    ts.lo = (UInt32)(abTime);

    IOHIDEventRef handEvent = _createDigitizerEvent(
        kCFAllocatorDefault, ts,
        kIOHIDDigitizerTransducerTypeHand,
        0, 0,
        kIOHIDDigitizerEventTouch,
        0,
        0, 0, 0,
        0, 0,
        0, true, 0);
    if (!handEvent) return NULL;
    _setIntValue(handEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, true);

    uint32_t eventMask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;
    uint32_t touching = isTouching ? 1 : 0;

    IOHIDEventRef fingerEvent = _createFingerEvent(
        kCFAllocatorDefault, ts,
        1, 2,
        eventMask,
        (IOHIDFloat)location.x, (IOHIDFloat)location.y, 0,
        0, 0,
        5.0, 5.0,
        1.0, 1.0, 1.0,
        (IOHIDFloat)touching, (IOHIDFloat)touching, 0);
    if (fingerEvent) {
        _setIntValue(fingerEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        _appendEvent(handEvent, fingerEvent);
        CFRelease(fingerEvent);
    }

    return handEvent;
}

#pragma mark - UITouch helper

static UITouch *_createTouch(CGPoint point, UIWindow *window, UITouchPhase phase) {
    UITouch *touch = [[UITouch alloc] init];

    [touch setWindow:window];
    [touch _setLocationInWindow:point resetPrevious:YES];

    UIView *hitView = [window hitTest:point withEvent:nil];
    [touch setView:hitView];
    [touch setPhase:phase];
    [touch setTimestamp:[[NSProcessInfo processInfo] systemUptime]];

    if ([touch respondsToSelector:@selector(setGestureView:)]) {
        [touch setGestureView:hitView];
    }

    if (@available(iOS 14.0, *)) {
        [touch _setIsTapToClick:NO];
    } else {
        [touch _setIsFirstTouchForView:YES];
    }

    BOOL isTouching = (phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled);
    IOHIDEventRef hidEvent = _createHIDEvent(point, isTouching);
    if (hidEvent) {
        [touch _setHidEvent:hidEvent];
        CFRelease(hidEvent);
    }

    return touch;
}

static void _sendTouch(UITouch *touch, UIWindow *window) {
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    [event _clearTouches];

    CGPoint location = [touch locationInView:window];
    BOOL isTouching = (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled);
    IOHIDEventRef hidEvent = _createHIDEvent(location, isTouching);
    if (hidEvent) {
        [event _setHIDEvent:hidEvent];
        CFRelease(hidEvent);
    }

    [event _addTouch:touch forDelayedDelivery:NO];
    [[UIApplication sharedApplication] sendEvent:event];
}

#pragma mark - Public API

@implementation PegasusFakeTouch

+ (void)tapAtPoint:(CGPoint)point inWindow:(UIWindow *)window {
    if (!_resolveIOHIDSymbols()) {
        _ftLog(@"[FakeTouch] Cannot tap — IOHIDEvent symbols not available");
        return;
    }

    _ftLog(@"[FakeTouch] Tapping at (%.1f, %.1f)", point.x, point.y);

    // Phase 1: Touch began
    UITouch *touch = _createTouch(point, window, UITouchPhaseBegan);
    _sendTouch(touch, window);

    // Phase 2: Touch ended (after short delay to mimic real finger tap)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setPhase:UITouchPhaseEnded];
        [touch setTimestamp:[[NSProcessInfo processInfo] systemUptime]];

        CGPoint loc = [touch locationInView:window];
        IOHIDEventRef endHid = _createHIDEvent(loc, NO);
        if (endHid) {
            [touch _setHidEvent:endHid];
            CFRelease(endHid);
        }

        _sendTouch(touch, window);
        _ftLog(@"[FakeTouch] Tap completed at (%.1f, %.1f)", point.x, point.y);
    });
}

+ (void)tapView:(UIView *)view {
    if (!view || !view.window) {
        _ftLog(@"[FakeTouch] Cannot tap — view or window is nil");
        return;
    }
    CGPoint center = [view.superview convertPoint:view.center toView:nil];
    [self tapAtPoint:center inWindow:view.window];
}

+ (void)tapAtPoint:(CGPoint)point targetView:(UIView *)targetView inWindow:(UIWindow *)window {
    if (!_resolveIOHIDSymbols()) {
        _ftLog(@"[FakeTouch] Cannot tap — IOHIDEvent symbols not available");
        return;
    }

    _ftLog(@"[FakeTouch] Force-tapping at (%.1f, %.1f) target=%@", point.x, point.y,
          NSStringFromClass([targetView class]));

    // Phase 1: Touch began — bypass hitTest, force target view
    UITouch *touch = [[UITouch alloc] init];
    [touch setWindow:window];
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setView:targetView];
    [touch setPhase:UITouchPhaseBegan];
    [touch setTimestamp:[[NSProcessInfo processInfo] systemUptime]];

    if ([touch respondsToSelector:@selector(setGestureView:)]) {
        [touch setGestureView:targetView];
    }

    if (@available(iOS 14.0, *)) {
        [touch _setIsTapToClick:NO];
    } else {
        [touch _setIsFirstTouchForView:YES];
    }

    IOHIDEventRef hidBegin = _createHIDEvent(point, YES);
    if (hidBegin) {
        [touch _setHidEvent:hidBegin];
        CFRelease(hidBegin);
    }

    _sendTouch(touch, window);

    // Phase 2: Touch ended
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setPhase:UITouchPhaseEnded];
        [touch setTimestamp:[[NSProcessInfo processInfo] systemUptime]];

        IOHIDEventRef hidEnd = _createHIDEvent(point, NO);
        if (hidEnd) {
            [touch _setHidEvent:hidEnd];
            CFRelease(hidEnd);
        }

        _sendTouch(touch, window);
        _ftLog(@"[FakeTouch] Force-tap completed at (%.1f, %.1f)", point.x, point.y);
    });
}

+ (NSArray<NSString *> *)dumpMethodsForObject:(NSObject *)object
                               matchingKeywords:(NSArray<NSString *> *)keywords {
    NSMutableArray *results = [NSMutableArray array];
    Class cls = [object class];

    while (cls && cls != [NSObject class]) {
        NSString *clsName = NSStringFromClass(cls);
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        if (methods) {
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                NSString *lower = [name lowercaseString];
                for (NSString *kw in keywords) {
                    if ([lower containsString:[kw lowercaseString]]) {
                        [results addObject:[NSString stringWithFormat:@"%@::%@", clsName, name]];
                        break;
                    }
                }
            }
            free(methods);
        }
        cls = [cls superclass];
    }
    return results;
}

+ (BOOL)triggerSendOnComposer:(UIViewController *)composer
                     withBody:(NSString *)body
                   recipients:(NSArray<NSString *> *)recipients {

    _ftLog(@"[FakeTouch] triggerSend: scanning composer %@ for send methods", NSStringFromClass([composer class]));

    // Strategy 1: Find the CKSMSComposeController child and scan its full hierarchy
    UIViewController *ckController = nil;
    for (UIViewController *child in composer.childViewControllers) {
        NSString *cls = NSStringFromClass([child class]);
        _ftLog(@"[FakeTouch] Child VC: %@", cls);
        if ([cls containsString:@"CK"] || [cls containsString:@"Compose"]) {
            ckController = child;
        }
    }

    if (ckController) {
        // Dump ALL methods on the CK controller's full class hierarchy
        NSArray *broadKeywords = @[@"send", @"commit", @"finish", @"done", @"deliver",
                                    @"submit", @"confirm", @"entry", @"compose", @"message",
                                    @"action", @"button", @"tap", @"press", @"click",
                                    @"trigger", @"perform", @"execute"];
        NSArray *allMethods = [self dumpMethodsForObject:(NSObject *)ckController
                                         matchingKeywords:broadKeywords];
        for (NSString *m in allMethods) {
            _ftLog(@"[FakeTouch] CK method: %@", m);
        }

        // Strategy 2: Try calling send-related selectors on the CK controller
        NSArray *trySelectors = @[
            @"sendMessage",
            @"send",
            @"send:",
            @"_send",
            @"_sendMessage",
            @"sendCurrentMessage",
            @"_sendCurrentMessage",
            @"commitAndSend",
            @"performSendAction",
            @"performSendAction:",
            @"_sendButtonTapped",
            @"_sendButtonTapped:",
            @"sendButtonAction",
            @"sendButtonAction:",
            @"handleSendButton",
            @"handleSendButton:",
        ];

        for (NSString *selName in trySelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([ckController respondsToSelector:sel]) {
                _ftLog(@"[FakeTouch] Found %@ on CK controller — calling it!", selName);
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                if ([selName hasSuffix:@":"]) {
                    [ckController performSelector:sel withObject:nil];
                } else {
                    [ckController performSelector:sel];
                }
                #pragma clang diagnostic pop
                return YES;
            }
        }

        // Strategy 3: Look for the entryView / inputBar and try to trigger send from there
        // CKComposeController typically has an _entryView (CKMessageEntryView) with a sendButton
        NSArray *entrySelectors = @[@"entryView", @"_entryView", @"messageEntryView",
                                     @"composeEntryView", @"inputAccessoryView"];
        for (NSString *selName in entrySelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([ckController respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id entryView = [ckController performSelector:sel];
                #pragma clang diagnostic pop
                if (entryView) {
                    _ftLog(@"[FakeTouch] Found entryView via %@: %@", selName,
                          NSStringFromClass([entryView class]));

                    // Look for sendButton on the entryView
                    SEL sendBtnSel = NSSelectorFromString(@"sendButton");
                    if ([entryView respondsToSelector:sendBtnSel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        UIButton *sendBtn = [entryView performSelector:sendBtnSel];
                        #pragma clang diagnostic pop
                        if (sendBtn) {
                            _ftLog(@"[FakeTouch] Found sendButton! Triggering action...");
                            [sendBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
                            return YES;
                        }
                    }

                    // Try calling send on the entryView itself
                    SEL entrySendSel = NSSelectorFromString(@"send:");
                    if ([entryView respondsToSelector:entrySendSel]) {
                        _ftLog(@"[FakeTouch] Calling send: on entryView");
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [entryView performSelector:entrySendSel withObject:nil];
                        #pragma clang diagnostic pop
                        return YES;
                    }
                }
            }
        }
    }

    // Strategy 4: Call shouldSendMessage on the CK controller (not the delegate)
    // This might trigger the full send flow including notifying the remote process
    if (ckController) {
        SEL shouldSendSel = NSSelectorFromString(@"smsComposeControllerShouldSendMessageWithText:toRecipients:completion:");
        if ([ckController respondsToSelector:shouldSendSel]) {
            _ftLog(@"[FakeTouch] Calling shouldSendMessage on CKSMSComposeController");
            NSMethodSignature *sig = [(NSObject *)ckController methodSignatureForSelector:shouldSendSel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:ckController];
                [inv setSelector:shouldSendSel];
                [inv setArgument:&body atIndex:2];
                [inv setArgument:&recipients atIndex:3];
                void (^completionBlock)(void) = ^{
                    _ftLog(@"[FakeTouch] CK shouldSend completion called!");
                };
                [inv setArgument:&completionBlock atIndex:4];
                [inv invoke];
                _ftLog(@"[FakeTouch] CK shouldSend invoked");
                // Don't return yet — try other strategies too
            }
        }
    }

    // Strategy 5: sendClientToHostAction — XPC to remote MessagesViewService
    if (ckController) {
        SEL clientToHostSel = NSSelectorFromString(@"sendClientToHostAction:");
        if ([ckController respondsToSelector:clientToHostSel]) {
            _ftLog(@"[FakeTouch] Found sendClientToHostAction: on CK controller");

            // Try various action payloads
            NSArray *actions = @[
                @"send",
                @"sendMessage",
                @"sendButtonTapped",
                @{@"action": @"send"},
                @{@"action": @"sendMessage", @"text": body, @"recipients": recipients},
            ];
            for (id action in actions) {
                _ftLog(@"[FakeTouch] Trying sendClientToHostAction: %@", action);
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                @try {
                    [ckController performSelector:clientToHostSel withObject:action];
                    _ftLog(@"[FakeTouch] sendClientToHostAction succeeded with: %@", action);
                } @catch (NSException *e) {
                    _ftLog(@"[FakeTouch] sendClientToHostAction exception: %@", e.reason);
                }
                #pragma clang diagnostic pop
            }
        } else {
            _ftLog(@"[FakeTouch] CK controller does not respond to sendClientToHostAction:");
        }
    }

    // Strategy 6: Find the _UIRemoteView and scan for action/proxy methods
    UIView *remoteView = nil;
    for (UIView *sub in composer.view.subviews) {
        remoteView = [self _findRemoteViewIn:sub];
        if (remoteView) break;
    }
    if (remoteView) {
        _ftLog(@"[FakeTouch] Scanning _UIRemoteView methods...");
        NSArray *remoteKeywords = @[@"action", @"send", @"proxy", @"remote", @"service",
                                     @"connection", @"request", @"forward", @"host"];
        NSArray *remoteMethods = [self dumpMethodsForObject:(NSObject *)remoteView
                                             matchingKeywords:remoteKeywords];
        for (NSString *m in remoteMethods) {
            _ftLog(@"[FakeTouch] RemoteView method: %@", m);
        }

        // Try getting the remote VC proxy
        NSArray *proxySelectors = @[@"remoteViewController", @"_remoteViewController",
                                     @"_remoteViewControllerProxy", @"_connection",
                                     @"_serviceViewControllerProxy"];
        for (NSString *selName in proxySelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([remoteView respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id proxy = [remoteView performSelector:sel];
                #pragma clang diagnostic pop
                if (proxy) {
                    _ftLog(@"[FakeTouch] Got proxy via %@: %@", selName,
                          NSStringFromClass([proxy class]));
                    // Dump proxy methods
                    NSArray *proxyMethods = [self dumpMethodsForObject:(NSObject *)proxy
                                                       matchingKeywords:@[@"send", @"action", @"message",
                                                                          @"compose", @"done", @"finish"]];
                    for (NSString *m in proxyMethods) {
                        _ftLog(@"[FakeTouch] Proxy method: %@", m);
                    }
                }
            }
        }
    }

    _ftLog(@"[FakeTouch] All strategies exhausted — user must tap Send manually");
    return NO;
}

+ (UIView *)_findRemoteViewIn:(UIView *)view {
    NSString *cls = NSStringFromClass([view class]);
    if ([cls containsString:@"RemoteView"] || [cls containsString:@"_UIRemote"]) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = [self _findRemoteViewIn:sub];
        if (found) return found;
    }
    return nil;
}

@end
