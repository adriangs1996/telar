#pragma once

#include "metrics.hpp"

#include "../exchange_capture/pipeline.hpp"
#include "../platform/private_directory.hpp"
#include "../platform/process_environment.hpp"
#include "../platform/system_certificates.hpp"
#include "../tls/system_root_bundle.hpp"
#include "authority_directory.hpp"
#include "client_configuration.hpp"
#include "port_memory.hpp"
#include "secret_file.hpp"
#include "service.hpp"
#include "trust/service.hpp"
#include "../redirect/ingress.hpp"
#include <sys/resource.h>

namespace telar::runtime {

template <ConcurrentAllocator Memory, EventLoop Poller, HostnameResolver Resolver, typename Tap = IgnoreCaptureTap>
  requires CaptureTap<Tap, Memory>
class ProxyRuntime {
public:
  explicit ProxyRuntime(Memory &memory, const ProxyOptions<Memory> &options, std::string_view endpoint, bool inherit_legacy)
    requires std::same_as<Tap, IgnoreCaptureTap>
      : ProxyRuntime(memory, options, endpoint, inherit_legacy, ignored_tap_) {}

  explicit ProxyRuntime(Memory &memory, const ProxyOptions<Memory> &options, std::string_view endpoint, bool inherit_legacy, Tap &tap)
      : memory_(memory), authority_directory_(directoryPath(memory, options)), certificate_path_(AllocatorRef<char, Memory>{memory}), bundle_path_(AllocatorRef<char, Memory>{memory}) {
    TELAR_TRACE("proxy.startRuntime");
    const auto &path = authority_directory_;
    const proxy_trust::Paths trust_paths{memory, path};
    struct stat record_state{};
    const auto record_path = trust_paths.file(proxy_trust::Record::filename);
    const bool has_trust_record = ::lstat(record_path.c_str(), &record_state) == 0;
    if (!options.enabled && !has_trust_record) {
      return;
    }

    library_.emplace(memory);
    const auto destination = trust_paths.nativeDestination(memory, ProcessEnvironment{});
    proxy_trust::SystemCommand trust_command{memory, stderr};
    proxy_trust::Service system_trust{memory, *library_, trust_paths, trust_command, destination};
    if (const auto rotated = system_trust.rotateIfNeeded()) {
      std::fprintf(stderr, "telar proxy trust: installed %.*s\n", static_cast<int>(rotated->fingerprint.size()), rotated->fingerprint.data());
    }

    const bool system_trusted = system_trust.inspect().status == proxy_trust::Status::installed;
    if (!options.enabled) {
      return;
    }

    raiseDescriptorLimit();
    createPrivateDirectory(path);
    FileDescriptor directory{::open(path.c_str(), O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)};
    if (!directory) {
      throw SystemError{"Open proxy authority directory"};
    }

    const auto authority_kind = system_trusted ? AuthorityKind::system_trust : AuthorityKind::private_local;
    auto authority = std::allocate_shared<CertificateAuthority<Memory>>(AllocatorRef<CertificateAuthority<Memory>, Memory>{memory}, CertificateAuthority<Memory>::loadOrCreate(memory, *library_, directory.get(), authority_kind));
    publishAuthority(*authority, directory.get());
    trust_.emplace(memory, *library_);
    SystemCertificates::read([this](std::span<const std::uint8_t> bytes) { trust_->addDer(bytes); });
    contexts_.emplace(memory, *library_, *trust_);
    interception_.emplace(*contexts_, std::move(authority));
    secret_.emplace(ProxySecretFile::ensure(memory, directory.get()));
    ProxyPortMemory ports{memory, directory.get(), endpoint, inherit_legacy};
    auto listener = ProxyListener::bind(ports.preferred(), ports.reserved());
    ports.remember(listener.port());

    certificate_path_ = path;
    certificate_path_ += '/';
    certificate_path_ += active_certificate;
    bundle_path_ = path;
    bundle_path_ += "/ca-bundle.pem";
    status_.active = true;
    status_.system_trusted = system_trusted;
    status_.port = listener.port();
    status_.preferred_port = ports.preferred();
    status_.scope = std::ranges::any_of(options.intercept_hosts.patterns(), [](const auto &host) { return host.starts_with('*'); }) ? ProxyScope::wildcard : ProxyScope::exact;
    service_.emplace(memory, options, *secret_, *interception_, std::move(listener), flowControl(tap));
    if (options.transparent_redirect) {
      String<Memory> redirect_path{endpoint, AllocatorRef<char, Memory>{memory}};
      redirect_path += redirect::socket_suffix;
      redirect_.emplace(redirect_path, *service_);
    }
    if (options.capture.enabled) {
      captures_.emplace(memory, service_->captures(), options.capture, tap);
    }
  }

  ProxyClientConfiguration clientConfiguration() const noexcept {
    return secret_ ? ProxyClientConfiguration{status_, *secret_, certificate_path_, bundle_path_} : ProxyClientConfiguration{};
  }

  int descriptor() const noexcept { return captures_ ? captures_->descriptor() : -1; }
  bool collect() noexcept { return captures_ && captures_->collect(); }

  CaptureMetrics captureMetrics() const noexcept {
    return service_ ? service_->captures().metrics() : CaptureMetrics{};
  }

  ProxyMetrics proxyMetrics() const noexcept {
    if (!service_) {
      return {};
    }

    return {service_->counters().snapshot(), service_->active(), service_->limitDrops()};
  }

  redirect::MonitorState redirectStatus() const noexcept { return redirect_ ? redirect_->status() : redirect::MonitorState::idle; }
  void stopRedirect() noexcept { if (redirect_) { redirect_->stop(); } }

