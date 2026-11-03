#pragma once

#include "control_session.hpp"
#include "runtime_event_output.hpp"
#include "runtime_options.hpp"
#include "telar_platform/runtime_paths.hpp"

namespace telar::runtime::cli {

inline void printRuntimeStatus(const ProxyStatus &status, bool json) {
  if (json) {
    writeText("{\"running\":true,\"schema_version\":" + quoteJson(nativeSchemaVersion()) + ",\"proxy\":" + proxyStatusJson(status) + "}\n");
    return;
  }

  auto output = std::format("Runtime: running\nSchema: {}\nProxy: {}\n", nativeSchemaVersion(), status.active ? "active" : "disabled");
  if (status.port) {
    if (!status.preferred_port) {
      output += std::format("Proxy port: {} (none remembered for this runtime)\n", *status.port);
    } else if (status.port == status.preferred_port) {
      output += std::format("Proxy port: {}\n", *status.port);
    } else {
      output += std::format("Proxy port: {} (warning: remembered port {} was held by another process; processes that inherited it do not reach this runtime)\n", *status.port, *status.preferred_port);
    }
  }

  output += std::format("Proxy scope: {}\nSystem trust: {}\n", status.scope == ProxyScope::exact ? "exact" : "wildcard", status.system_trusted ? "installed" : "absent");
  writeText(output);
}

inline void printRuntimeMetrics(const SystemMetrics &metrics, bool json) {
  if (json) {
    writeText(metricsJson(metrics, false) + "\n");
    return;
  }

  writeText(std::format("CPU: {}% of {}\nMemory: {}.{} of {}.{} GiB\nBattery: {}\n", metrics.cpu_percent, metrics.cpu_count, metrics.memory_used_decigib / 10, metrics.memory_used_decigib % 10, metrics.memory_total_decigib / 10, metrics.memory_total_decigib % 10, metrics.has_battery ? std::to_string(metrics.battery_percent) + "%" : "unavailable"));
}

inline std::string runtimeEventJson(std::span<const Byte> frame, DecodeStorage &storage) {
  switch (static_cast<ServerTag>(frame.front())) {
  case ServerTag::proxy_status:
    return "{\"type\":\"proxy_status\",\"data\":" + proxyStatusJson(Codec::decode<ProxyStatus>(frame, storage)) + "}";
  case ServerTag::system_metrics:
    return "{\"type\":\"system_metrics\",\"data\":" + metricsJson(Codec::decode<SystemMetrics>(frame, storage), true) + "}";
  case ServerTag::workspace_list:
    return workspaceEventJson(Codec::decode<WorkspaceList>(frame, storage));
  case ServerTag::agent_snapshot:
    return agentEventJson(Codec::decode<AgentSnapshot>(frame, storage));
  case ServerTag::runtime_stopping:
    Codec::decode<RuntimeStopping>(frame, storage);
    return "{\"type\":\"runtime_stopping\"}";
  case ServerTag::resync_required:
    Codec::decode<ResyncRequired>(frame, storage);
    return "{\"type\":\"resync_required\"}";
  default:
    return {};
  }
}

template <Allocator Memory>
void observeRuntime(Memory &memory, const RuntimeOptions &options) {
  ServerOptions server_options{};
  server_options.socket = options.socket.value_or("");
  const RuntimePaths paths{memory, server_options, ProcessEnvironment{}};
  RuntimeConnection connection{paths.socket.c_str()};
  if (options.action != RuntimeOptions::Action::watch) {
    connection.receiveTimeout(30);
  }

  std::array<Byte, 32> outgoing;
  connection.send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false}, outgoing);
  Vector<Byte, Memory> incoming(max_payload_size, Byte{}, AllocatorRef<Byte, Memory>{memory});
  Vector<Byte, Memory> decoded(max_payload_size, Byte{}, AllocatorRef<Byte, Memory>{memory});
  std::uint64_t count = 0;
  for (;;) {
    const auto frame = connection.receive(incoming);
    DecodeStorage storage{decoded};
    const auto tag = static_cast<ServerTag>(frame.front());
    if (tag == ServerTag::request_failed) {
      const auto failure = Codec::decode<RequestFailed>(frame, storage);
      throw ControlFailure{failure.code, failure.message};
    }

    if (options.action == RuntimeOptions::Action::watch) {
      const bool selected = !options.proxy_only || tag == ServerTag::proxy_status || tag == ServerTag::runtime_stopping || tag == ServerTag::resync_required;
      if (selected) {
        const auto event = runtimeEventJson(frame, storage);
        if (!event.empty()) {
          writeText(event + "\n");
          ++count;
        }
      }

      if (tag == ServerTag::resync_required) {
        throw std::runtime_error{"RuntimeResyncRequired"};
      }

      if (tag == ServerTag::runtime_stopping || (options.count && count >= *options.count)) {
        return;
      }
    } else if (tag == ServerTag::proxy_status && options.action == RuntimeOptions::Action::status) {
      printRuntimeStatus(Codec::decode<ProxyStatus>(frame, storage), options.json);
      return;
    } else if (tag == ServerTag::system_metrics && options.action == RuntimeOptions::Action::metrics) {
      printRuntimeMetrics(Codec::decode<SystemMetrics>(frame, storage), options.json);
      return;
    } else if (tag == ServerTag::runtime_stopping) {
      throw std::runtime_error{"RuntimeStopping"};
    }
  }
}

template <Allocator Memory>
int runRuntime(Memory &memory, const RuntimeOptions &options) {
  try {
    observeRuntime(memory, options);
    return 0;
  } catch (const SystemError &error) {
    const bool timeout = error.code() == EAGAIN || error.code() == ETIMEDOUT;
    writeText(std::string{"telar runtime: "} + (timeout ? "RuntimeTimeout" : systemErrorName(error.code())) + "\n", STDERR_FILENO);
    return timeout ? 3 : 1;
  } catch (const std::exception &error) {
    const auto reason = commandErrorName(error);
    writeText("telar runtime: " + std::string{reason} + "\n", STDERR_FILENO);
    return reason == "RuntimeTimeout" ? 3 : 1;
  }
}

}
