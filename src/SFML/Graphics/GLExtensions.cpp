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
#include <SFML/Graphics/GLExtensions.hpp>
#include <SFML/Graphics/GLES1Emu.hpp>
#include <SFML/Window/Context.hpp>
#include <SFML/System/Err.hpp>

// We check for this definition in order to avoid multiple definitions of GLAD
// entities during unity builds of SFML.
#ifndef SF_GLAD_GL_IMPLEMENTATION_INCLUDED
#define SF_GLAD_GL_IMPLEMENTATION_INCLUDED
#define SF_GLAD_GL_IMPLEMENTATION
#include <glad/gl.h>
#endif

#if !defined(GL_MAJOR_VERSION)
    #define GL_MAJOR_VERSION 0x821B
#endif

#if !defined(GL_MINOR_VERSION)
    #define GL_MINOR_VERSION 0x821C
#endif


namespace sf
{
namespace priv
{
////////////////////////////////////////////////////////////
void ensureExtensionsInit()
{
    static bool initialized = false;
    if (!initialized)
    {
        initialized = true;

#ifdef SFML_OPENGL_ES
        gladLoadGLES1(reinterpret_cast<GLADloadfunc>(sf::Context::getFunction));

        // mkxp-ios: gladLoadGLES1 populates ES 1.1 entry points only.
        // ANGLE's libGLESv2 exports the core ES2+ framebuffer functions
        // (glGenFramebuffers, glBindFramebuffer, glReadPixels via FBO,
        // ...) but NOT their OES_framebuffer_object aliases that
        // SFML's GLEXT_* macros expand to on iOS. Manually alias the
        // OES function pointers to the core ones via the same
        // sf::Context::getFunction loader so SFML's
        // `Texture::copyToImage`, `RenderTextureImplFBO::createFrameBuffer`,
        // and friends find a real entry point at runtime instead of
        // dereferencing the NULL slot left behind by the ES1 loader.
        auto load = [](const char* name) {
            return reinterpret_cast<void*>(sf::Context::getFunction(name));
        };
        if (auto p = load("glGenFramebuffers"))
            sf_glad_glGenFramebuffersOES = reinterpret_cast<PFNGLGENFRAMEBUFFERSOESPROC>(p);
        if (auto p = load("glBindFramebuffer"))
            sf_glad_glBindFramebufferOES = reinterpret_cast<PFNGLBINDFRAMEBUFFEROESPROC>(p);
        if (auto p = load("glDeleteFramebuffers"))
            sf_glad_glDeleteFramebuffersOES = reinterpret_cast<PFNGLDELETEFRAMEBUFFERSOESPROC>(p);
        if (auto p = load("glCheckFramebufferStatus"))
            sf_glad_glCheckFramebufferStatusOES = reinterpret_cast<PFNGLCHECKFRAMEBUFFERSTATUSOESPROC>(p);
        if (auto p = load("glFramebufferTexture2D"))
            sf_glad_glFramebufferTexture2DOES = reinterpret_cast<PFNGLFRAMEBUFFERTEXTURE2DOESPROC>(p);
        if (auto p = load("glFramebufferRenderbuffer"))
            sf_glad_glFramebufferRenderbufferOES = reinterpret_cast<PFNGLFRAMEBUFFERRENDERBUFFEROESPROC>(p);
        if (auto p = load("glGenRenderbuffers"))
            sf_glad_glGenRenderbuffersOES = reinterpret_cast<PFNGLGENRENDERBUFFERSOESPROC>(p);
        if (auto p = load("glBindRenderbuffer"))
            sf_glad_glBindRenderbufferOES = reinterpret_cast<PFNGLBINDRENDERBUFFEROESPROC>(p);
        if (auto p = load("glDeleteRenderbuffers"))
            sf_glad_glDeleteRenderbuffersOES = reinterpret_cast<PFNGLDELETERENDERBUFFERSOESPROC>(p);
        if (auto p = load("glRenderbufferStorage"))
            sf_glad_glRenderbufferStorageOES = reinterpret_cast<PFNGLRENDERBUFFERSTORAGEOESPROC>(p);
        if (auto p = load("glGenerateMipmap"))
            sf_glad_glGenerateMipmapOES = reinterpret_cast<PFNGLGENERATEMIPMAPOESPROC>(p);

        // mkxp-ios: ANGLE-on-Metal advertises GLES2 / EGL_KHR_image
        // etc., NOT the GLES1-era GL_OES_framebuffer_object extension
        // string. SFML's `RenderTextureImplFBO::isAvailable()` keys
        // off `SF_GLAD_GL_OES_framebuffer_object`, which glad parses
        // from the extension list, so it's 0 here even though the
        // core GLES2 FBO entry points are fully functional (we just
        // aliased them above). Without this, every sf::RenderTexture
        // falls back to `RenderTextureImplDefault`, which spins up an
        // offscreen pbuffer context, draws into it, and copies pixels
        // back via glCopyTexSubImage2D. PSDK uses RTs heavily; the
        // fallback path renders correctly into the pbuffer but the
        // copy lands in a tiny (320x240) corner of the user-visible
        // framebuffer because glViewport was set for the pbuffer
        // size. Forcing the flag here keeps SFML on its (working)
        // FBO path.
        SF_GLAD_GL_OES_framebuffer_object = 1;

        // mkxp-ios: install our GLES1 fixed-function emulator on top
        // of the active GLES2 context. ANGLE's own GLES1-on-Metal
        // emulator crashes during the first FBO setup; we sidestep
        // it by intercepting SFML's glad pointers and re-implementing
        // the handful of fixed-function calls SFML actually uses.
        installGLES1Emu();
#else
        gladLoadGL(reinterpret_cast<GLADloadfunc>(sf::Context::getFunction));
#endif

        // Retrieve the context version number
        int majorVersion = 0;
        int minorVersion = 0;

        // Try the new way first
        glGetIntegerv(GL_MAJOR_VERSION, &majorVersion);
        glGetIntegerv(GL_MINOR_VERSION, &minorVersion);

        if (glGetError() == GL_INVALID_ENUM)
        {
            // Try the old way
            const GLubyte* version = glGetString(GL_VERSION);
            if (version)
            {
                // The beginning of the returned string is "major.minor" (this is standard)
                majorVersion = version[0] - '0';
                minorVersion = version[2] - '0';
            }
            else
            {
                // Can't get the version number, assume 1.1
                majorVersion = 1;
                minorVersion = 1;
            }
        }

        if ((majorVersion < 1) || ((majorVersion == 1) && (minorVersion < 1)))
        {
            err() << "sfml-graphics requires support for OpenGL 1.1 or greater" << std::endl;
            err() << "Ensure that hardware acceleration is enabled if available" << std::endl;
        }
    }
}

} // namespace priv

} // namespace sf
