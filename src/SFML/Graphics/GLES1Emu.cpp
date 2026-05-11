////////////////////////////////////////////////////////////
// GLES1 fixed-function emulation atop GLES2.
//
// Hooks into SFML's glad function pointer table after
// gladLoadGLES1 so we can re-implement glVertexPointer,
// glMatrixMode, glDrawArrays, etc. on top of a single
// position+color+texcoord shader. SFML source is unmodified;
// only GLExtensions.cpp invokes installGLES1Emu().
//
// The emulator owns:
// - one program (compiled lazily)
// - two 4x4 matrix stacks (modelview, projection)
// - three client-side vertex pointer descriptors (vertex,
//   color, texCoord0)
// - state flags for GL_TEXTURE_2D enable + current GL_COLOR_ARRAY
//   enable (used as a uniform so the shader can choose per-vertex
//   color vs glColor4f current color)
//
// Shader uniforms:
//   uniform mat4  u_mvp;
//   uniform int   u_useTexture;     // 1 = sample texture, 0 = ignore
//   uniform int   u_useColorArray;  // 1 = use a_color attrib, 0 = u_color
//   uniform vec4  u_color;          // glColor4f current
//   uniform sampler2D u_texture;
//
// Shader attribs:
//   layout(0) attribute vec2 a_position;
//   layout(1) attribute vec4 a_color;
//   layout(2) attribute vec2 a_texCoord;
//
// Caveats:
// - Only GL_FLOAT vertex/texcoord data with stride > 0 is
//   supported (matches every site SFML calls glVertexPointer
//   from). glColorPointer is restricted to GL_UNSIGNED_BYTE.
// - GL_LIGHTING / GL_ALPHA_TEST / GL_TEXTURE_2D enable/disable
//   are swallowed (don't exist in GLES2).
////////////////////////////////////////////////////////////

#include <SFML/Graphics/GLES1Emu.hpp>
#include <SFML/Window/Context.hpp>
#include <SFML/System/Err.hpp>

#include <glad/gl.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#ifndef GL_FRAGMENT_SHADER
#define GL_FRAGMENT_SHADER 0x8B30
#endif
#ifndef GL_VERTEX_SHADER
#define GL_VERTEX_SHADER 0x8B31
#endif
#ifndef GL_COMPILE_STATUS
#define GL_COMPILE_STATUS 0x8B81
#endif
#ifndef GL_LINK_STATUS
#define GL_LINK_STATUS 0x8B82
#endif

namespace {

////////////////////////////////////////////////////////////
// 4x4 column-major matrix utilities. Layout matches OpenGL.
////////////////////////////////////////////////////////////
struct Mat4 {
    float m[16];

    static Mat4 identity() {
        Mat4 r;
        std::memset(r.m, 0, sizeof(r.m));
        r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1.0f;
        return r;
    }

    static Mat4 multiply(const Mat4& a, const Mat4& b) {
        Mat4 r;
        for (int col = 0; col < 4; ++col) {
            for (int row = 0; row < 4; ++row) {
                float sum = 0.0f;
                for (int k = 0; k < 4; ++k) {
                    sum += a.m[row + k * 4] * b.m[k + col * 4];
                }
                r.m[row + col * 4] = sum;
            }
        }
        return r;
    }
};

////////////////////////////////////////////////////////////
// Captured GLES2 entry points we resolve via eglGetProcAddress
// (gladLoadGLES1 only loaded ES1.1 entries).
////////////////////////////////////////////////////////////
struct GLES2Fns {
    typedef unsigned int (*PFN_create_shader)(unsigned int);
    typedef void (*PFN_shader_source)(unsigned int, int, const char* const*, const int*);
    typedef void (*PFN_compile_shader)(unsigned int);
    typedef void (*PFN_get_shader_iv)(unsigned int, unsigned int, int*);
    typedef void (*PFN_get_shader_info_log)(unsigned int, int, int*, char*);
    typedef unsigned int (*PFN_create_program)();
    typedef void (*PFN_attach_shader)(unsigned int, unsigned int);
    typedef void (*PFN_bind_attrib_location)(unsigned int, unsigned int, const char*);
    typedef void (*PFN_link_program)(unsigned int);
    typedef void (*PFN_get_program_iv)(unsigned int, unsigned int, int*);
    typedef void (*PFN_get_program_info_log)(unsigned int, int, int*, char*);
    typedef void (*PFN_use_program)(unsigned int);
    typedef void (*PFN_delete_shader)(unsigned int);
    typedef int  (*PFN_get_uniform_location)(unsigned int, const char*);
    typedef void (*PFN_uniform_1i)(int, int);
    typedef void (*PFN_uniform_4fv)(int, int, const float*);
    typedef void (*PFN_uniform_matrix_4fv)(int, int, unsigned char, const float*);
    typedef void (*PFN_vertex_attrib_pointer)(unsigned int, int, unsigned int, unsigned char, int, const void*);
    typedef void (*PFN_enable_vertex_attrib_array)(unsigned int);
    typedef void (*PFN_disable_vertex_attrib_array)(unsigned int);
    typedef void (*PFN_vertex_attrib_4fv)(unsigned int, const float*);
    typedef void (*PFN_active_texture)(unsigned int);
    typedef void (*PFN_bind_buffer)(unsigned int, unsigned int);
    typedef unsigned char (*PFN_is_program)(unsigned int);

