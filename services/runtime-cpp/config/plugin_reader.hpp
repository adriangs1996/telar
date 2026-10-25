#pragma once

#include "../lua/value.hpp"
#include "../plugins/specifications.hpp"
#include "limit_notices.hpp"

namespace telar::runtime::config {

class PluginReader {
public:
  static void read(const lua::Value &value, plugins::Specifications &destination, LimitNotices &limits) {
    if (!value.present()) {
      return;
    }

    const auto listed = value.listLength();
    const auto count = std::min(listed, plugins::PackageLimits::configured);
    if (count < listed) {
      limits.add({.name = "plugins.max_plugins", .noun = "plugins", .value = plugins::PackageLimits::configured, .requested = listed});
    }

    destination.count = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const auto specification = value.element(static_cast<lua_Integer>(index + 1));
      specification.onlyFields({"path", "enabled"});
      const auto path_value = specification.field("path");
      const auto path = path_value.string();
      if (path.empty() || path.size() > plugins::PackageLimits::configured_path_bytes) {
        path_value.fail("is outside its bounds");
      }

      auto &plugin = destination.entries[destination.count];
      plugin.path.assign(path);
      plugin.enabled = specification.field("enabled").boolean(true);
      ++destination.count;
    }
  }
};

}
