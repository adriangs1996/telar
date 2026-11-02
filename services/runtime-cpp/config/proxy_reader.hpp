#pragma once

#include "../lua/value.hpp"
#include "../proxy/options.hpp"

namespace telar::runtime::config {

template <Allocator Memory>
class ProxyReader {
public:
  static void read(const lua::Value &table, ProxyOptions<Memory> &values) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"enabled", "anonymous_tunnels", "ca_dir", "intercept_hosts", "capture", "network_capture", "transparent_redirect", "transparent_tls", "stream_interception"});
    values.enabled = table.field("enabled").boolean(values.enabled);
    values.anonymous_tunnels = table.field("anonymous_tunnels").boolean(values.anonymous_tunnels);
    values.network_capture = table.field("network_capture").boolean(values.network_capture);
    values.transparent_redirect = table.field("transparent_redirect").boolean(values.transparent_redirect);
    values.transparent_tls = table.field("transparent_tls").boolean(values.transparent_tls);
    values.stream_interception = table.field("stream_interception").boolean(values.stream_interception);
    if (values.transparent_tls && !values.transparent_redirect) { table.fail("transparent_tls requires transparent_redirect"); }
    if (values.stream_interception && (!values.enabled || !values.network_capture)) { table.fail("stream_interception requires enabled and network_capture"); }
    if (values.transparent_redirect && !values.enabled) {
      table.fail("transparent_redirect requires the proxy to be enabled");
    }
    capture(table.field("capture"), values.capture);
    const auto directory = table.field("ca_dir");
    if (directory.present()) {
      const auto text = directory.string();
      if (text.empty() || text.size() > maximum_path_bytes || text.contains('\0')) {
        directory.fail("is invalid");
      }
      values.authority_directory = text;
    }

    const auto hosts = table.field("intercept_hosts");
    if (!hosts.present()) {
      return;
    }
    const auto count = hosts.arraySize();
    if (count > ProxyHostPolicy<Memory>::maximum_hosts) {
      hosts.fail("exceeds 256 entries");
    }

    values.intercept_hosts.clear();
    for (std::size_t index = 1; index <= count; ++index) {
      const auto host = hosts.element(static_cast<lua_Integer>(index));
      if (!values.intercept_hosts.append(host.string())) {
        host.fail("is not a valid hostname");
      }
    }
    values.intercept_hosts.finish();
  }

private:
  static std::size_t positive(const lua::Value &field, std::size_t fallback) {
    return field.boundedInteger(fallback, 1, SIZE_MAX);
  }

  static void capture(const lua::Value &table, ProxyCaptureLimits &limits) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"enabled", "max_part_bytes", "max_exchange_bytes", "max_total_bytes", "join_timeout_ms"});
    limits.enabled = table.field("enabled").boolean(limits.enabled);
    limits.part_bytes = positive(table.field("max_part_bytes"), limits.part_bytes);
    limits.exchange_bytes = positive(table.field("max_exchange_bytes"), limits.exchange_bytes);
    limits.total_bytes = positive(table.field("max_total_bytes"), limits.total_bytes);
    const auto timeout = positive(table.field("join_timeout_ms"), static_cast<std::size_t>(limits.join_timeout.count()));
    if (timeout > static_cast<std::size_t>(std::chrono::duration_cast<std::chrono::milliseconds>(ProxyCaptureLimits::maximum_join_timeout).count())) {
      table.field("join_timeout_ms").fail("exceeds its 3600000 ms ceiling");
    }
    limits.join_timeout = std::chrono::milliseconds{timeout};

    if (limits.exchange_bytes < 2 || limits.part_bytes > limits.exchange_bytes || limits.exchange_bytes > limits.total_bytes) {
      table.fail("byte limits must satisfy part <= exchange <= total");
    }
    if (limits.exchange_bytes > ProxyCaptureLimits::maximum_exchange_bytes) {
      table.field("max_exchange_bytes").fail("exceeds its 67108864-byte ceiling");
    }
    if (limits.total_bytes > ProxyCaptureLimits::maximum_total_bytes) {
      table.field("max_total_bytes").fail("exceeds its 1073741824-byte ceiling");
    }
  }

  static constexpr std::size_t maximum_path_bytes = 1024;
};

}
