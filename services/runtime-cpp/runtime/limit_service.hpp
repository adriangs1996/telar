#pragma once

#include "../diagnostics/limit_ledger.hpp"
#include "../model/runtime_model.hpp"
#include <cstdio>

namespace telar::runtime {

template <Allocator Memory>
class LimitService {
public:
  explicit LimitService(RuntimeModel<Memory> &model) noexcept
      : model_(model) {}

  void receive(ClientSession<Memory> &client, const ReportLimit &message) {
    if (!admit(client)) {
      return;
    }

    const auto recorded = model_.limits.clients.record(message.reach, message.hits);
    if (recorded.show && client.role == ClientRole::control) {
      show(recorded.row);
    }
  }

  void report(const LimitReach &reach) {
    const auto recorded = model_.limits.runtime.record(reach, 1);
    if (recorded.show) {
      show(recorded.row);
    }
  }

  void query(ClientSession<Memory> &client, const QueryLimits &request) {
    client.connection.defer(request);
  }

private:
  bool admit(ClientSession<Memory> &client) noexcept {
    const auto now = std::chrono::steady_clock::now();
    if (now - client.limit_report_window >= std::chrono::seconds{1}) {
      client.limit_report_window = now;
      client.limit_reports = 0;
    }

    if (client.limit_reports == reports_per_second) {
      model_.limits.refused_reports = saturatedAdd(model_.limits.refused_reports, 1);
      return false;
    }

    ++client.limit_reports;
    return true;
  }

  void show(const LimitLedger::Row &row) noexcept {
    std::array<char, 256> text{};
    const auto reach = row.reach();
    const char *separator = reach.noun.empty() ? "" : " ";
    int length = 0;
    if (reach.requested) {
      length = std::snprintf(text.data(), text.size(), "%.*s: %llu%s%.*s; limit %llu", static_cast<int>(reach.name.size()), reach.name.data(), *reach.requested, separator, static_cast<int>(reach.noun.size()), reach.noun.data(), reach.value);
    } else if (reach.value == 0) {
      length = std::snprintf(text.data(), text.size(), "%.*s: limit reached", static_cast<int>(reach.name.size()), reach.name.data());
    } else {
      length = std::snprintf(text.data(), text.size(), "%.*s: limit %llu%s%.*s reached", static_cast<int>(reach.name.size()), reach.name.data(), reach.value, separator, static_cast<int>(reach.noun.size()), reach.noun.data());
    }

    if (row.hits > 1) {
      length += std::snprintf(text.data() + length, text.size() - length, " (%llu times)", row.hits);
    }

    const Notification notification{NotificationBody{.level = NotificationLevel::warning,
                                                     .duration_ms = 8000,
                                                     .title = "Limit reached",
                                                     .message = {text.data(), static_cast<std::size_t>(length)}}};
    for (auto *client : model_.clients.items()) {
      if (client == nullptr || client->role != ClientRole::interactive || client->connection.closing) {
        continue;
      }

      try {
        client->connection.trySend(notification);
      } catch (...) {
        client->connection.closing = true;
      }
    }
  }

  static constexpr unsigned reports_per_second = 32;
  RuntimeModel<Memory> &model_;
};

template <Allocator Memory>
LimitService(RuntimeModel<Memory> &model) -> LimitService<Memory>;

}
