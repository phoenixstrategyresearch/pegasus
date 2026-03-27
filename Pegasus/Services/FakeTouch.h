#ifndef FakeTouch_h
#define FakeTouch_h

#import <UIKit/UIKit.h>

/// Simulates a tap at the given point in the given window's coordinate system.
/// Based on KIF/PTFakeTouch — works within the app's own process (user mode).
@interface PegasusFakeTouch : NSObject

/// Simulate a single tap at the given screen-coordinate point.
/// Must be called on the main thread.
+ (void)tapAtPoint:(CGPoint)point inWindow:(UIWindow *)window;

/// Simulate a tap at the center of a view.
+ (void)tapView:(UIView *)view;

/// Simulate a tap at a point, forcing the touch target to the given view
/// (bypasses hitTest — useful for _UIRemoteView which has interactive=false).
+ (void)tapAtPoint:(CGPoint)point targetView:(UIView *)targetView inWindow:(UIWindow *)window;

/// Try to programmatically trigger the send action on an MFMessageComposeViewController.
/// Uses ObjC runtime to call private methods on the compose controller and its children.
/// Returns YES if a send method was successfully called.
+ (BOOL)triggerSendOnComposer:(UIViewController *)composer
                     withBody:(NSString *)body
                   recipients:(NSArray<NSString *> *)recipients;

/// Dump all methods on a class hierarchy (for diagnostics).
+ (NSArray<NSString *> *)dumpMethodsForObject:(NSObject *)object
                               matchingKeywords:(NSArray<NSString *> *)keywords;

@end

#endif
