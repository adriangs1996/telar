module;
#include <cstdlib>
#include <stdlib.h>
#include <limits>
#include <concepts>
#include <new>
#include <vector>
#include <cstdio>
#include <variant>

#include <optional>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <cerrno>
#include <exception>
#include <array>
#include <cstdint>
#include <string_view>
#include <sys/stat.h>
#include <sys/un.h>
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstddef>
#include <cstring>
#include <span>
#include <stdexcept>
#include <chrono>
#include <bit>
#include <csignal>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <utility>
#include <pcap/pcap.h>
#include <arpa/inet.h>
#include <string>
#include <unordered_map>
#include <charconv>
#include <limits.h>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <type_traits>
#include <poll.h>
#include <thread>

export module telar.runtime.traffic.tap;

export import telar.runtime.traffic.control_backend;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: traffic/tap.cppm
export {
namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory, typename Plugins>
class Tap {
public:
  inline explicit Tap(Plugins &plugins, Service<Memory> *traffic) noexcept : plugins_(plugins), traffic_(traffic) {}

  inline FlowControl *flowControl() noexcept { return traffic_; }

  inline bool listening() const noexcept { return plugins_.listening() || (traffic_ && traffic_->listening()); }

  inline void submit(CapturedExchange<Memory> &exchange) noexcept {
    if (traffic_) {
      traffic_->submit(exchange);
    }
    plugins_.submit(exchange);
  }

private:
  Plugins &plugins_;
  Service<Memory> *traffic_;
};

}
}