    PFN_create_shader              createShader              = nullptr;
    PFN_shader_source              shaderSource              = nullptr;
    PFN_compile_shader             compileShader             = nullptr;
    PFN_get_shader_iv              getShaderiv               = nullptr;
    PFN_get_shader_info_log        getShaderInfoLog          = nullptr;
    PFN_create_program             createProgram             = nullptr;
    PFN_attach_shader              attachShader              = nullptr;
    PFN_bind_attrib_location       bindAttribLocation        = nullptr;
    PFN_link_program               linkProgram               = nullptr;
    PFN_get_program_iv             getProgramiv              = nullptr;
    PFN_get_program_info_log       getProgramInfoLog         = nullptr;
    PFN_use_program                useProgram                = nullptr;
    PFN_delete_shader              deleteShader              = nullptr;
    PFN_get_uniform_location       getUniformLocation        = nullptr;
    PFN_uniform_1i                 uniform1i                 = nullptr;
    PFN_uniform_4fv                uniform4fv                = nullptr;
    PFN_uniform_matrix_4fv         uniformMatrix4fv          = nullptr;
    PFN_vertex_attrib_pointer      vertexAttribPointer       = nullptr;
    PFN_enable_vertex_attrib_array enableVertexAttribArray   = nullptr;
    PFN_disable_vertex_attrib_array disableVertexAttribArray = nullptr;
    PFN_vertex_attrib_4fv          vertexAttrib4fv           = nullptr;
    PFN_active_texture             activeTexture             = nullptr;
    PFN_bind_buffer                bindBuffer                = nullptr;
    PFN_is_program                 isProgram                 = nullptr;

    bool ready = false;
};

////////////////////////////////////////////////////////////
// Vertex pointer descriptor.
////////////////////////////////////////////////////////////
struct VertexArray {
    int           size    = 0;
    unsigned int  type    = 0;
    int           stride  = 0;
    const void*   pointer = nullptr;
    bool          enabled = false;
};

constexpr unsigned int kAttribPosition = 0;
constexpr unsigned int kAttribColor    = 1;
constexpr unsigned int kAttribTexCoord = 2;

constexpr unsigned int GL_MODELVIEW_GLES1  = 0x1700;
constexpr unsigned int GL_PROJECTION_GLES1 = 0x1701;
// GL_TEXTURE matrix mode: SFML's Texture::bind(Pixels) loads a
// scale matrix here to convert pixel texCoords into normalised
// [0,1] sampling coords. We maintain it as a separate stack and
// upload it as u_texMatrix so our shader can do the same.
constexpr unsigned int GL_TEXTURE_GLES1    = 0x1702;
constexpr unsigned int GL_VERTEX_ARRAY_GLES1        = 0x8074;
constexpr unsigned int GL_COLOR_ARRAY_GLES1         = 0x8076;
constexpr unsigned int GL_TEXTURE_COORD_ARRAY_GLES1 = 0x8078;
constexpr unsigned int GL_NORMAL_ARRAY_GLES1        = 0x8075;

struct State {
    GLES2Fns fns;

    unsigned int program     = 0;
    int          locMvp       = -1;
    int          locTexMatrix = -1;
    int          locUseTex    = -1;
    int          locUseColor  = -1;
    int          locColor     = -1;
    int          locSampler   = -1;

