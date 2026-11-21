#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/fonts/font_resolver.hpp"
#include <QtCore/qtypes.h>

#pragma once

namespace telar::gui::qt {

// An interface of pure virtual calls with a protected, non-virtual destructor has no member to define out of line.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wweak-vtables"

  // What an editor's view asks of the window it is drawn in.
  class NvimHost {
  public:
    NvimHost(const NvimHost&) = delete;
    NvimHost& operator=(const NvimHost&) = delete;
    NvimHost(NvimHost&&) = delete;
    NvimHost& operator=(NvimHost&&) = delete;

    // The configured font, at the density of the editor's window.
    [[nodiscard]] virtual ResolvedFont resolveFont(qreal scale) = 0;

  protected:
    NvimHost() = default;
    ~NvimHost() = default;
  };

#pragma clang diagnostic pop

}
