#include "check.hpp"
#include "protocol_peer.hpp"
#include <chrono>

using namespace telar;

int main(int argc, char **argv) {
  if (argc != 5 || std::string_view{argv[2]} != "metrics") {
    return 2;
  }

  try {
    ProtocolPeer client{argv[1]};
    const auto started = std::chrono::steady_clock::now();
    client.send(RequestRuntimeState{.client_identity = 41, .interactive = true});
    const auto first = client.receive<SystemMetrics>();
    const auto elapsed = std::chrono::steady_clock::now() - started;
    check(first.revision == 2 && first.cpu_percent == 0);
    check(first.memory_used_decigib > 0 && first.memory_total_decigib > 0 && first.cpu_count > 0);
    check(elapsed >= std::chrono::seconds{1} && elapsed < std::chrono::seconds{8});

    ProtocolPeer later{argv[1]};
    later.send(RequestRuntimeState{.client_identity = 42, .interactive = false});
    const auto retained = later.receive<SystemMetrics>();
    check(retained.revision == first.revision && retained.cpu_percent == first.cpu_percent && retained.memory_used_decigib == first.memory_used_decigib);
    check(retained.cpu_count == first.cpu_count && retained.memory_total_decigib == first.memory_total_decigib && retained.has_battery == first.has_battery && retained.battery_percent == first.battery_percent);

    auto stable = first;
    stable.memory_used_decigib = 0;
    stable.battery_percent = 0;
    std::ofstream dump{argv[4], std::ios::binary};
    client.record(dump, stable);
    std::printf("{\"initial_delivery_ns\":%lld,\"cpu_count\":%u,\"memory_used_decigib\":%u,\"memory_total_decigib\":%u,\"has_battery\":%s,\"battery_percent\":%u}\n", static_cast<long long>(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count()), first.cpu_count, first.memory_used_decigib, first.memory_total_decigib, first.has_battery ? "true" : "false", first.battery_percent);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
