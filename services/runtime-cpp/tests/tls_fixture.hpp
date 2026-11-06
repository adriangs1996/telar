#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <string_view>
#include <sys/stat.h>
#include "telar_base/memory/allocator.hpp"
#include <cstddef>
#include <cstring>
#include <cstdint>
#include "telar_platform/random_bytes.hpp"
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include <span>
#include <unistd.h>
#include <cstdlib>
#include "telar_platform/trace.hpp"
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <arpa/inet.h>
#include <optional>
#include <chrono>
#include <ctime>
#include <openssl/crypto.h>
#include <stdexcept>
#include <filesystem>

#pragma once



import telar.platform;
import telar.tls;

using namespace telar;
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
