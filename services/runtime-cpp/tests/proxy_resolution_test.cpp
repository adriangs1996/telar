#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include <pthread.h>
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <array>
#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <optional>
#include <sys/socket.h>
#include <netdb.h>
#include <span>
#include <string_view>
#include <algorithm>
#include <arpa/inet.h>
#include <cstddef>
#include "telar_platform/trace.hpp"
#include <concepts>
#include <type_traits>
#include <utility>
#include <atomic>
#include <chrono>
#include <poll.h>
#include <semaphore>
#include <thread>



import telar.runtime.proxy.relay_direction;

using namespace telar;
using namespace telar::runtime;

struct BlockingNameResolver {
  inline static std::counting_semaphore<64> permits{0};
  inline static std::atomic<unsigned> calls{0};

  static ResolutionSummary resolve(const char *, std::span<NetworkAddress> addresses) noexcept {
    calls.fetch_add(1);
    permits.acquire();
    sockaddr_in address{};
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(443);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    for (auto &destination : addresses) {
      destination = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&address), sizeof(address));
    }
    return {.found = 40};
  }
};

template <typename Condition>
static void waitFor(const Condition &ready) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (!ready()) {
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
}

static void waitSignal(CompletionSignal &signal) {
  pollfd pending{.fd = signal.descriptor(), .events = POLLIN, .revents = 0};
  check(::poll(&pending, 1, 5000) == 1);
  signal.drain();
}

static void testSharedResolution() {
  using Resolutions = NameResolutions<BlockingNameResolver>;
  CompletionSignal first_signal;
  CompletionSignal second_signal;
  Resolutions::Notifications first_notifications{first_signal};
  Resolutions::Notifications second_notifications{second_signal};
  auto first = Resolutions::request("shared.example");
  auto second = Resolutions::request("SHARED.EXAMPLE");
  check(first && second && Resolutions::pending() == 1);
  check(!Resolutions::request("invalid..example"));
  waitFor([] { return BlockingNameResolver::calls.load() == 1; });
  Resolutions::Result result;
  check(!first->collect(result));
  first.reset();
  BlockingNameResolver::permits.release();
  waitSignal(first_signal);
  waitSignal(second_signal);
  check(second->collect(result) && result.summary.found == 40 && result.summary.error == 0);
  for (const auto &address : result.addresses) {
    check(address.storage.ss_family == AF_INET && address.length == sizeof(sockaddr_in));
    check(reinterpret_cast<const sockaddr_in *>(&address.storage)->sin_port == 0);
  }
  auto moved = std::move(*second);
  check(!second->collect(result) && moved.collect(result));
  moved.reset();
  check(Resolutions::pending() == 0);
}

static void testResolutionSaturation() {
  using Resolutions = NameResolutions<BlockingNameResolver>;
  {
    CompletionSignal signal;
    Resolutions::Notifications notifications{signal};
    std::array<std::optional<Resolutions::Ticket>, Resolutions::capacity> tickets;
    for (std::size_t index = 0; index < tickets.size(); ++index) {
      tickets[index] = Resolutions::request("host" + std::to_string(index) + ".example");
      check(tickets[index].has_value());
    }
    check(Resolutions::pending() == Resolutions::capacity && !Resolutions::request("overflow.example"));
    auto shared = Resolutions::request("HOST0.EXAMPLE");
    check(shared.has_value());
    shared.reset();
  }
  check(Resolutions::pending() == Resolutions::capacity);
  BlockingNameResolver::permits.release(Resolutions::capacity);
  waitFor([] { return Resolutions::pending() == 0; });

  CompletionSignal signal;
  Resolutions::Notifications notifications{signal};
  auto next = Resolutions::request("reused.example");
  check(next.has_value());
  BlockingNameResolver::permits.release();
  waitSignal(signal);
  Resolutions::Result result;
  check(next->collect(result) && result.summary.found == 40);
}

static void testSystemResolution() {
  using Resolutions = NameResolutions<SystemNameResolver>;
  CompletionSignal signal;
  Resolutions::Notifications notifications{signal};
  auto local = Resolutions::request("localhost");
  check(local.has_value());
  waitSignal(signal);
  Resolutions::Result result;
  check(local->collect(result) && result.summary.error == 0 && result.summary.found > 0);
}

void testProxyResolution() {
  testSharedResolution();
  testResolutionSaturation();
  testSystemResolution();
}
