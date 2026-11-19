module;
#include <climits>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

export module telar.gui.tests.plugin_catalog_cases;

import std;
import telar.gui.features.plugins;
import telar.wire.clients;
import telar.wire.vocabulary;
import telar.plugins;
import telar.base.ds;

export {
  namespace telar::gui::test {

    inline void checkPluginCatalog(bool condition) {
      if (!condition) {
        throw std::runtime_error{"Plugin catalog contract failed"};
      }
    }

    template <typename Operation>
    void pluginQueryError(Operation&& operation, std::string_view expected) {
      bool failed = false;

      try {
        std::forward<Operation>(operation)();
      } catch (const std::invalid_argument& error) {
        failed = error.what() == expected;
      }

      checkPluginCatalog(failed);
    }

    inline void pluginCatalogCases() {
      namespace plugins = runtime::plugins;
      ds::Array<plugins::ConfiguredPlugin, 3> specifications{};

      specifications.atMut(0).path.assign("disabled");
      specifications.atMut(0).enabled = false;
      specifications.atMut(1).path.assign("./enabled");
      specifications.atMut(2).path.assign("last");
      ds::Array<plugins::Package, 2> packages{};
      auto& manifest = packages.atMut(0).manifest;

      manifest.id.assign("sample");
      manifest.version.assign("1");
      manifest.entry.assign("main.lua");
      manifest.source.assign("fixture");
      manifest.revision.assign("1");
      manifest.actions.atMut(0).assign("first");
      manifest.actions.atMut(1).assign("second");
      manifest.action_count = 2;
      manifest.capabilities.insert(plugins::Capability::notifications);
      manifest.capabilities.insert(plugins::Capability::workspace_read);
      packages.atMut(1).manifest.id.assign("last-id");
      constexpr std::uint64_t generation = 42;
      const features::plugins::PluginCatalog catalog{generation, specifications, packages};

      checkPluginCatalog(catalog.package(0) == nullptr && catalog.package(1) == packages.data() && catalog.package(2) == &packages[1]);
      checkPluginCatalog(catalog.find("disabled") == 0 && catalog.find("./enabled") == 1 && catalog.find("sample") == 1);
      ds::Array<char, 4096> output{};
      ClientCommand request{.action = ClientAction::plugin_list};
      auto page = features::plugins::PluginQuery::list(catalog, request, output.viewMut());

      checkPluginCatalog(page.next == 1 && page.text == R"({"generation":42,"entries":[{"index":0,"path":"disabled","id":null,"version":null,"requested_enabled":false,"enabled":false}]})");
      request.value = 1;
      page = features::plugins::PluginQuery::list(catalog, request, output.viewMut());
      checkPluginCatalog(page.next == 2 && page.text == R"({"generation":42,"entries":[{"index":1,"path":"./enabled","id":"sample","version":"1","requested_enabled":true,"enabled":true}]})");
      request.value = 3;
      page = features::plugins::PluginQuery::list(catalog, request, output.viewMut());
      checkPluginCatalog(page.next == -1 && page.text == R"({"generation":42,"entries":[]})");
      request = {.action = ClientAction::plugin_get, .target_id = generation, .text = "disabled"};
      page = features::plugins::PluginQuery::get(catalog, request, output.viewMut());
      checkPluginCatalog(page.next == -1 && page.text == R"({"generation":42,"entries":[{"path":"disabled","requested_enabled":false,"enabled":false,"id":null}]})");
      request.text = "sample";
      page = features::plugins::PluginQuery::get(catalog, request, output.viewMut());
      checkPluginCatalog(page.next == 1 && page.text == R"({"generation":42,"entries":[{"path":"./enabled","requested_enabled":true,"enabled":true,"id":"sample","version":"1","entry":"main.lua","source":"fixture","revision":"1","digest":"0000000000000000000000000000000000000000000000000000000000000000","capabilities":["workspace.read","notifications"]}]})");
      request.value = 1;
      page = features::plugins::PluginQuery::get(catalog, request, output.viewMut());
      checkPluginCatalog(page.next == 2 && page.text == R"({"generation":42,"entries":["first"]})");
      request.value = 2;
      page = features::plugins::PluginQuery::get(catalog, request, output.viewMut());
      checkPluginCatalog(page.next == -1 && page.text == R"({"generation":42,"entries":["second"]})");
      request.value = -1;
      pluginQueryError([&] {
        static_cast<void>(features::plugins::PluginQuery::get(catalog, request, output.viewMut()));
      },
          "InvalidPage");
      request.text = "missing";
      pluginQueryError([&] {
        static_cast<void>(features::plugins::PluginQuery::get(catalog, request, output.viewMut()));
      },
          "PluginNotConfigured");
      request.target_id = generation + 1;
      pluginQueryError([&] {
        static_cast<void>(features::plugins::PluginQuery::get(catalog, request, output.viewMut()));
      },
          "StaleConfiguration");
      pluginQueryError([&] {
        static_cast<void>(features::plugins::PluginQuery::list(catalog, request, output.viewMut()));
      },
          "StaleConfiguration");
      request.target_id = 0;
      request.value = std::numeric_limits<std::int64_t>::max();
      pluginQueryError([&] {
        static_cast<void>(features::plugins::PluginQuery::list(catalog, request, output.viewMut()));
      },
          "InvalidPage");
      specifications.atMut(0).path.assign("sample");
      checkPluginCatalog(catalog.find("sample") == 0);
    }

  }
}
