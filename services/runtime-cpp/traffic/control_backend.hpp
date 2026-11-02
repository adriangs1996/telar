#pragma once

#include "control_protocol.hpp"
#include "service.hpp"
#include "../platform/command_output.hpp"
#include "../platform/spawn_options.hpp"
#include "../proxy/runtime.hpp"
#include "../redirect/socket_owners.hpp"
#include "../redirect/process_token.hpp"
#include "../redirect/selection.hpp"
#include "../redirect/local_addresses.hpp"

namespace telar::runtime::traffic::control {

template <Allocator Memory>
class TrustCommand {
public:
  explicit TrustCommand(Memory &memory, const std::atomic<bool> &cancelled) noexcept : memory_(memory), cancelled_(cancelled) {}

  void run(std::span<const std::string_view> arguments) {
    if (arguments.empty() || arguments.front() != "/usr/bin/security") { throw std::invalid_argument{"Invalid trust operation"}; }
    Command command{memory_, Launch{.arguments = arguments}, CommandPurpose::administration};
    CommandOutput output{memory_, Limits::reply_bytes, &cancelled_};
    if (output.run(command, std::chrono::steady_clock::now() + std::chrono::seconds{10}, true) != 0) { throw SystemError{"Certificate store operation failed", EACCES}; }
  }

private:
  Memory &memory_;
  const std::atomic<bool> &cancelled_;
};

struct Configuration {
  std::string_view endpoint;
  std::string_view executable;
  bool proxy = false;
  bool redirect = false;
  bool transparent_tls = false;
  bool interception = false;
  bool administration = false;
};

template <ConcurrentAllocator Memory, typename Proxy>
class Backend {
  using Clock = std::chrono::steady_clock;
public:
  explicit Backend(Memory &memory, Proxy &proxy, traffic::Service<Memory> *capture, Configuration configuration)
      : memory_(memory), proxy_(proxy), capture_(capture), configuration_(configuration) {}

  ~Backend() {
    capture_cancelled_ = true;
    redirect_cancelled_ = true;
    if (capture_child_ > 0 && capture_) { capture_->stopCapture(); }
    if (redirect_child_ > 0) { proxy_.stopRedirect(); }
    const auto deadline = Clock::now() + std::chrono::seconds{5};
    while ((capture_child_ > 0 || redirect_child_ > 0) && Clock::now() < deadline) {
      tick();
      ::poll(nullptr, 0, 5);
    }
  }

  void tick() noexcept {
    reap(capture_child_);
    reap(redirect_child_);
    if (capture_cancelled_ && capture_child_ > 0 && capture_ && capture_->captureStatus().state != traffic::Service<Memory>::CaptureState::idle) { capture_->stopCapture(); }
    if (redirect_cancelled_ && redirect_child_ > 0) {
      const auto state = proxy_.redirectStatus();
      if (state == redirect::MonitorState::starting || state == redirect::MonitorState::active) { proxy_.stopRedirect(); }
    }
  }

