#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <openssl/ssl.h>
#include <span>

namespace telar::runtime {

class AlpnSelection {
public:
  bool assign(std::span<const unsigned char> protocol) noexcept {
    if (protocol.size() > name_.size()) {
      return false;
    }
    std::copy(protocol.begin(), protocol.end(), name_.begin());
    length_ = static_cast<unsigned char>(protocol.size());
    return true;
  }

  std::span<const unsigned char> protocol() const noexcept {
    return std::span{name_}.first(length_);
  }

  // OpenSSL fixes this ABI; the selection is borrowed from the stable session via SSL app data.
  static int select(SSL *connection, const unsigned char **selected, unsigned char *length, const unsigned char *offered, unsigned offered_length, void *) noexcept {
    const auto *selection = static_cast<const AlpnSelection *>(SSL_get_app_data(connection));
    if (selection == nullptr || selection->length_ == 0) {
      return SSL_TLSEXT_ERR_NOACK;
    }

    std::span<const unsigned char> names{offered, offered_length};
    while (!names.empty()) {
      const auto size = names.front();
      names = names.subspan(1);
      if (size > names.size()) {
        return SSL_TLSEXT_ERR_ALERT_FATAL;
      }
      if (std::ranges::equal(names.first(size), selection->protocol())) {
        *selected = selection->name_.data();
        *length = selection->length_;
        return SSL_TLSEXT_ERR_OK;
      }
      names = names.subspan(size);
    }
    return SSL_TLSEXT_ERR_ALERT_FATAL;
  }

private:
  std::array<unsigned char, 255> name_;
  unsigned char length_ = 0;
};

}
