#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstring>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.config.core;
import telar.lua;
import telar.gui.features.components;
import telar.gui.application;

namespace {

  using telar::testing::check;
  using namespace telar::gui;
  using namespace telar::gui::features::components;

  void retainedLuaItems() {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{8} * 1024 * 1024;
    BudgetAllocator memory{system, allocation_budget};
    PickItems items;
    telar::runtime::config::LimitNotices limits;

    {
      telar::MemoryAdapter erased{memory};
      telar::runtime::lua::Vm<telar::Memory> machine{erased};

      machine.execute(R"(
      return {
        valid={'low',{label='á λ',value='a\tb',detail='detail',selected=true,swatch={'#000000','#abcdef','#ffffff'}}},
        invalid={'first',{label='bad\n'}},
        bad_metadata={{label='safe',selected='yes'}},
      }
    )",
          "@pick-items.lua");
      const telar::runtime::lua::Value root{machine.state(), -1, "fixture"};

      application::PickItemsReader::read(root.field("valid"), items, limits);
      check(items.size() == 2 && items.at(1).selected && items.at(1).swatch.has_value(), "a pick must retain selection and swatch metadata");

      struct Failure {
        const char* name;
        std::size_t read;
      };

      PickItems failed;

      for (const auto failure : {Failure{.name = "invalid", .read = 1}, Failure{.name = "bad_metadata", .read = 0}}) {
        bool rejected = false;

        application::PickItemsReader::read(root.field("valid"), failed, limits);
        try {
          application::PickItemsReader::read(root.field(failure.name), failed, limits);
        } catch (const std::exception&) {
          rejected = true;
        }

        check(rejected && failed.size() == failure.read, "a failed list parse must replace the list with the options read before the failure");
      }
    }

    check(memory.liveBytes() == 0 && items.at(1).value == "a\tb" && items.at(1).detail == "detail", "option strings must outlive the Lua producer without retaining its VM");
  }

  void limitsAndRawLines() {
    PickItems items;
    PickInput input;

    input.label = "option";
    for (std::size_t index = 0; index <= PickItems::maximum_items; ++index) {
      items.keep(input);
    }

    telar::runtime::config::LimitNotices limits;

    items.report(limits);
    check(items.size() == PickItems::maximum_items && std::ranges::any_of(limits.entries(), [](const auto& entry) {
      return entry.name == "picks.max_items";
    }),
        "count overflow must keep a complete bounded prefix and report its bound");
    application::PickItemsReader::lines(" \r\n  low \n a\tb \n", items, limits);
    check(items.size() == 2 && items.at(1).label == "a b" && items.at(1).value == "a\tb", "raw line labels must show tabs as spaces while values retain their original bytes");
    input.label = "unchanged";
    const std::string oversized(PickItems::maximum_value_bytes + 1, 'v');

    input.value = oversized;
    items.keep(input);
    check(items.size() == 2, "a value that cannot fit in one argv element must be omitted whole");
    input.value.reset();
    input.label = std::string_view{"\xff", 1};
    bool rejected = false;

    try {
      items.keep(input);
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected && items.size() == 2, "invalid UTF-8 must not publish an incomplete option");
  }

  void matchingAndTextBounds() {
    PickItems items;

    for (const auto* const label : {"xxalpha", "alpha", "alpha", "none"}) {
      PickInput input;

      input.label = label;
      input.detail = input.label == "none" ? "alpha" : "";
      items.keep(input);
    }

    PickMatches matches;

    matches.collect(items, "ALPHA");
    check(matches.rows().size() == 4 && matches.rows()[0].index == 1 && matches.rows()[1].index == 2 && matches.rows()[2].index == 3 && matches.rows()[3].index == 0, "matching must search labels before details and keep input order among equal scores");
    matches.collect(items, "");
    check(matches.rows().size() == 4 && matches.rows()[0].index == 0 && matches.rows()[3].index == 3, "clearing the query must restore list order");

    items.clear();
    const std::string value(PickItems::maximum_value_bytes, 'v');
    const std::string detail(PickItems::maximum_detail_bytes, 'd');
    PickInput input;

    input.label = "item";
    input.value = value;
    input.detail = detail;
    for (std::size_t index = 0; index < PickItems::maximum_items; ++index) {
      items.keep(input);
    }

    telar::runtime::config::LimitNotices limits;

    items.report(limits);
    check(items.size() > 0 && items.size() < PickItems::maximum_items && std::ranges::any_of(limits.entries(), [](const auto& entry) {
      return entry.name == "picks.max_text_bytes";
    }),
        "the shared text budget must stop storage and report excess offered text");
    matches.collect(items, "item");
    check(matches.rows().size() == items.size(), "every retained option must remain selectable after text-budget fitting");
  }

  const telar::testing::Case case_retained_lua_items{"pick_items.retained_lua_items", retainedLuaItems};
  const telar::testing::Case case_limits_and_raw_lines{"pick_items.limits_and_raw_lines", limitsAndRawLines};
  const telar::testing::Case case_matching_and_text_bounds{"pick_items.matching_and_text_bounds", matchingAndTextBounds};

}
