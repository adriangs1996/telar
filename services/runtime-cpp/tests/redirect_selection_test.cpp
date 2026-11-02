#include "check.hpp"
#include "redirect/selection.hpp"
#include <semaphore>
#include <thread>

using namespace telar::runtime;

struct SelectionResolver {
  inline static std::binary_semaphore release{0};
  inline static std::atomic<bool> blocked{false};

  static ResolutionSummary resolve(const char *hostname, std::span<NetworkAddress> output) noexcept {
    const std::string_view name{hostname};
    if (name == "blocked.test") {
      blocked = true;
      release.acquire();
    }
    if (name == "missing.test") { return {.error = EAI_NONAME}; }
    if (name == "truncated.test") { return {.found = output.size() + 1}; }
    const std::size_t found = name == "overflow.test" ? 17 : name == "mixed.test" ? 3 : 1;
    for (std::size_t index = 0; index < found; ++index) {
      sockaddr_in address{};
#if defined(__APPLE__)
      address.sin_len = sizeof(address);
#endif
      address.sin_family = AF_INET;
      address.sin_addr.s_addr = htonl(name == "multicast.test" ? 0xe0000001u : 0x7f000001u + (name == "overflow.test" ? static_cast<unsigned>(index) : 0));
      output[index] = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&address), sizeof(address));
    }
    if (name == "mixed.test" || name == "scoped.test") {
      sockaddr_in6 address{};
#if defined(__APPLE__)
      address.sin6_len = sizeof(address);
#endif
      address.sin6_family = AF_INET6;
      address.sin6_addr = in6addr_loopback;
      address.sin6_scope_id = name == "scoped.test" ? 1 : 0;
      output[name == "mixed.test" ? 1 : 0] = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&address), sizeof(address));
    }
    return {.found = found};
  }
};

template <typename Operation>
static void rejects(Operation operation) {
  bool failed = false;
  try { operation(); } catch (const std::exception &) { failed = true; }
  check(failed);
}

static void resolution() {
  const std::atomic<bool> cancelled{false};
  const std::array<std::string_view, 3> input{"mixed.test:443", "alias.test:443", "127.0.0.1:80"};
  const redirect::Selection<SelectionResolver> selected{input, cancelled, std::chrono::steady_clock::now() + std::chrono::seconds{2}};
  check(selected.targets().size() == 3);
  bool v4 = false;
  bool v6 = false;
  bool http = false;
  for (std::size_t index = 0; index < selected.targets().size(); ++index) {
    v4 |= selected.argument(index) == "127.0.0.1:443";
    v6 |= selected.argument(index) == "[::1]:443";
    http |= selected.argument(index) == "127.0.0.1:80";
    const auto parsed = redirect::Target::parse(selected.argument(index));
    check(parsed.host.view() == selected.targets()[index].host.view() && parsed.port == selected.targets()[index].port);
  }
  check(v4 && v6 && http);

  for (const auto input : {"*.test:443", "invalid..test:443", "host.test:0", "host.test:65536", "host.test", "[host.test]:443", "0.0.0.0:443", "[::]:443", "999.1.1.1:443", "missing.test:443", "truncated.test:443", "overflow.test:443", "multicast.test:443", "scoped.test:443"}) {
    const std::array<std::string_view, 1> invalid{input};
    rejects([&] { const redirect::Selection<SelectionResolver> selected{invalid, cancelled, std::chrono::steady_clock::now() + std::chrono::seconds{2}}; });
  }
  const std::array<std::string_view, 2> duplicate{"[::1]:443", "[0:0:0:0:0:0:0:1]:443"};
  rejects([&] { const redirect::Selection<SelectionResolver> selected{duplicate, cancelled, std::chrono::steady_clock::now() + std::chrono::seconds{2}}; });
}

static void deadlineAndCancellation() {
  const std::array<std::string_view, 1> input{"blocked.test:443"};
  std::atomic<bool> cancelled{false};
  const auto started = std::chrono::steady_clock::now();
  rejects([&] { const redirect::Selection<SelectionResolver> selected{input, cancelled, started + std::chrono::milliseconds{40}}; });
  check(std::chrono::steady_clock::now() - started < std::chrono::seconds{1});
  SelectionResolver::release.release();
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  while (NameResolutions<SelectionResolver>::pending() != 0) {
    check(std::chrono::steady_clock::now() < deadline);
    ::poll(nullptr, 0, 1);
  }

  SelectionResolver::blocked = false;
  std::jthread cancel{[&] {
    while (!SelectionResolver::blocked) {
      check(std::chrono::steady_clock::now() < deadline);
      ::poll(nullptr, 0, 1);
    }
    cancelled = true;
  }};
  rejects([&] { const redirect::Selection<SelectionResolver> selected{input, cancelled, deadline}; });
  SelectionResolver::release.release();
  cancel.join();
  while (NameResolutions<SelectionResolver>::pending() != 0) {
    check(std::chrono::steady_clock::now() < deadline);
    ::poll(nullptr, 0, 1);
  }
}

static void systemResolver() {
  const std::atomic<bool> cancelled{false};
  const std::array<std::string_view, 1> input{"localhost:443"};
  const redirect::Selection selected{input, cancelled, std::chrono::steady_clock::now() + std::chrono::seconds{3}};
  check(!selected.targets().empty());
  for (const auto &target : selected.targets()) { check(target.host.view() == "127.0.0.1" || target.host.view() == "::1"); }
}

int main() {
  resolution();
  deadlineAndCancellation();
  systemResolver();
  std::puts("Redirect DNS selection, numeric scope, bounds, deadline and cancellation verified");
}
