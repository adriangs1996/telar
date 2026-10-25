#pragma once

#include "../memory/sensitive_buffer.hpp"
#include "../platform/command.hpp"
#include "secret.hpp"

namespace telar::runtime {

class ProxyClientConfiguration {
public:
  ProxyClientConfiguration() noexcept = default;

  explicit ProxyClientConfiguration(ProxyStatus status, const ProxySecret &secret, std::string_view certificate, std::string_view bundle) noexcept
      : status_(status), secret_(&secret), certificate_(certificate), bundle_(bundle) {}

  const ProxyStatus &status() const noexcept {
    return status_;
  }

  template <Allocator Memory>
  void apply(Command<Memory> &command) const {
    if (!status_.active) {
      return;
    }

    SensitiveBuffer<256> storage;
    const auto bytes = storage.bytes();
    const auto url = secret_->formatUrl({reinterpret_cast<char *>(bytes.data()), bytes.size()}, *status_.port);
    if (!url) {
      throw SystemError{"Format child proxy URL", EOVERFLOW};
    }
    command.setEnvironment("HTTPS_PROXY", *url);
    command.setEnvironment("https_proxy", *url);
    command.setEnvironment("NODE_USE_ENV_PROXY", "1");
    command.setEnvironment("NODE_EXTRA_CA_CERTS", certificate_);
    for (const auto name : {"SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "AWS_CA_BUNDLE", "GIT_SSL_CAINFO", "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE"}) {
      command.setEnvironment(name, bundle_);
    }
    command.setEnvironment("TELAR_PROXY_TLS", "1");
  }

private:
  ProxyStatus status_{};
  const ProxySecret *secret_ = nullptr;
  std::string_view certificate_;
  std::string_view bundle_;
};

}
