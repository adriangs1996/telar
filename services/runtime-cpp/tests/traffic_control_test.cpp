#include "check.hpp"
#include "tls_fixture.hpp"
#include "socket_pair.hpp"
#include "traffic/control_backend.hpp"
#include "traffic/control_service.hpp"
#include "traffic/connection.hpp"
#include "platform/temporary_directory.hpp"
#include <vector>

using namespace telar::runtime;
using telar::Byte;
namespace traffic_control = telar::runtime::traffic::control;

template <typename Predicate>
static void await(Predicate predicate) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (!predicate()) {
    check(std::chrono::steady_clock::now() < deadline);
    ::poll(nullptr, 0, 1);
  }
}

template <typename Operation>
static void rejects(Operation operation) {
  bool rejected = false;
  try { operation(); } catch (const std::exception &) { rejected = true; }
  check(rejected);
}

static void receiveAll(int socket, std::span<Byte> bytes) {
  while (!bytes.empty()) {
    pollfd descriptor{socket, POLLIN, 0};
    check(::poll(&descriptor, 1, 5000) > 0);
    const auto count = ::recv(socket, bytes.data(), bytes.size(), 0);
    check(count > 0);
    bytes = bytes.subspan(static_cast<std::size_t>(count));
  }
}

static std::vector<Byte> request(int socket, traffic_control::Request request) {
  std::array<Byte, traffic_control::Limits::request_bytes> output;
  const auto body = traffic_control::Protocol::encode(output, request);
  const auto prefix = traffic_control::Protocol::prefix(body.size());
  for (const auto byte : prefix) { traffic::sendAll(socket, {&byte, 1}); }
  for (const auto byte : body) { traffic::sendAll(socket, {&byte, 1}); }
  std::array<Byte, traffic_control::Protocol::prefix_bytes> header;
  receiveAll(socket, header);
  plugins::FrameReader reader{header};
  const auto size = reader.integer<std::uint32_t>();
  check(size <= traffic_control::Limits::reply_bytes);
  std::vector<Byte> reply(size);
  receiveAll(socket, reply);
  return reply;
}

static std::vector<Byte> request(const std::string &path, traffic_control::Request message) {
  const auto socket = traffic::connect(path);
  return request(socket.get(), message);
}

static void codec() {
  std::array<Byte, traffic_control::Limits::reply_bytes> output;
  traffic_control::Request redirect{.operation = traffic_control::Operation::redirect_start, .targets = {"127.0.0.1:443", "[::1]:80"}, .target_count = 2};
  const auto encoded = traffic_control::Protocol::encode(output, redirect);
  const std::vector<Byte> bytes{encoded.begin(), encoded.end()};
  const auto decoded = traffic_control::Protocol::request(bytes);
  check(decoded.operation == redirect.operation && decoded.target_count == 2 && decoded.targets[1] == "[::1]:80");
  redirect.processes[0] = static_cast<std::uint32_t>(::getpid());
  redirect.process_count = 1;
  const auto process_selection = traffic_control::Protocol::request(traffic_control::Protocol::encode(output, redirect));
  check(process_selection.process_count == 1 && process_selection.processes[0] == static_cast<std::uint32_t>(::getpid()));
  redirect.processes[1] = redirect.processes[0];
  redirect.process_count = 2;
  rejects([&] { traffic_control::Protocol::encode(output, redirect); });
  redirect.process_count = 0;
  redirect.direction = telar::runtime::redirect::Direction::inbound;
  check(traffic_control::Protocol::request(traffic_control::Protocol::encode(output, redirect)).direction == telar::runtime::redirect::Direction::inbound);
  redirect.direction = telar::runtime::redirect::Direction::both;
  check(traffic_control::Protocol::request(traffic_control::Protocol::encode(output, redirect)).direction == telar::runtime::redirect::Direction::both);
  redirect.process_count = 1;
  rejects([&] { traffic_control::Protocol::encode(output, redirect); });
  redirect.process_count = 0;
  redirect.direction = telar::runtime::redirect::Direction::outbound;
  auto invalid = std::vector<Byte>{bytes.begin(), bytes.end()};
  invalid.push_back(0);
  rejects([&] { traffic_control::Protocol::request(invalid); });
  invalid.assign(bytes.begin(), bytes.end());
  invalid[sizeof(traffic_control::Protocol::magic)] = UINT8_MAX;
  rejects([&] { traffic_control::Protocol::request(invalid); });
  rejects([&] { traffic_control::Protocol::encode(output, traffic_control::Request{.operation = traffic_control::Operation::redirect_start}); });
  rejects([&] { traffic_control::Protocol::encode(output, traffic_control::Request{.targets = {"127.0.0.1:80"}, .target_count = 1}); });
  redirect.targets[0] = std::string_view{"127.0.0.1:8\0bad", 14};
  rejects([&] { traffic_control::Protocol::encode(output, redirect); });

  traffic_control::Reply response{.result = traffic_control::Result::authorization_required, .status = {.capture = traffic_control::CaptureState::live, .redirect = traffic_control::RedirectState::active, .interfaces = 2}, .message = "fixture", .authorization = {"/usr/bin/sudo", "--", "/fixture/runtime"}, .argument_count = 3};
  const auto reply = traffic_control::Protocol::reply(traffic_control::Protocol::encode(output, response));
  check(reply.result == response.result && reply.status.interfaces == 2 && reply.authorization[2] == "/fixture/runtime");
}

