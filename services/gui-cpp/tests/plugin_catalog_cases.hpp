#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <type_traits>
#include <utility>
#include "../core/memory.hpp"
#include <tuple>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <variant>
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <limits.h>

#pragma once


import telar.gui.config.plugin_query;

namespace telar::gui::test {

inline void checkPluginCatalog(bool condition) {
  if (!condition) {
    throw std::runtime_error{"Plugin catalog contract failed"};
  }
}

template <typename Operation>
void pluginQueryError(Operation &&operation, std::string_view expected) {
  bool failed = false;
  try {
    std::forward<Operation>(operation)();
  } catch (const std::invalid_argument &error) {
    failed = error.what() == expected;
  }

  checkPluginCatalog(failed);
}

inline void pluginCatalogCases() {
  namespace plugins = runtime::plugins;
  std::array<plugins::ConfiguredPlugin, 3> specifications{};
  specifications[0].path.assign("disabled");
  specifications[0].enabled = false;
  specifications[1].path.assign("./enabled");
  specifications[2].path.assign("last");
  std::array<plugins::Package, 2> packages{};
  auto &manifest = packages[0].manifest;
  manifest.id.assign("sample");
  manifest.version.assign("1");
  manifest.entry.assign("main.lua");
  manifest.source.assign("fixture");
  manifest.revision.assign("1");
  manifest.actions[0].assign("first");
  manifest.actions[1].assign("second");
  manifest.action_count = 2;
  manifest.capabilities.insert(plugins::Capability::notifications);
  manifest.capabilities.insert(plugins::Capability::workspace_read);
  packages[1].manifest.id.assign("last-id");
  constexpr std::uint64_t generation = 42;
  const PluginCatalog catalog{generation, specifications, packages};
  checkPluginCatalog(catalog.package(0) == nullptr && catalog.package(1) == packages.data() && catalog.package(2) == &packages[1]);
  checkPluginCatalog(catalog.find("disabled") == 0 && catalog.find("./enabled") == 1 && catalog.find("sample") == 1);
  std::array<char, 4096> output{};
  ClientCommand request{.action = ClientAction::plugin_list};
  auto page = PluginQuery::list(catalog, request, output);
  checkPluginCatalog(page.next == 1 && page.text == R"({"generation":42,"entries":[{"index":0,"path":"disabled","id":null,"version":null,"requested_enabled":false,"enabled":false}]})");
  request.value = 1;
  page = PluginQuery::list(catalog, request, output);
  checkPluginCatalog(page.next == 2 && page.text == R"({"generation":42,"entries":[{"index":1,"path":"./enabled","id":"sample","version":"1","requested_enabled":true,"enabled":true}]})");
  request.value = 3;
  page = PluginQuery::list(catalog, request, output);
  checkPluginCatalog(page.next == -1 && page.text == R"({"generation":42,"entries":[]})");
  request = {.action = ClientAction::plugin_get, .target_id = generation, .text = "disabled"};
  page = PluginQuery::get(catalog, request, output);
  checkPluginCatalog(page.next == -1 && page.text == R"({"generation":42,"entries":[{"path":"disabled","requested_enabled":false,"enabled":false,"id":null}]})");
  request.text = "sample";
  page = PluginQuery::get(catalog, request, output);
  checkPluginCatalog(page.next == 1 && page.text == R"({"generation":42,"entries":[{"path":"./enabled","requested_enabled":true,"enabled":true,"id":"sample","version":"1","entry":"main.lua","source":"fixture","revision":"1","digest":"0000000000000000000000000000000000000000000000000000000000000000","capabilities":["workspace.read","notifications"]}]})");
  request.value = 1;
  page = PluginQuery::get(catalog, request, output);
  checkPluginCatalog(page.next == 2 && page.text == R"({"generation":42,"entries":["first"]})");
  request.value = 2;
  page = PluginQuery::get(catalog, request, output);
  checkPluginCatalog(page.next == -1 && page.text == R"({"generation":42,"entries":["second"]})");
  request.value = -1;
  pluginQueryError([&] {
    static_cast<void>(PluginQuery::get(catalog, request, output));
  },
                   "InvalidPage");
  request.text = "missing";
  pluginQueryError([&] {
    static_cast<void>(PluginQuery::get(catalog, request, output));
  },
                   "PluginNotConfigured");
  request.target_id = generation + 1;
  pluginQueryError([&] {
    static_cast<void>(PluginQuery::get(catalog, request, output));
  },
                   "StaleConfiguration");
  pluginQueryError([&] {
    static_cast<void>(PluginQuery::list(catalog, request, output));
  },
                   "StaleConfiguration");
  request.target_id = 0;
  request.value = std::numeric_limits<std::int64_t>::max();
  pluginQueryError([&] {
    static_cast<void>(PluginQuery::list(catalog, request, output));
  },
                   "InvalidPage");
  specifications[0].path.assign("sample");
  checkPluginCatalog(catalog.find("sample") == 0);
}

}
