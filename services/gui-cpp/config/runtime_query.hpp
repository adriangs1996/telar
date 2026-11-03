#pragma once

#include "core/json_writer.hpp"
#include "core/memory.hpp"
#include "telar_config/proxy/options.hpp"
#include "telar_config/runtime_values.hpp"
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

class RuntimeQuery {
public:
  template <Allocator Memory>
  [[nodiscard]] static std::string_view write(const runtime::config::RuntimeValues<Memory> &values, std::span<char> output) {
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("graphics_pane_bytes", values.graphics.pane_bytes);
      object.member("graphics_global_bytes", values.graphics.global_bytes);
      object.member("history_path", nullablePath(values.history_path));
      object.member("history_output_capture", values.capture_output);
      object.member("session_path", nullablePath(values.session_path));
      object.member("session_persist", values.persist_session);
      object.member("session_resume_agents", values.resume_agents);
      writeProxy(object, values.proxy);
      object.member("engine_idle_timeout_ms", values.engine.idle_timeout.count());
      object.member("agent_manifest_count", values.manifests.entries().size());
    });

    return writer.view();
  }

private:
  static std::optional<std::string_view> nullablePath(std::string_view path) noexcept {
    return path.empty() ? std::nullopt : std::optional{path};
  }

  template <Allocator Memory>
  static void writeProxy(JsonWriter &writer, const runtime::ProxyOptions<Memory> &proxy) {
    writer.member("proxy_enabled", proxy.enabled);
    writer.member("proxy_anonymous_tunnels", proxy.anonymous_tunnels);
    writer.member("proxy_ca_dir", nullablePath(proxy.authority_directory));
    writer.member("proxy_intercept_hosts", [&](JsonWriter &value) {
      value.array([&](JsonWriter &array) {
        for (const auto &host : proxy.intercept_hosts.patterns()) {
          array.element(std::string_view{host});
        }
      });
    });
    writer.member("proxy_capture_enabled", proxy.capture.enabled);
    writer.member("proxy_capture_max_part_bytes", proxy.capture.part_bytes);
    writer.member("proxy_capture_max_exchange_bytes", proxy.capture.exchange_bytes);
    writer.member("proxy_capture_max_total_bytes", proxy.capture.total_bytes);
    writer.member("proxy_capture_join_timeout_ms", proxy.capture.join_timeout.count());
  }
};

}
