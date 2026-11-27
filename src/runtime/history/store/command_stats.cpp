module telar.runtime.history.store;

import std;
import telar.base.diagnostics;
import telar.base.ds;

// How one command's runs went, as the inspector tells them: the index keeps each command's counts
// as its runs change and walks only the days asked for; while it loads, or once it outgrew its
// bounds, SQL counts them through the runs' text_id and start-time index.
namespace telar::runtime {

  namespace {

    constexpr std::int64_t day_ms = 86'400'000;
    constexpr std::int64_t nanoseconds_per_millisecond = 1'000'000;

  }

  void HistoryStore::commandStats(const QueryHistoryCommandStats& request, EncodedReply<ConcurrentMemory>& reply) {
    if (!readable(request.request_id, reply)) {
      return;
    }

    const auto lock = readLock();

    apply();
    loadIndex(0);

    ds::Array<std::uint32_t, QueryHistoryCommandStats::maximum_days> days{};
    const auto per_day = days.viewMut().first(std::min<std::size_t>(request.days, QueryHistoryCommandStats::maximum_days));
    const auto until_ms = request.until_ms != 0 ? request.until_ms : wallMilliseconds();
    HistoryCommandStats result{.request_id = request.request_id, .per_day = per_day};
    const auto text_id = commandTextId(request);
    ds::Option<HistoryIndexCommandStats> found;

    if (text_id) {
      found = index_.complete() ? index_.commandStats(*text_id, until_ms, per_day) : commandStatsSql(*text_id, until_ms, per_day);
    }

    if (found) {
      result.found = true;
      result.runs = found->runs;
      result.measured = found->measured;
      result.mean_duration_ms = found->measured != 0 ? found->measured_ms / found->measured : 0;
      result.ended = found->ended;
      result.succeeded = found->succeeded;
      result.last_started_ms = found->last_started_ms;
      result.last_exit = found->last_exit;
    }

    reply.send(result);
  }

  ds::Option<std::int64_t> HistoryStore::commandTextId(const QueryHistoryCommandStats& request) {
    auto& database = readerOf(reader_, database_);

    if (request.entry_id != 0) {
      Statement run{database, "SELECT text_id FROM command WHERE id = ?1", Preparation::kept};

      run.bind(1, integer(request.entry_id));
      return run.next() ? ds::Option<std::int64_t>{run.integer(0)} : ds::none;
    }

    if (request.command.empty()) {
      return ds::none;
    }

    Statement text{database, "SELECT id FROM command_text WHERE hash = ?1 AND text = ?2", Preparation::kept};

    text.bind(1, HistoryTexts::hash(request.command));
    text.bind(2, request.command);
    return text.next() ? ds::Option<std::int64_t>{text.integer(0)} : ds::none;
  }

  ds::Option<HistoryIndexCommandStats> HistoryStore::commandStatsSql(std::int64_t text_id, std::int64_t until_ms, std::span<std::uint32_t> per_day) {
    auto& database = readerOf(reader_, database_);
    // Counted as the index counts them: a duration in whole milliseconds, at most 2^32 - 1.
    Statement counts{database, "SELECT COUNT(*), COALESCE(SUM(duration_ns > 0 AND status != ?2), 0), COALESCE(SUM(CASE WHEN duration_ns > 0 AND status != ?2 THEN MIN(duration_ns / ?4, 4294967295) ELSE 0 END), 0), COALESCE(SUM(exit_code IS NOT NULL AND status = ?3), 0), COALESCE(SUM(exit_code = 0 AND status = ?3), 0) FROM command WHERE text_id = ?1", Preparation::kept};

    counts.bind(1, text_id);
    counts.bind(2, std::int64_t{std::to_underlying(HistoryStatus::running)});
    counts.bind(3, std::int64_t{std::to_underlying(HistoryStatus::completed)});
    counts.bind(4, nanoseconds_per_millisecond);
    checkRow(counts);
    if (counts.integer(0) == 0) {
      return ds::none;
    }

    HistoryIndexCommandStats result{
        .runs = static_cast<std::uint64_t>(counts.integer(0)),
        .measured = static_cast<std::uint64_t>(counts.integer(1)),
        .measured_ms = static_cast<std::uint64_t>(counts.integer(2)),
        .ended = static_cast<std::uint64_t>(counts.integer(3)),
        .succeeded = static_cast<std::uint64_t>(counts.integer(4)),
    };

    Statement last{database, "SELECT started_at_ms, exit_code FROM command WHERE text_id = ?1 ORDER BY started_at_ms DESC, id DESC LIMIT 1", Preparation::kept};

    last.bind(1, text_id);
    checkRow(last);
    result.last_started_ms = last.integer(0);
    result.last_exit = last.isNull(1) ? ds::none : ds::Option<std::int32_t>{static_cast<std::int32_t>(last.integer(1))};
    std::ranges::fill(per_day, 0U);
    if (per_day.empty()) {
      return result;
    }

    const auto since_ms = until_ms - (static_cast<std::int64_t>(per_day.size()) * day_ms);
    Statement runs{database, "SELECT started_at_ms FROM command WHERE text_id = ?1 AND started_at_ms >= ?2 AND started_at_ms < ?3", Preparation::kept};

    runs.bind(1, text_id);
    runs.bind(2, since_ms);
    runs.bind(3, until_ms);
    while (runs.next()) {
      const auto back = (until_ms - 1 - runs.integer(0)) / day_ms;

      ++per_day[per_day.size() - 1 - static_cast<std::size_t>(back)];
    }

    return result;
  }

}
