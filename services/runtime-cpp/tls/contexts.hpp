#pragma once

#include "alpn_selection.hpp"
#include "trust_store.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsContexts {
public:
  explicit TlsContexts(Memory &memory, const TlsLibrary<Memory> &library, const TlsTrustStore<Memory> &trust) {
    requireTls(library.uses(memory), "TLS contexts allocator does not match its library");
    origin_.reset(SSL_CTX_new(TLS_client_method()));
    child_.reset(SSL_CTX_new(TLS_server_method()));
    requireTls(origin_ != nullptr && child_ != nullptr, "Allocate TLS contexts");

    for (auto *context : {origin_.get(), child_.get()}) {
      requireTls(SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) == 1, "Set TLS minimum version");
      // A TCP half-close ends only the receiving direction. HTTP framing
      // determines whether that EOF truncates an unfinished message.
      SSL_CTX_set_options(context, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION | SSL_OP_IGNORE_UNEXPECTED_EOF);
      SSL_CTX_set_mode(context, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
      SSL_CTX_set_session_cache_mode(context, SSL_SESS_CACHE_OFF);
    }
    SSL_CTX_set_verify(origin_.get(), SSL_VERIFY_PEER, nullptr);
    requireTls(SSL_CTX_set1_verify_cert_store(origin_.get(), trust.native()) == 1, "Set TLS origin trust");
    requireTls(SSL_CTX_set_num_tickets(child_.get(), 0) == 1, "Disable TLS session tickets");
    SSL_CTX_set_alpn_select_cb(child_.get(), &AlpnSelection::select, nullptr);
  }

  SSL_CTX *origin() const noexcept {
    return origin_.get();
  }

  SSL_CTX *child() const noexcept {
    return child_.get();
  }

private:
  TlsContext origin_;
  TlsContext child_;
};

}
