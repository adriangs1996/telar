#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "allocation_gate.hpp"
#include "assertions.hpp"
#include "../core/memory.hpp"
#include "font_fixture.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <array>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include <string_view>
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include "telar_client/serializers/telar_cells.hpp"
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <bit>
#include <functional>
#include <concepts>
#include <utility>
#include <ghostty/vt/unicode.h>
#include <exception>
#include <filesystem>
#include <iostream>
#include <new>
#include <string>

#include "core/memory.hpp"


import telar.gui.fonts.face;
import telar.gui.fonts.font_requests;
import telar.gui.fonts.row_text_layout;

namespace {

using namespace telar::gui;
using namespace telar::gui::fonts;
using namespace telar::gui::test;

constexpr std::uint16_t text_height = 13;
constexpr TextRequest request{.pixel_height = text_height};
constexpr std::string_view mixed_text = "AV \uf07b fi \uf013 end";
constexpr std::string_view branch_symbol = "\u2387";
constexpr std::size_t mixed_span_count = 5;

void queryPreservesWholeClusters() {
  const auto query = requireValue(FontQuery::create("e\u200d\ufe0f\U000e0100\u0301"), "valid graphemes must produce a native query");
  require(query.text() == "e\u200d\ufe0f\U000e0100\u0301", "queries must retain the complete original cluster");
  require(std::string_view{query.codepoints()} == "e\u0301", "native queries must remove selectors and joiners without dropping combining marks");
  require(!FontQuery::create("\u200d\ufe0f"), "selector-only queries must not reach the platform");
  const std::string maximum(FontQuery::maximum_bytes, 'a');
  require(FontQuery::create(maximum).has_value(), "a full query must fit with its native terminator");
  require(!FontQuery::create(maximum + 'a'), "oversized clusters must remain bounded");
  bool rejected = false;
  try {
    static_cast<void>(FontQuery::create("\xc0\xaf"));
  } catch (const std::invalid_argument &) {
    rejected = true;
  }

  require(rejected, "invalid UTF-8 must not reach native font lookup");
}

void requestsBoundAndRetireWork() {
  FontRequests requests;
  requests.request("\U0010eeee\u0301");
  require(!requests.take(), "image placeholders must never trigger installed-font lookup");
  for (std::size_t index = 0; index <= FontRequests::pending_capacity; ++index) {
    requests.request(std::to_string(index));
  }

  const auto first = requireValue(requests.take(), "the first query must be admitted");
  require(first.text() == "0" && !requests.take(), "one oldest query may be in flight");
  requests.request("0");
  require(!requests.finish(first, false), "a queued suffix must finish before retry invalidation");
  for (std::size_t index = 1; index < FontRequests::pending_capacity; ++index) {
    const auto current = requireValue(requests.take(), "admitted queries must remain discoverable");
    require(current.text() == std::to_string(index), "queries must retain FIFO order after duplicate reports");
    const auto invalidate = requests.finish(current, false);
    require(invalidate == (index + 1 == FontRequests::pending_capacity), "a drained overflow must invalidate once");
  }

  requests.request("0");
  require(!requests.take(), "a failed lookup must not repeat after every reshape");
  requests.request(std::to_string(FontRequests::pending_capacity));
  const auto retried = requireValue(requests.take(), "a refused suffix must be allowed after the queue drains");
  require(requests.finish(retried, true), "an adopted font must invalidate shaped labels");
}

void overflowRetriesRemainBounded() {
  FontRequests requests;
  for (unsigned round = 0; round <= FontRequests::maximum_retries; ++round) {
    for (std::size_t index = 0; index <= FontRequests::pending_capacity; ++index) {
      requests.request(std::to_string(round) + '/' + std::to_string(index));
    }

    bool invalidated = false;
    while (const auto query = requests.take()) {
      invalidated = requests.finish(*query, false) || invalidated;
    }

    require(invalidated == (round < FontRequests::maximum_retries), "repeated uncovered output must stop retiring the shaping cache after the original retry bound");
  }
}

void naturalAndMixedRuns(FontFixture<SystemAllocator> &fonts) {
  SystemAllocator memory;
  TextLayout layout{memory};
  constexpr std::string_view natural = "AVATAR fi ffi · Crème";
  layout.shape(fonts, natural, request);
  require(layout.spans().size() == 1 && layout.spans().front().role == FontRole::regular, "covered text must retain one contextual shaping run");
  const auto original = fonts.face(FontRole::regular).shape(natural, text_height);
  require(layout.advance() == original.advance() && layout.glyphs().size() == original.size(), "covered text must retain original shaping metrics");
  for (std::size_t index = 0; index < original.size(); ++index) {
    require(layout.glyphs()[index] == original.glyph(index), "covered text must retain complete HarfBuzz glyph positions");
  }

  layout.shape(fonts, mixed_text, request);
  require(layout.spans().size() == mixed_span_count, "fallback clusters must split preferred text without discarding its contextual spans");
  require(layout.spans()[1].role == FontRole::symbols && layout.spans()[3].role == FontRole::symbols, "resident symbols must precede installed-font lookup");
  require(layout.spans()[1].columns == 1 && layout.spans()[3].columns == 1, "fallback glyphs must retain their complete cell width");
  const auto primary_metrics = fonts.face(FontRole::primary).metrics(text_height);
  const auto expected = fonts.face(FontRole::regular).shape("AV ", text_height).advance() + fonts.face(FontRole::regular).shape(" fi ", text_height).advance() + fonts.face(FontRole::regular).shape(" end", text_height).advance() + (2 * primary_metrics.maximum_advance);
  require(layout.advance() == expected && TextLayout<SystemAllocator>::measure(fonts, mixed_text, request) == expected, "measurement must preserve natural advances and fitted fallback cells");
  layout.shape(fonts, branch_symbol, request);
  require(layout.spans().size() == 1 && layout.spans().front().role == FontRole::primary, "an undiscovered cluster must temporarily use the configured face");
  constexpr std::string_view primary_text = "\u2387 AVATAR fi";
  layout.shape(fonts, primary_text, {.pixel_height = text_height, .preferred = FontRole::primary});
  require(layout.spans().size() == 1, "a primary run must keep contextual shaping across missing glyphs");
  const auto primary_run = fonts.face(FontRole::primary).shape(primary_text, text_height);
  require(layout.advance() == primary_run.advance() && layout.glyphs().size() == primary_run.size(), "missing primary glyphs must not change neighboring shaping");
  for (std::size_t index = 0; index < primary_run.size(); ++index) {
    require(layout.glyphs()[index] == primary_run.glyph(index), "primary glyph positions must match the original complete contextual run");
  }
}

void layoutOwnershipAndWarmReuse(FontFixture<SystemAllocator> &fonts) {
  SystemAllocator upstream;
  BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{budget};
  {
    TextLayout layout{memory};
    const auto before = budget.allocations();
    layout.shape(fonts, "AVATAR", request);
    require(budget.allocations() == before + 1, "covered text must allocate only its glyph storage");
    layout.shape(fonts, mixed_text, request);
    const auto allocations = budget.allocations();
    constexpr std::size_t repetitions = 100;
    for (std::size_t index = 0; index < repetitions; ++index) {
      layout.shape(fonts, mixed_text, request);
    }

    require(budget.allocations() == allocations, "warm mixed shaping must reuse injected glyph and span storage");
    memory.permit(0);
    bool rejected = false;
    try {
      constexpr std::size_t oversized_title_bytes = 4096;
      layout.shape(fonts, std::string(oversized_title_bytes, 'a'), request);
    } catch (const std::bad_alloc &) {
      rejected = true;
    }

    require(rejected, "layout allocation must flow through the injected allocator");
    memory.permit(std::nullopt);
    layout.shape(fonts, mixed_text, request);
    require(layout.spans().size() == mixed_span_count, "failed shaping must remain retryable");
  }

  require(budget.liveBytes() == 0, "text layout destruction must release every injected allocation");
}

void captionsRetainRunOriginsAndWarmStorage(FontFixture<SystemAllocator> &fonts) {
  SystemAllocator upstream;
  BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{budget};
  {
    TextLayout layout{memory};
    constexpr std::array runs{std::string_view{"History AV kerning: "}, std::string_view{"AVATARVAAVATARVAAVATARVAAVATAR"}, std::string_view{"VAAVATARVA"}};
    std::string label;
    for (const auto run : runs) {
      label += run;
    }

    layout.shapeCaption(fonts, label, request);
    require(layout.spans().size() == runs.size(), "captions must preserve each original bounded shaping origin");
    std::int32_t advance = 0;
    std::size_t first = 0;
    for (std::size_t index = 0; index < runs.size(); ++index) {
      const auto shaped = fonts.face(FontRole::regular).shape(runs[index], text_height);
      const auto span = layout.spans()[index];
      require(span.offset == advance && span.first == first && span.count == shaped.size(), "caption spans must use independently rounded original advances");
      for (std::size_t glyph = 0; glyph < shaped.size(); ++glyph) {
        require(layout.glyphs()[first + glyph] == shaped.glyph(glyph), "caption glyphs must retain the full original shaped run");
      }

      first += shaped.size();
      advance += shaped.advance();
    }

    require(layout.advance() == advance, "caption width must sum original rounded run widths");
    const auto allocations = budget.allocations();
    memory.permit(0);
    constexpr std::size_t repetitions = 100;
    for (std::size_t index = 0; index < repetitions; ++index) {
      layout.shapeCaption(fonts, label, request);
    }

    require(budget.allocations() == allocations, "warm captions must reuse injected glyph and span storage");
    layout.shape(fonts, "AVATAR", request);
    require(layout.spans().size() == 1, "ordinary shaping must retire previous caption boundaries");
  }

  require(budget.liveBytes() == 0, "caption destruction must release all retained storage");
}

}

int main(int argc, char **argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  constexpr std::size_t expected_arguments = 2;
  if (arguments.size() != expected_arguments) {
    return 1;
  }

  try {
    queryPreservesWholeClusters();
    requestsBoundAndRetireWork();
    overflowRetriesRemainBounded();
    SystemAllocator memory;
    FontFixture fonts{memory, std::filesystem::path{arguments[1]}};
    naturalAndMixedRuns(fonts);
    layoutOwnershipAndWarmReuse(fonts);
    captionsRetainRunOriginsAndWarmStorage(fonts);
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
