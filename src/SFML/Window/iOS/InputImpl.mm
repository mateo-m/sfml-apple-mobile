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
#include <SFML/Window/iOS/InputImpl.hpp>
#include <SFML/Window/iOS/SFAppDelegate.hpp>
#include <SFML/Window/VideoMode.hpp>
#include <SFML/Window/Window.hpp>
#include <SFML/System/Err.hpp>

#include <array>
#include <atomic>


namespace
{
// mkxp-ios: synthetic key-state bitsets the host fills via the C
// shim below. Touchscreens have no physical keyboard so a polling
// caller like LiteRGSS / PSDK's `Sf::Keyboard.press?(key)` would
// otherwise always read `false`. The host's on-screen gamepad
// pushes presses + releases through `sfml_ios_inject_key` so the
// engine sees its directional pad / buttons as real key state.
//
// std::atomic<bool> elements: the host updates these from the main
// thread (UIKit touch handlers) while the engine reads them on its
// own thread (LiteRGSS worker, mkxp render thread). One atomic per
// slot keeps the read/write race trivially correct without a
// global lock that could starve the render loop.
std::array<std::atomic<bool>, sf::Keyboard::KeyCount> g_syntheticKeys{};
std::array<std::atomic<bool>, sf::Keyboard::Scan::ScancodeCount> g_syntheticScans{};
}


namespace sf
{
namespace priv
{
////////////////////////////////////////////////////////////
bool InputImpl::isKeyPressed(Keyboard::Key key)
{
    if (key < 0 || key >= Keyboard::KeyCount)
        return false;
    return g_syntheticKeys[static_cast<size_t>(key)].load(std::memory_order_acquire);
}

bool InputImpl::isKeyPressed(Keyboard::Scancode code)
{
    if (code < 0 || code >= Keyboard::Scan::ScancodeCount)
        return false;
    return g_syntheticScans[static_cast<size_t>(code)].load(std::memory_order_acquire);
}

Keyboard::Key InputImpl::localize(Keyboard::Scancode /* code */)
{
    // Not applicable
    return Keyboard::Unknown;
}

Keyboard::Scancode InputImpl::delocalize(Keyboard::Key /* key */)
{
    // Not applicable
    return Keyboard::Scan::Unknown;
}

String InputImpl::getDescription(Keyboard::Scancode /* code */)
{
    // Not applicable
    return "";
}

////////////////////////////////////////////////////////////
void InputImpl::setVirtualKeyboardVisible(bool visible)
{
    [[SFAppDelegate getInstance] setVirtualKeyboardVisible:visible];
}


////////////////////////////////////////////////////////////
bool InputImpl::isMouseButtonPressed(Mouse::Button /* button */)
{
    // Not applicable
    return false;
}


////////////////////////////////////////////////////////////
Vector2i InputImpl::getMousePosition()
{
    return Vector2i(0, 0);
}


////////////////////////////////////////////////////////////
Vector2i InputImpl::getMousePosition(const WindowBase& /* relativeTo */)
{
    return getMousePosition();
}


////////////////////////////////////////////////////////////
void InputImpl::setMousePosition(const Vector2i& /* position */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
void InputImpl::setMousePosition(const Vector2i& /* position */, const WindowBase& /* relativeTo */)
{
    // Not applicable
}


////////////////////////////////////////////////////////////
bool InputImpl::isTouchDown(unsigned int finger)
{
    return [[SFAppDelegate getInstance] getTouchPosition:finger] != Vector2i(-1, -1);
}


////////////////////////////////////////////////////////////
Vector2i InputImpl::getTouchPosition(unsigned int finger)
{
    return [[SFAppDelegate getInstance] getTouchPosition:finger];
}


////////////////////////////////////////////////////////////
Vector2i InputImpl::getTouchPosition(unsigned int finger, const WindowBase& /* relativeTo */)
{
    return getTouchPosition(finger);
}

} // namespace priv

} // namespace sf

// mkxp-ios: C-linkage shim the host calls from its on-screen gamepad
// (or any other touch UI) to inject synthetic key presses + releases
// that engines polling `sf::Keyboard::isKeyPressed` (e.g. LiteRGSS /
// PSDK) can observe. Out-of-range keys are silently ignored so the
// caller doesn't have to enumerate Keyboard::KeyCount constants on
// every build. `pressed` is treated as a boolean: 0 = released,
// non-zero = pressed.
extern "C" void sfml_ios_inject_key(int sfKey, int pressed)
{
    if (sfKey < 0 || sfKey >= sf::Keyboard::KeyCount)
        return;
    g_syntheticKeys[static_cast<size_t>(sfKey)].store(pressed != 0, std::memory_order_release);
}

extern "C" void sfml_ios_inject_scancode(int sfScan, int pressed)
{
    if (sfScan < 0 || sfScan >= sf::Keyboard::Scan::ScancodeCount)
        return;
    g_syntheticScans[static_cast<size_t>(sfScan)].store(pressed != 0, std::memory_order_release);
}

// mkxp-ios: push a real KeyPressed / KeyReleased into the active
// sf::Window's event queue so engines like LiteRGSS / PSDK that
// route input through `Window.on_key_pressed` callbacks (instead of
// polling sf::Keyboard) react to host-injected presses. The polling
// shims above remain for engines that only check
// sf::Keyboard::isKeyPressed; this one targets the event-driven
// path. Both are called from `empo_injectKeyEvent` so the host
// doesn't need to know which input style the engine uses.
extern "C" void sfml_ios_inject_key_event(int sfScan, int pressed)
{
    if (sfScan < 0 || sfScan >= sf::Keyboard::Scan::ScancodeCount)
        return;
    sf::Keyboard::Scancode scancode = static_cast<sf::Keyboard::Scancode>(sfScan);
    if (pressed)
        [[SFAppDelegate getInstance] notifyKeyDown:scancode];
    else
        [[SFAppDelegate getInstance] notifyKeyUp:scancode];
}

// mkxp-ios: push a sf::Event::TextEntered with `unicode` so engines
// reading typed characters via `Window.on_text_entered` (LiteRGSS /
// PSDK's `Input.get_text`, name entry, chat boxes, ...) see input
// from the host's iOS keyboard. The system keyboard fires character
// events one at a time; this is the bridge from those into SFML's
// event queue. Out-of-band scancode bridge (sfml_ios_inject_key_*)
// covers cursor / confirm / cancel; this one covers letter typing.
extern "C" void sfml_ios_inject_character(unsigned int unicode)
{
    [[SFAppDelegate getInstance] notifyCharacter:unicode];
}
