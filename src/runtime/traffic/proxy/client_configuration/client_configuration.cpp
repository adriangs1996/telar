module telar.runtime.traffic.proxy.client_configuration;

import telar.base.memory.sensitive;
import telar.platform.error;

namespace telar::runtime {

  ProxyClientConfiguration::ProxyClientConfiguration(std::shared_ptr<const Identity> identity) noexcept
      : identity_(std::move(identity)) {}

  const ProxyStatus& ProxyClientConfiguration::status() const noexcept {
    return identity_ ? identity_->status : inactive;
  }

  template <Allocator Memory>
  void ProxyClientConfiguration::apply(Command<Memory>& command) const {
    environment(&command, [](void* target, std::string_view name, std::string_view value) {
      static_cast<Command<Memory>*>(target)->setEnvironment({.name = name, .value = value});
    });
  }

  void ProxyClientConfiguration::environment(void* target, void (*set)(void* target, std::string_view name, std::string_view value)) const {
    if (!identity_ || !identity_->status.active) {
      return;
    }

    if (identity_->https_proxy) {
      // Room for the URL that carries the secret: scheme, user, the secret's digits, address and port.
      constexpr std::size_t url_capacity = 256;

      SensitiveBuffer<url_capacity> storage;
      const auto url = identity_->secret.formatUrl(charsOf(storage.bytes()), *identity_->status.port);
      if (!url) {
        throw SystemError{"Format child proxy URL", EOVERFLOW};
      }

      set(target, "HTTPS_PROXY", *url);
      set(target, "https_proxy", *url);
      set(target, "NODE_USE_ENV_PROXY", "1");
    }

    set(target, "NODE_EXTRA_CA_CERTS", identity_->certificate.view());
    for (const auto* const name : {"SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "AWS_CA_BUNDLE", "GIT_SSL_CAINFO", "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE"}) {
      set(target, name, identity_->bundle.view());
    }

    set(target, "TELAR_PROXY_TLS", "1");
  }

  template void ProxyClientConfiguration::apply(Command<Memory>& command) const;
  template void ProxyClientConfiguration::apply(Command<ConcurrentMemory>& command) const;
  template void ProxyClientConfiguration::apply(Command<SystemAllocator>& command) const;
  template void ProxyClientConfiguration::apply(Command<BudgetAllocator<SystemAllocator>>& command) const;
  template void ProxyClientConfiguration::apply(Command<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>& command) const;

}