  struct AuthorityStatus {
    bool active = false;
    bool accepting = false;
    proxy_trust::Status trust = proxy_trust::Status::absent;
    std::array<char, 40> fingerprint_sha1{};
    std::array<char, 64> fingerprint_sha256{};
    std::array<Byte, PemDocument::maximum_bytes> certificate{};
    std::size_t certificate_bytes = 0;
  };

  AuthorityStatus authorityStatus(bool include_certificate = false) const {
    AuthorityStatus result;
    if (!interception_) { return result; }
    const proxy_trust::Paths paths{memory_, authority_directory_};
    const auto destination = paths.nativeDestination(memory_, ProcessEnvironment{});
    const auto inspection = proxy_trust::inspect(memory_, *library_, paths, destination);
    const auto current = interception_->snapshot();
    requireTls(current != nullptr, "TLS authority is unavailable");
    const auto &authority = *current;
    result.active = true;
    result.accepting = !interception_->suspended();
    result.trust = inspection.status;
    result.fingerprint_sha1 = authority.fingerprint();
    result.fingerprint_sha256 = authority.fingerprintSha256();
    if (inspection.record && inspection.record->fingerprint != result.fingerprint_sha1) { result.trust = proxy_trust::Status::stale; }
    if (include_certificate) {
      const PemDocument certificate{authority.certificate()};
      std::ranges::copy(certificate.bytes(), result.certificate.begin());
      result.certificate_bytes = certificate.bytes().size();
    }
    return result;
  }

  // Keep each handshake's signer alive independently. If store or file updates
  // fail, new TLS sessions remain suspended until an explicit retry synchronizes
  // the signer and the stable trust files used by newly launched processes.
  template <proxy_trust::TrustCommandExecutor Executor>
  void manageAuthority(proxy_trust::Action action, Executor &executor) {
    if (!interception_) { throw std::invalid_argument{"Proxy TLS is disabled"}; }
    const proxy_trust::Paths paths{memory_, authority_directory_};
    const auto destination = paths.nativeDestination(memory_, ProcessEnvironment{});
    proxy_trust::Service trust{memory_, *library_, paths, executor, destination};
    const auto previous = trust.inspect();
    if (previous.status == proxy_trust::Status::stale && !previous.record) { throw std::invalid_argument{"Proxy trust record is invalid"}; }
    interception_->suspend(true);
    const auto directory = paths.prepare();
    auto kind = AuthorityKind::private_local;
    if (action == proxy_trust::Action::uninstall) {
      if (previous.record) { trust.uninstall(*previous.record); }
    } else if (action == proxy_trust::Action::install || previous.record) {
      trust.install(previous.record, action == proxy_trust::Action::rotate);
      kind = AuthorityKind::system_trust;
    } else {
      proxy_trust::PreparedAuthority prepared{memory_, *library_, directory.get(), proxy_trust::AuthorityPreparation{.kind = AuthorityKind::private_local, .force_rotation = true}};
      prepared.activate();
      prepared.commit();
    }
    auto authority = std::allocate_shared<CertificateAuthority<Memory>>(AllocatorRef<CertificateAuthority<Memory>, Memory>{memory_}, CertificateAuthority<Memory>::loadOrCreate(memory_, *library_, directory.get(), kind));
    publishAuthority(*authority, directory.get());
    interception_->replace(std::move(authority));
    interception_->suspend(false);
  }

private:
  static constexpr std::string_view active_certificate = "ca-active-cert.pem";

  void publishAuthority(const CertificateAuthority<Memory> &authority, int directory) {
    const PemDocument certificate{authority.certificate()};
    if (const auto error = writePrivateFile(directory, active_certificate, certificate.bytes(), PrivateFileMode::replace)) { throw SystemError{"Publish active TLS certificate", error}; }
    authority.writeBundle(directory, SystemRootBundle{memory_}.bytes());
  }

  static traffic::FlowControl *flowControl(Tap &tap) noexcept {
    if constexpr (requires { tap.flowControl(); }) {
      return tap.flowControl();
    }
    return nullptr;
  }

  static String<Memory> directoryPath(Memory &memory, const ProxyOptions<Memory> &options) {
    if (!options.authority_directory.empty()) {
      return options.authority_directory;
    }

    return proxyAuthorityDirectory(memory, ProcessEnvironment{});
  }

  static void raiseDescriptorLimit() noexcept {
    constexpr rlim_t descriptors_per_connection = 2;
    constexpr rlim_t reserved_descriptors = 448;
    constexpr rlim_t wanted = ProxyConnectionPolicy::capacity * descriptors_per_connection + NameResolutions<Resolver>::capacity + reserved_descriptors;
    static_assert(wanted == 1024);
    rlimit limit;
    if (::getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < wanted) {
      limit.rlim_cur = std::min(limit.rlim_max, wanted);
      ::setrlimit(RLIMIT_NOFILE, &limit);
    }
  }

  Memory &memory_;
  String<Memory> authority_directory_;
  String<Memory> certificate_path_;
  String<Memory> bundle_path_;
  ProxyStatus status_{};
  std::optional<TlsLibrary<Memory>> library_;
  std::optional<TlsTrustStore<Memory>> trust_;
  std::optional<TlsContexts<Memory>> contexts_;
  std::optional<TlsInterception<Memory>> interception_;
  std::optional<ProxySecret> secret_;
  std::optional<ProxyService<Memory, Poller, Resolver>> service_;
  std::optional<CapturePipeline<Memory, Tap>> captures_;
  std::optional<redirect::Ingress<ProxyService<Memory, Poller, Resolver>>> redirect_;
  inline static IgnoreCaptureTap ignored_tap_;
};

}
