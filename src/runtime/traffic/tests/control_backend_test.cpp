#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.traffic.redirect.ingress;
import telar.runtime.traffic.control_backend;
import telar.runtime.traffic.control_protocol;
import telar.tls;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  namespace control = telar::runtime::traffic::control;

  // The proxy as the control backend sees it: a redirect whose helper state the test sets, and no
  // authority.
  struct FakeProxy {
    struct Authority {
      bool active = false;
      bool accepting = false;
      proxy_trust::Status trust = proxy_trust::Status::absent;
      ds::Array<char, 40> fingerprint_sha1{};
      ds::Array<char, 64> fingerprint_sha256{};
      ds::Array<Byte, 1> certificate{};
      std::size_t certificate_bytes = 0;
    };

    struct ClientStatus {
      ds::Option<std::uint16_t> port;
    };

    struct Client {
      ClientStatus status() const noexcept {
        return {};
      }
    };

    redirect::MonitorState state = redirect::MonitorState::idle;
    unsigned authority_changes = 0;

    void stopRedirect() noexcept {}

    redirect::MonitorState redirectStatus() const noexcept {
      return state;
    }

    Authority authorityStatus(bool = false) const noexcept {
      return {};
    }

    Client clientConfiguration() const noexcept {
      return {};
    }

    template <typename Executor>
    void manageAuthority(proxy_trust::Action, Executor&) {
      ++authority_changes;
    }
  };

  struct Fixture {
    SystemAllocator system;
    SynchronizedAllocator<SystemAllocator> synchronized{system};
    MemoryAdapter<SynchronizedAllocator<SystemAllocator>> adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    FakeProxy proxy;
    ds::Array<Byte, control::Limits::reply_bytes> output;
    const std::atomic<bool> cancelled{false};

    control::Reply handle(control::Configuration configuration, const control::Request& request) {
      control::Backend backend{memory, proxy, nullptr, configuration};

      return control::Protocol::reply(backend.handle(request, output.viewMut(), cancelled));
    }
  };

  // The root helper must only ever redirect the runtime's own processes: a selected process of
  // another account fails the request before any helper is authorized.
  void testForeignProcessSelection() {
    if (::geteuid() == 0) {
      telar::testing::skip("every process belongs to root's account");
    }

    Fixture fixture;
    const auto reply = fixture.handle({.endpoint = "/tmp/fixture.sock", .executable = "/fixture/runtime", .redirect = true, .administration = true}, {.operation = control::Operation::redirect_start, .targets = {"127.0.0.1:443"}, .target_count = 1, .processes = {1}, .process_count = 1});

    check(reply.result == control::Result::failed && reply.argument_count == 0);
  }

  // Stopping a redirect reports what is left: nothing to stop without redirection, and a helper that
  // left without confirming its PF cleanup asks for the cleanup command.
  void testRedirectStopCleanup() {
    Fixture fixture;
    const control::Configuration disabled{.endpoint = "/tmp/fixture.sock", .executable = "/fixture/runtime", .administration = true};

    check(fixture.handle(disabled, {.operation = control::Operation::redirect_stop}).result == control::Result::disabled);

    auto enabled = disabled;

    enabled.redirect = true;
    fixture.proxy.state = redirect::MonitorState::cleanup_required;
    const auto reply = fixture.handle(enabled, {.operation = control::Operation::redirect_stop});

    check(reply.result == control::Result::cleanup_required && reply.argument_count >= 5);
    check(reply.authorization[0] == "/usr/bin/sudo" && reply.authorization[2] == "/fixture/runtime" && reply.authorization[4] == "redirect-cleanup");
  }

  // The certificate store is changed only through its own tools: any other program is refused
  // without running, and without a proxy no authority request reaches it.
  void testTrustCommandAllowlist() {
    Fixture fixture;
    const auto marker = std::filesystem::temp_directory_path() / ("telar-trust-" + std::to_string(::getpid()));
    const auto script = "touch " + marker.string();
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", script};
    control::TrustCommand command{fixture.memory, fixture.cancelled};
    bool refused = false;

    try {
      command.run(arguments);
    } catch (const std::invalid_argument&) {
      refused = true;
    }

    check(refused && !std::filesystem::exists(marker));

    const control::Configuration without_proxy{.endpoint = "/tmp/fixture.sock", .executable = "/fixture/runtime", .administration = true};

    for (const auto operation : {control::Operation::ca_install, control::Operation::ca_uninstall, control::Operation::ca_rotate}) {
      check(fixture.handle(without_proxy, {.operation = operation}).result == control::Result::disabled);
    }

    check(fixture.proxy.authority_changes == 0);
  }

  const telar::testing::Case case_foreign_process_selection{"traffic_control.foreign_process_selection", testForeignProcessSelection};
  const telar::testing::Case case_redirect_stop_cleanup{"traffic_control.redirect_stop_cleanup", testRedirectStopCleanup};
  const telar::testing::Case case_trust_command_allowlist{"traffic_control.trust_command_allowlist", testTrustCommandAllowlist};

}
