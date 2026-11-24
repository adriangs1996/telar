module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.history.store;

import std;
import telar.native.sqlite;
import telar.tbc;
import telar.base.diagnostics;
import telar.base.history;
import telar.wire.runtime;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The ?N parameters of the statements below, as their SQL numbers them, and the columns of
    // HistoryStore::entry_columns. A session's context leads the statements that write a session or
    // a command.
    namespace context_parameter {
      constexpr int session = 1;
      constexpr int pane = 2;
      constexpr int location_kind = 3;
      constexpr int location_id = 4;
      constexpr int tab = 5;
      constexpr int workspace_path = 6;
    }

    namespace agent_session_parameter {
      constexpr int started_at = 7;
    }

    namespace agent_finish_parameter {
      constexpr int command = 1;
      constexpr int cwd = 2;
      constexpr int finished_at = 3;
      constexpr int exit_code = 4;
      constexpr int session = 5;
      constexpr int tool_call = 6;
      constexpr int workspace_path = 7;
      constexpr int provider = 8;
    }

    // Past the context's tab.
    namespace agent_insert_parameter {
      constexpr int command = 6;
      constexpr int cwd = 7;
      constexpr int workspace_path = 8;
      constexpr int started_at = 9;
      constexpr int exit_code = 10;
      constexpr int status = 11;
      constexpr int provider = 12;
      constexpr int tool_call = 13;
    }

    namespace launch_parameter {
      constexpr int pane = 1;
      constexpr int generation = 2;
      constexpr int location_kind = 3;
      constexpr int location_id = 4;
      constexpr int tab = 5;
      constexpr int workspace_path = 6;
      constexpr int shell = 7;
      constexpr int started_at = 8;
      constexpr int failed_at = 9;
      constexpr int phase = 10;
      constexpr int cause = 11;
    }

    namespace pane_session_parameter {
      constexpr int shell = 7;
      constexpr int started_at = 8;
    }

    namespace pane_command_parameter {
      constexpr int command = 7;
      constexpr int truncated = 8;
      constexpr int cwd = 9;
      constexpr int started_at = 10;
      constexpr int duration = 11;
      constexpr int exit_code = 12;
      constexpr int status = 13;
      constexpr int author = 14;
    }

    namespace import_command_parameter {
      constexpr int session = 1;
      constexpr int pane = 2;
      constexpr int sequence = 3;
      constexpr int command = 4;
      constexpr int started_at = 5;
    }

    // A query numbers each filter apart, so a statement binds only the ones its SQL appends.
    namespace query_parameter {
      constexpr int snapshot = 1;
      constexpr int entry = 2;
      constexpr int match = 3;
      constexpr int before = 4;
      constexpr int author = 5;
      constexpr int scope = 6;
      constexpr int limit = 7;
      constexpr int offset = 8;
    }

    namespace entry_column {
      constexpr int id = 0;
      constexpr int pane = 1;
      constexpr int started_at = 2;
      constexpr int duration = 3;
      constexpr int exit_code = 4;
      constexpr int status = 5;
      constexpr int command = 6;
      constexpr int cwd = 7;
      constexpr int workspace_path = 8;
      constexpr int author = 9;
      constexpr int origin = 10;
      constexpr int provider = 11;
      constexpr int command_truncated = 12;
    }

    // The pinned Wyhash variant ImportIdentity::hash computes.
    constexpr ds::Array<std::uint64_t, 4> wyhash_secret{0xa0761d6478bd642f, 0xe7037ed1a0b428db, 0x8ebc6af09c88c6e3, 0x589965cc75374cc3};
    constexpr std::size_t wyhash_word_bytes = 8;
    // A step reads two words; a block, a step for each of the three lanes.
    constexpr std::size_t wyhash_step_bytes = 16;
    constexpr std::size_t wyhash_block_bytes = 48;
    constexpr unsigned half_word_bits = 32;
    constexpr unsigned word_bits = 64;
    constexpr unsigned byte_bits = 8;

    struct WyhashWords {
      std::uint64_t left = 0;
      std::uint64_t right = 0;
      std::uint64_t state = 0;
    };

    // The little-endian integer at offset, which the caller keeps inside the input.
    template <typename Integer>
    std::uint64_t readWord(std::span<const char> input, std::size_t offset) noexcept {
      ds::Array<char, sizeof(Integer)> bytes{};

      std::ranges::copy(input.subspan(offset, sizeof(Integer)), bytes.viewMut().begin());
      return std::bit_cast<Integer>(bytes);
    }

    std::uint64_t mix(std::uint64_t left, std::uint64_t right) noexcept {
      const __uint128_t product = static_cast<__uint128_t>(left) * right;

      return static_cast<std::uint64_t>(product) ^ static_cast<std::uint64_t>(product >> word_bits);
    }

    // An input of at most wyhash_step_bytes: its words are read straight from its ends.
    WyhashWords shortWords(std::span<const char> input, std::uint64_t seeded) noexcept {
      if (input.size() >= 4) {
        const auto end = input.size() - 4;
        const auto quarter = (input.size() >> 3U) << 2U;

        return {
            .left = (readWord<std::uint32_t>(input, 0) << half_word_bits) | readWord<std::uint32_t>(input, quarter),
            .right = (readWord<std::uint32_t>(input, end) << half_word_bits) | readWord<std::uint32_t>(input, end - quarter),
            .state = seeded,
        };
      }

      if (input.empty()) {
        return {.state = seeded};
      }

      const auto first = std::uint64_t{static_cast<unsigned char>(input.front())};
      const auto middle = std::uint64_t{static_cast<unsigned char>(input[input.size() >> 1U])};
      const auto last = std::uint64_t{static_cast<unsigned char>(input.back())};

      return {.left = (first << (2 * byte_bits)) | (middle << byte_bits) | last, .state = seeded};
    }

    // A longer input folds through three lanes a block at a time, then a step at a time.
    WyhashWords longWords(std::span<const char> input, std::uint64_t seeded) noexcept {
      ds::Array<std::uint64_t, 3> state{seeded, seeded, seeded};
      std::size_t offset = 0;

      if (input.size() >= wyhash_block_bytes) {
        while (offset + wyhash_block_bytes < input.size()) {
          for (std::size_t lane = 0; lane < state.size(); ++lane) {
            const auto step = offset + (wyhash_step_bytes * lane);

            state.atMut(lane) = mix(readWord<std::uint64_t>(input, step) ^ wyhash_secret[lane + 1], readWord<std::uint64_t>(input, step + wyhash_word_bytes) ^ state[lane]);
          }

          offset += wyhash_block_bytes;
        }

        state.atMut(0) ^= state[1] ^ state[2];
      }

      while (offset + wyhash_step_bytes < input.size()) {
        state.atMut(0) = mix(readWord<std::uint64_t>(input, offset) ^ wyhash_secret[1], readWord<std::uint64_t>(input, offset + wyhash_word_bytes) ^ state[0]);
        offset += wyhash_step_bytes;
      }

      return {
          .left = readWord<std::uint64_t>(input, input.size() - wyhash_step_bytes),
          .right = readWord<std::uint64_t>(input, input.size() - wyhash_word_bytes),
          .state = state[0],
      };
    }

    // telar_fold(text): the text with historyFold's case fold, which a short query matches with
    // as the index's trigrams fold a longer one. Its scratch is the store's memory.
    void foldText(sqlite3_context* context, int count, sqlite3_value** values) {
      constexpr std::size_t small_text = 1024;
      if (count != 1 || sqlite3_value_type(values[0]) == SQLITE_NULL) {
        sqlite3_result_null(context);
        return;
      }

      const auto* bytes = reinterpret_cast<const char*>(sqlite3_value_text(values[0]));
      const std::string_view text{bytes == nullptr ? "" : bytes, static_cast<std::size_t>(sqlite3_value_bytes(values[0]))};

      try {
        ds::Array<char, small_text> scratch; // NOLINT(cppcoreguidelines-pro-type-member-init): historyFold writes every byte SQLite copies
        ds::String<ConcurrentMemory> large{*static_cast<ConcurrentMemory*>(sqlite3_user_data(context))};
        std::span<char> out = scratch.viewMut();

        if (text.size() > out.size()) {
          large.resizeForOverwrite(text.size());
          out = large.viewMut();
        }

        const auto written = historyFold(text, out);

        sqlite3_result_text(context, out.data(), static_cast<int>(written), SQLITE_TRANSIENT);
      } catch (...) {
        sqlite3_result_error_nomem(context);
      }
    }

    // The schema must be current before the index can be built over it.
    bool prepareHistory(Database& database) {
      migrateHistory(database);
      return enableHistoryIndex(database);
    }

    // Outputs stored before the tracker dropped the shell integration's marks keep them, and the
    // pane's token they carry: version 6 strips them, once.
    void stripOutputMarks(Database& database, ConcurrentMemory& memory) {
      constexpr std::int64_t stripped_version = 6;

      {
        Statement version{database, "SELECT version FROM history_schema"};
        if (!version.next() || version.integer(0) >= stripped_version) {
          return;
        }
      }

      Transaction transaction{database};
      Statement rows{database, "SELECT command_id, content FROM command_output WHERE instr(content, char(27) || ']133') > 0 OR instr(content, char(27) || ']6973') > 0"};
      Statement update{database, "UPDATE command_output SET content = ?2 WHERE command_id = ?1"};
      ds::String<ConcurrentMemory> kept{memory};

      while (rows.next()) {
        const auto content = rows.text(1);
        IntegrationMarkFilter marks;

        kept.clear();
        marks.feed(byteView(content), [&](std::span<const std::uint8_t> run) {
          kept.append({reinterpret_cast<const char*>(run.data()), run.size()});
        });

        update.reset();
        update.bind(1, rows.integer(0));
        update.bind(2, kept.view());
        update.finish();
      }

      database.execute("UPDATE history_schema SET version = 6 WHERE version < 6");
      transaction.commit();
    }

  }

  AgentCommandWriter::AgentCommandWriter(Database& database)
      : database_(database),
        session_(database, session_sql),
        finish_(database, finish_sql),
        insert_(database, insert_sql) {}

  void AgentCommandWriter::persist(const ReportAgentCommand& request, const RequestContext& context) {
    TELAR_TRACE("history.persistAgentCommand");
    if (request.phase == AgentCommandPhase::started && request.tool_call_id.empty()) {
      return;
    }

    Transaction transaction{database_};
    const auto now = context.received_at_ms != 0 ? context.received_at_ms : wallMilliseconds();

    session_.reset();
    session_.bind(context_parameter::session, std::span{context.history_session});
    session_.bind(context_parameter::pane, static_cast<std::int64_t>(request.pane_id));
    session_.bind(context_parameter::location_kind, static_cast<std::int64_t>(context.location.workspace.kind));
    session_.bind(context_parameter::location_id, static_cast<std::int64_t>(context.location.workspace.id));
    session_.bind(context_parameter::tab, static_cast<std::int64_t>(context.location.tab_id));
    session_.bind(context_parameter::workspace_path, context.workspace_path);
    session_.bind(agent_session_parameter::started_at, now);
    session_.finish();

    if (request.phase == AgentCommandPhase::finished && !request.tool_call_id.empty()) {
      finish_.reset();
      finish_.bind(agent_finish_parameter::command, request.command);
      finish_.bind(agent_finish_parameter::cwd, request.cwd);
      finish_.bind(agent_finish_parameter::finished_at, now);
      if (request.exit_code) {
        finish_.bind(agent_finish_parameter::exit_code, *request.exit_code);
      } else {
        finish_.bindNull(agent_finish_parameter::exit_code);
      }

      finish_.bind(agent_finish_parameter::session, std::span{context.history_session});
      finish_.bind(agent_finish_parameter::tool_call, request.tool_call_id);
      finish_.bind(agent_finish_parameter::workspace_path, context.workspace_path);
      finish_.bind(agent_finish_parameter::provider, request.provider);
      finish_.finish();
      if (sqlite3_changes(database_.handle()) != 0) {
        transaction.commit();
        return;
      }
    }

    insert_.reset();
    insert_.bind(context_parameter::session, std::span{context.history_session});
    insert_.bind(context_parameter::pane, static_cast<std::int64_t>(request.pane_id));
    insert_.bind(context_parameter::location_kind, static_cast<std::int64_t>(context.location.workspace.kind));
    insert_.bind(context_parameter::location_id, static_cast<std::int64_t>(context.location.workspace.id));
    insert_.bind(context_parameter::tab, static_cast<std::int64_t>(context.location.tab_id));
    insert_.bind(agent_insert_parameter::command, request.command);
    insert_.bind(agent_insert_parameter::cwd, request.cwd);
    insert_.bind(agent_insert_parameter::workspace_path, context.workspace_path);
    insert_.bind(agent_insert_parameter::started_at, now);
    if (request.exit_code) {
      insert_.bind(agent_insert_parameter::exit_code, *request.exit_code);
    } else {
      insert_.bindNull(agent_insert_parameter::exit_code);
    }

    insert_.bind(agent_insert_parameter::status, static_cast<std::int64_t>(request.phase == AgentCommandPhase::started ? HistoryStatus::running : HistoryStatus::completed));
    insert_.bind(agent_insert_parameter::provider, request.provider);
    if (request.tool_call_id.empty()) {
      insert_.bindNull(agent_insert_parameter::tool_call);
    } else {
      insert_.bind(agent_insert_parameter::tool_call, request.tool_call_id);
    }

    insert_.finish();
    transaction.commit();
  }

  ImportIdentity::ImportIdentity(std::string_view source) noexcept {
    constexpr std::uint64_t import_seed = 0x74656c6172696d70;
    // A pane id keeps the low 62 bits of the hash, and is never 0.
    constexpr unsigned pane_bits = 62;
    const auto low = hash(import_seed, source);
    const auto high = hash(low, source);
    static_assert(std::endian::native == std::endian::little);

    session = std::bit_cast<ds::Array<std::uint8_t, history_session_bytes>>(ds::Array{low, high});
    pane = (low & ((std::uint64_t{1} << pane_bits) - 1)) | 1U;
  }

  std::uint64_t ImportIdentity::hash(std::uint64_t seed, std::string_view input) noexcept {
    const std::span<const char> bytes{input};
    const auto seeded = seed ^ mix(seed ^ wyhash_secret[0], wyhash_secret[1]);
    const auto words = bytes.size() <= wyhash_step_bytes ? shortWords(bytes, seeded) : longWords(bytes, seeded);
    const __uint128_t product = static_cast<__uint128_t>(words.left ^ wyhash_secret[1]) * (words.right ^ words.state);

    return mix(static_cast<std::uint64_t>(product) ^ wyhash_secret[0] ^ input.size(), static_cast<std::uint64_t>(product >> word_bits) ^ wyhash_secret[1]);
  }

  LaunchHistoryWriter::LaunchHistoryWriter(Database& database)
      : insert_(database, insert_sql) {}

  void LaunchHistoryWriter::persist(const HistoryEventView& event) {
    TELAR_TRACE("history.persistLaunchFailure");
    const auto& session = event.session;
    const auto& failure = event.failure;
    if (session.pane > std::numeric_limits<std::int64_t>::max() || failure.generation > std::numeric_limits<std::int64_t>::max() || session.location.workspace.id > std::numeric_limits<std::int64_t>::max() || session.location.tab_id > std::numeric_limits<std::int64_t>::max()) {
      throw RequestError{FailureCode::resource_limit, "History identity exceeds the database integer range"};
    }

    insert_.reset();
    insert_.bind(launch_parameter::pane, static_cast<std::int64_t>(session.pane));
    insert_.bind(launch_parameter::generation, static_cast<std::int64_t>(failure.generation));
    insert_.bind(launch_parameter::location_kind, static_cast<std::int64_t>(session.location.workspace.kind));
    insert_.bind(launch_parameter::location_id, static_cast<std::int64_t>(session.location.workspace.id));
    insert_.bind(launch_parameter::tab, static_cast<std::int64_t>(session.location.tab_id));
    insert_.bind(launch_parameter::workspace_path, session.workspace_path);
    insert_.bind(launch_parameter::shell, session.shell);
    insert_.bind(launch_parameter::started_at, session.started_at_ms);
    insert_.bind(launch_parameter::failed_at, event.finished_at_ms);
    insert_.bind(launch_parameter::phase, static_cast<std::int64_t>(failure.phase));
    insert_.bind(launch_parameter::cause, failure.cause);
    insert_.finish();
  }

  PaneHistoryWriter::PaneHistoryWriter(Database& database)
      : database_(database),
        session_(database, session_sql),
        command_(database, command_sql),
        output_(database, output_sql),
        finish_(database, finish_sql),
        title_(database, title_sql) {}

  void PaneHistoryWriter::persist(const HistoryEventView& event) {
    TELAR_TRACE("history.persistPaneEvent");
    if (event.kind == HistoryEventKind::launch_failed) {
      throw RequestError{FailureCode::invalid_request, "A failed launch has no history session"};
    }

    Transaction transaction{database_};

    if (event.kind != HistoryEventKind::session_title) {
      ensureSession(event.session);
    }

    switch (event.kind) {
    case HistoryEventKind::session_started:
    case HistoryEventKind::launch_failed:
      break;
    case HistoryEventKind::session_finished:
      finish_.reset();
      finish_.bind(1, std::span{event.session.id});
      finish_.bind(2, event.finished_at_ms);
      finish_.finish();
      break;
    case HistoryEventKind::command_finished:
      insertCommand(event.session, event.command);
      break;
    case HistoryEventKind::session_title:
      title_.reset();
      title_.bind(1, std::span{event.title.session});
      title_.bind(2, event.title.title.view());
      title_.bind(3, static_cast<std::int64_t>(event.title.source));
      title_.bind(4, static_cast<std::int64_t>(event.title.state));
      title_.finish();
      if (::sqlite3_changes(database_.handle()) != 1) {
        throw RequestError{FailureCode::invalid_request, "History session does not exist"};
      }

      break;
    }

    transaction.commit();
  }

  void PaneHistoryWriter::ensureSession(const HistorySession& session) {
    session_.reset();
    bindContext(session_, session);
    session_.bind(pane_session_parameter::shell, session.shell);
    session_.bind(pane_session_parameter::started_at, session.started_at_ms);
    session_.finish();
  }

  void PaneHistoryWriter::insertCommand(const HistorySession& session, const CapturedCommand& command) {
    command_.reset();
    bindContext(command_, session);
    command_.bind(pane_command_parameter::command, command.command);
    command_.bind(pane_command_parameter::truncated, static_cast<std::int64_t>(command.truncated));
    command_.bind(pane_command_parameter::cwd, command.directory);
    command_.bind(pane_command_parameter::started_at, command.started.milliseconds);
    command_.bind(pane_command_parameter::duration, command.duration_ns);
    if (command.exit_code) {
      command_.bind(pane_command_parameter::exit_code, *command.exit_code);
    } else {
      command_.bindNull(pane_command_parameter::exit_code);
    }

    command_.bind(pane_command_parameter::status, static_cast<std::int64_t>(command.status));
    command_.bind(pane_command_parameter::author, static_cast<std::int64_t>(command.author));
    command_.finish();
    if (!command.output.empty() || command.output_observed != 0) {
      output_.reset();
      output_.bind(1, textView(command.output));
      output_.bind(2, static_cast<std::int64_t>(command.outputTruncated()));
      output_.bind(3, static_cast<std::int64_t>(std::min<std::uint64_t>(command.output_observed, std::numeric_limits<std::int64_t>::max())));
      output_.finish();
    }
  }

  void PaneHistoryWriter::bindContext(Statement& statement, const HistorySession& session) {
    if (session.pane > std::numeric_limits<std::int64_t>::max() || session.location.workspace.id > std::numeric_limits<std::int64_t>::max() || session.location.tab_id > std::numeric_limits<std::int64_t>::max()) {
      throw RequestError{FailureCode::resource_limit, "History identity exceeds the database integer range"};
    }

    statement.bind(context_parameter::session, std::span{session.id});
    statement.bind(context_parameter::pane, static_cast<std::int64_t>(session.pane));
    statement.bind(context_parameter::location_kind, static_cast<std::int64_t>(session.location.workspace.kind));
    statement.bind(context_parameter::location_id, static_cast<std::int64_t>(session.location.workspace.id));
    statement.bind(context_parameter::tab, static_cast<std::int64_t>(session.location.tab_id));
    statement.bind(context_parameter::workspace_path, session.workspace_path);
  }

  HistoryRows::HistoryRows(ConcurrentMemory& memory)
      : text_(memory, max_payload_size),
        entries_(memory) {
    text_.reserve(max_payload_size);
    entries_.reserve(maximum_entries);
    clear();
  }

  void HistoryRows::clear() noexcept {
    text_.clear();
    entries_.clear();
    encoded_bytes_ = result_header_bytes;
  }

  bool HistoryRows::append(const Statement& row) {
    const auto stored = view(row);
    const auto bytes = ValueCodec<HistoryEntry>::encodedSize(stored);
    if (entries_.size() == maximum_entries || bytes > max_payload_size - encoded_bytes_) {
      return false;
    }

    // The kept entry starts with no text and views only the copies these rows hold.
    auto entry = header(row);

    entry.command = copy(stored.command);
    entry.cwd = copy(stored.cwd);
    entry.workspace_path = copy(stored.workspace_path);
    entry.provider = copy(stored.provider);
    entries_.push(entry);
    encoded_bytes_ += bytes;
    return true;
  }

  std::string_view HistoryRows::copy(std::string_view text) const {
    const auto offset = text_.size();

    text_.append(byteView(text));
    return textView(text_.readable().subspan(offset, text.size()));
  }

  std::span<const HistoryEntry> HistoryRows::entries() const noexcept {
    return entries_;
  }

  HistoryEntry HistoryRows::view(const Statement& row) {
    auto entry = header(row);

    entry.provider = row.text(entry_column::provider);
    entry.command = row.text(entry_column::command);
    entry.cwd = row.text(entry_column::cwd);
    entry.workspace_path = row.text(entry_column::workspace_path);
    return entry;
  }

  tbc::val_static<HistoryEntry> HistoryRows::header(const Statement& row) {
    if (row.integer(entry_column::id) <= 0 || row.integer(entry_column::pane) <= 0) {
      throw RequestError{FailureCode::internal, "Invalid stored history identity"};
    }

    if (row.integer(entry_column::status) < 0 || row.integer(entry_column::status) > static_cast<std::int64_t>(HistoryStatus::running) || row.integer(entry_column::author) < 0 || row.integer(entry_column::author) > static_cast<std::int64_t>(HistoryAuthor::agent) || row.integer(entry_column::origin) < 0 || row.integer(entry_column::origin) > static_cast<std::int64_t>(HistoryOrigin::plugin)) {
      throw RequestError{FailureCode::internal, "Invalid stored history state"};
    }

    return HistoryEntry{
        .id = static_cast<std::uint64_t>(row.integer(entry_column::id)),
        .pane_id = static_cast<std::uint64_t>(row.integer(entry_column::pane)),
        .started_at_ms = row.integer(entry_column::started_at),
        .duration_ns = row.integer(entry_column::duration),
        .exit_code = row.isNull(entry_column::exit_code) ? ds::none : ds::Option{static_cast<std::int32_t>(row.integer(entry_column::exit_code))},
        .status = static_cast<HistoryStatus>(row.integer(entry_column::status)),
        .author = static_cast<HistoryAuthor>(row.integer(entry_column::author)),
        .origin = static_cast<HistoryOrigin>(row.integer(entry_column::origin)),
        .command_truncated = row.integer(entry_column::command_truncated) != 0,
    };
  }

  void migrateHistory(Database& database) {
    database.execute(history_schema);

    struct Migration {
      const char* table;
      const char* column;
      const char* sql;
    };

    constexpr ds::Array migrations{
        Migration{.table = "session", .column = "tab_id", .sql = "ALTER TABLE session ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0"},
        Migration{.table = "command", .column = "tab_id", .sql = "ALTER TABLE command ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0"},
        Migration{.table = "session", .column = "title", .sql = "ALTER TABLE session ADD COLUMN title TEXT"},
        Migration{.table = "session", .column = "title_source", .sql = "ALTER TABLE session ADD COLUMN title_source INTEGER"},
        Migration{.table = "session", .column = "title_state", .sql = "ALTER TABLE session ADD COLUMN title_state INTEGER"},
        Migration{.table = "command", .column = "author", .sql = "ALTER TABLE command ADD COLUMN author INTEGER NOT NULL DEFAULT 0"},
        Migration{.table = "command", .column = "origin", .sql = "ALTER TABLE command ADD COLUMN origin INTEGER NOT NULL DEFAULT 0"},
        Migration{.table = "command", .column = "provider", .sql = "ALTER TABLE command ADD COLUMN provider TEXT"},
        Migration{.table = "command", .column = "tool_call_id", .sql = "ALTER TABLE command ADD COLUMN tool_call_id TEXT"},
    };

    for (const auto& migration : migrations) {
      Statement columns{database, "SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2"};

      columns.bind(1, std::string_view{migration.table});
      columns.bind(2, std::string_view{migration.column});
      if (!columns.next()) {
        database.execute(migration.sql);
      }
    }

    database.execute("CREATE UNIQUE INDEX IF NOT EXISTS command_tool_call ON command(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL; UPDATE history_schema SET version = 5 WHERE version < 5;");
  }

  bool enableHistoryIndex(Database& database) {
    bool exists = false;

    {
      Statement table{database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'command_fts'"};

      exists = table.next();
    }

    if (!exists) {
      if (!database.tryExecute("CREATE VIRTUAL TABLE command_fts USING fts5(command, content='command', content_rowid='id', tokenize='trigram case_sensitive 0')")) {
        return false;
      }

      if (!database.tryExecute("INSERT INTO command_fts(command_fts) VALUES('rebuild')")) {
        database.tryExecute("DROP TABLE command_fts");
        return false;
      }
    }

    return database.tryExecute(R"sql(
CREATE TRIGGER IF NOT EXISTS command_fts_insert AFTER INSERT ON command BEGIN
  INSERT INTO command_fts(rowid, command) VALUES (new.id, new.command);
END;
CREATE TRIGGER IF NOT EXISTS command_fts_delete AFTER DELETE ON command BEGIN
  INSERT INTO command_fts(command_fts, rowid, command) VALUES ('delete', old.id, old.command);
END;
CREATE TRIGGER IF NOT EXISTS command_fts_update AFTER UPDATE OF command ON command BEGIN
  INSERT INTO command_fts(command_fts, rowid, command) VALUES ('delete', old.id, old.command);
  INSERT INTO command_fts(rowid, command) VALUES (new.id, new.command);
END;
)sql");
  }

  HistoryStore::HistoryStore(ConcurrentMemory& memory, const char* path, const HistoryFilters& filters)
      : memory_(memory),
        filters_(filters),
        database_(path),
        rows_(memory),
        indexed_(prepareHistory(database_)) {
    stripOutputMarks(database_, memory_);
    checkSqlite(sqlite3_create_function_v2(database_.handle(), "telar_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, &memory_, foldText, nullptr, nullptr, nullptr));
  }

  void HistoryStore::reportAgentCommand(const ReportAgentCommand& request, const RequestContext& context, EncodedReply<ConcurrentMemory>& reply) {
    if (!filters_.allowsAgent(request.command, request.cwd)) {
      reply.send(RequestCompleted{.request_id = request.request_id});
      return;
    }

    if (!agent_commands_) {
      agent_commands_.emplace(database_);
    }

    agent_commands_.getMut().persist(request, context);
    reply.send(RequestCompleted{.request_id = request.request_id});
  }

  void HistoryStore::record(const HistoryEventView& event) {
    if (!accepts(event)) {
      return;
    }

    if (event.kind == HistoryEventKind::launch_failed) {
      if (!launch_writer_) {
        launch_writer_.emplace(database_);
      }

      launch_writer_.getMut().persist(event);
      return;
    }

    if (!pane_writer_) {
      pane_writer_.emplace(database_);
    }

    pane_writer_.getMut().persist(event);
  }

  bool HistoryStore::accepts(const HistoryEventView& event) const noexcept {
    return event.kind != HistoryEventKind::command_finished || filters_.allowsPane(event.command.command, event.command.directory);
  }

  void HistoryStore::importEntries(const ImportHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    const auto sequence = integer(request.base_sequence);
    if (std::cmp_greater(request.entries.size(), std::numeric_limits<std::int64_t>::max() - sequence)) {
      throw RequestError{FailureCode::invalid_request, "History import sequence overflows"};
    }

    const ImportIdentity identity{request.source};
    Transaction transaction{database_};
    Statement session{database_, "INSERT OR IGNORE INTO session(id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms) VALUES(?1, ?2, 0, ?2, ?2, '', ?3, ?4)"};

    session.bind(1, std::span{identity.session});
    session.bind(2, integer(identity.pane));
    session.bind(3, request.source);
    session.bind(4, request.entries.front().started_at_ms);
    session.finish();

    Statement command{database_, "INSERT OR IGNORE INTO command(session_id, pane_id, location_kind, location_id, tab_id, sequence, command, cwd, workspace_path, started_at_ms, duration_ns, exit_code, status, author, origin) VALUES(?1, ?2, 0, ?2, ?2, ?3, ?4, '', '', ?5, 0, NULL, 0, 0, 0)"};

    for (std::size_t index = 0; index < request.entries.size(); ++index) {
      command.bind(import_command_parameter::session, std::span{identity.session});
      command.bind(import_command_parameter::pane, integer(identity.pane));
      command.bind(import_command_parameter::sequence, sequence + static_cast<std::int64_t>(index));
      command.bind(import_command_parameter::command, request.entries[index].command);
      command.bind(import_command_parameter::started_at, request.entries[index].started_at_ms);
      command.finish();
      command.reset();
    }

    transaction.commit();
    reply.send(RequestCompleted{.request_id = request.request_id});
  }

  void HistoryStore::query(QueryHistory request, EncodedReply<ConcurrentMemory>& reply) {
    rows_.clear();
    if (request.snapshot_id == 0) {
      Statement boundary{database_, "SELECT COALESCE(MAX(id), 0) FROM command"};

      checkRow(boundary);
      request.snapshot_id = static_cast<std::uint64_t>(boundary.integer(0));
    }

    if (request.match == HistoryMatch::fuzzy && !request.query.empty() && request.entry_id == 0) {
      queryFuzzy(request, reply);
      return;
    }

    auto sql = string("SELECT ");

    sql.append(entry_columns);
    sql.append(" FROM command WHERE id <= ?1");
    if (request.entry_id != 0) {
      sql.append(" AND id = ?2");
    }

    appendMatch(sql, request.query);
    appendFilters(sql, request);
    // A distinct page counts its offset in commands, not rows: SQL cannot cut it, so the rows
    // stream newest first and stop once the page and one more command are found.
    const bool distinct = request.distinct && request.entry_id == 0;

    sql.append(distinct ? " ORDER BY started_at_ms DESC, id DESC" : " ORDER BY started_at_ms DESC, id DESC LIMIT ?7 OFFSET ?8");
    Statement statement{database_, sql};

    statement.bind(query_parameter::snapshot, integer(request.snapshot_id));
    if (request.entry_id != 0) {
      statement.bind(query_parameter::entry, integer(request.entry_id));
    }

    bindMatch(statement, request.query);
    bindFilters(statement, request);
    if (!distinct) {
      statement.bind(query_parameter::limit, static_cast<std::int64_t>(request.limit) + 1);
      statement.bind(query_parameter::offset, request.offset);
    }

    HashSet seen{memory_};
    std::uint32_t skipped = 0;
    bool more = false;

    while (statement.next()) {
      if (distinct) {
        if (!seen.insert(ImportIdentity::hash(command_hash_seed, statement.text(entry_column::command)), true)) {
          continue;
        }

        if (skipped < request.offset) {
          ++skipped;
          continue;
        }
      }

      if (rows_.entries().size() == request.limit || !rows_.append(statement)) {
        more = true;
        break;
      }
    }

    reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .has_more = more, .entries = rows_.entries()});
  }

  void HistoryStore::remove(const DeleteHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    Statement statement{database_, "DELETE FROM command WHERE id = ?1"};

    statement.bind(1, integer(request.id));
    statement.finish();
    reply.send(HistoryPruned{.request_id = request.request_id, .removed = static_cast<std::uint64_t>(sqlite3_changes64(database_.handle()))});
  }

  void HistoryStore::removeCommand(const DeleteHistoryCommand& request, EncodedReply<ConcurrentMemory>& reply) {
    Statement statement{database_, "DELETE FROM command WHERE command = (SELECT command FROM command WHERE id = ?1)"};

    statement.bind(1, integer(request.id));
    statement.finish();
    reply.send(HistoryPruned{.request_id = request.request_id, .removed = static_cast<std::uint64_t>(sqlite3_changes64(database_.handle()))});
  }

  void HistoryStore::prune(const PruneHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    auto sql = string("DELETE FROM command WHERE 1=1");

    appendMatch(sql, request.match);
    if (request.failed_only) {
      sql.append(" AND exit_code IS NOT NULL AND exit_code <> 0");
    }

    if (request.before_ms != 0) {
      sql.append(" AND started_at_ms < ?4");
    }

    appendScope(sql, request.scope);
    Statement statement{database_, sql};

    bindMatch(statement, request.match);
    if (request.before_ms != 0) {
      statement.bind(query_parameter::before, request.before_ms);
    }

    bindScope(statement, request.scope, request.scope_value);
    statement.finish();
    reply.send(HistoryPruned{.request_id = request.request_id, .removed = static_cast<std::uint64_t>(sqlite3_changes64(database_.handle()))});
  }

  void HistoryStore::readOutput(const ReadHistoryOutput& request, EncodedReply<ConcurrentMemory>& reply) {
    Statement statement{database_, "SELECT content, truncated, observed_bytes FROM command_output WHERE command_id = ?1"};

    statement.bind(1, integer(request.id));
    HistoryOutput result{.request_id = request.request_id, .id = request.id};

    if (statement.next()) {
      const auto text = statement.text(0);

      result.content = byteView(text);
      result.truncated = statement.integer(1) != 0;
      result.observed_bytes = static_cast<std::uint64_t>(statement.integer(2));
    }

    reply.send(result);
  }

  void HistoryStore::workspaces(const QueryHistoryWorkspaces& request, EncodedReply<ConcurrentMemory>& reply) {
    rows_.clear();
    Statement recorded{database_, "SELECT DISTINCT workspace_path FROM session LIMIT ?1"};

    // One more than a reply lists, to tell a full reply from a truncated one.
    recorded.bind(1, static_cast<std::int64_t>(HistoryWorkspaces::maximum_paths) + 1);
    ds::Vec<std::string_view, ConcurrentMemory> paths{memory_};
    HistoryWorkspaces result{.request_id = request.request_id};
    std::size_t bytes = 0;

    while (recorded.next()) {
      const auto path = recorded.text(0);

      // No directory has such a path, so it names no workspace to look for.
      if (path.empty() || path.size() >= max_path_bytes || path.contains('\0')) {
        continue;
      }

      if (paths.size() == HistoryWorkspaces::maximum_paths || bytes + path.size() > HistoryWorkspaces::maximum_bytes) {
        result.truncated = true;
        break;
      }

      bytes += path.size();
      paths.push(rows_.copy(path));
    }

    result.paths = paths;
    reply.send(result);
  }

  void HistoryStore::stats(const HistoryStatsQuery& request, EncodedReply<ConcurrentMemory>& reply) {
    rows_.clear();
    auto filters = string(" WHERE 1=1");

    appendScope(filters, request.scope);
    if (request.since_ms != 0) {
      filters.append(" AND started_at_ms >= ?1");
    }

    auto sql = string("SELECT COUNT(*), COUNT(DISTINCT command) FROM command");

    sql.append(filters);
    Statement totals{database_, sql};

    bindScope(totals, request.scope, request.scope_value);
    if (request.since_ms != 0) {
      totals.bind(1, request.since_ms);
    }

    checkRow(totals);
    HistoryStatsResult result{.request_id = request.request_id, .total = static_cast<std::uint64_t>(totals.integer(0)), .unique = static_cast<std::uint64_t>(totals.integer(1))};

    sql.assign("SELECT command, COUNT(*) AS n FROM command");
    sql.append(filters);
    sql.append(" GROUP BY command ORDER BY n DESC LIMIT 400");
    Statement top{database_, sql};

    bindScope(top, request.scope, request.scope_value);
    if (request.since_ms != 0) {
      top.bind(1, request.since_ms);
    }

    ds::Array<HistoryStatsEntry, maximum_stats_candidates> groups;
    std::size_t count = 0;

    while (top.next()) {
      const auto group = historyGroup(top.text(0));
      const auto occurrences = static_cast<std::uint64_t>(top.integer(1));
      const auto existing = groups.view().first(count);
      const auto found = static_cast<std::size_t>(std::ranges::find(existing, group, &HistoryStatsEntry::command) - existing.begin());
      if (found != count) {
        groups.atMut(found).count += occurrences;
      } else {
        groups.atMut(count++) = HistoryStatsEntry{.count = occurrences, .command = rows_.copy(group)};
      }
    }

    std::ranges::sort(groups.viewMut().first(count), [](const auto& left, const auto& right) {
      return left.count == right.count ? left.command < right.command : left.count > right.count;
    });

    result.top = std::span{groups}.first(std::min(count, maximum_stats_results));
    reply.send(result);
  }

  void HistoryStore::queryFuzzy(const QueryHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    // The newest candidates, newest first: SQLite walks the started_at index and stops at the
    // cap instead of every command being read and scored on each keystroke. For a list of each
    // command once, the cap counts commands, not runs: a run of a command already read is
    // passed over as it is read, so no command run often hides an older one.
    auto sql = string("SELECT id, command FROM command WHERE id <= ?1");

    appendFilters(sql, request);
    sql.append(" ORDER BY started_at_ms DESC, id DESC");
    if (!request.distinct) {
      sql.append(" LIMIT ");
      sql.append(fuzzy_candidate_limit);
    }

    Statement statement{database_, sql};

    statement.bind(1, integer(request.snapshot_id));
    bindFilters(statement, request);
    ds::Vec<RankedEntry, ConcurrentMemory> ranked{memory_};

    ranked.reserve(maximum_fuzzy_candidates);
    HashSet seen{memory_};
    std::size_t read = 0;
    bool capped = false;
    std::uint32_t order = 0;

    while (statement.next()) {
      const auto command = statement.text(1);

      if (request.distinct && !seen.insert(ImportIdentity::hash(command_hash_seed, command), true)) {
        continue;
      }

      if (read == maximum_fuzzy_candidates) {
        capped = true;
        break;
      }

      ++read;
      if (const auto score = historyScore(command, request.query)) {
        ranked.push(RankedEntry{.id = statement.integer(0), .score = *score, .order = order++});
      }
    }

    const auto precedes = [](const RankedEntry& left, const RankedEntry& right) {
      return left.score == right.score ? left.order < right.order : left.score > right.score;
    };

    const auto end = std::min(std::uint64_t{request.offset} + request.limit, static_cast<std::uint64_t>(ranked.size()));

    auto ranking = ranked.viewMut();

    std::ranges::partial_sort(ranking, ranking.begin() + static_cast<std::ptrdiff_t>(end), precedes);
    sql.assign("SELECT ");
    sql.append(entry_columns);
    sql.append(" FROM command WHERE id = ?1");
    Statement detail{database_, sql};
    const auto start = std::min<std::size_t>(request.offset, ranked.size());

    for (std::size_t index = start; index < end; ++index) {
      detail.bind(1, ranked[index].id);
      checkRow(detail);
      if (!rows_.append(detail)) {
        break;
      }

      detail.reset();
    }

    // Past the cap there are commands the search did not read.
    reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .has_more = capped || start + rows_.entries().size() < ranked.size(), .entries = rows_.entries()});
  }

  ds::String<ConcurrentMemory> HistoryStore::string(std::string_view value) const {
    return ds::String<ConcurrentMemory>{memory_, value};
  }

  std::int64_t HistoryStore::integer(std::uint64_t value) {
    if (value > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
      throw RequestError{FailureCode::invalid_request, "History identity exceeds the database integer range"};
    }

    return static_cast<std::int64_t>(value);
  }

  void HistoryStore::checkRow(Statement& statement) {
    if (!statement.next()) {
      throw RequestError{FailureCode::internal, "Expected history row is absent"};
    }
  }

  bool HistoryStore::useIndex(std::string_view query) const noexcept {
    // A UTF-8 continuation byte is 10xxxxxx; every other byte starts a character.
    constexpr unsigned continuation_mask = 0xc0;
    constexpr unsigned continuation_tag = 0x80;
    std::size_t characters = 0;

    for (const char byte : query) {
      characters += static_cast<std::size_t>((static_cast<unsigned char>(byte) & continuation_mask) != continuation_tag);
    }

    return indexed_ && characters >= 3;
  }

  void HistoryStore::appendMatch(ds::String<ConcurrentMemory>& sql, std::string_view query) const {
    if (!query.empty()) {
      sql.append(useIndex(query) ? " AND id IN (SELECT rowid FROM command_fts WHERE command_fts MATCH ?3)" : " AND instr(telar_fold(command), telar_fold(?3)) > 0");
    }
  }

  void HistoryStore::bindMatch(Statement& statement, std::string_view query) const {
    if (query.empty()) {
      return;
    }

    if (!useIndex(query)) {
      statement.bind(query_parameter::match, query);
      return;
    }

    auto quoted = string("\"");

    for (const char byte : query) {
      quoted.push(byte);
      if (byte == '"') {
        quoted.push('"');
      }
    }

    quoted.push('"');
    statement.bind(query_parameter::match, std::string_view{quoted});
  }

  void HistoryStore::appendScope(ds::String<ConcurrentMemory>& sql, HistoryScope scope) {
    switch (scope) {
    case HistoryScope::global:
      break;
    case HistoryScope::cwd:
      sql.append(" AND cwd = ?6");
      break;
    case HistoryScope::workspace:
      sql.append(" AND workspace_path = ?6");
      break;
    case HistoryScope::pane:
      sql.append(" AND pane_id = ?6");
      break;
    }
  }

  void HistoryStore::bindScope(Statement& statement, HistoryScope scope, const HistoryScopeValue& value) {
    if (scope == HistoryScope::pane) {
      statement.bind(query_parameter::scope, integer(std::get<std::uint64_t>(value)));
    } else if (scope != HistoryScope::global) {
      statement.bind(query_parameter::scope, std::get<std::string_view>(value));
    }
  }

  void HistoryStore::appendFilters(ds::String<ConcurrentMemory>& sql, const QueryHistory& request) {
    if (request.failed_only) {
      sql.append(" AND exit_code IS NOT NULL AND exit_code <> 0");
    }

    if (request.author != HistoryAuthorFilter::all) {
      sql.append(" AND author = ?5");
    }

    appendScope(sql, request.scope);
  }

  void HistoryStore::bindFilters(Statement& statement, const QueryHistory& request) {
    if (request.author != HistoryAuthorFilter::all) {
      statement.bind(query_parameter::author, static_cast<std::int64_t>(request.author == HistoryAuthorFilter::agent));
    }

    bindScope(statement, request.scope, request.scope_value);
  }

}
