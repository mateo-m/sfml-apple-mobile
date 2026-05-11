////////////////////////////////////////////////////////////
// SFML 2.x's iOS render path (`#ifdef SFML_OPENGL_ES`) uses
// the GLES1 fixed-function pipeline: glEnableClientState,
// glMatrixMode, glLoadMatrixf, glVertexPointer and friends.
// ANGLE's GLES1-on-Metal emulator exists in our prebuilt
// libraries but crashes on iOS sim during the first FBO
// setup (NULL deref inside ProgramExecutable::getUniformByIndex).
//
// Instead of fighting the emulator we keep our proven
// GLES2 EGL context and intercept SFML's fixed-function calls
// here. The shim re-implements just enough of GLES1 (vertex
// arrays + matrix stacks + a couple of enable toggles) on top
// of GLES2 by routing every glDrawArrays / glDrawElements
// through a stock shader that the shim owns.
//
// Hook installation overwrites SFML's glad-loaded function
// pointers (`sf_glad_glVertexPointer` etc.) so SFML itself
// needs no source changes.
////////////////////////////////////////////////////////////

#ifndef SFML_GLES1EMU_HPP
#define SFML_GLES1EMU_HPP

namespace sf {
namespace priv {

// Install our GLES1 fixed-function emulation atop the active
// GLES2 context. Must be called after gladLoadGLES1 so we can
// snapshot ANGLE's real glDrawArrays/glDrawElements before we
// overwrite the glad slots with our own intercepts. Idempotent.
void installGLES1Emu();

} // namespace priv
} // namespace sf

#endif // SFML_GLES1EMU_HPP
