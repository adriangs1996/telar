#pragma once

#include "../serializers/telar_messages.hpp"
#include "telar_base/ds/values.hpp"

namespace telar {

  template <>
  struct MessageSchema<RequestRuntimeState>
      : Schema<Direction::client, ClientTag::request_runtime_state, Field<&RequestRuntimeState::client_identity, u64, "client_identity">, Field<&RequestRuntimeState::interactive, BoolByte, "interactive">> {
    static constexpr const char* name = "RequestRuntimeState";
  };

  template <>
  struct MessageSchema<SystemMetrics>
      : Schema<Direction::server, ServerTag::system_metrics, Field<&SystemMetrics::revision, u64, "revision">, Field<&SystemMetrics::cpu_percent, u8, "cpu_percent">, Field<&SystemMetrics::memory_used_decigib, u16, "memory_used_decigib">, Field<&SystemMetrics::has_battery, BoolByte, "has_battery">, Field<&SystemMetrics::battery_percent, u8, "battery_percent">, Field<&SystemMetrics::cpu_count, u16, "cpu_count">, Field<&SystemMetrics::memory_total_decigib, u16, "memory_total_decigib">> {
    static constexpr const char* name = "SystemMetrics";
  };

  static_assert(MessageSchema<RequestRuntimeState>::payload_size == 10);
  static_assert(MessageSchema<SystemMetrics>::payload_size == 18);

  struct RuntimeStop {};

  template <>
  struct MessageSchema<RuntimeStop> : Schema<Direction::client, ClientTag::runtime_stop> {};

  struct ReportLimit {
    LimitReach reach{};
    std::uint32_t hits{};
  };

  template <>
  struct MessageSchema<ReportLimit>
      : Schema<Direction::client, ClientTag::report_limit, Field<&ReportLimit::reach, ValueCodec<LimitReach>, "reach">, Field<&ReportLimit::hits, BoundedInteger<u32, 1>, "hits">> {};

  struct QueryLimits {
    std::uint64_t request_id{};
  };

  template <>
  struct MessageSchema<QueryLimits>
      : Schema<Direction::client, ClientTag::query_limits, Field<&QueryLimits::request_id, NonzeroU64, "request_id">> {};

  struct RequestFailed {
    std::uint64_t request_id{};
    FailureCode code{};
    std::string_view message{};
  };

  template <>
  struct MessageSchema<RequestFailed>
      : Schema<Direction::server, ServerTag::request_failed, Field<&RequestFailed::request_id, u64, "request_id">, Field<&RequestFailed::code, EnumInteger<FailureCode, u16, 1, 17>, "code">, Field<&RequestFailed::message, Utf8Tail<1024>, "message">> {};

  struct RuntimeStopping {};

  template <>
  struct MessageSchema<RuntimeStopping> : Schema<Direction::server, ServerTag::runtime_stopping> {};

  struct ProxyStatus {
    bool active{};
    ProxyScope scope{};
    bool system_trusted{};
    ds::Option<std::uint16_t> port{};
    ds::Option<std::uint16_t> preferred_port{};
  };

  template <>
  struct MessageSchema<ProxyStatus>
      : Schema<Direction::server, ServerTag::proxy_status, Field<&ProxyStatus::active, BoolByte, "active">, Field<&ProxyStatus::scope, EnumByte<ProxyScope, 1>, "scope">, Field<&ProxyStatus::system_trusted, BoolByte, "system_trusted">, Field<&ProxyStatus::port, OptionalValue<u16>, "port">, Field<&ProxyStatus::preferred_port, OptionalValue<u16>, "preferred_port">> {};

  struct RequestCompleted {
    std::uint64_t request_id{};
  };

  template <>
  struct MessageSchema<RequestCompleted>
      : Schema<Direction::server, ServerTag::request_completed, Field<&RequestCompleted::request_id, NonzeroU64, "request_id">> {};

  struct LimitList {
    std::uint64_t request_id{};
    std::uint64_t runtime_evicted{};
    std::uint64_t client_evicted{};
    std::uint64_t refused_reports{};
    std::span<const LimitListEntry> entries{};
  };

  template <>
  struct MessageSchema<LimitList>
      : Schema<Direction::server, ServerTag::limit_list, Field<&LimitList::request_id, NonzeroU64, "request_id">, Field<&LimitList::runtime_evicted, u64, "runtime_evicted">, Field<&LimitList::client_evicted, u64, "client_evicted">, Field<&LimitList::refused_reports, u64, "refused_reports">, SpanCountField<&LimitList::entries, u16, ValueCodec<LimitListEntry>, 256, "entry_count", 0>, SpanItemsField<&LimitList::entries, ValueCodec<LimitListEntry>, "entries">> {};

} // namespace telar