static void captureControl(TlsTestMemory &memory) {
  TemporaryDirectory directory{"/tmp/tlr-control.XXXXXX"};
  const auto base = std::string{directory.path()} + "/runtime.sock";
  traffic::Service capture{memory, base + ".traffic"};
  ProxyOptions options{memory};
  ProxyRuntime<TlsTestMemory, NativeEventLoop<TlsTestMemory>, SystemNameResolver> proxy{memory, options, base, false};
  traffic_control::Backend backend{memory, proxy, &capture, traffic_control::Configuration{.endpoint = base, .executable = "/fixture/runtime", .administration = true}};
  traffic_control::Service service{memory, base + ".network", backend};
  auto status = request(base + ".network", {});
  check(traffic_control::Protocol::reply(status).status.capture == traffic_control::CaptureState::idle);
  auto disabled = request(base + ".network", {.operation = traffic_control::Operation::redirect_start, .targets = {"127.0.0.1:80"}, .target_count = 1});
  check(traffic_control::Protocol::reply(disabled).result == traffic_control::Result::disabled);

  auto producer = traffic::connect(base + ".traffic");
  std::array<Byte, traffic::Protocol::greeting_bytes> greeting;
  traffic::sendAll(producer.get(), traffic::Protocol::greeting(greeting, traffic::Role::offline_capture));
  await([&] { return capture.captureStatus().state == decltype(capture)::CaptureState::offline; });
  auto active = request(base + ".network", {});
  check(traffic_control::Protocol::reply(active).status.capture == traffic_control::CaptureState::offline);
  traffic_control::Backend read_only{memory, proxy, &capture, traffic_control::Configuration{.endpoint = base, .executable = "/fixture/runtime"}};
  std::array<Byte, traffic_control::Limits::reply_bytes> denied;
  const std::atomic<bool> cancelled{false};
  const auto forbidden = traffic_control::Protocol::reply(read_only.handle({.operation = traffic_control::Operation::capture_stop}, denied, cancelled));
  check(forbidden.result == traffic_control::Result::disabled && !forbidden.status.administration);
  check(capture.captureStatus().state == decltype(capture)::CaptureState::offline);
  auto stopped = request(base + ".network", {.operation = traffic_control::Operation::capture_stop});
  check(traffic_control::Protocol::reply(stopped).result == traffic_control::Result::ok);
  check(traffic_control::Protocol::reply(stopped).status.capture == traffic_control::CaptureState::idle);
  std::array<Byte, 1024> incoming;
  await([&] { return ::recv(producer.get(), incoming.data(), incoming.size(), MSG_DONTWAIT) == 0; });

  auto malformed = traffic::connect(base + ".network");
  std::array<Byte, traffic_control::Protocol::prefix_bytes> excessive{0xff, 0xff, 0xff, 0x7f};
  traffic::sendAll(malformed.get(), excessive);
  await([&] { Byte byte; return ::recv(malformed.get(), &byte, 1, MSG_DONTWAIT) == 0; });
  status = request(base + ".network", {});
  check(traffic_control::Protocol::reply(status).result == traffic_control::Result::ok);
}

