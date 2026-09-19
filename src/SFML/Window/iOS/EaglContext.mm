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
// EaglContext-via-ANGLE.
//
// Class name kept for source-compat with SFML's
// `sf::priv::GlContext::createImpl` factory in GlContext.cpp;
// implementation rewritten on top of ANGLE / EGL so the iOS
// build doesn't depend on Apple's deprecated OpenGLES framework
// (EAGLContext, CAEAGLLayer). ANGLE translates GLES2 calls into
// Metal at runtime, which is what Apple supports going forward.
//
// Window-attached contexts get an EGLSurface backed by the
// associated SFView's CAMetalLayer (see SFView.mm where
// +layerClass returns CAMetalLayer). Offscreen / shared
// contexts use a pbuffer surface instead. Frame swap is
// `eglSwapBuffers` rather than [m_context presentRenderbuffer:].
//
// SFML's render code (sf::Texture, sf::Sprite, sf::Shader) calls
// portable GLES2 entry points through the glad-loaded function
// table; those don't change between EAGL and ANGLE.
////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////
// Headers
////////////////////////////////////////////////////////////
#include <SFML/Window/iOS/EaglContext.hpp>
#include <SFML/Window/iOS/WindowImplUIKit.hpp>
#include <SFML/Window/iOS/SFView.hpp>
#include <SFML/System/Err.hpp>
#include <SFML/System/Lock.hpp>
#include <SFML/System/Sleep.hpp>
#include <EGL/egl.h>
#include <UIKit/UIKit.h>

namespace
{
    ////////////////////////////////////////////////////////////
    /// One process-wide EGL display; ANGLE shares state across
    /// every context that uses it. Lazily initialised on first
    /// EaglContext construction so SFML's static
    /// `internalContext` (created during sfml-window
    /// initialisation) doesn't crash if ANGLE isn't ready yet.
    ////////////////////////////////////////////////////////////
    EGLDisplay g_display = EGL_NO_DISPLAY;

    EGLDisplay ensureEglDisplay()
    {
        if (g_display != EGL_NO_DISPLAY)
            return g_display;

        EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display == EGL_NO_DISPLAY)
        {
            sf::err() << "[EaglContext] eglGetDisplay returned EGL_NO_DISPLAY"
                      << std::endl;
            return EGL_NO_DISPLAY;
        }

        EGLint major = 0, minor = 0;
        if (!eglInitialize(display, &major, &minor))
        {
            sf::err() << "[EaglContext] eglInitialize failed (0x"
                      << std::hex << eglGetError() << ")" << std::endl;
            return EGL_NO_DISPLAY;
        }

        g_display = display;
        return g_display;
    }

    ////////////////////////////////////////////////////////////
    /// Choose an EGL config matching the requested SFML settings.
    /// SFML's ContextSettings carries depth/stencil/AA bits; we
    /// honour them where ANGLE has the matching attributes.
    ////////////////////////////////////////////////////////////
    EGLConfig chooseConfig(EGLDisplay display, const sf::ContextSettings& settings)
    {
        EGLint attribs[] = {
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_SURFACE_TYPE,    EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_ALPHA_SIZE,      8,
            EGL_DEPTH_SIZE,      static_cast<EGLint>(settings.depthBits),
            EGL_STENCIL_SIZE,    static_cast<EGLint>(settings.stencilBits),
            EGL_NONE
        };

        EGLConfig  config    = nullptr;
        EGLint     numConfig = 0;
        if (!eglChooseConfig(display, attribs, &config, 1, &numConfig) || numConfig == 0)
        {
            sf::err() << "[EaglContext] eglChooseConfig failed (0x"
                      << std::hex << eglGetError() << ")" << std::endl;
        }
        return config;
    }
}


