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
