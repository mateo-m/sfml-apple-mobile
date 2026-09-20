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
#include <SFML/Window/iOS/SFView.hpp>
#include <SFML/Window/iOS/SFAppDelegate.hpp>
#include <SFML/System/Utf.hpp>
#include <QuartzCore/CAMetalLayer.h>
#include <Metal/MTLPixelFormat.h>
#include <Metal/MTLDevice.h>
#include <cstring>

@interface SFView()

// mkxp-ios: SFML's cmake enables ARC via `sfml_set_xcode_property
// CLANG_ENABLE_OBJC_ARC YES`, but that property only takes effect
// under the Xcode generator. With Unix Makefiles / Ninja the .mm
// files compile under MRC, where `@property (nonatomic)` defaults
// to `assign`. The autoreleased `[NSMutableArray array]` returned
// by initWithFrame: gets freed at the next pool drain, leaving
// `self.touches` dangling; a later touchesBegan: then sends
// `addObject:` to whatever immutable NSArray now occupies that
// memory, crashing with `__NSArrayI unrecognized selector`.
//
// Make the ownership explicit so the setter retains regardless of
// ARC mode. `strong` is a synonym for `retain` under MRC.
@property (nonatomic, strong) NSMutableArray* touches;

// The size layoutSubviews last reported, so a layout pass that keeps
// the size sends no event.
@property (nonatomic) CGSize reportedSize;

@end


@implementation SFView

@synthesize context;


////////////////////////////////////////////////////////////
-(BOOL)canBecomeFirstResponder
{
    return true;
}


////////////////////////////////////////////////////////////
- (BOOL)hasText
{
    return true;
}


////////////////////////////////////////////////////////////
- (void)deleteBackward
{
    [[SFAppDelegate getInstance] notifyCharacter:'\b'];
}


////////////////////////////////////////////////////////////
- (void)insertText:(NSString*)text
{
    // Convert the NSString to UTF-8
    const char* utf8 = [text UTF8String];

    // Then convert to UTF-32 and notify the application delegate of each new character
    const char* end = utf8 + std::strlen(utf8);
    while (utf8 < end)
    {
        sf::Uint32 character;
        utf8 = sf::Utf8::decode(utf8, end, character);
        [[SFAppDelegate getInstance] notifyCharacter:character];
    }
}


////////////////////////////////////////////////////////////
- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event
{
    for (UITouch* touch in touches)
    {
        // find an empty slot for the new touch
        NSUInteger index = [self.touches indexOfObject:[NSNull null]];
        if (index != NSNotFound)
        {
            [self.touches replaceObjectAtIndex:index withObject:touch];
        }
        else
        {
            [self.touches addObject:touch];
            index = [self.touches count] - 1;
        }

        // get the touch position
        CGPoint point = [touch locationInView:self];
        sf::Vector2i position(static_cast<int>(point.x), static_cast<int>(point.y));

        // notify the application delegate
        [[SFAppDelegate getInstance] notifyTouchBegin:(static_cast<unsigned int>(index)) atPosition:position];
    }
}


////////////////////////////////////////////////////////////
- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event
{
    for (UITouch* touch in touches)
    {
        // find the touch
        NSUInteger index = [self.touches indexOfObject:touch];
        if (index != NSNotFound)
        {
            // get the touch position
            CGPoint point = [touch locationInView:self];
            sf::Vector2i position(static_cast<int>(point.x), static_cast<int>(point.y));

            // notify the application delegate
            [[SFAppDelegate getInstance] notifyTouchMove:(static_cast<unsigned int>(index)) atPosition:position];
        }
    }
}


////////////////////////////////////////////////////////////
- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event
{
    for (UITouch* touch in touches)
    {
        // find the touch
        NSUInteger index = [self.touches indexOfObject:touch];
        if (index != NSNotFound)
        {
            // get the touch position
            CGPoint point = [touch locationInView:self];
            sf::Vector2i position(static_cast<int>(point.x), static_cast<int>(point.y));

            // notify the application delegate
            [[SFAppDelegate getInstance] notifyTouchEnd:(static_cast<unsigned int>(index)) atPosition:position];

            // remove the touch
            [self.touches replaceObjectAtIndex:index withObject:[NSNull null]];
        }
    }
}


