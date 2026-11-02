#pragma once

#include "session.hpp"
#include <atomic>
#include <mutex>

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsInterception {
public:
  explicit TlsInterception(const TlsContexts<Memory> &contexts, const CertificateAuthority<Memory> &authority) noexcept
      : contexts_(contexts), authority_(&authority) {}

  explicit TlsInterception(const TlsContexts<Memory> &contexts, std::shared_ptr<const CertificateAuthority<Memory>> authority) noexcept
      : contexts_(contexts), replacement_(std::move(authority)) {}

  Owned<TlsSession<Memory>, Memory> open(Memory &memory, TunnelSockets sockets, std::string_view hostname) const {
    requireTls(!suspended_.load(std::memory_order_acquire), "TLS authority synchronization is in progress");
    auto current = snapshot();
    const auto *authority = current ? current.get() : authority_;
    requireTls(authority != nullptr, "TLS authority is unavailable");
    return makeOwned<TlsSession<Memory>>(memory, contexts_, *authority, sockets, hostname, std::move(current));
  }

  std::shared_ptr<const CertificateAuthority<Memory>> snapshot() const noexcept {
    std::lock_guard lock{mutex_};
    return replacement_;
  }

  void replace(std::shared_ptr<const CertificateAuthority<Memory>> authority) noexcept {
    std::lock_guard lock{mutex_};
    replacement_.swap(authority);
  }
  void suspend(bool value) noexcept { suspended_.store(value, std::memory_order_release); }
  bool suspended() const noexcept { return suspended_.load(std::memory_order_acquire); }

private:
  const TlsContexts<Memory> &contexts_;
  const CertificateAuthority<Memory> *authority_ = nullptr;
  mutable std::mutex mutex_;
  std::shared_ptr<const CertificateAuthority<Memory>> replacement_;
  std::atomic<bool> suspended_{false};
};

}