static void destinationAuthorization(TlsTestMemory &memory) {
  TemporaryDirectory directory{"/tmp/tlr-selection-control.XXXXXX"};
  const auto base = std::string{directory.path()} + "/runtime.sock";
  const auto missing_executable = std::string{directory.path()} + "/missing-runtime";
  ProxyOptions options{memory};
  ProxyRuntime<TlsTestMemory, NativeEventLoop<TlsTestMemory>, SystemNameResolver> proxy{memory, options, base, false};
  traffic::Service capture{memory, base + ".traffic"};
  traffic_control::Backend backend{memory, proxy, &capture, traffic_control::Configuration{.endpoint = base, .executable = missing_executable, .redirect = true, .administration = true}};
  traffic_control::Service service{memory, base + ".network", backend};
  const auto bytes = request(base + ".network", {.operation = traffic_control::Operation::redirect_start, .targets = {"localhost:443"}, .target_count = 1, .processes = {static_cast<std::uint32_t>(::getpid())}, .process_count = 1});
  const auto reply = traffic_control::Protocol::reply(bytes);
  check(reply.result == traffic_control::Result::authorization_required || reply.result == traffic_control::Result::failed);
  check(reply.argument_count >= 11 && reply.authorization[2] == missing_executable);
  std::size_t targets = 0;
  for (std::size_t index = 7; index < reply.argument_count; index += 2) {
    if (reply.authorization[index] == "--target") {
      const auto target = redirect::Target::parse(reply.authorization[index + 1]);
      check((target.host.view() == "127.0.0.1" || target.host.view() == "::1") && target.port == 443);
      ++targets;
    } else {
      check(reply.authorization[index] == "--process");
      const auto process = redirect::ProcessToken::parse(reply.authorization[index + 1]);
      check(process.pid == ::getpid() && process.started_seconds != 0);
    }
  }
  check(targets != 0 && reply.status.redirect == traffic_control::RedirectState::idle);
}

