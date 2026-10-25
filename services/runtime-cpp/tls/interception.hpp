#pragma once

#include "session.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsInterception {
public:
  explicit TlsInterception(const TlsContexts<Memory> &contexts, const CertificateAuthority<Memory> &authority) noexcept
      : contexts_(contexts), authority_(authority) {}

  Owned<TlsSession<Memory>, Memory> open(Memory &memory, TunnelSockets sockets, std::string_view hostname) const {
    return makeOwned<TlsSession<Memory>>(memory, contexts_, authority_, sockets, hostname);
  }

private:
  const TlsContexts<Memory> &contexts_;
  const CertificateAuthority<Memory> &authority_;
};

}
