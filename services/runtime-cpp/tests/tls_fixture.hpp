#pragma once

#include "check.hpp"
#include "platform/private_directory.hpp"
#include "tls/authority.hpp"
#include <cstring>
#include <filesystem>

using namespace telar::runtime;

using TlsTestMemory = SynchronizedAllocator<BudgetAllocator<SystemAllocator>>;

class AuthorityDirectory {
public:
  AuthorityDirectory() {
    std::array<char, 64> path{};
    std::strcpy(path.data(), "/tmp/telar-tls-test.XXXXXX");
    check(::mkdtemp(path.data()) != nullptr);
    path_ = path.data();
    descriptor = FileDescriptor{::open(path_.c_str(), O_DIRECTORY | O_CLOEXEC | O_RDONLY)};
    check(static_cast<bool>(descriptor));
  }

  ~AuthorityDirectory() {
    std::filesystem::remove_all(path_);
  }

  FileDescriptor descriptor;

private:
  std::filesystem::path path_;
};

inline bool advanceTlsPeer(SSL *connection, bool &failed) {
  ERR_clear_error();
  const int result = SSL_do_handshake(connection);
  if (result == 1) {
    return true;
  }
  const auto error = SSL_get_error(connection, result);
  failed = error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE;
  return false;
}

inline TlsConnection createTlsPeer(SSL_CTX *context, int socket, bool server) {
  TlsConnection connection{SSL_new(context)};
  check(connection != nullptr && SSL_set_fd(connection.get(), socket) == 1);
  if (server) {
    SSL_set_accept_state(connection.get());
  } else {
    SSL_set_connect_state(connection.get());
  }
  return connection;
}

struct TlsPin {
  EVP_PKEY *key;
  bool checked = false;
  bool matched = false;
};

inline int verifyTlsPin(int verified, X509_STORE_CTX *context) noexcept {
  if (!verified || X509_STORE_CTX_get_error_depth(context) != 0) { return verified; }
  auto *connection = static_cast<SSL *>(X509_STORE_CTX_get_ex_data(context, SSL_get_ex_data_X509_STORE_CTX_idx()));
  auto *pin = static_cast<TlsPin *>(SSL_get_app_data(connection));
  check(pin != nullptr && pin->key != nullptr);
  pin->checked = true;
  pin->matched = EVP_PKEY_eq(pin->key, X509_get0_pubkey(X509_STORE_CTX_get_current_cert(context))) == 1;
  if (!pin->matched) { X509_STORE_CTX_set_error(context, X509_V_ERR_APPLICATION_VERIFICATION); }

  return pin->matched;
}
