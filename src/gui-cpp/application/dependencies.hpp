#pragma once

#include "core/memory.hpp"

#ifndef TELAR_GUI_ALLOCATOR
#define TELAR_GUI_ALLOCATOR ::telar::gui::SystemAllocator
#endif

namespace telar::gui {

using ApplicationAllocator = TELAR_GUI_ALLOCATOR;
static_assert(Allocator<ApplicationAllocator>);

}