    std::vector<Mat4> modelview;
    std::vector<Mat4> projection;
    std::vector<Mat4> texture;
    unsigned int      matrixMode = GL_MODELVIEW_GLES1;

    VertexArray vertexArr;
    VertexArray colorArr;
    VertexArray texCoordArr;

    float currentColor[4] = {1.f, 1.f, 1.f, 1.f};
    bool  textureEnabled  = false;

    // Saved real entry points (so emuDrawArrays can call ANGLE's draw)
    PFNGLDRAWARRAYSPROC   realDrawArrays   = nullptr;
    PFNGLDRAWELEMENTSPROC realDrawElements = nullptr;
    PFNGLENABLEPROC       realEnable       = nullptr;
    PFNGLDISABLEPROC      realDisable      = nullptr;

    bool installed = false;
};

State& state() {
    static State s;
    return s;
}

void* loadProc(const char* name) {
    return reinterpret_cast<void*>(sf::Context::getFunction(name));
}

void loadGLES2Fns(GLES2Fns& f) {
    f.createShader            = reinterpret_cast<GLES2Fns::PFN_create_shader>(loadProc("glCreateShader"));
    f.shaderSource            = reinterpret_cast<GLES2Fns::PFN_shader_source>(loadProc("glShaderSource"));
    f.compileShader           = reinterpret_cast<GLES2Fns::PFN_compile_shader>(loadProc("glCompileShader"));
    f.getShaderiv             = reinterpret_cast<GLES2Fns::PFN_get_shader_iv>(loadProc("glGetShaderiv"));
    f.getShaderInfoLog        = reinterpret_cast<GLES2Fns::PFN_get_shader_info_log>(loadProc("glGetShaderInfoLog"));
    f.createProgram           = reinterpret_cast<GLES2Fns::PFN_create_program>(loadProc("glCreateProgram"));
    f.attachShader            = reinterpret_cast<GLES2Fns::PFN_attach_shader>(loadProc("glAttachShader"));
    f.bindAttribLocation      = reinterpret_cast<GLES2Fns::PFN_bind_attrib_location>(loadProc("glBindAttribLocation"));
    f.linkProgram             = reinterpret_cast<GLES2Fns::PFN_link_program>(loadProc("glLinkProgram"));
    f.getProgramiv            = reinterpret_cast<GLES2Fns::PFN_get_program_iv>(loadProc("glGetProgramiv"));
    f.getProgramInfoLog       = reinterpret_cast<GLES2Fns::PFN_get_program_info_log>(loadProc("glGetProgramInfoLog"));
    f.useProgram              = reinterpret_cast<GLES2Fns::PFN_use_program>(loadProc("glUseProgram"));
    f.deleteShader            = reinterpret_cast<GLES2Fns::PFN_delete_shader>(loadProc("glDeleteShader"));
    f.getUniformLocation      = reinterpret_cast<GLES2Fns::PFN_get_uniform_location>(loadProc("glGetUniformLocation"));
    f.uniform1i               = reinterpret_cast<GLES2Fns::PFN_uniform_1i>(loadProc("glUniform1i"));
    f.uniform4fv              = reinterpret_cast<GLES2Fns::PFN_uniform_4fv>(loadProc("glUniform4fv"));
    f.uniformMatrix4fv        = reinterpret_cast<GLES2Fns::PFN_uniform_matrix_4fv>(loadProc("glUniformMatrix4fv"));
    f.vertexAttribPointer     = reinterpret_cast<GLES2Fns::PFN_vertex_attrib_pointer>(loadProc("glVertexAttribPointer"));
    f.enableVertexAttribArray = reinterpret_cast<GLES2Fns::PFN_enable_vertex_attrib_array>(loadProc("glEnableVertexAttribArray"));
    f.disableVertexAttribArray = reinterpret_cast<GLES2Fns::PFN_disable_vertex_attrib_array>(loadProc("glDisableVertexAttribArray"));
    f.vertexAttrib4fv         = reinterpret_cast<GLES2Fns::PFN_vertex_attrib_4fv>(loadProc("glVertexAttrib4fv"));
    f.activeTexture           = reinterpret_cast<GLES2Fns::PFN_active_texture>(loadProc("glActiveTexture"));
    f.bindBuffer              = reinterpret_cast<GLES2Fns::PFN_bind_buffer>(loadProc("glBindBuffer"));
    f.isProgram               = reinterpret_cast<GLES2Fns::PFN_is_program>(loadProc("glIsProgram"));

    f.ready =
        f.createShader && f.shaderSource && f.compileShader && f.createProgram &&
        f.attachShader && f.bindAttribLocation && f.linkProgram && f.useProgram &&
        f.getUniformLocation && f.uniform1i && f.uniform4fv && f.uniformMatrix4fv &&
        f.vertexAttribPointer && f.enableVertexAttribArray && f.disableVertexAttribArray &&
        f.bindBuffer;
}

const char* kVertexShader =
    "attribute vec2 a_position;\n"
    "attribute vec4 a_color;\n"
    "attribute vec2 a_texCoord;\n"
    "uniform mat4 u_mvp;\n"
    "uniform mat4 u_texMatrix;\n"
    "uniform int  u_useColorArray;\n"
    "uniform vec4 u_color;\n"
    "varying vec4 v_color;\n"
    "varying vec2 v_texCoord;\n"
    "void main() {\n"
    "    gl_Position = u_mvp * vec4(a_position, 0.0, 1.0);\n"
    "    v_color = (u_useColorArray == 1) ? a_color : u_color;\n"
    "    v_texCoord = (u_texMatrix * vec4(a_texCoord, 0.0, 1.0)).xy;\n"
    "}\n";

const char* kFragmentShader =
    "precision mediump float;\n"
    "varying vec4 v_color;\n"
    "varying vec2 v_texCoord;\n"
    "uniform int u_useTexture;\n"
    "uniform sampler2D u_texture;\n"
    "void main() {\n"
    "    if (u_useTexture == 1) {\n"
    "        gl_FragColor = texture2D(u_texture, v_texCoord) * v_color;\n"
    "    } else {\n"
    "        gl_FragColor = v_color;\n"
    "    }\n"
    "}\n";

unsigned int compileShader(GLES2Fns& f, unsigned int type, const char* source) {
    unsigned int sh = f.createShader(type);
    f.shaderSource(sh, 1, &source, nullptr);
    f.compileShader(sh);
    int ok = 0;
    f.getShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024] = {0};
        f.getShaderInfoLog(sh, sizeof(log) - 1, nullptr, log);
        sf::err() << "[GLES1Emu] shader compile failed: " << log << std::endl;
        f.deleteShader(sh);
        return 0;
    }
    return sh;
}

