module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.history.store;

import std;
import telar.sys.posix;
import telar.platform.primitives;
import telar.tbc;
import telar.base.diagnostics;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The ?N parameters of the statements below, as their SQL numbers them. A session's context
    // leads the statements that write a session or a command.
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
      constexpr int text = 1;
      constexpr int cwd = 2;
      constexpr int finished_at = 3;
      constexpr int exit_code = 4;
      constexpr int session = 5;
      constexpr int tool_call = 6;
      constexpr int workspace_path = 7;
      constexpr int provider = 8;
      constexpr int cwd_key = 9;
      constexpr int workspace_key = 10;
      constexpr int status = 11;
    }

    // Past the context's tab.
    namespace agent_insert_parameter {
      constexpr int text = 6;
      constexpr int cwd = 7;
      constexpr int workspace_path = 8;
      constexpr int started_at = 9;
      constexpr int exit_code = 10;
      constexpr int status = 11;
      constexpr int provider = 12;
      constexpr int tool_call = 13;
      constexpr int cwd_key = 14;
      constexpr int workspace_key = 15;
      constexpr int host = 16;
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
      constexpr int text = 7;
      constexpr int truncated = 8;
      constexpr int cwd = 9;
      constexpr int started_at = 10;
      constexpr int duration = 11;
      constexpr int exit_code = 12;
      constexpr int status = 13;
      constexpr int author = 14;
      constexpr int cwd_key = 15;
      constexpr int workspace_key = 16;
      constexpr int host = 17;
      constexpr int branch = 18;
      constexpr int shell = 19;
    }

    namespace complete_parameter {
      constexpr int id = 1;
      constexpr int duration = 2;
      constexpr int exit_code = 3;
      constexpr int status = 4;
      constexpr int truncated = 5;
    }

    // The texts a feed's change keeps in its buffer, in order.
    namespace change_part {
      constexpr std::size_t text = 0;
      constexpr std::size_t cwd_key = 1;
      constexpr std::size_t workspace_key = 2;
      constexpr std::size_t host = 3;
      constexpr std::size_t branch = 4;
      constexpr std::size_t shell = 5;
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
      constexpr int host = 13;
      constexpr int branch = 14;
      constexpr int shell = 15;
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

    // How a run ended as the history keeps it: a shell's Ctrl-C (130) and a broken pipe (141)
    // interrupt it, which is not a failure.
    HistoryStatus endedStatus(ds::Option<std::int32_t> exit_code, HistoryStatus status) noexcept {
      constexpr std::int32_t interrupt_exit = 130;
      constexpr std::int32_t broken_pipe_exit = 141;

      if (status == HistoryStatus::completed && exit_code && (*exit_code == interrupt_exit || *exit_code == broken_pipe_exit)) {
        return HistoryStatus::interrupted;
      }

      return status;
    }

    // The key of `path`, through the store's cache of keys when the writer has one.
    void directoryKey(DirectoryKeys* keys, std::string_view path, FixedText<PATH_MAX>& out) {
      if (keys != nullptr) {
        keys->key(path, out);
        return;
      }

      ds::Array<char, PATH_MAX> buffer; // NOLINT(cppcoreguidelines-pro-type-member-init): resolveDirectoryKey writes what it views

      out.assign(resolveDirectoryKey(path, buffer));
    }

    bool outputIndexed(Database& database) {
      Statement table{database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'command_output_fts'"};

      return table.next();
    }

    // `path` absolute against `directory`, its `.` and `..` resolved as written; none for a path
    // that is too long or climbs above the root.
    bool absolutePath(std::string_view directory, std::string_view path, ds::String<ConcurrentMemory>& out) { // NOLINT(bugprone-easily-swappable-parameters): the directory a path is relative to, then the path
      out.clear();
      if (!path.starts_with('/')) {
        out.append(directory);
        out.push('/');
      }

      out.append(path);
      if (out.size() >= PATH_MAX) {
        return false;
      }

      // Rewritten in place: each component is kept, dropped, or drops the one before it.
      ds::String<ConcurrentMemory> clean{out.memory()};
      std::string_view rest = out.view();

      while (!rest.empty()) {
        rest.remove_prefix(std::min(rest.find_first_not_of('/'), rest.size()));
        const auto end = std::min(rest.find('/'), rest.size());
        const auto part = rest.substr(0, end);

        rest.remove_prefix(end);
        if (part.empty() || part == ".") {
          continue;
        }

        if (part == "..") {
          const auto slash = clean.view().rfind('/');
          if (slash == std::string_view::npos) {
            return false;
          }

          clean.truncate(slash);
          continue;
        }

        clean.push('/');
        clean.append(part);
      }

      out.assign(clean.empty() ? std::string_view{"/"} : clean.view());
      return true;
    }

    bool isDirectory(const ds::String<ConcurrentMemory>& path) {
      ds::Array<char, PATH_MAX> terminated{};
      struct stat state{};

      if (path.size() >= terminated.size()) {
        return false;
      }

      std::ranges::copy(path.view(), terminated.dataMut());
      return ::stat(terminated.data(), &state) == 0 && S_ISDIR(state.st_mode);
    }

    bool exists(const ds::String<ConcurrentMemory>& path) {
      ds::Array<char, PATH_MAX> terminated{};
      struct stat state{};

      if (path.size() >= terminated.size()) {
        return true;
      }

      std::ranges::copy(path.view(), terminated.dataMut());
      return ::lstat(terminated.data(), &state) == 0 || sys::lastError() != ENOENT;
    }

  }

  HistoryTexts::HistoryTexts(Database& database)
      : find_(database, "SELECT id FROM command_text WHERE hash = ?1 AND text = ?2"),
        insert_(database, "INSERT INTO command_text(hash, text) VALUES (?1, ?2) RETURNING id") {}

  std::int64_t HistoryTexts::hash(std::string_view text) noexcept {
    constexpr std::uint64_t seed = 0x74656c6172;

    return std::bit_cast<std::int64_t>(ImportIdentity::hash(seed, text));
  }

  std::int64_t HistoryTexts::idOf(std::string_view text) {
    const auto hashed = hash(text);
    auto& slot = recent_.atMut(static_cast<std::size_t>(std::bit_cast<std::uint64_t>(hashed) % remembered));
    if (slot.id != 0 && slot.hash == hashed) {
      return slot.id;
    }

    find_.reset();
    find_.bind(1, hashed);
    find_.bind(2, text);
    std::int64_t id = 0;

    if (find_.next()) {
      id = find_.integer(0);
    } else {
      insert_.reset();
      insert_.bind(1, hashed);
      insert_.bind(2, text);
      if (!insert_.next()) {
        throw RequestError{FailureCode::internal, "History text was not stored"};
      }

      id = insert_.integer(0);
      insert_.reset();
    }

    find_.reset();
    slot = {.hash = hashed, .id = id};
    return id;
  }

  void HistoryTexts::forget() noexcept {
    recent_ = {};
  }

  HistoryChangeLog::HistoryChangeLog(ConcurrentMemory& memory)
      : items_(memory) {}

  void HistoryChangeLog::push(Item item) {
    if (many_) {
      return;
    }

    if (items_.size() >= maximum_items) {
      many();
      return;
    }

    items_.push(item);
  }

  void HistoryChangeLog::ran(std::int64_t id, std::uint64_t pane) {
    push({.kind = Kind::ran, .id = id, .pane = pane});
  }

  void HistoryChangeLog::removed(std::int64_t id) {
    push({.kind = Kind::removed, .id = id});
  }

  void HistoryChangeLog::removedText(std::int64_t text_id, std::int64_t entry_id) {
    push({.kind = Kind::removed_text, .id = entry_id, .value = text_id});
  }

  void HistoryChangeLog::session(std::uint64_t pane, std::int64_t started_ms) {
    push({.kind = Kind::session, .pane = pane, .value = started_ms});
  }

  void HistoryChangeLog::selected(std::int64_t text_id) {
    push({.kind = Kind::selected, .value = text_id});
  }

  void HistoryChangeLog::many() noexcept {
    if (!many_) {
      many_mark_ = items_.size();
    }

    many_ = true;
  }

  std::size_t HistoryChangeLog::mark() const noexcept {
    return many_ ? std::numeric_limits<std::size_t>::max() : items_.size();
  }

  void HistoryChangeLog::rewind(std::size_t mark) noexcept {
    if (mark == std::numeric_limits<std::size_t>::max()) {
      return;
    }

    if (many_ && many_mark_ >= mark) {
      many_ = false;
    }

    items_.truncate(std::min(mark, items_.size()));
  }

  void HistoryChangeLog::clear() noexcept {
    items_.clear();
    many_ = false;
  }

  bool HistoryChangeLog::empty() const noexcept {
    return items_.empty() && !many_;
  }

  bool HistoryChangeLog::manyChanged() const noexcept {
    return many_;
  }

  std::span<const HistoryChangeLog::Item> HistoryChangeLog::items() const noexcept {
    return items_.view();
  }

  AgentCommandWriter::AgentCommandWriter(Database& database, HistoryChangeLog* log, HistoryWriteOptions options)
      : database_(database),
        log_(log),
        options_(options),
        texts_(database),
        session_(database, session_sql),
        finish_(database, finish_sql),
        insert_(database, insert_sql),
        drop_(database, drop_sql) {}

  void AgentCommandWriter::forgetTexts() noexcept {
    texts_.forget();
  }

  void AgentCommandWriter::persist(const ReportAgentCommand& request, const RequestContext& context) {
    TELAR_TRACE("history.persistAgentCommand");
    if (request.phase == AgentCommandPhase::started && request.tool_call_id.empty()) {
      return;
    }

    try {
      WriteScope scope{database_};
      const bool finished = request.phase == AgentCommandPhase::finished;
      const auto status = finished ? endedStatus(request.exit_code, HistoryStatus::completed) : HistoryStatus::running;
      AgentRun run{
          .workspace_path = writtenDirectory(context.workspace_path),
          .cwd = writtenDirectory(request.cwd),
          .now = context.received_at_ms != 0 ? context.received_at_ms : wallMilliseconds(),
          .status = status,
          .dropped = finished && !options_.store_failed && historyFailed(request.exit_code, status),
      };

      directoryKey(options_.keys, context.workspace_path, workspace_key_);
      directoryKey(options_.keys, request.cwd, cwd_key_);
      openSession(request, context, run);
      run.text = texts_.idOf(request.command);
      // A finish completes the run its start stored; without one it is a run of its own.
      const bool completed = finished && !request.tool_call_id.empty() && finishCall(request, context, run);

      if (!completed && !run.dropped) {
        insertCall(request, context, run);
      }

      scope.commit();
    } catch (...) {
      // A text it learned may be one the rollback took back.
      texts_.forget();
      throw;
    }
  }

  void AgentCommandWriter::openSession(const ReportAgentCommand& request, const RequestContext& context, const AgentRun& run) {
    session_.reset();
    session_.bind(context_parameter::session, std::span{context.history_session});
    session_.bind(context_parameter::pane, static_cast<std::int64_t>(request.pane_id));
    session_.bind(context_parameter::location_kind, static_cast<std::int64_t>(context.location.workspace.kind));
    session_.bind(context_parameter::location_id, static_cast<std::int64_t>(context.location.workspace.id));
    session_.bind(context_parameter::tab, static_cast<std::int64_t>(context.location.tab_id));
    session_.bind(context_parameter::workspace_path, run.workspace_path);
    session_.bind(agent_session_parameter::started_at, run.now);
    session_.finish();
  }

  bool AgentCommandWriter::finishCall(const ReportAgentCommand& request, const RequestContext& context, const AgentRun& run) {
    finish_.reset();
    finish_.bind(agent_finish_parameter::text, run.text);
    finish_.bind(agent_finish_parameter::cwd, run.cwd);
    finish_.bind(agent_finish_parameter::finished_at, run.now);
    finish_.bind(agent_finish_parameter::exit_code, request.exit_code);
    finish_.bind(agent_finish_parameter::session, std::span{context.history_session});
    finish_.bind(agent_finish_parameter::tool_call, request.tool_call_id);
    finish_.bind(agent_finish_parameter::workspace_path, run.workspace_path);
    finish_.bind(agent_finish_parameter::provider, request.provider);
    finish_.bind(agent_finish_parameter::cwd_key, cwd_key_.view());
    finish_.bind(agent_finish_parameter::workspace_key, workspace_key_.view());
    finish_.bind(agent_finish_parameter::status, static_cast<std::int64_t>(run.status));
    if (!finish_.next()) {
      finish_.reset();
      return false;
    }

    const auto id = finish_.integer(0);

    finish_.reset();
    if (run.dropped) {
      // A failed run the history does not keep goes, though it was kept while it ran.
      drop_.reset();
      drop_.bind(1, id);
      drop_.finish();
      if (log_ != nullptr) {
        log_->removed(id);
      }
    } else if (log_ != nullptr) {
      log_->ran(id, request.pane_id);
    }

    return true;
  }

  void AgentCommandWriter::insertCall(const ReportAgentCommand& request, const RequestContext& context, const AgentRun& run) {
    insert_.reset();
    insert_.bind(context_parameter::session, std::span{context.history_session});
    insert_.bind(context_parameter::pane, static_cast<std::int64_t>(request.pane_id));
    insert_.bind(context_parameter::location_kind, static_cast<std::int64_t>(context.location.workspace.kind));
    insert_.bind(context_parameter::location_id, static_cast<std::int64_t>(context.location.workspace.id));
    insert_.bind(context_parameter::tab, static_cast<std::int64_t>(context.location.tab_id));
    insert_.bind(agent_insert_parameter::text, run.text);
    insert_.bind(agent_insert_parameter::cwd, run.cwd);
    insert_.bind(agent_insert_parameter::workspace_path, run.workspace_path);
    insert_.bind(agent_insert_parameter::started_at, run.now);
    insert_.bind(agent_insert_parameter::exit_code, request.exit_code);
    insert_.bind(agent_insert_parameter::status, static_cast<std::int64_t>(run.status));
    insert_.bind(agent_insert_parameter::provider, request.provider);
    insert_.bind(agent_insert_parameter::cwd_key, cwd_key_.view());
    insert_.bind(agent_insert_parameter::workspace_key, workspace_key_.view());
    insert_.bind(agent_insert_parameter::host, options_.host);
    if (request.tool_call_id.empty()) {
      insert_.bindNull(agent_insert_parameter::tool_call);
    } else {
      insert_.bind(agent_insert_parameter::tool_call, request.tool_call_id);
    }

    if (insert_.next() && log_ != nullptr) {
      log_->ran(insert_.integer(0), request.pane_id);
    }

    insert_.reset();
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

  std::int64_t ImportIdentity::entry(std::int64_t started_at_ms, std::string_view command, std::uint32_t run) noexcept {
    constexpr std::uint64_t entry_seed = 0x74656c6172656e74;
    // Two bits short of a word: the top one keeps the sequence positive, the next one sets it apart.
    constexpr unsigned entry_bits = 62;
    const ds::Array<std::uint64_t, 2> when{static_cast<std::uint64_t>(started_at_ms), run};
    const auto seed = hash(entry_seed, std::string_view{reinterpret_cast<const char*>(when.data()), sizeof(when)}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the time's and the run's bytes are what the seed hashes
    const auto identity = hash(seed, command) & ((std::uint64_t{1} << entry_bits) - 1);

    return static_cast<std::int64_t>(static_cast<std::uint64_t>(first_entry) | identity);
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

  PaneHistoryWriter::PaneHistoryWriter(Database& database, HistoryChangeLog* log, HistoryWriteOptions options)
      : database_(database),
        log_(log),
        options_(options),
        texts_(database),
        output_index_(options.memory != nullptr && outputIndexed(database)),
        session_(database, session_sql),
        command_(database, command_sql),
        running_(database, running_sql),
        complete_(database, complete_sql),
        drop_(database, drop_sql),
        output_(database, output_sql),
        finish_(database, finish_sql),
        orphans_(database, orphans_sql),
        title_(database, title_sql),
        select_(database, select_sql) {
    if (output_index_ && options.memory != nullptr) {
      output_index_statement_.emplace(database, "INSERT INTO command_output_fts(rowid, content) VALUES (?1, ?2)");
      plain_.emplace(*options.memory);
    }
  }

  void PaneHistoryWriter::forgetTexts() noexcept {
    texts_.forget();
  }

  void PaneHistoryWriter::persist(const HistoryEventView& event) {
    TELAR_TRACE("history.persistPaneEvent");
    if (event.kind == HistoryEventKind::launch_failed) {
      throw RequestError{FailureCode::invalid_request, "A failed launch has no history session"};
    }

    try {
      WriteScope scope{database_};

      if (event.kind != HistoryEventKind::session_title) {
        ensureSession(event.session);
      }

      apply(event);
      scope.commit();
    } catch (...) {
      // A text it learned may be one the rollback took back.
      texts_.forget();
      throw;
    }
  }

  void PaneHistoryWriter::apply(const HistoryEventView& event) {
    switch (event.kind) {
    case HistoryEventKind::session_started:
      if (log_ != nullptr) {
        log_->session(event.session.pane, event.session.started_at_ms);
      }

      break;
    case HistoryEventKind::launch_failed:
      break;
    case HistoryEventKind::session_finished:
      finish_.reset();
      finish_.bind(1, std::span{event.session.id});
      finish_.bind(2, event.finished_at_ms);
      finish_.finish();
      closeSession(event.session, event.finished_at_ms);
      break;
    case HistoryEventKind::command_started: {
      const auto id = insertCommand(event.session, event.command, HistoryStatus::running);

      if (log_ != nullptr) {
        log_->ran(id, event.session.pane);
      }

      break;
    }
    case HistoryEventKind::command_finished:
      finishCommand(event.session, event.command);
      break;
    case HistoryEventKind::session_title:
      title_.reset();
      title_.bind(1, std::span{event.title.session});
      title_.bind(2, event.title.title.view());
      title_.bind(3, static_cast<std::int64_t>(event.title.source));
      title_.bind(4, static_cast<std::int64_t>(event.title.state));
      title_.finish();
      if (database_.changes() != 1) {
        throw RequestError{FailureCode::invalid_request, "History session does not exist"};
      }

      break;
    }
  }

  void PaneHistoryWriter::ensureSession(const HistorySession& session) {
    session_.reset();
    bindContext(session_, session);
    session_.bind(pane_session_parameter::shell, session.shell);
    session_.bind(pane_session_parameter::started_at, session.started_at_ms);
    session_.finish();
  }

  std::int64_t PaneHistoryWriter::insertCommand(const HistorySession& session, const CapturedCommand& command, HistoryStatus status) {
    command_.reset();
    bindContext(command_, session);
    command_.bind(pane_command_parameter::text, texts_.idOf(command.command));
    command_.bind(pane_command_parameter::truncated, static_cast<std::int64_t>(command.truncated));
    directoryKey(options_.keys, command.directory, cwd_key_);
    directoryKey(options_.keys, session.workspace_path, workspace_key_);
    command_.bind(pane_command_parameter::cwd, writtenDirectory(command.directory));
    command_.bind(pane_command_parameter::cwd_key, cwd_key_.view());
    command_.bind(pane_command_parameter::workspace_key, workspace_key_.view());
    command_.bind(pane_command_parameter::started_at, command.started.milliseconds);
    command_.bind(pane_command_parameter::duration, status == HistoryStatus::running ? 0 : command.duration_ns);
    command_.bind(pane_command_parameter::exit_code, status == HistoryStatus::running ? ds::none : ds::Option<std::int32_t>{command.exit_code.hasValue() ? ds::Option<std::int32_t>{*command.exit_code} : ds::none});
    command_.bind(pane_command_parameter::status, static_cast<std::int64_t>(status));
    command_.bind(pane_command_parameter::author, static_cast<std::int64_t>(command.author));
    command_.bind(pane_command_parameter::host, command.host.empty() ? options_.host : command.host);
    command_.bind(pane_command_parameter::branch, utf8Prefix(command.branch, max_branch_bytes));
    command_.bind(pane_command_parameter::shell, utf8Prefix(session.shell, max_history_shell_bytes));
    if (!command_.next()) {
      throw RequestError{FailureCode::internal, "History command was not stored"};
    }

    const auto id = command_.integer(0);

    command_.reset();
    return id;
  }

  void PaneHistoryWriter::finishCommand(const HistorySession& session, const CapturedCommand& command) {
    const ds::Option<std::int32_t> exit_code = command.exit_code ? ds::Option<std::int32_t>{*command.exit_code} : ds::none;
    const auto status = endedStatus(exit_code, command.status);
    const auto text = texts_.idOf(command.command);
    ds::Option<std::int64_t> id;

    // The run its start stored, when it stored one.
    running_.reset();
    running_.bind(1, std::span{session.id});
    running_.bind(2, command.started.milliseconds);
    running_.bind(3, text);
    if (running_.next()) {
      id = running_.integer(0);
    }

    running_.reset();
    if (!options_.store_failed && historyFailed(exit_code, status)) {
      if (id) {
        drop_.reset();
        drop_.bind(1, *id);
        drop_.finish();
        if (log_ != nullptr) {
          log_->removed(*id);
        }
      }

      return;
    }

    if (id) {
      complete_.reset();
      complete_.bind(complete_parameter::id, *id);
      complete_.bind(complete_parameter::duration, command.duration_ns);
      complete_.bind(complete_parameter::exit_code, exit_code);
      complete_.bind(complete_parameter::status, static_cast<std::int64_t>(status));
      complete_.bind(complete_parameter::truncated, static_cast<std::int64_t>(command.truncated));
      complete_.finish();
    } else {
      id = insertCommand(session, command, status);
    }

    storeOutput(*id, command);
    if (log_ != nullptr) {
      log_->ran(*id, session.pane);
    }

    directoryKey(options_.keys, command.directory, cwd_key_);
    noteChoice(session.pane, text, cwd_key_.view());
    if (status == HistoryStatus::completed && exit_code == 0) {
      followMove(command);
    }
  }

  void PaneHistoryWriter::storeOutput(std::int64_t id, const CapturedCommand& command) {
    if (command.output.empty() && command.output_observed == 0) {
      return;
    }

    const auto content = textView(command.output);

    output_.reset();
    output_.bind(1, content);
    output_.bind(2, static_cast<std::int64_t>(command.outputTruncated()));
    output_.bind(3, static_cast<std::int64_t>(std::min<std::uint64_t>(command.output_observed, std::numeric_limits<std::int64_t>::max())));
    output_.bind(4, id);
    output_.finish();
    if (output_index_ && !content.empty()) {
      plainHistoryOutput(content, plain_.getMut());
      auto& index = output_index_statement_.getMut();

      index.reset();
      index.bind(1, id);
      index.bind(2, plain_->view());
      index.finish();
    }
  }

  void PaneHistoryWriter::closeSession(const HistorySession& session, std::int64_t finished_at_ms) {
    // A run whose end never came, as when its pane closed mid-command, ends with its session.
    orphans_.reset();
    orphans_.bind(1, std::span{session.id});
    orphans_.bind(2, finished_at_ms);
    while (orphans_.next()) {
      if (log_ != nullptr) {
        log_->ran(orphans_.integer(0), static_cast<std::uint64_t>(orphans_.integer(1)));
      }
    }

    orphans_.reset();
  }

  void PaneHistoryWriter::choose(std::uint64_t pane, std::int64_t text_id, std::string_view cwd_key, std::int64_t now_ms) {
    // The pane's own slot, a free one, or the one chosen longest ago.
    std::size_t slot = 0;

    for (std::size_t index = 0; index < choices_.size(); ++index) {
      if (choices_[index].pane == pane || choices_[index].pane == 0) {
        slot = index;
        break;
      }

      if (choices_[index].chosen_ms < choices_[slot].chosen_ms) {
        slot = index;
      }
    }

    choices_.atMut(slot) = {.pane = pane, .text_id = text_id, .cwd_hash = HistoryTexts::hash(cwd_key), .chosen_ms = now_ms};
  }

  void PaneHistoryWriter::noteChoice(std::uint64_t pane, std::int64_t text_id, std::string_view cwd_key) { // NOLINT(bugprone-easily-swappable-parameters): a pane id and a text's row id
    if (pane == 0) {
      return;
    }

    const auto found = std::ranges::find(choices_.view(), pane, &HistoryChoice::pane);
    if (found == choices_.view().end()) {
      return;
    }

    // The pane's next command counts only when it is the one chosen, unchanged, where it was.
    const auto choice = *found;
    const bool same = choice.text_id == text_id && choice.cwd_hash == HistoryTexts::hash(cwd_key) && wallMilliseconds() - choice.chosen_ms <= choice_lifetime_ms;

    choices_.atMut(static_cast<std::size_t>(found - choices_.view().begin())) = {};
    if (!same) {
      return;
    }

    select_.reset();
    select_.bind(1, text_id);
    select_.finish();
    if (log_ != nullptr) {
      log_->selected(text_id);
    }
  }

  ds::Option<ds::Array<std::string_view, 2>> PaneHistoryWriter::moveOperands(std::string_view text) {
    // Only a plain `mv OLD NEW` that the shell ran as written: no options, quotes, expansions
    // or operators, whose words name paths as they are.
    constexpr std::string_view special = "'\"\\$*?[]{}~;&|<>`()!#\n";
    constexpr std::string_view verb = "mv ";
    if (!text.starts_with(verb) || text.find_first_of(special) != std::string_view::npos) {
      return ds::none;
    }

    ds::Array<std::string_view, 2> words{};
    std::size_t count = 0;
    auto rest = text.substr(verb.size());

    for (;;) {
      rest.remove_prefix(std::min(rest.find_first_not_of(" \t"), rest.size()));
      if (rest.empty()) {
        break;
      }

      const auto end = std::min(rest.find_first_of(" \t"), rest.size());
      const auto word = rest.substr(0, end);

      rest.remove_prefix(end);
      if (word == "--" && count == 0) {
        continue;
      }

      if (word.starts_with('-') || count == words.size()) {
        return ds::none;
      }

      words.atMut(count++) = word;
    }

    return count == words.size() ? ds::Option{words} : ds::none;
  }

  void PaneHistoryWriter::followMove(const CapturedCommand& command) {
    // Only a plain `mv OLD NEW` that the shell ran as written: no options, quotes, expansions
    // or operators, whose words name paths as they are.
    constexpr std::int64_t maximum_rows = 100'000;
    const auto words = moveOperands(command.command);
    if (!words || options_.memory == nullptr) {
      return;
    }

    auto& memory = *options_.memory;
    ds::String<ConcurrentMemory> old_path{memory};
    ds::String<ConcurrentMemory> new_path{memory};

    if (!absolutePath(command.directory, (*words)[0], old_path) || !absolutePath(command.directory, (*words)[1], new_path) || old_path.view() == "/" || exists(old_path)) {
      return;
    }

    // `mv dir existing` moves dir into existing; `mv dir new` renames it.
    ds::String<ConcurrentMemory> into{memory, new_path.view()};

    into.push('/');
    into.append(old_path.view().substr(old_path.view().rfind('/') + 1));
    if (isDirectory(into)) {
      new_path.assign(into.view());
    } else if (!isDirectory(new_path)) {
      return;
    }

    // The old directory's key is its parent's, which still exists, and its name.
    const auto slash = old_path.view().rfind('/');
    FixedText<PATH_MAX> parent_key;
    FixedText<PATH_MAX> new_key;

    directoryKey(options_.keys, slash == 0 ? std::string_view{"/"} : old_path.view().substr(0, slash), parent_key);
    directoryKey(options_.keys, new_path.view(), new_key);
    ds::String<ConcurrentMemory> old_key{memory, parent_key.view() == "/" ? std::string_view{} : parent_key.view()};

    old_key.push('/');
    old_key.append(old_path.view().substr(slash + 1));
    if (old_key.view() == new_key.view()) {
      return;
    }

    struct Rewrite {
      const char* sql;
      std::string_view from;
      std::string_view to;
    };

    // The keys and the paths as written, of the runs in the directory or below it, at most
    // maximum_rows of them for each.
    const ds::Array rewrites{
        Rewrite{.sql = "UPDATE command SET cwd_key = ?2 || substr(cwd_key, length(?1) + 1) WHERE id IN (SELECT id FROM command WHERE cwd_key = ?1 OR (cwd_key >= ?1 || '/' AND cwd_key < ?1 || '0') LIMIT ?3)", .from = old_key.view(), .to = new_key.view()},
        Rewrite{.sql = "UPDATE command SET workspace_key = ?2 || substr(workspace_key, length(?1) + 1) WHERE id IN (SELECT id FROM command WHERE workspace_key = ?1 OR (workspace_key >= ?1 || '/' AND workspace_key < ?1 || '0') LIMIT ?3)", .from = old_key.view(), .to = new_key.view()},
        Rewrite{.sql = "UPDATE command SET cwd = ?2 || substr(cwd, length(?1) + 1) WHERE id IN (SELECT id FROM command WHERE cwd = ?1 OR (cwd >= ?1 || '/' AND cwd < ?1 || '0') LIMIT ?3)", .from = old_path.view(), .to = new_path.view()},
        Rewrite{.sql = "UPDATE command SET workspace_path = ?2 || substr(workspace_path, length(?1) + 1) WHERE id IN (SELECT id FROM command WHERE workspace_path = ?1 OR (workspace_path >= ?1 || '/' AND workspace_path < ?1 || '0') LIMIT ?3)", .from = old_path.view(), .to = new_path.view()},
    };

    std::int64_t changed = 0;

    for (const auto& rewrite : rewrites) {
      Statement update{database_, rewrite.sql};

      update.bind(1, rewrite.from);
      update.bind(2, rewrite.to);
      update.bind(3, maximum_rows);
      update.finish();
      changed += database_.changes();
    }

    if (changed != 0) {
      if (options_.keys != nullptr) {
        options_.keys->forget();
      }

      if (log_ != nullptr) {
        log_->many();
      }
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
    statement.bind(context_parameter::workspace_path, writtenDirectory(session.workspace_path));
  }

  HistoryRows::TextArena::TextArena(ConcurrentMemory& memory, std::size_t limit)
      : storage_(memory, limit) {}

  void HistoryRows::TextArena::reserve(std::size_t capacity) {
    storage_.reserve(capacity);
  }

  void HistoryRows::TextArena::clear() noexcept {
    storage_.clear();
  }

  std::string_view HistoryRows::TextArena::copy(std::string_view text) const {
    const auto offset = storage_.size();

    storage_.append(byteView(text));
    return textView(storage_.readable().subspan(offset, text.size()));
  }

  HistoryRows::HistoryRows(ConcurrentMemory& memory)
      : text_(memory, max_payload_size),
        entries_(memory),
        ranges_(memory) {
    text_.reserve(max_payload_size);
    entries_.reserve(maximum_entries);
    ranges_.reserve(maximum_entries * max_history_match_ranges * 2);
    clear();
  }

  void HistoryRows::clear() noexcept {
    text_.clear();
    entries_.clear();
    ranges_.clear();
    encoded_bytes_ = result_header_bytes;
  }

  std::span<const HistoryRange> HistoryRows::keep(std::span<const HistoryRange> ranges) {
    const auto kept = std::min(ranges.size(), max_history_match_ranges);
    const auto offset = ranges_.size();

    ranges_.extend(ranges.first(kept));
    return ranges_.view().subspan(offset, kept);
  }

  bool HistoryRows::append(const Statement& row, const HistoryRowExtra& extra) {
    auto stored = view(row);

    stored.run_count = extra.run_count;
    stored.last_exit = extra.last_exit;
    stored.ranges = extra.ranges.first(std::min(extra.ranges.size(), max_history_match_ranges));
    stored.excerpt = extra.excerpt;
    stored.excerpt_ranges = extra.excerpt_ranges.first(std::min(extra.excerpt_ranges.size(), max_history_match_ranges));
    stored.neighbour = extra.neighbour;
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
    entry.host = copy(stored.host);
    entry.branch = copy(stored.branch);
    entry.shell = copy(stored.shell);
    entry.excerpt = copy(stored.excerpt);
    entry.run_count = stored.run_count;
    entry.last_exit = stored.last_exit;
    entry.ranges = keep(stored.ranges);
    entry.excerpt_ranges = keep(stored.excerpt_ranges);
    entry.neighbour = stored.neighbour;
    entries_.push(entry);
    encoded_bytes_ += bytes;
    return true;
  }

  std::string_view HistoryRows::copy(std::string_view text) const {
    return text_.copy(text);
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
    entry.host = utf8Prefix(row.text(entry_column::host), max_history_host_bytes);
    entry.branch = utf8Prefix(row.text(entry_column::branch), max_branch_bytes);
    entry.shell = utf8Prefix(row.text(entry_column::shell), max_history_shell_bytes);
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

  HistoryIndexFeed::Change::Change(ConcurrentMemory& memory)
      : texts(memory) {}

  void HistoryIndexFeed::Change::keep(const HistoryRunFacts& facts) {
    // The numbers alone: the texts live in the change's own buffer.
    run = {
        .id = facts.id,
        .text_id = facts.text_id,
        .pane = facts.pane,
        .started_ms = facts.started_ms,
        .duration_ns = facts.duration_ns,
        .exit_code = facts.exit_code,
        .status = facts.status,
        .author = facts.author,
        .selected = facts.selected,
    };

    texts.clear();
    const ds::Array pieces{facts.text, facts.cwd_key, facts.workspace_key, facts.host, facts.branch, facts.shell};

    for (std::size_t piece = 0; piece < pieces.size(); ++piece) {
      lengths.atMut(piece) = static_cast<std::uint32_t>(pieces[piece].size());
      texts.append(pieces[piece]);
    }
  }

  HistoryRunFacts HistoryIndexFeed::Change::facts() const {
    auto result = run;
    std::size_t offset = 0;
    const auto next = [&](std::size_t part) {
      const auto view = texts.view().substr(offset, lengths[part]);

      offset += lengths[part];
      return view;
    };

    result.text = next(change_part::text);
    result.cwd_key = next(change_part::cwd_key);
    result.workspace_key = next(change_part::workspace_key);
    result.host = next(change_part::host);
    result.branch = next(change_part::branch);
    result.shell = next(change_part::shell);
    return result;
  }

  HistoryIndexFeed::HistoryIndexFeed(ConcurrentMemory& memory)
      : pending_(memory) {}

  void HistoryIndexFeed::publish(ds::Vec<Change, ConcurrentMemory>& changes) {
    const std::scoped_lock lock{mutex_};

    if (pending_.empty()) {
      std::swap(pending_, changes);
      return;
    }

    for (auto& change : changes.viewMut()) {
      pending_.push(std::move(change));
    }

    changes.clear();
  }

  void HistoryIndexFeed::drain(ds::Vec<Change, ConcurrentMemory>& changes) {
    changes.clear();
    const std::scoped_lock lock{mutex_};

    std::swap(pending_, changes);
  }

}