////////////////////////////////////////////////////////////
- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event
{
    // Treat touch cancel events the same way as touch end
    [self touchesEnded:touches withEvent:event];
}


////////////////////////////////////////////////////////////
- (void)layoutSubviews
{
    // mkxp-ios: the drawable takes this view's size, and the window
    // keeps its own copy of that size for the drawing code. Upstream
    // updates the copy from the device orientation notification. That
    // path asks the root view controller for permission first, and a
    // window made without sf::Style::Resize answers no. The copy then
    // keeps the size the window had at creation, and every later frame
    // draws in a rectangle of the wrong shape. The layout is the event
    // that says the drawable changed.
    CGSize size = CGSizeMake(self.bounds.size.width * self.contentScaleFactor,
                             self.bounds.size.height * self.contentScaleFactor);
    if (!CGSizeEqualToSize(size, self.reportedSize))
    {
        self.reportedSize = size;
        if (sf::priv::WindowImplUIKit* window = [SFAppDelegate getInstance].sfWindow)
        {
            sf::Event event;
            event.type = sf::Event::Resized;
            event.size.width = static_cast<unsigned int>(size.width);
            event.size.height = static_cast<unsigned int>(size.height);
            window->forwardEvent(event);
        }
    }

    // update the attached context's buffers
    if (self.context)
        self.context->recreateRenderBuffers(self);
}


////////////////////////////////////////////////////////////
+ (Class)layerClass
{
    // ANGLE-backed: SFML's GL context now uses ANGLE which renders
    // through a CAMetalLayer instead of EAGL/CAEAGLLayer. Same
    // visual result; runs on iOS where Apple has been deprecating
    // the OpenGL ES framework path.
    return [CAMetalLayer class];
}

////////////////////////////////////////////////////////////
- (id)initWithFrame:(CGRect)frame andContentScaleFactor:(CGFloat)factor
{
    self = [super initWithFrame:frame];

    self.contentScaleFactor = factor;

    if (self)
    {
        self.context = NULL;
        self.touches = [NSMutableArray array];

        // Configure the Metal layer for ANGLE consumption.
        CAMetalLayer* metalLayer = (CAMetalLayer*)self.layer;
        metalLayer.opaque = YES;
        // ANGLE-on-Metal needs framebufferOnly=YES for the swap chain
        // to present drawable contents to the visible layer. With NO,
        // eglSwapBuffers reports success but the layer keeps showing
        // its background colour and never picks up the drawable's
        // content (root cause of the long-standing all-black render
        // after PSDK boot). YES costs nothing here because we never
        // sample the swap-chain drawable as a texture.
        metalLayer.framebufferOnly = YES;
        // CAMetalLayer doesn't derive drawableSize from bounds
        // automatically — leaving it at default (0, 0) makes
        // nextDrawable return nil and ANGLE's swap silently no-ops.
        // Set it explicitly from frame * contentsScale, matching the
        // pixel grid SFML expects.
        metalLayer.drawableSize = CGSizeMake(
            frame.size.width * factor, frame.size.height * factor);
        metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        // mkxp-ios: ANGLE-on-Metal needs the CAMetalLayer to have an
        // explicit MTLDevice set; without it nextDrawable returns nil
        // and eglSwapBuffers reports success but nothing reaches the
        // display (visible as "container bg shows through but layer
        // contents stay empty"). Assign the system default device so
        // ANGLE's swap actually presents.
        metalLayer.device = MTLCreateSystemDefaultDevice();

        // Enable user interactions on the view (multi-touch events)
        self.userInteractionEnabled = true;
        self.multipleTouchEnabled = true;
    }

    return self;
}

////////////////////////////////////////////////////////////
- (UITextAutocorrectionType) autocorrectionType
{
    return UITextAutocorrectionTypeNo;
}


@end
