#pragma once

#include "check.hpp"
#include "proxy/socket.hpp"

using telar::runtime::configureProxySocket;
using telar::runtime::FileDescriptor;

class SocketPair {
public:
  SocketPair() {
    int descriptors[2];
    check(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
    local = FileDescriptor{descriptors[0]};
    remote = FileDescriptor{descriptors[1]};
    configureProxySocket(local.get());
    configureProxySocket(remote.get());
    const int capacity = 64 * 1024;
    for (const auto socket : descriptors) {
      check(::setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &capacity, sizeof(capacity)) == 0);
      check(::setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &capacity, sizeof(capacity)) == 0);
    }
  }

  FileDescriptor local;
  FileDescriptor remote;
};