bool ensureProgram(State& s) {
    // The EGL context can be torn down and recreated mid-process
    // (DisplayWindow.reload destroys the sf::Window). All GL handles
    // (program, shaders) live in the old context's namespace and are
    // dead in the new one. Validate via glIsProgram before reuse;
    // glIsProgram returns false for handles that don't exist in the
    // current context (including ones that were valid in a now-dead
    // context).
    if (s.program) {
        if (s.fns.isProgram && s.fns.isProgram(s.program)) return true;
        // Stale handle. Force a rebuild and invalidate uniform locs.
        s.program      = 0;
        s.locMvp       = -1;
        s.locTexMatrix = -1;
        s.locUseTex    = -1;
        s.locUseColor  = -1;
        s.locColor     = -1;
        s.locSampler   = -1;
    }
    if (!s.fns.ready) return false;

    unsigned int vs = compileShader(s.fns, GL_VERTEX_SHADER, kVertexShader);
    unsigned int fs = compileShader(s.fns, GL_FRAGMENT_SHADER, kFragmentShader);
    if (!vs || !fs) return false;

    s.program = s.fns.createProgram();
    s.fns.attachShader(s.program, vs);
    s.fns.attachShader(s.program, fs);
    s.fns.bindAttribLocation(s.program, kAttribPosition, "a_position");
    s.fns.bindAttribLocation(s.program, kAttribColor,    "a_color");
    s.fns.bindAttribLocation(s.program, kAttribTexCoord, "a_texCoord");
    s.fns.linkProgram(s.program);
    int ok = 0;
    s.fns.getProgramiv(s.program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024] = {0};
        s.fns.getProgramInfoLog(s.program, sizeof(log) - 1, nullptr, log);
        sf::err() << "[GLES1Emu] program link failed: " << log << std::endl;
        return false;
    }
    s.fns.deleteShader(vs);
    s.fns.deleteShader(fs);

    s.locMvp       = s.fns.getUniformLocation(s.program, "u_mvp");
    s.locTexMatrix = s.fns.getUniformLocation(s.program, "u_texMatrix");
    s.locUseTex    = s.fns.getUniformLocation(s.program, "u_useTexture");
    s.locUseColor  = s.fns.getUniformLocation(s.program, "u_useColorArray");
    s.locColor     = s.fns.getUniformLocation(s.program, "u_color");
    s.locSampler   = s.fns.getUniformLocation(s.program, "u_texture");
    return true;
}

