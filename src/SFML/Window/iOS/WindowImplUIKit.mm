////////////////////////////////////////////////////////////
//
// SFML - Simple and Fast Multimedia Library
// Copyright (C) 2007-2023 Laurent Gomila (laurent@sfml-dev.org)
//
// This software is provided 'as-is', without any express or implied warranty.
// In no event will the authors be held liable for any damages arising from the use of this software.
//
// Permission is granted to anyone to use this software for any purpose,
// including commercial applications, and to alter it and redistribute it freely,
// subject to the following restrictions:
//
// 1. The origin of this software must not be misrepresented;
//    you must not claim that you wrote the original software.
//    If you use this software in a product, an acknowledgment
//    in the product documentation would be appreciated but is not required.
//
// 2. Altered source versions must be plainly marked as such,
//    and must not be misrepresented as being the original software.
//
// 3. This notice may not be removed or altered from any source distribution.
//
////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////
// Headers
////////////////////////////////////////////////////////////
#include <SFML/Window/iOS/WindowImplUIKit.hpp>
#include <SFML/Window/iOS/SFView.hpp>
#include <SFML/Window/iOS/SFViewController.hpp>
#include <SFML/Window/iOS/SFAppDelegate.hpp>
#include <SFML/Window/WindowStyle.hpp>
#include <SFML/System/Err.hpp>
#include <UIKit/UIKit.h>

#if defined(__APPLE__)
    #if defined(__clang__)
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    #elif defined(__GNUC__)
        #pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    #endif
#endif

namespace sf
{
namespace priv
{
////////////////////////////////////////////////////////////
WindowImplUIKit::WindowImplUIKit(WindowHandle /* handle */)
{
    // Not implemented
}


////////////////////////////////////////////////////////////
WindowImplUIKit::WindowImplUIKit(VideoMode mode,
                                 const String& /* title */,
                                 unsigned long style,
                                 const ContextSettings& /* settings */)
{
    // mkxp-ios: every UIKit / UIWindow / UIView operation has to
    // happen on the main thread or UIApplication throws
    // NSInternalInconsistencyException ("Call must be made on main
    // thread"). LiteRGSS / mkxp drive the engine from a worker
    // thread (the SDL worker for litergss_run, the RGSS thread for
    // mkxp), so the construction below has to be marshaled. Use
    // dispatch_sync so the worker blocks until the window is up
    // and `m_window` / `m_view` etc. are valid before this
    // constructor returns. Skip the dispatch when already on main
    // (e.g. tests, or if some embedder calls in from main) to
    // avoid the deadlock dispatch_sync_to_self_queue would cause.
    auto setup = [&]() {
        m_backingScale = static_cast<float>([SFAppDelegate getInstance].backingScaleFactor);

        // Apply the fullscreen flag
        [UIApplication sharedApplication].statusBarHidden = !(style & Style::Titlebar) || (style & Style::Fullscreen);

        // Set the orientation according to the requested size
        if (mode.width > mode.height)
            [[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationLandscapeLeft];
        else
            [[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationPortrait];

        // Create the window
        CGRect frame = [UIScreen mainScreen].bounds; // Ignore user size, it wouldn't make sense to use something else
        // mkxp-ios: on iOS 13+ multi-scene apps, a UIWindow created
        // with -initWithFrame: doesn't attach to any UIWindowScene
        // and never lays out / displays. Find the active foreground
        // scene from the host app and bind the SFML window to it so
        // it actually shows. Falls back to the legacy initWithFrame:
        // path on iOS 12 or in the rare case no foreground scene is
        // available yet.
        UIWindowScene* foregroundScene = nil;
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes)
        {
            if (scene.activationState == UISceneActivationStateForegroundActive
                && [scene isKindOfClass:[UIWindowScene class]])
            {
                foregroundScene = (UIWindowScene*)scene;
                break;
            }
        }
        if (!foregroundScene)
        {
            for (UIScene* scene in [UIApplication sharedApplication].connectedScenes)
            {
                if ([scene isKindOfClass:[UIWindowScene class]])
                {
                    foregroundScene = (UIWindowScene*)scene;
                    break;
                }
            }
        }
        if (foregroundScene)
        {
            m_window = [[UIWindow alloc] initWithWindowScene:foregroundScene];
            m_window.frame = frame;
        }
        else
        {
            m_window = [[UIWindow alloc] initWithFrame:frame];
        }
        // Layer above the host app's main window so the game render
        // is visible even if the host has its own UIWindow open.
        m_window.windowLevel = UIWindowLevelNormal + 2;
        m_hasFocus = true;

        // Assign it to the application delegate
        [SFAppDelegate getInstance].sfWindow = this;

        CGRect viewRect = frame;
        // if UI-orientation doesn't match window-layout, swap the view size and notify the window about it
        // iOS 7 and 8 do different stuff here. In iOS 7 frame.x<frame.y always! In iOS 8 it correctly depends on orientation
        if (NSFoundationVersionNumber <= NSFoundationVersionNumber_iOS_7_1)
            if ((mode.width > mode.height) != (frame.size.width > frame.size.height))
                std::swap(viewRect.size.width, viewRect.size.height);

        // Create the view
        m_view = [[SFView alloc] initWithFrame:viewRect andContentScaleFactor:(static_cast<double>(m_backingScale))];
        [m_view resignFirstResponder];

        // Create the view controller. mkxp-ios: original SFML code
        // had `[SFViewController alloc]` without an `init`, leaving
        // the UIViewController without its designated initializer
        // run. UIKit then misroutes a number of calls (view loading,
        // safe area, layout) and the view never displays. Use the
        // proper `[[... alloc] initWithNibName:bundle:]` pattern.
        // We can't safely set `.view = m_view` before -loadView
        // fires, so let UIKit create its default view, then add the
        // SFView as a subview that fills the bounds.
        m_viewController = [[SFViewController alloc] initWithNibName:nil bundle:nil];
        m_viewController.orientationCanChange = style & Style::Resize;
        // Force the view controller's view to load by accessing it,
        // then drop our SFView in. The container view fills the
        // window; the SFView fills the container so resizes
        // propagate via autoresizing.
        UIView* containerView = m_viewController.view;
        containerView.backgroundColor = [UIColor blackColor];
        m_view.frame = containerView.bounds;
        m_view.autoresizingMask = UIViewAutoresizingFlexibleWidth
                                | UIViewAutoresizingFlexibleHeight;
        [containerView addSubview:m_view];
        m_window.rootViewController = m_viewController;

        // Make it the current window
        [m_window makeKeyAndVisible];
    };

    if ([NSThread isMainThread]) {
        setup();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ setup(); });
    }
}


////////////////////////////////////////////////////////////
WindowImplUIKit::~WindowImplUIKit()
{
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::processEvents()
{
    while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0001, true) == kCFRunLoopRunHandledSource)
        ;
}


