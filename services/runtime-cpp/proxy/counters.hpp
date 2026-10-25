#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <string_view>

namespace telar::runtime {

enum class ProxyCounter : std::size_t {
  rejected_connection,
  invalid_authorization_rejection,
  unknown_credential_rejection,
  h2_decode_failure,
  passthrough_connection,
  anonymous_tunnel,
  upstream_connect_failure,
  tls_context_failure,
  tls_upstream_handshake_failure,
  tls_downstream_handshake_failure,
  tls_mint_failure,
  h2_capture_stream_skipped,
  http1_head_too_large,
  http1_chunk_line_too_long,
  http1_trailer_line_too_long,
  connect_head_too_large,
  connect_head_timeout,
  establish_timeout,
  eviction,
  unauthenticated_refusal,
  unauthenticated_eviction,
  h2_header_block_too_large,
  h2_stream_untracked,
  resolution_refusal,
  resolution_truncated,
  count
};

class ProxyCounters {
public:
  static constexpr auto capacity = static_cast<std::size_t>(ProxyCounter::count);
  static constexpr std::array<std::string_view, capacity> names = {
      "rejected_connection", "invalid_authorization_rejection", "unknown_credential_rejection",
      "h2_decode_failure", "passthrough_connection", "anonymous_tunnel", "upstream_connect_failure",
      "tls_context_failure", "tls_upstream_handshake_failure", "tls_downstream_handshake_failure",
      "tls_mint_failure", "h2_capture_stream_skipped", "http1_head_too_large", "http1_chunk_line_too_long",
      "http1_trailer_line_too_long", "connect_head_too_large", "connect_head_timeout", "establish_timeout",
      "eviction", "unauthenticated_refusal", "unauthenticated_eviction", "h2_header_block_too_large",
      "h2_stream_untracked", "resolution_refusal", "resolution_truncated"};

  void record(ProxyCounter counter, std::uint64_t count = 1) noexcept {
    counters_[static_cast<std::size_t>(counter)].fetch_add(count, std::memory_order_relaxed);
  }

  std::uint64_t read(ProxyCounter counter) const noexcept {
    return counters_[static_cast<std::size_t>(counter)].load(std::memory_order_relaxed);
  }

  std::array<std::uint64_t, capacity> snapshot() const noexcept {
    std::array<std::uint64_t, capacity> result;
    for (std::size_t index = 0; index != capacity; ++index) {
      result[index] = counters_[index].load(std::memory_order_relaxed);
    }

    return result;
  }

private:
  std::array<std::atomic<std::uint64_t>, capacity> counters_{};
};

}