Mat4& currentMatrix(State& s) {
    if (s.matrixMode == GL_PROJECTION_GLES1) return s.projection.back();
    if (s.matrixMode == GL_TEXTURE_GLES1)    return s.texture.back();
    return s.modelview.back();
}

////////////////////////////////////////////////////////////
// Emulated entry points (replace SFML's glad pointers).
////////////////////////////////////////////////////////////
extern "C" {

static void emuMatrixMode(unsigned int mode) { state().matrixMode = mode; }

static void emuLoadIdentity() { currentMatrix(state()) = Mat4::identity(); }

static void emuLoadMatrixf(const float* m) {
    std::memcpy(currentMatrix(state()).m, m, sizeof(float) * 16);
}

static void emuMultMatrixf(const float* m) {
    Mat4 incoming;
    std::memcpy(incoming.m, m, sizeof(incoming.m));
    Mat4& cur = currentMatrix(state());
    cur = Mat4::multiply(cur, incoming);
}

static void emuPushMatrix() {
    State& s = state();
    if      (s.matrixMode == GL_PROJECTION_GLES1) s.projection.push_back(s.projection.back());
    else if (s.matrixMode == GL_TEXTURE_GLES1)    s.texture.push_back(s.texture.back());
    else                                          s.modelview.push_back(s.modelview.back());
}

static void emuPopMatrix() {
    State& s = state();
    if (s.matrixMode == GL_PROJECTION_GLES1) {
        if (s.projection.size() > 1) s.projection.pop_back();
    } else if (s.matrixMode == GL_TEXTURE_GLES1) {
        if (s.texture.size() > 1) s.texture.pop_back();
    } else {
        if (s.modelview.size() > 1) s.modelview.pop_back();
    }
}

static void setArray(VertexArray& a, int size, unsigned int type, int stride, const void* ptr) {
    a.size = size; a.type = type; a.stride = stride; a.pointer = ptr;
}

static void emuVertexPointer(int size, unsigned int type, int stride, const void* ptr) {
    setArray(state().vertexArr, size, type, stride, ptr);
}
static void emuColorPointer(int size, unsigned int type, int stride, const void* ptr) {
    setArray(state().colorArr, size, type, stride, ptr);
}
static void emuTexCoordPointer(int size, unsigned int type, int stride, const void* ptr) {
    setArray(state().texCoordArr, size, type, stride, ptr);
}
static void emuNormalPointer(unsigned int /*type*/, int /*stride*/, const void* /*ptr*/) {
    // unused by SFML 2.x render path
}
static void emuClientActiveTexture(unsigned int /*texture*/) {
    // single-unit emulation: SFML only ever activates GL_TEXTURE0 here.
}

static void emuEnableClientState(unsigned int cap) {
    State& s = state();
    if      (cap == GL_VERTEX_ARRAY_GLES1)        s.vertexArr.enabled   = true;
    else if (cap == GL_COLOR_ARRAY_GLES1)         s.colorArr.enabled    = true;
    else if (cap == GL_TEXTURE_COORD_ARRAY_GLES1) s.texCoordArr.enabled = true;
    else if (cap == GL_NORMAL_ARRAY_GLES1)        { /* ignore */ }
}

static void emuDisableClientState(unsigned int cap) {
    State& s = state();
    if      (cap == GL_VERTEX_ARRAY_GLES1)        s.vertexArr.enabled   = false;
    else if (cap == GL_COLOR_ARRAY_GLES1)         s.colorArr.enabled    = false;
    else if (cap == GL_TEXTURE_COORD_ARRAY_GLES1) s.texCoordArr.enabled = false;
    else if (cap == GL_NORMAL_ARRAY_GLES1)        { /* ignore */ }
}

static bool isGLES1OnlyToggle(unsigned int cap) {
    // Caps that exist in GLES1 / desktop GL but NOT in GLES2; they
    // generate GL_INVALID_ENUM if forwarded to ANGLE on Metal.
    return cap == 0x0B50 /* GL_LIGHTING                  */
        || cap == 0x0BC0 /* GL_ALPHA_TEST                */
        || cap == 0x0DE1 /* GL_TEXTURE_2D enable bit     */
        || cap == 0x0B10 /* GL_POINT_SMOOTH              */
        || cap == 0x0B20 /* GL_LINE_SMOOTH               */
        || cap == 0x8DB9 /* GL_FRAMEBUFFER_SRGB (desktop) */
        || cap == 0x809D /* GL_MULTISAMPLE                */;
}

static void emuEnable(unsigned int cap) {
    if (cap == 0x0DE1) { state().textureEnabled = true; return; }
    if (isGLES1OnlyToggle(cap)) return;
    if (state().realEnable) state().realEnable(cap);
}

static void emuDisable(unsigned int cap) {
    if (cap == 0x0DE1) { state().textureEnabled = false; return; }
    if (isGLES1OnlyToggle(cap)) return;
    if (state().realDisable) state().realDisable(cap);
}

static void emuColor4f(float r, float g, float b, float a) {
    State& s = state();
    s.currentColor[0] = r; s.currentColor[1] = g;
    s.currentColor[2] = b; s.currentColor[3] = a;
}

static void emuColor4ub(unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    emuColor4f(r / 255.f, g / 255.f, b / 255.f, a / 255.f);
}

////////////////////////////////////////////////////////////
// The hot path. Compose mvp, bind program, set up vertex
// attribs from the saved client array descriptors, then
// dispatch to ANGLE's real glDrawArrays.
////////////////////////////////////////////////////////////
static void prepareDraw() {
    State& s = state();
    if (!ensureProgram(s)) return;

    s.fns.useProgram(s.program);

    // MKXP-IOS: SFML's iOS code submits vertex data via client-side
    // pointers (no VBO). The GLES2 spec says client-side pointers
    // are valid only when GL_ARRAY_BUFFER==0. If any SFML code path
    // (sf::VertexBuffer, sf::Shape's internal buffers) leaves a VBO
    // bound, client pointers get reinterpreted as offsets into that
    // VBO. Force the binding to 0 each draw so nothing upstream
    // wedges our attribute reads.
    s.fns.bindBuffer(0x8892 /* GL_ARRAY_BUFFER */, 0);

    Mat4 mvp = Mat4::multiply(s.projection.back(), s.modelview.back());
    s.fns.uniformMatrix4fv(s.locMvp, 1, 0 /* transpose=false */, mvp.m);
    s.fns.uniformMatrix4fv(s.locTexMatrix, 1, 0, s.texture.back().m);

    const int useTexture = (s.textureEnabled && s.texCoordArr.enabled) ? 1 : 0;
    s.fns.uniform1i(s.locUseTex,   useTexture);
    s.fns.uniform1i(s.locUseColor, s.colorArr.enabled ? 1 : 0);
    s.fns.uniform4fv(s.locColor, 1, s.currentColor);
    if (useTexture) s.fns.uniform1i(s.locSampler, 0);

    if (s.vertexArr.enabled && s.vertexArr.pointer) {
        s.fns.enableVertexAttribArray(kAttribPosition);
        s.fns.vertexAttribPointer(
            kAttribPosition, s.vertexArr.size, s.vertexArr.type,
            0 /* normalized */, s.vertexArr.stride, s.vertexArr.pointer);
    } else {
        s.fns.disableVertexAttribArray(kAttribPosition);
    }

    if (s.colorArr.enabled && s.colorArr.pointer) {
        s.fns.enableVertexAttribArray(kAttribColor);
        const unsigned char normalize = (s.colorArr.type == GL_UNSIGNED_BYTE) ? 1 : 0;
        s.fns.vertexAttribPointer(
            kAttribColor, s.colorArr.size, s.colorArr.type,
            normalize, s.colorArr.stride, s.colorArr.pointer);
    } else {
        s.fns.disableVertexAttribArray(kAttribColor);
        s.fns.vertexAttrib4fv(kAttribColor, s.currentColor);
    }

    if (s.texCoordArr.enabled && s.texCoordArr.pointer) {
        s.fns.enableVertexAttribArray(kAttribTexCoord);
        s.fns.vertexAttribPointer(
            kAttribTexCoord, s.texCoordArr.size, s.texCoordArr.type,
            0, s.texCoordArr.stride, s.texCoordArr.pointer);
    } else {
        s.fns.disableVertexAttribArray(kAttribTexCoord);
    }
}

static void emuDrawArrays(unsigned int mode, int first, int count) {
    prepareDraw();
    if (state().realDrawArrays) state().realDrawArrays(mode, first, count);
}

static void emuDrawElements(unsigned int mode, int count, unsigned int type, const void* indices) {
    prepareDraw();
    if (state().realDrawElements) state().realDrawElements(mode, count, type, indices);
}

} // extern "C"

} // namespace