  std::span<const Byte> handle(const Request &request, std::span<Byte> output, const std::atomic<bool> &cancelled, const plugins::ServiceSpec *package = nullptr) {
    Reply reply;
    std::optional<SensitiveAllocation<Memory>> recording_output;
    std::array<char, 1025> error{};
    try {
      if (package && !authorized(*package, request)) {
        reply.result = Result::disabled;
        reply.message = "Package traffic capability denied or revoked";
      } else if (request.operation != Operation::status && request.operation != Operation::ca_certificate && request.operation != Operation::recording && !configuration_.administration) {
        reply.result = Result::disabled;
        reply.message = "Runtime proxy.network_control permission is disabled";
      } else switch (request.operation) {
      case Operation::status:
      case Operation::ca_certificate:
        break;
      case Operation::capture_start:
      case Operation::redirect_start:
        start(request, reply, cancelled);
        break;
      case Operation::capture_stop:
        if (!capture_) { reply.result = Result::disabled; }
        else {
          capture_cancelled_ = true;
          const auto revision = capture_->stopCapture();
          if (!wait([&] { return capture_->captureStopped(revision) && capture_child_ <= 0; }, cancelled)) { reply.result = Result::busy; reply.message = "Capture is stopping"; }
        }
        break;
      case Operation::redirect_stop:
        if (!configuration_.redirect) { reply.result = Result::disabled; }
        else {
          redirect_cancelled_ = true;
          proxy_.stopRedirect();
          if (!wait([&] { const auto state = proxy_.redirectStatus(); return redirect_child_ <= 0 && (state == redirect::MonitorState::idle || state == redirect::MonitorState::cleanup_required); }, cancelled)) {
            reply.result = Result::busy;
            reply.message = "Redirect cleanup is still running";
          } else if (proxy_.redirectStatus() == redirect::MonitorState::cleanup_required) {
            reply.result = Result::cleanup_required;
            reply.message = "The helper disconnected without confirming PF cleanup";
            authorization(request, reply, "redirect-cleanup");
          }
        }
        break;
      case Operation::ca_install:
      case Operation::ca_uninstall:
      case Operation::ca_rotate:
        if (!configuration_.proxy) { reply.result = Result::disabled; }
        else {
          TrustCommand command{memory_, cancelled};
          proxy_.manageAuthority(request.operation == Operation::ca_install ? proxy_trust::Action::install : request.operation == Operation::ca_uninstall ? proxy_trust::Action::uninstall : proxy_trust::Action::rotate, command);
        }
        break;
      case Operation::recording:
        if (!capture_) { reply.result = Result::disabled; }
        else {
          recording_output.emplace(memory_, recording::Limits::page_bytes);
          reply.recording = capture_->recording(*request.recording, recording_output->bytes(), package ? recording::Owner::package(*package) : recording::Owner{});
        }
        break;
      }
    } catch (const std::exception &failure) {
      reply.result = Result::failed;
      const auto message = std::string_view{failure.what()}.substr(0, error.size() - 1);
      std::ranges::copy(message, error.begin());
      reply.message = {error.data(), message.size()};
    }

    reply.status = status();
    if (package && !package->allows(plugins::Capability::traffic_control)) { reply.status.administration = false; }
    const auto authority = proxy_.authorityStatus(request.operation == Operation::ca_certificate);
    reply.status.tls_accepting = authority.accepting;
    reply.status.trust = static_cast<TrustState>(authority.trust);
    if (authority.active) {
      reply.fingerprint_sha1 = {authority.fingerprint_sha1.data(), authority.fingerprint_sha1.size()};
      reply.fingerprint_sha256 = {authority.fingerprint_sha256.data(), authority.fingerprint_sha256.size()};
      reply.certificate = std::span{authority.certificate}.first(authority.certificate_bytes);
    } else if (request.operation == Operation::ca_certificate) { reply.result = Result::disabled; }
    return Protocol::encode(output, reply);
  }

private:
  Status status() const noexcept {
    Status status{.proxy = configuration_.proxy, .transparent_tls = configuration_.transparent_tls, .interception = configuration_.interception, .administration = configuration_.administration};
    const auto proxy = proxy_.clientConfiguration().status();
    status.port = proxy.port.value_or(0);
    if (capture_) {
      const auto capture = capture_->captureStatus();
      switch (capture.state) {
      case traffic::Service<Memory>::CaptureState::idle: status.capture = CaptureState::idle; break;
      case traffic::Service<Memory>::CaptureState::live: status.capture = CaptureState::live; break;
      case traffic::Service<Memory>::CaptureState::offline: status.capture = CaptureState::offline; break;
      }
      status.capture_session = capture.session;
      status.interfaces = capture.interfaces;
      status.interface_errors = capture.interface_errors;
    }
    if (configuration_.redirect) {
      switch (proxy_.redirectStatus()) {
      case redirect::MonitorState::idle: status.redirect = RedirectState::idle; break;
      case redirect::MonitorState::starting: status.redirect = RedirectState::starting; break;
      case redirect::MonitorState::active: status.redirect = RedirectState::active; break;
      case redirect::MonitorState::stopping: status.redirect = RedirectState::stopping; break;
      case redirect::MonitorState::cleanup_required: status.redirect = RedirectState::cleanup_required; break;
      }
    }
    return status;
  }

  void authorization(const Request &request, Reply &reply, std::string_view action) const {
    reply.authorization[0] = "/usr/bin/sudo";
    reply.authorization[1] = "--";
    reply.authorization[2] = configuration_.executable;
    reply.authorization[3] = "traffic";
    reply.authorization[4] = action;
    reply.authorization[5] = "--socket";
    reply.authorization[6] = configuration_.endpoint;
    reply.argument_count = 7;
    if (action == "redirect") {
      for (std::size_t index = 0; index < selection_->targets().size(); ++index) {
        reply.authorization[reply.argument_count++] = "--target";
        reply.authorization[reply.argument_count++] = selection_->argument(index);
      }
      for (std::size_t index = 0; index < request.process_count; ++index) {
        reply.authorization[reply.argument_count++] = "--process";
        reply.authorization[reply.argument_count++] = process_arguments_[index].view();
      }
      if (request.direction != redirect::Direction::outbound) {
        reply.authorization[reply.argument_count++] = "--direction";
        reply.authorization[reply.argument_count++] = redirect::directionName(request.direction);
      }
    }
  }

