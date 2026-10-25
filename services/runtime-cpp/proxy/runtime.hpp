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
      : certificate_path_(AllocatorRef<char, Memory>{memory}), bundle_path_(AllocatorRef<char, Memory>{memory}) {
    TELAR_TRACE("proxy.startRuntime");
    const auto path = directoryPath(memory, options);
    const proxy_trust::Paths trust_paths{memory, path};
    struct stat record_state{};
    const auto record_path = trust_paths.file(proxy_trust::Record::filename);
    const bool has_trust_record = ::lstat(record_path.c_str(), &record_state) == 0;
    if (!options.enabled && !has_trust_record) {
      return;
    }

    library_.emplace(memory);
    const auto keychain = trust_paths.keychain(memory, ProcessEnvironment{});
    proxy_trust::SystemCommand trust_command{memory, stderr};
    proxy_trust::Service system_trust{memory, *library_, trust_paths, trust_command, keychain};
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
    authority_.emplace(CertificateAuthority<Memory>::loadOrCreate(memory, *library_, directory.get(), authority_kind));
    authority_->writeBundle(directory.get(), SystemRootBundle{memory}.bytes());
    trust_.emplace(memory, *library_);
    SystemCertificates::read([this](std::span<const std::uint8_t> bytes) { trust_->addDer(bytes); });
    contexts_.emplace(memory, *library_, *trust_);
    interception_.emplace(*contexts_, *authority_);
    secret_.emplace(ProxySecretFile::ensure(memory, directory.get()));
    ProxyPortMemory ports{memory, directory.get(), endpoint, inherit_legacy};
    auto listener = ProxyListener::bind(ports.preferred(), ports.reserved());
    ports.remember(listener.port());

    certificate_path_ = path;
    certificate_path_ += '/';
    certificate_path_ += AuthorityFiles::forKind(authority_kind).certificate;
    bundle_path_ = path;
    bundle_path_ += "/ca-bundle.pem";
    status_.active = true;
    status_.system_trusted = system_trusted;
    status_.port = listener.port();
    status_.preferred_port = ports.preferred();
    status_.scope = std::ranges::any_of(options.intercept_hosts.patterns(), [](const auto &host) { return host.starts_with('*'); }) ? ProxyScope::wildcard : ProxyScope::exact;
    service_.emplace(memory, options, *secret_, *interception_, std::move(listener));
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

private:
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

  String<Memory> certificate_path_;
  String<Memory> bundle_path_;
  ProxyStatus status_{};
  std::optional<TlsLibrary<Memory>> library_;
  std::optional<CertificateAuthority<Memory>> authority_;
  std::optional<TlsTrustStore<Memory>> trust_;
  std::optional<TlsContexts<Memory>> contexts_;
  std::optional<TlsInterception<Memory>> interception_;
  std::optional<ProxySecret> secret_;
  std::optional<ProxyService<Memory, Poller, Resolver>> service_;
  std::optional<CapturePipeline<Memory, Tap>> captures_;
  inline static IgnoreCaptureTap ignored_tap_;
};

}