static void packageControl(TlsTestMemory &memory) {
  namespace app = telar::runtime::plugins;
  namespace recording = traffic::recording;
  TemporaryDirectory directory{"/tmp/tlr-package-control.XXXXXX"};
  const auto base = std::string{directory.path()} + "/runtime.sock";
  traffic::Service capture{memory, base + ".traffic"};
  ProxyOptions options{memory};
  ProxyRuntime<TlsTestMemory, NativeEventLoop<TlsTestMemory>, SystemNameResolver> proxy{memory, options, base, false};
  traffic_control::Backend backend{memory, proxy, &capture, traffic_control::Configuration{.endpoint = base, .executable = "/fixture/runtime", .administration = true}};
  traffic_control::Service service{memory, base + ".network", backend};
  const auto package = [](app::Capability capability, Byte digest) {
    app::ServiceSpec specification;
    specification.plugin_id = 11;
    specification.generation = 1;
    specification.digest.fill(digest);
    specification.declared.insert(capability);
    specification.granted.insert(capability);
    specification.permission = std::make_shared<std::atomic<bool>>(true);
    return specification;
  };
  const auto observer = package(app::Capability::traffic_observe, 0x5a);
  const auto recorder = package(app::Capability::traffic_record, 0x5b);
  const auto other = package(app::Capability::traffic_record, 0x5c);
  const auto send = [&](const app::ServiceSpec &specification, const traffic_control::Request &message) {
    const auto channel = service.openPackage(specification);
    return request(channel.get(), message);
  };
  auto denied = send(observer, {.operation = traffic_control::Operation::capture_stop});
  check(traffic_control::Protocol::reply(denied).result == traffic_control::Result::disabled);
  denied = send(observer, {.operation = traffic_control::Operation::recording, .recording = recording::Request{.operation = recording::Operation::list}});
  check(traffic_control::Protocol::reply(denied).result == traffic_control::Result::disabled);
  auto status = send(recorder, {});
  check(traffic_control::Protocol::reply(status).result == traffic_control::Result::ok && !traffic_control::Protocol::reply(status).status.administration);
  const traffic_control::Request start{.operation = traffic_control::Operation::recording, .recording = recording::Request{.operation = recording::Operation::start, .max_bytes = 4096, .max_events = 2}};
  auto first = send(recorder, start);
  auto second = send(other, start);
  const auto id = recording::Protocol::page(traffic_control::Protocol::reply(first).recording).id;
  const auto other_id = recording::Protocol::page(traffic_control::Protocol::reply(second).recording).id;
  for (const auto operation : {recording::Operation::query, recording::Operation::stop, recording::Operation::erase, recording::Operation::pcapng}) {
    const auto forbidden = send(other, {.operation = traffic_control::Operation::recording, .recording = recording::Request{.operation = operation, .id = id}});
    check(traffic_control::Protocol::reply(forbidden).result == traffic_control::Result::failed);
  }
  const auto listing = send(other, {.operation = traffic_control::Operation::recording, .recording = recording::Request{.operation = recording::Operation::list}});
  const auto page = recording::Protocol::page(traffic_control::Protocol::reply(listing).recording);
  plugins::FrameReader rows{page.rows};
  check(page.count == 1 && recording::Protocol::page(rows.bytes()).id == other_id);
  const auto revoked_channel = service.openPackage(recorder);
  recorder.permission->store(false, std::memory_order_release);
  capture.revokePackage(recorder);
  const auto revoked = request(revoked_channel.get(), {});
  check(traffic_control::Protocol::reply(revoked).result == traffic_control::Result::disabled);
  rejects([&] { service.openPackage(recorder); });
  const auto visible = request(base + ".network", {.operation = traffic_control::Operation::recording, .recording = recording::Request{.id = id}});
  check(!recording::Protocol::page(traffic_control::Protocol::reply(visible).recording).active);
}

struct SameUser {
  static bool allows(uid_t uid) noexcept { return uid == ::geteuid(); }
};
struct IgnoreConnections {
  bool adopt(redirect::Connection) noexcept { return false; }
};

static FileDescriptor monitor(const std::string &path) {
  auto channel = traffic::connect(path);
  std::array<Byte, redirect::Protocol::frame_bytes> output;
  traffic::sendAll(channel.get(), redirect::Protocol::encode(output, redirect::Kind::monitor, {}));
  std::array<Byte, sizeof(std::uint32_t)> uid;
  receiveAll(channel.get(), uid);
  return channel;
}

static void redirectControl() {
  TemporaryDirectory directory{"/tmp/tlr-monitor.XXXXXX"};
  const auto path = std::string{directory.path()} + "/redirect";
  IgnoreConnections sink;
  redirect::Ingress<IgnoreConnections, SameUser> ingress{path, sink};
  auto helper = monitor(path);
  await([&] { return ingress.status() == redirect::MonitorState::starting; });
  const auto active = static_cast<Byte>(redirect::MonitorUpdate::active);
  traffic::sendAll(helper.get(), {&active, 1});
  await([&] { return ingress.status() == redirect::MonitorState::active; });
  ingress.stop();
  Byte stop;
  receiveAll(helper.get(), {&stop, 1});
  check(stop == redirect::stop_request && ingress.status() == redirect::MonitorState::stopping);
  const auto stopped = static_cast<Byte>(redirect::MonitorUpdate::stopped);
  traffic::sendAll(helper.get(), {&stopped, 1});
  helper.reset();
  await([&] { return ingress.status() == redirect::MonitorState::idle; });
  helper = monitor(path);
  helper.reset();
  await([&] { return ingress.status() == redirect::MonitorState::cleanup_required; });

  helper = monitor(path);
  ingress.stop();
  receiveAll(helper.get(), {&stop, 1});
  const std::array updates{active, stopped};
  traffic::sendAll(helper.get(), updates);
  helper.reset();
  await([&] { return ingress.status() == redirect::MonitorState::idle; });
}