namespace sf
{
namespace priv
{
////////////////////////////////////////////////////////////
EaglContext::EaglContext(EaglContext* shared) :
m_display     (EGL_NO_DISPLAY),
m_context     (EGL_NO_CONTEXT),
m_surface     (EGL_NO_SURFACE),
m_config      (nullptr),
m_pendingView (nullptr),
m_vsyncEnabled(false),
m_clock       ()
{
    EGLDisplay display = ensureEglDisplay();
    if (display == EGL_NO_DISPLAY)
        return;
    m_display = display;

    ContextSettings defaults;
    EGLConfig config = chooseConfig(display, defaults);
    m_config = config;

    EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
    EGLContext sharedCtx = shared ? static_cast<EGLContext>(shared->m_context) : EGL_NO_CONTEXT;
    EGLContext context = eglCreateContext(display, config, sharedCtx, contextAttribs);
    if (context == EGL_NO_CONTEXT)
    {
        err() << "[EaglContext] eglCreateContext (shared) failed (0x"
              << std::hex << eglGetError() << ")" << std::endl;
        return;
    }
    m_context = context;

    // 1x1 pbuffer so contexts without a window have something to bind.
    EGLint pbufferAttribs[] = {
        EGL_WIDTH,  1,
        EGL_HEIGHT, 1,
        EGL_NONE
    };
    m_surface = eglCreatePbufferSurface(display, config, pbufferAttribs);
}


////////////////////////////////////////////////////////////
EaglContext::EaglContext(EaglContext* shared, const ContextSettings& settings,
                         const WindowImpl* owner, unsigned int /* bitsPerPixel */) :
m_display     (EGL_NO_DISPLAY),
m_context     (EGL_NO_CONTEXT),
m_surface     (EGL_NO_SURFACE),
m_config      (nullptr),
m_pendingView (nullptr),
m_vsyncEnabled(false),
m_clock       ()
{
    m_settings = settings;

    EGLDisplay display = ensureEglDisplay();
    if (display == EGL_NO_DISPLAY)
        return;
    m_display = display;

    EGLConfig config = chooseConfig(display, m_settings);
    m_config = config;

    EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
    EGLContext sharedCtx = shared ? static_cast<EGLContext>(shared->m_context) : EGL_NO_CONTEXT;
    EGLContext context = eglCreateContext(display, config, sharedCtx, contextAttribs);
    if (context == EGL_NO_CONTEXT)
    {
        err() << "[EaglContext] eglCreateContext (window) failed (0x"
              << std::hex << eglGetError() << ")" << std::endl;
        return;
    }
    m_context = context;

    // Window-attached: bind the surface to the SFView's CAMetalLayer.
    const WindowImplUIKit* window = static_cast<const WindowImplUIKit*>(owner);
    SFView* view = window->getGlView();
    if (view)
    {
        // eglCreateWindowSurface has to run on the main thread. ANGLE's
        // Metal backend reads the CAMetalLayer here and keeps what it
        // reads for the life of the surface. Off the main thread it
        // binds a layer state that never becomes presentable, and then
        // every eglSwapBuffers returns EGL_BAD_SURFACE and the screen
        // stays black. Measured on the simulator: 1560 swaps, 1560
        // failures off the main thread, 0 failures on it.
        //
        // SFML calls this from the thread that owns the context, which
        // is the game thread in a host that keeps the main thread in
        // its runloop. The recreate path below needs no such guard
        // because layoutSubviews already runs on the main thread.
        __block EGLSurface surface = EGL_NO_SURFACE;
        void (^create)(void) = ^{
            EGLNativeWindowType nativeWindow = (__bridge EGLNativeWindowType)view.layer;
            surface = eglCreateWindowSurface(display, config, nativeWindow, nullptr);
        };
        if ([NSThread isMainThread])
            create();
        else
            dispatch_sync(dispatch_get_main_queue(), create);
        if (surface == EGL_NO_SURFACE)
        {
            err() << "[EaglContext] eglCreateWindowSurface failed (0x"
                  << std::hex << eglGetError() << ")" << std::endl;
        }
        m_surface = surface;
        view.context = this;
    }
}


////////////////////////////////////////////////////////////
EaglContext::EaglContext(EaglContext* shared, const ContextSettings& settings,
                         unsigned int width, unsigned int height) :
m_display     (EGL_NO_DISPLAY),
m_context     (EGL_NO_CONTEXT),
m_surface     (EGL_NO_SURFACE),
m_config      (nullptr),
m_pendingView (nullptr),
m_vsyncEnabled(false),
m_clock       ()
{
    m_settings = settings;

    EGLDisplay display = ensureEglDisplay();
    if (display == EGL_NO_DISPLAY)
        return;
    m_display = display;

    EGLConfig config = chooseConfig(display, m_settings);
    m_config = config;

    EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
    EGLContext sharedCtx = shared ? static_cast<EGLContext>(shared->m_context) : EGL_NO_CONTEXT;
    EGLContext context = eglCreateContext(display, config, sharedCtx, contextAttribs);
    if (context == EGL_NO_CONTEXT)
    {
        err() << "[EaglContext] eglCreateContext (pbuffer) failed (0x"
              << std::hex << eglGetError() << ")" << std::endl;
        return;
    }
    m_context = context;

    EGLint pbufferAttribs[] = {
        EGL_WIDTH,  static_cast<EGLint>(width),
        EGL_HEIGHT, static_cast<EGLint>(height),
        EGL_NONE
    };
    m_surface = eglCreatePbufferSurface(display, config, pbufferAttribs);
}


////////////////////////////////////////////////////////////
EaglContext::~EaglContext()
{
    cleanupUnsharedResources();

    EGLDisplay display = static_cast<EGLDisplay>(m_display);
    EGLContext context = static_cast<EGLContext>(m_context);
    EGLSurface surface = static_cast<EGLSurface>(m_surface);

    if (display != EGL_NO_DISPLAY)
    {
        if (eglGetCurrentContext() == context)
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

        if (surface != EGL_NO_SURFACE)
            eglDestroySurface(display, surface);
        if (context != EGL_NO_CONTEXT)
            eglDestroyContext(display, context);
    }
}


////////////////////////////////////////////////////////////
GlFunctionPointer EaglContext::getFunction(const char* name)
{
    return reinterpret_cast<GlFunctionPointer>(eglGetProcAddress(name));
}


////////////////////////////////////////////////////////////
void EaglContext::recreateRenderBuffers(SFView* glView)
{
    if (!glView)
        return;

    // Only hand the view over. UIKit calls this from layoutSubviews on
    // the main thread, and the surface swap has to happen on the thread
    // that owns the context. display() picks this up.
    Lock lock(m_pendingMutex);
    m_pendingView = (__bridge void*)glView;
}


////////////////////////////////////////////////////////////
void EaglContext::replaceSurface(void* view)
{
    EGLDisplay display = static_cast<EGLDisplay>(m_display);
    EGLConfig  config  = static_cast<EGLConfig>(m_config);
    EGLContext context = static_cast<EGLContext>(m_context);
    SFView*    glView  = (__bridge SFView*)view;

    // ANGLE gives one window surface per layer, so the old surface has
    // to go before the new one can exist. Creating first answers
    // EGL_BAD_ALLOC. Releasing and destroying it from the main thread
    // instead leaves this thread holding a handle eglMakeCurrent then
    // refuses, and every later eglSwapBuffers answers EGL_BAD_SURFACE.
    // Both were measured on the simulator. Only this thread has the
    // surface current, so only this thread can do the swap.
    EGLSurface oldSurface = static_cast<EGLSurface>(m_surface);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (oldSurface != EGL_NO_SURFACE)
        eglDestroySurface(display, oldSurface);
    m_surface = EGL_NO_SURFACE;

    // Same main-thread rule as the first creation above.
    __block EGLSurface surface = EGL_NO_SURFACE;
    void (^create)(void) = ^{
        EGLNativeWindowType nativeWindow = (__bridge EGLNativeWindowType)glView.layer;
        surface = eglCreateWindowSurface(display, config, nativeWindow, nullptr);
    };
    if ([NSThread isMainThread])
        create();
    else
        dispatch_sync(dispatch_get_main_queue(), create);

    if (surface == EGL_NO_SURFACE)
    {
        err() << "[EaglContext] eglCreateWindowSurface (recreate) failed (0x"
              << std::hex << eglGetError() << std::dec << ")" << std::endl;
        return;
    }
    m_surface = surface;

    if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE)
        err() << "[EaglContext] eglMakeCurrent on the new surface failed (0x"
              << std::hex << eglGetError() << std::dec << ")" << std::endl;
}


////////////////////////////////////////////////////////////
bool EaglContext::makeCurrent(bool current)
{
    EGLDisplay display = static_cast<EGLDisplay>(m_display);
    if (display == EGL_NO_DISPLAY)
    {
        static bool warnedNoDisplay = false;
        if (!warnedNoDisplay)
        {
            warnedNoDisplay = true;
            err() << "[EaglContext] makeCurrent: m_display is EGL_NO_DISPLAY"
                  << std::endl;
        }
        return false;
    }

    if (current)
    {
        EGLSurface surface = static_cast<EGLSurface>(m_surface);
        EGLContext context = static_cast<EGLContext>(m_context);
        if (eglMakeCurrent(display, surface, surface, context) == EGL_TRUE)
            return true;

        // mkxp-ios: log the actual EGL error code on first failure
        // so we can distinguish bad surface vs bad context vs not
        // current thread vs surface-was-destroyed cases. After the
        // first time we just log nothing — the SFML render loop
        // calls us 60+ times a second.
        static bool warnedActivateFail = false;
        if (!warnedActivateFail)
        {
            warnedActivateFail = true;
            err() << "[EaglContext] makeCurrent(true) eglMakeCurrent failed (0x"
                  << std::hex << eglGetError() << std::dec
                  << "); surface=" << (surface == EGL_NO_SURFACE ? "no" : "yes")
                  << " context=" << (context == EGL_NO_CONTEXT ? "no" : "yes")
                  << std::endl;
        }
        return false;
    }

    return eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) == EGL_TRUE;
}