namespace sf {
namespace priv {

void installGLES1Emu() {
    State& s = state();
    if (s.installed) return;

    s.modelview.push_back(Mat4::identity());
    s.projection.push_back(Mat4::identity());
    s.texture.push_back(Mat4::identity());

    loadGLES2Fns(s.fns);
    if (!s.fns.ready) {
        sf::err() << "[GLES1Emu] could not load required GLES2 entry points; emulation disabled" << std::endl;
        return;
    }

    // Snapshot ANGLE's real entry points before we overwrite the
    // glad slots with our intercepts. emuDrawArrays will dispatch
    // here once it has set up the shader and attribs.
    s.realDrawArrays   = sf_glad_glDrawArrays;
    s.realDrawElements = sf_glad_glDrawElements;
    s.realEnable       = sf_glad_glEnable;
    s.realDisable      = sf_glad_glDisable;

    sf_glad_glMatrixMode         = reinterpret_cast<PFNGLMATRIXMODEPROC>        (&emuMatrixMode);
    sf_glad_glLoadIdentity       = reinterpret_cast<PFNGLLOADIDENTITYPROC>      (&emuLoadIdentity);
    sf_glad_glLoadMatrixf        = reinterpret_cast<PFNGLLOADMATRIXFPROC>       (&emuLoadMatrixf);
    sf_glad_glMultMatrixf        = reinterpret_cast<PFNGLMULTMATRIXFPROC>       (&emuMultMatrixf);
    sf_glad_glPushMatrix         = reinterpret_cast<PFNGLPUSHMATRIXPROC>        (&emuPushMatrix);
    sf_glad_glPopMatrix          = reinterpret_cast<PFNGLPOPMATRIXPROC>         (&emuPopMatrix);

    sf_glad_glVertexPointer      = reinterpret_cast<PFNGLVERTEXPOINTERPROC>     (&emuVertexPointer);
    sf_glad_glColorPointer       = reinterpret_cast<PFNGLCOLORPOINTERPROC>      (&emuColorPointer);
    sf_glad_glTexCoordPointer    = reinterpret_cast<PFNGLTEXCOORDPOINTERPROC>   (&emuTexCoordPointer);
    sf_glad_glNormalPointer      = reinterpret_cast<PFNGLNORMALPOINTERPROC>     (&emuNormalPointer);
    sf_glad_glClientActiveTexture = reinterpret_cast<PFNGLCLIENTACTIVETEXTUREPROC>(&emuClientActiveTexture);
    sf_glad_glEnableClientState  = reinterpret_cast<PFNGLENABLECLIENTSTATEPROC> (&emuEnableClientState);
    sf_glad_glDisableClientState = reinterpret_cast<PFNGLDISABLECLIENTSTATEPROC>(&emuDisableClientState);

    sf_glad_glColor4f            = reinterpret_cast<PFNGLCOLOR4FPROC>           (&emuColor4f);
    sf_glad_glColor4ub           = reinterpret_cast<PFNGLCOLOR4UBPROC>          (&emuColor4ub);

    sf_glad_glDrawArrays         = reinterpret_cast<PFNGLDRAWARRAYSPROC>        (&emuDrawArrays);
    sf_glad_glDrawElements       = reinterpret_cast<PFNGLDRAWELEMENTSPROC>      (&emuDrawElements);

    sf_glad_glEnable             = reinterpret_cast<PFNGLENABLEPROC>            (&emuEnable);
    sf_glad_glDisable            = reinterpret_cast<PFNGLDISABLEPROC>           (&emuDisable);

    s.installed = true;
}

} // namespace priv
} // namespace sf
