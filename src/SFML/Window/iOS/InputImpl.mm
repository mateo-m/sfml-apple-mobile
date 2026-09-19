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

Keyboard::Key InputImpl::localize(Keyboard::Scancode code)
{
    // Nothing in SFML's iOS backend makes a key event. There is no
    // pressesBegan: and no UIKey in any of its files, so every key event
    // here arrives through sfml_ios_inject_key_event below and the host
    // picks the scancode. The table is the US layout, which is the layout
    // the host numbers its own on-screen controls against.
    //
    // A program is free to read either number off the event. PSDK games
    // built before the scancode existed read the key code, so without this
    // table they see -1 for every key and match no key at all.
    switch (code)
    {
        // A..Z and the letter keys share the same order in both enums.
        case Keyboard::Scan::A: return Keyboard::A;
        case Keyboard::Scan::B: return Keyboard::B;
        case Keyboard::Scan::C: return Keyboard::C;
        case Keyboard::Scan::D: return Keyboard::D;
        case Keyboard::Scan::E: return Keyboard::E;
        case Keyboard::Scan::F: return Keyboard::F;
        case Keyboard::Scan::G: return Keyboard::G;
        case Keyboard::Scan::H: return Keyboard::H;
        case Keyboard::Scan::I: return Keyboard::I;
        case Keyboard::Scan::J: return Keyboard::J;
        case Keyboard::Scan::K: return Keyboard::K;
        case Keyboard::Scan::L: return Keyboard::L;
        case Keyboard::Scan::M: return Keyboard::M;
        case Keyboard::Scan::N: return Keyboard::N;
        case Keyboard::Scan::O: return Keyboard::O;
        case Keyboard::Scan::P: return Keyboard::P;
        case Keyboard::Scan::Q: return Keyboard::Q;
        case Keyboard::Scan::R: return Keyboard::R;
        case Keyboard::Scan::S: return Keyboard::S;
        case Keyboard::Scan::T: return Keyboard::T;
        case Keyboard::Scan::U: return Keyboard::U;
        case Keyboard::Scan::V: return Keyboard::V;
        case Keyboard::Scan::W: return Keyboard::W;
        case Keyboard::Scan::X: return Keyboard::X;
        case Keyboard::Scan::Y: return Keyboard::Y;
        case Keyboard::Scan::Z: return Keyboard::Z;

        // The digits do not share an order. Scancodes run 1..9 then 0,
        // and keys run 0..9.
        case Keyboard::Scan::Num0: return Keyboard::Num0;
        case Keyboard::Scan::Num1: return Keyboard::Num1;
        case Keyboard::Scan::Num2: return Keyboard::Num2;
        case Keyboard::Scan::Num3: return Keyboard::Num3;
        case Keyboard::Scan::Num4: return Keyboard::Num4;
        case Keyboard::Scan::Num5: return Keyboard::Num5;
        case Keyboard::Scan::Num6: return Keyboard::Num6;
        case Keyboard::Scan::Num7: return Keyboard::Num7;
        case Keyboard::Scan::Num8: return Keyboard::Num8;
        case Keyboard::Scan::Num9: return Keyboard::Num9;

        case Keyboard::Scan::Enter:      return Keyboard::Enter;
        case Keyboard::Scan::Escape:     return Keyboard::Escape;
        case Keyboard::Scan::Backspace:  return Keyboard::Backspace;
        case Keyboard::Scan::Tab:        return Keyboard::Tab;
        case Keyboard::Scan::Space:      return Keyboard::Space;
        case Keyboard::Scan::Hyphen:     return Keyboard::Hyphen;
        case Keyboard::Scan::Equal:      return Keyboard::Equal;
        case Keyboard::Scan::LBracket:   return Keyboard::LBracket;
        case Keyboard::Scan::RBracket:   return Keyboard::RBracket;
        case Keyboard::Scan::Backslash:  return Keyboard::Backslash;
        case Keyboard::Scan::Semicolon:  return Keyboard::Semicolon;
        case Keyboard::Scan::Apostrophe: return Keyboard::Apostrophe;
        case Keyboard::Scan::Grave:      return Keyboard::Grave;
        case Keyboard::Scan::Comma:      return Keyboard::Comma;
        case Keyboard::Scan::Period:     return Keyboard::Period;
        case Keyboard::Scan::Slash:      return Keyboard::Slash;

        case Keyboard::Scan::F1:  return Keyboard::F1;
        case Keyboard::Scan::F2:  return Keyboard::F2;
        case Keyboard::Scan::F3:  return Keyboard::F3;
        case Keyboard::Scan::F4:  return Keyboard::F4;
        case Keyboard::Scan::F5:  return Keyboard::F5;
        case Keyboard::Scan::F6:  return Keyboard::F6;
        case Keyboard::Scan::F7:  return Keyboard::F7;
        case Keyboard::Scan::F8:  return Keyboard::F8;
        case Keyboard::Scan::F9:  return Keyboard::F9;
        case Keyboard::Scan::F10: return Keyboard::F10;
        case Keyboard::Scan::F11: return Keyboard::F11;
        case Keyboard::Scan::F12: return Keyboard::F12;
        case Keyboard::Scan::F13: return Keyboard::F13;
        case Keyboard::Scan::F14: return Keyboard::F14;
        case Keyboard::Scan::F15: return Keyboard::F15;

        case Keyboard::Scan::Pause:    return Keyboard::Pause;
        case Keyboard::Scan::Insert:   return Keyboard::Insert;
        case Keyboard::Scan::Home:     return Keyboard::Home;
        case Keyboard::Scan::PageUp:   return Keyboard::PageUp;
        case Keyboard::Scan::Delete:   return Keyboard::Delete;
        case Keyboard::Scan::End:      return Keyboard::End;
        case Keyboard::Scan::PageDown: return Keyboard::PageDown;
        case Keyboard::Scan::Right:    return Keyboard::Right;
        case Keyboard::Scan::Left:     return Keyboard::Left;
        case Keyboard::Scan::Down:     return Keyboard::Down;
        case Keyboard::Scan::Up:       return Keyboard::Up;

        case Keyboard::Scan::NumpadDivide:   return Keyboard::Divide;
        case Keyboard::Scan::NumpadMultiply: return Keyboard::Multiply;
        case Keyboard::Scan::NumpadMinus:    return Keyboard::Subtract;
        case Keyboard::Scan::NumpadPlus:     return Keyboard::Add;
        case Keyboard::Scan::NumpadEnter:    return Keyboard::Enter;
        case Keyboard::Scan::Numpad0:        return Keyboard::Numpad0;
        case Keyboard::Scan::Numpad1:        return Keyboard::Numpad1;
        case Keyboard::Scan::Numpad2:        return Keyboard::Numpad2;
        case Keyboard::Scan::Numpad3:        return Keyboard::Numpad3;
        case Keyboard::Scan::Numpad4:        return Keyboard::Numpad4;
        case Keyboard::Scan::Numpad5:        return Keyboard::Numpad5;
        case Keyboard::Scan::Numpad6:        return Keyboard::Numpad6;
        case Keyboard::Scan::Numpad7:        return Keyboard::Numpad7;
        case Keyboard::Scan::Numpad8:        return Keyboard::Numpad8;
        case Keyboard::Scan::Numpad9:        return Keyboard::Numpad9;

        case Keyboard::Scan::LControl: return Keyboard::LControl;
        case Keyboard::Scan::LShift:   return Keyboard::LShift;
        case Keyboard::Scan::LAlt:     return Keyboard::LAlt;
        case Keyboard::Scan::LSystem:  return Keyboard::LSystem;
        case Keyboard::Scan::RControl: return Keyboard::RControl;
        case Keyboard::Scan::RShift:   return Keyboard::RShift;
        case Keyboard::Scan::RAlt:     return Keyboard::RAlt;
        case Keyboard::Scan::RSystem:  return Keyboard::RSystem;
        case Keyboard::Scan::Menu:     return Keyboard::Menu;

        default: return Keyboard::Unknown;
    }
}

Keyboard::Scancode InputImpl::delocalize(Keyboard::Key key)
{
    for (int i = 0; i < Keyboard::Scan::ScancodeCount; ++i)
    {
        Keyboard::Scancode scan = static_cast<Keyboard::Scancode>(i);
        if (localize(scan) == key)
            return scan;
    }
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

// mkxp-ios: the event queue and isKeyPressed share no state in this
// backend. PSDK reads both. LiteRGSS takes the event through
// `on_key_pressed`, then `Input.press?` asks isKeyPressed on every frame
// (SfKeyBoard.cpp:8). An event alone leaves that answer false, so the
// game sees the key once and never as held. Set both states here, so no
// caller can set one and forget the other.
extern "C" void sfml_ios_inject_key_event(int sfScan, int pressed)
{
    if (sfScan < 0 || sfScan >= sf::Keyboard::Scan::ScancodeCount)
        return;
    sf::Keyboard::Scancode scancode = static_cast<sf::Keyboard::Scancode>(sfScan);
    sfml_ios_inject_scancode(sfScan, pressed);
    sfml_ios_inject_key(static_cast<int>(sf::Keyboard::localize(scancode)), pressed);
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