////////////////////////////////////////////////////////////
void EaglContext::display()
{
    EGLDisplay display = static_cast<EGLDisplay>(m_display);

    void* pendingView = nullptr;
    {
        Lock lock(m_pendingMutex);
        pendingView = m_pendingView;
        m_pendingView = nullptr;
    }
    if (pendingView)
        replaceSurface(pendingView);

    EGLSurface surface = static_cast<EGLSurface>(m_surface);
    if (display == EGL_NO_DISPLAY || surface == EGL_NO_SURFACE)
    {
        static bool warnedNoSurface = false;
        if (!warnedNoSurface)
        {
            warnedNoSurface = true;
            err() << "[EaglContext] display: skipping eglSwapBuffers; "
                  << "display=" << (display == EGL_NO_DISPLAY ? "no" : "yes")
                  << " surface=" << (surface == EGL_NO_SURFACE ? "no" : "yes")
                  << std::endl;
        }
        return;
    }

    // Report the first failure of a run and the recovery that ends it.
    // A single failure across a resize is normal. A count that never
    // stops growing is the black screen this file used to have, and
    // only the recovery line tells the two apart.
    static unsigned swapFailures = 0;
    if (eglSwapBuffers(display, surface) != EGL_TRUE)
    {
        if (swapFailures++ == 0)
            err() << "[EaglContext] eglSwapBuffers failed (0x"
                  << std::hex << eglGetError() << std::dec << ")" << std::endl;
    }
    else if (swapFailures > 0)
    {
        err() << "[EaglContext] eglSwapBuffers recovered after " << swapFailures
              << " failures" << std::endl;
        swapFailures = 0;
    }


    // CADisplayLink would be the proper iOS v-sync, but mirroring
    // the original EAGL implementation we fake it with a frame-rate
    // limit. ANGLE-on-Metal has its own pacing too, so the
    // sleep+clock dance below is mostly a safety net.
    if (m_vsyncEnabled)
    {
        static const Time frameDuration = seconds(1.f / 60.f);
        sleep(frameDuration - m_clock.getElapsedTime());
        m_clock.restart();
    }
}


////////////////////////////////////////////////////////////
void EaglContext::setVerticalSyncEnabled(bool enabled)
{
    m_vsyncEnabled = enabled;
    EGLDisplay display = static_cast<EGLDisplay>(m_display);
    if (display != EGL_NO_DISPLAY)
        eglSwapInterval(display, enabled ? 1 : 0);
}


////////////////////////////////////////////////////////////
void EaglContext::createContext(EaglContext* /* shared */,
                                const WindowImplUIKit* /* window */,
                                unsigned int /* bitsPerPixel */,
                                const ContextSettings& /* settings */)
{
    // Folded into the constructors above; left in place so
    // EaglContext.hpp's private declaration stays valid even if a
    // future SFML re-merge re-introduces a delegating call site.
}

} // namespace priv

} // namespace sf