////////////////////////////////////////////////////////////
WindowHandle WindowImplUIKit::getSystemHandle() const
{
#if defined(__APPLE__)
    #if defined(__clang__)
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wold-style-cast"
    #elif defined(__GNUC__)
        #pragma GCC diagnostic push
        #pragma GCC diagnostic ignored "-Wold-style-cast"
    #endif
#endif

    return (__bridge WindowHandle)m_window;

#if defined(__APPLE__)
    #if defined(__clang__)
        #pragma clang diagnostic pop
    #elif defined(__GNUC__)
        #pragma GCC diagnostic pop
    #endif
#endif
}


////////////////////////////////////////////////////////////
Vector2i WindowImplUIKit::getPosition() const
{
    CGPoint origin = m_window.frame.origin;
    return Vector2i(static_cast<int>(origin.x * static_cast<double>(m_backingScale)), static_cast<int>(origin.y * static_cast<double>(m_backingScale)));
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setPosition(const Vector2i& /* position */)
{
}


////////////////////////////////////////////////////////////
Vector2u WindowImplUIKit::getSize() const
{
    CGRect physicalFrame = m_window.frame;
    // iOS 7 and 8 do different stuff here. In iOS 7 frame.x<frame.y always! In iOS 8 it correctly depends on orientation
    if ((NSFoundationVersionNumber <= NSFoundationVersionNumber_iOS_7_1)
        && UIInterfaceOrientationIsLandscape([[UIApplication sharedApplication] statusBarOrientation]))
        std::swap(physicalFrame.size.width, physicalFrame.size.height);
    return Vector2u(static_cast<unsigned int>(physicalFrame.size.width * static_cast<double>(m_backingScale)), static_cast<unsigned int>(physicalFrame.size.height * static_cast<double>(m_backingScale)));
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setSize(const Vector2u& size)
{
    // @todo ...

    // if these sizes are required one day, don't forget to scale them!
    // size.x /= m_backingScale;
    // size.y /= m_backingScale;

    // Set the orientation according to the requested size; UIKit
    // setStatusBarOrientation requires main thread.
    auto apply = [size]() {
        if (size.x > size.y)
            [[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationLandscapeLeft];
        else
            [[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationPortrait];
    };
    if ([NSThread isMainThread]) {
        apply();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ apply(); });
    }
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setTitle(const String& /* title */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setIcon(unsigned int /* width */, unsigned int /* height */, const Uint8* /* pixels */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setVisible(bool /* visible */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setMouseCursorVisible(bool /* visible */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setMouseCursorGrabbed(bool /* grabbed */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setMouseCursor(const CursorImpl& /* cursor */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setKeyRepeatEnabled(bool /* enabled */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::requestFocus()
{
    // To implement
}


////////////////////////////////////////////////////////////
bool WindowImplUIKit::hasFocus() const
{
    return m_hasFocus;
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::forwardEvent(Event event)
{
    if (event.type == Event::GainedFocus)
        m_hasFocus = true;
    else if (event.type == Event::LostFocus)
        m_hasFocus = false;

    pushEvent(event);
}


////////////////////////////////////////////////////////////
SFView* WindowImplUIKit::getGlView() const
{
    return m_view;
}


////////////////////////////////////////////////////////////
void WindowImplUIKit::setVirtualKeyboardVisible(bool visible)
{
    // becomeFirstResponder / resignFirstResponder are UIKit calls,
    // main-thread only.
    auto toggle = [this, visible]() {
        if (visible)
            [m_view becomeFirstResponder];
        else
            [m_view resignFirstResponder];
    };
    if ([NSThread isMainThread]) {
        toggle();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ toggle(); });
    }
}

} // namespace priv

} // namespace sf
