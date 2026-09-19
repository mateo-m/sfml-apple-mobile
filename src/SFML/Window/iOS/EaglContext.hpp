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

#ifndef SFML_EAGLCONTEXT_HPP
#define SFML_EAGLCONTEXT_HPP

////////////////////////////////////////////////////////////
// Headers
////////////////////////////////////////////////////////////
#include <SFML/Window/GlContext.hpp>
#include <SFML/Window/iOS/ObjCType.hpp>
#include <SFML/System/Vector2.hpp>
#include <SFML/System/Clock.hpp>
#include <SFML/System/Mutex.hpp>


SFML_DECLARE_OBJC_CLASS(SFView);

namespace sf
{
namespace priv
{
class WindowImplUIKit;

////////////////////////////////////////////////////////////
/// \brief iOS implementation of OpenGL contexts via ANGLE/EGL
///
/// Class kept named EaglContext for source compatibility with
/// SFML's GlContext factory in GlContext.cpp; the implementation
/// has been swapped from Apple's deprecated EAGL framework over
/// to ANGLE's EGL (which translates GLES2 calls to Metal under
/// the hood). The same SFML render code paths now work without
/// EAGL/CAEAGLLayer / OpenGLES.framework, which Apple has been
/// signalling will be removed.
///
////////////////////////////////////////////////////////////
class EaglContext : public GlContext
{
public:

    ////////////////////////////////////////////////////////////
    /// \brief Create a new context, not associated to a window
    ///
    /// \param shared Context to share the new one with (can be NULL)
    ///
    ////////////////////////////////////////////////////////////
    EaglContext(EaglContext* shared);

    ////////////////////////////////////////////////////////////
    /// \brief Create a new context attached to a window
    ///
    /// \param shared       Context to share the new one with
    /// \param settings     Creation parameters
    /// \param owner        Pointer to the owner window
    /// \param bitsPerPixel Pixel depth, in bits per pixel
    ///
    ////////////////////////////////////////////////////////////
    EaglContext(EaglContext* shared, const ContextSettings& settings,
                const WindowImpl* owner, unsigned int bitsPerPixel);

    ////////////////////////////////////////////////////////////
    /// \brief Create a new context that embeds its own rendering target
    ///
    /// \param shared   Context to share the new one with
    /// \param settings Creation parameters
    /// \param width    Back buffer width, in pixels
    /// \param height   Back buffer height, in pixels
    ///
    ////////////////////////////////////////////////////////////
    EaglContext(EaglContext* shared, const ContextSettings& settings,
                unsigned int width, unsigned int height);

    ////////////////////////////////////////////////////////////
    /// \brief Destructor
    ///
    ////////////////////////////////////////////////////////////
    ~EaglContext();

    ////////////////////////////////////////////////////////////
    /// \brief Get the address of an OpenGL function
    ///
    /// \param name Name of the function to get the address of
    ///
    /// \return Address of the OpenGL function, 0 on failure
    ///
    ////////////////////////////////////////////////////////////
    static GlFunctionPointer getFunction(const char* name);

    ////////////////////////////////////////////////////////////
    /// \brief Recreate the render buffers of the context
    ///
    /// This function must be called whenever the containing view
    /// changes (typically after an orientation change)
    ///
    /// \param glView: Container of the context
    ///
    ////////////////////////////////////////////////////////////
    void recreateRenderBuffers(SFView* glView);

    ////////////////////////////////////////////////////////////
    /// \brief Display what has been rendered to the context so far
    ///
    ////////////////////////////////////////////////////////////
    virtual void display();

    ////////////////////////////////////////////////////////////
    /// \brief Enable or disable vertical synchronization
    ///
    /// Activating vertical synchronization will limit the number
    /// of frames displayed to the refresh rate of the monitor.
    /// This can avoid some visual artifacts, and limit the framerate
    /// to a good value (but not constant across different computers).
    ///
    /// \param enabled: True to enable v-sync, false to deactivate
    ///
    ////////////////////////////////////////////////////////////
    virtual void setVerticalSyncEnabled(bool enabled);

protected:

    ////////////////////////////////////////////////////////////
    /// \brief Activate the context as the current target
    ///        for rendering
    ///
    /// \param current Whether to make the context current or no longer current
    ///
    /// \return True on success, false if any error happened
    ///
    ////////////////////////////////////////////////////////////
    virtual bool makeCurrent(bool current);

private:

    ////////////////////////////////////////////////////////////
    /// \brief Create the context
    ///
    /// \param shared       Context to share the new one with (can be NULL)
    /// \param window       Window to attach the context to (can be NULL)
    /// \param bitsPerPixel Pixel depth, in bits per pixel
    /// \param settings     Creation parameters
    ///
    ////////////////////////////////////////////////////////////
    void createContext(EaglContext* shared,
                       const WindowImplUIKit* window,
                       unsigned int bitsPerPixel,
                       const ContextSettings& settings);

    ////////////////////////////////////////////////////////////
    // Member data
    ////////////////////////////////////////////////////////////
    /// \brief Replace the window surface, on the thread that owns the
    ///        context
    ///
    /// \param view The SFView whose layer backs the new surface
    ///
    ////////////////////////////////////////////////////////////
    void replaceSurface(void* view);

    ////////////////////////////////////////////////////////////
    // Opaque void*s here so this header doesn't pull in EGL/egl.h
    // (whose typedef set conflicts with SFML's bundled glad/egl.h
    // when both end up in the same translation unit). The .mm file
    // casts these to EGLDisplay/EGLContext/EGLSurface/EGLConfig.
    void* m_display;        ///< EGLDisplay (process-shared, from ANGLE)
    void* m_context;        ///< EGLContext owned by this object
    void* m_surface;        ///< EGLSurface (window or pbuffer)
    void* m_config;         ///< EGLConfig the context was created with

    ////////////////////////////////////////////////////////////
    // recreateRenderBuffers runs on the main thread, but the whole
    // surface swap has to run on the thread that owns the context. It
    // leaves the view here and display() does the work.
    void* m_pendingView;     ///< SFView whose layer needs a new surface
    Mutex m_pendingMutex;
    bool  m_vsyncEnabled;   ///< Vertical sync activation flag
    Clock m_clock;          ///< Measures the elapsed time for the fake v-sync implementation
};

} // namespace priv

} // namespace sf

#endif // SFML_EAGLCONTEXT_HPP