  void start(const Request &request, Reply &reply, const std::atomic<bool> &cancelled) {
    const bool capture = request.operation == Operation::capture_start;
    if (capture ? capture_ == nullptr : !configuration_.redirect) { reply.result = Result::disabled; return; }
    if (capture && capture_->captureStatus().state == traffic::Service<Memory>::CaptureState::live) { return; }
    if ((capture && capture_->captureStatus().state == traffic::Service<Memory>::CaptureState::offline) || (!capture && proxy_.redirectStatus() != redirect::MonitorState::idle && proxy_.redirectStatus() != redirect::MonitorState::cleanup_required)) {
      reply.result = Result::busy;
      reply.message = "An existing helper must stop before its selection changes";
      return;
    }
    if (!capture) {
      const ProcessInspector inspector;
      for (std::size_t index = 0; index < request.process_count; ++index) {
        const auto process = inspector.identity(static_cast<pid_t>(request.processes[index]));
        if (!process) { throw std::invalid_argument{"Selected process must be running under the runtime account"}; }
        process_arguments_[index] = redirect::ProcessToken::format(*process);
      }
      selection_.emplace(std::span{request.targets}.first(request.target_count), cancelled, Clock::now() + std::chrono::seconds{3});
      redirect::LocalAddresses::selection(selection_->targets(), request.direction);
    }
    auto &child = capture ? capture_child_ : redirect_child_;
    tick();
    if (child > 0) { reply.result = Result::busy; reply.message = "The previous helper is still stopping"; return; }
    (capture ? capture_cancelled_ : redirect_cancelled_) = false;
    authorization(request, reply, capture ? "capture" : "redirect");
    std::array<std::string_view, Limits::arguments> arguments;
    arguments[0] = "/usr/bin/sudo";
    arguments[1] = "-n";
    arguments[2] = "-l";
    std::ranges::copy(std::span{reply.authorization}.subspan(1, reply.argument_count - 1), arguments.begin() + 3);
    const auto count = reply.argument_count + 2;
    Command preflight{memory_, Launch{.arguments = std::span{arguments}.first(count)}, CommandPurpose::administration};
    CommandOutput result{memory_, Limits::reply_bytes, &cancelled};
    if (result.run(preflight, Clock::now() + std::chrono::seconds{3}, true) != 0) {
      reply.result = Result::authorization_required;
      reply.message = "Run authorization_argv in a terminal to authorize this native helper";
      return;
    }
    arguments[2] = "--";
    std::ranges::copy(std::span{reply.authorization}.subspan(2, reply.argument_count - 2), arguments.begin() + 3);
    Command command{memory_, Launch{.arguments = std::span{arguments}.first(count - 1)}, CommandPurpose::administration};
    const auto specification = command.specification({});
    SpawnOptions spawn{0};
    FileDescriptor input{::open("/dev/null", O_RDONLY | O_CLOEXEC)};
    if (!input) { throw SystemError{"Prepare privileged helper input"}; }
    spawn.redirect(input.get(), STDIN_FILENO);
    spawn.redirect(STDOUT_FILENO, STDOUT_FILENO);
    spawn.redirect(STDERR_FILENO, STDERR_FILENO);
    pid_t started;
    checkSpawn(::posix_spawn(&started, specification.executable, &spawn.actions, &spawn.attributes, specification.arguments, specification.environment));
    child = started;
    const auto ready = [&] { return capture ? capture_->captureStatus().state == traffic::Service<Memory>::CaptureState::live : proxy_.redirectStatus() == redirect::MonitorState::active; };
    wait([&] { return ready() || child <= 0; }, cancelled);
    if (!ready()) {
      reply.result = Result::failed;
      reply.message = "The privileged helper did not confirm activation; authorization_argv also provides its terminal diagnostics";
      (capture ? capture_cancelled_ : redirect_cancelled_) = true;
      if (capture) { capture_->stopCapture(); }
      if (!capture) { proxy_.stopRedirect(); }
      return;
    }
    reply.argument_count = 0;
  }

  template <typename Predicate>
  bool wait(Predicate predicate, const std::atomic<bool> &cancelled) {
    const auto deadline = Clock::now() + std::chrono::seconds{5};
    while (!predicate()) {
      if (cancelled.load(std::memory_order_acquire)) { throw std::runtime_error{"Network control is stopping"}; }
      if (Clock::now() >= deadline) { return false; }
      tick();
      ::poll(nullptr, 0, 5);
    }
    return true;
  }

  static void reap(pid_t &child) noexcept {
    if (child <= 0) { return; }
    int status;
    const auto waited = ::waitpid(child, &status, WNOHANG);
    if (waited == child || (waited < 0 && errno == ECHILD)) { child = -1; }
  }

  Memory &memory_;
  Proxy &proxy_;
  traffic::Service<Memory> *capture_;
  Configuration configuration_;
  static_assert(Limits::processes == redirect::SocketOwners::maximum_processes);
  static_assert(Limits::targets == redirect::Target::maximum_targets);
  std::optional<redirect::Selection<>> selection_;
  std::array<FixedText<redirect::ProcessToken::maximum_bytes>, Limits::processes> process_arguments_;
  pid_t capture_child_ = -1;
  pid_t redirect_child_ = -1;
  bool capture_cancelled_ = false;
  bool redirect_cancelled_ = false;
};

}