struct TrustCommands {
  std::vector<std::vector<std::string>> calls;
  bool fail = false;
  void run(std::span<const std::string_view> arguments) {
    if (fail) { throw SystemError{"Fixture certificate-store rejection", EACCES}; }
    std::vector<std::string> call;
    for (const auto argument : arguments) { call.emplace_back(argument); }
    calls.push_back(std::move(call));
  }
};

static void authorityControl(TlsTestMemory &memory) {
  TemporaryDirectory directory{"/tmp/tlr-authority.XXXXXX"};
  ProxyOptions options{memory};
  options.enabled = true;
  options.authority_directory = directory.path();
  options.capture.enabled = false;
  ProxyRuntime<TlsTestMemory, NativeEventLoop<TlsTestMemory>, SystemNameResolver> proxy{memory, options, std::string{directory.path()} + "/runtime.sock", false};
  const auto original = proxy.authorityStatus(true);
  check(original.active && original.accepting && original.trust == proxy_trust::Status::absent);
  const std::string certificate{reinterpret_cast<const char *>(original.certificate.data()), original.certificate_bytes};
  check(certificate.starts_with("-----BEGIN CERTIFICATE-----") && !certificate.contains("PRIVATE KEY"));

  TrustCommands commands;
  proxy.manageAuthority(proxy_trust::Action::rotate, commands);
  const auto rotated = proxy.authorityStatus(true);
  check(rotated.accepting && rotated.fingerprint_sha256 != original.fingerprint_sha256 && commands.calls.empty());
  proxy.manageAuthority(proxy_trust::Action::install, commands);
  const auto installed = proxy.authorityStatus();
  check(installed.accepting && installed.trust == proxy_trust::Status::installed && installed.fingerprint_sha256 != rotated.fingerprint_sha256);
  check(commands.calls.size() == 1);
#if defined(__APPLE__)
  check(commands.calls[0][1] == "add-trusted-cert");
#else
  check(commands.calls[0][2] == "/usr/bin/trust" && commands.calls[0][3] == "anchor");
#endif
  proxy.manageAuthority(proxy_trust::Action::rotate, commands);
  const auto replaced = proxy.authorityStatus();
  check(replaced.accepting && replaced.trust == proxy_trust::Status::installed && replaced.fingerprint_sha256 != installed.fingerprint_sha256);
  check(commands.calls.size() == 3);
#if defined(__APPLE__)
  check(commands.calls[2][1] == "delete-certificate");
#else
  check(commands.calls[2][2] == "/usr/bin/trust" && commands.calls[2][3] == "anchor" && commands.calls[2][4] == "--remove");
#endif
  proxy.manageAuthority(proxy_trust::Action::uninstall, commands);
  const auto uninstalled = proxy.authorityStatus();
  check(uninstalled.accepting && uninstalled.trust == proxy_trust::Status::absent && uninstalled.fingerprint_sha256 == rotated.fingerprint_sha256);

  const proxy_trust::Paths paths{memory, directory.path()};
  const auto handle = paths.open();
  Vector<Byte, TlsTestMemory> published{AllocatorRef<Byte, TlsTestMemory>{memory}};
  check(readPrivateFile(handle.get(), "ca-active-cert.pem", published, PemDocument::maximum_bytes));
  check(std::ranges::equal(published, std::span{rotated.certificate}.first(rotated.certificate_bytes)));
  commands.fail = true;
  rejects([&] { proxy.manageAuthority(proxy_trust::Action::install, commands); });
  check(!proxy.authorityStatus().accepting);
  commands.fail = false;
  proxy.manageAuthority(proxy_trust::Action::uninstall, commands);
  check(proxy.authorityStatus().accepting && proxy.authorityStatus().fingerprint_sha256 == rotated.fingerprint_sha256);
}

int main() {
  codec();
  SystemAllocator system;
  BudgetAllocator budget{system, 256 * 1024 * 1024};
  TlsTestMemory memory{budget};
  captureControl(memory);
  destinationAuthorization(memory);
  packageControl(memory);
  redirectControl();
  authorityControl(memory);
  check(budget.liveBytes() == 0);
  std::puts("Network control: bounded IPC, capture stop, redirect activation/cleanup acknowledgement and live CA lifecycle passed");
}
