#pragma once

#include "../exchange_capture/metrics.hpp"
#include "../proxy/metrics.hpp"
#include "line.hpp"

namespace telar::runtime::diagnostics {

inline void writeProxySample(Line &line, const ProxyMetrics &metrics) {
  line.field("proxy_active_connections", metrics.active_connections);
  line.field("proxy_connection_limit_drops", metrics.connection_limit_drops);
  line.field("proxy_rejected_connections", metrics.read(ProxyCounter::rejected_connection));
  line.field("proxy_invalid_authorization_rejections", metrics.read(ProxyCounter::invalid_authorization_rejection));
  line.field("proxy_unknown_credential_rejections", metrics.read(ProxyCounter::unknown_credential_rejection));
  line.field("proxy_h2_decode_failures", metrics.read(ProxyCounter::h2_decode_failure));
  line.field("proxy_passthrough_connections", metrics.read(ProxyCounter::passthrough_connection));
  line.field("proxy_anonymous_tunnels", metrics.read(ProxyCounter::anonymous_tunnel));
  line.field("proxy_upstream_connect_failures", metrics.read(ProxyCounter::upstream_connect_failure));
  line.field("proxy_tls_context_failures", metrics.read(ProxyCounter::tls_context_failure));
  line.field("proxy_tls_upstream_handshake_failures", metrics.read(ProxyCounter::tls_upstream_handshake_failure));
  line.field("proxy_tls_downstream_handshake_failures", metrics.read(ProxyCounter::tls_downstream_handshake_failure));
  line.field("proxy_tls_mint_failures", metrics.read(ProxyCounter::tls_mint_failure));
}

inline void writeCaptureSample(Line &line, const CaptureMetrics &metrics) {
  line.field("proxy_capture_started", metrics.started);
  line.field("proxy_capture_truncated", metrics.truncated);
  line.field("proxy_capture_skipped_quota", metrics.skipped);
  line.field("proxy_capture_dropped_queue", metrics.dropped_queue);
  line.field("proxy_capture_decode_failed", metrics.decode_failed);
  line.field("proxy_capture_queue_depth", metrics.queued);
  line.field("proxy_capture_queue_high_water", metrics.queue_high_water);
}

}
