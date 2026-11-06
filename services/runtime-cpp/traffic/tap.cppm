module;

#include "telar_platform/random_bytes.hpp"
#include <optional>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <array>
#include <cstdint>
#include <string_view>
#include <sys/stat.h>
#include <sys/un.h>
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstddef>
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <span>
#include <stdexcept>
#include <chrono>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <bit>
#include <csignal>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <utility>
#include <pcap/pcap.h>
#include <arpa/inet.h>
#include <string>
#include <unordered_map>
#include "telar_base/memory/fixed_text.hpp"
#include <charconv>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <limits.h>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <type_traits>
#include <poll.h>
#include <thread>

export module telar.runtime.traffic.tap;

export import telar.runtime.traffic.control_backend;

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
