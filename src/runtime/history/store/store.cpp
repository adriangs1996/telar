module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.history.store;

import std;
import telar.sys.posix;
import telar.platform.primitives;
import telar.tbc;
import telar.base.diagnostics;
import telar.base.history;
import telar.base.text.utf8;
import telar.wire.runtime;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // A query numbers each filter apart, so a statement binds only the ones its SQL appends.
    namespace query_parameter {
      constexpr int snapshot = 1;
      constexpr int match = 3;
      constexpr int before = 4;
      constexpr int author = 5;
      constexpr int scope = 6;
      constexpr int keep = 7;
      constexpr int exit_code = 9;
      constexpr int since = 10;
      constexpr int until = 11;
      constexpr int duration = 12;
      constexpr int host = 13;
      constexpr int branch = 14;
      constexpr int shell = 15;
      constexpr int after_started = 16;
      constexpr int after_id = 17;
    }

    namespace import_command_parameter {
      constexpr int session = 1;
      constexpr int pane = 2;
      constexpr int sequence = 3;
      constexpr int text = 4;
      constexpr int started_at = 5;
      constexpr int host = 6;
      constexpr int cwd = 7;
      constexpr int cwd_key = 8;
      constexpr int duration = 9;
      constexpr int exit_code = 10;
    }

    // A rewrite reads the entries a prune matches in pages of ids past the last one read.
    namespace rewrite_parameter {
      constexpr int after = 1;
      constexpr int limit = 8;
    }

    // The columns facts_sql reads, in its order.
    namespace fact_column {
      constexpr int id = 0;
      constexpr int text_id = 1;
      constexpr int text = 2;
      constexpr int cwd_key = 3;
      constexpr int workspace_key = 4;
      constexpr int host = 5;
      constexpr int branch = 6;
      constexpr int shell = 7;
      constexpr int pane = 8;
      constexpr int started_at = 9;
      constexpr int duration = 10;
      constexpr int exit_code = 11;
      constexpr int status = 12;
      constexpr int author = 13;
      constexpr int selected = 14;
    }

    // The column of a row past HistoryRows::entry_columns: the text's id, and an output's content.
    constexpr int text_id_column = 16;
    constexpr int content_column = 17;

    // Whether a list of each command once reads `row`, a row of HistoryRows::entry_columns, only to
    // know its command was listed: the row is no older than the cursor, the last run an earlier
    // page showed. Other listings leave those rows out in SQL.
    bool beforeCursor(const QueryHistory& request, const Statement& row) {
      constexpr int id_column = 0;
      constexpr int started_column = 2;

      if (!request.distinct || request.after_id == 0) {
        return false;
      }

      const auto started = row.integer(started_column);

      return started > request.after_started_ms || (started == request.after_started_ms && std::cmp_greater_equal(row.integer(id_column), request.after_id));
    }

    constexpr std::string_view facts_sql = "SELECT c.id, c.text_id, t.text, c.cwd_key, c.workspace_key, c.host, c.branch, c.shell, c.pane_id, c.started_at_ms, c.duration_ns, c.exit_code, c.status, c.author, t.selected FROM command c JOIN command_text t ON t.id = c.text_id";
    constexpr std::int64_t nanoseconds_per_millisecond = 1'000'000;
    constexpr std::int64_t milliseconds_per_day = 86'400'000;

    HistoryRunFacts factsOf(const Statement& row) {
      const auto status = row.integer(fact_column::status);
      const auto author = row.integer(fact_column::author);

      return {
          .id = row.integer(fact_column::id),
          .text_id = row.integer(fact_column::text_id),
          .text = row.text(fact_column::text),
          .cwd_key = row.text(fact_column::cwd_key),
          .workspace_key = row.text(fact_column::workspace_key),
          .host = row.text(fact_column::host),
          .branch = row.text(fact_column::branch),
          .shell = row.text(fact_column::shell),
          .pane = static_cast<std::uint64_t>(std::max<std::int64_t>(0, row.integer(fact_column::pane))),
          .started_ms = row.integer(fact_column::started_at),
          .duration_ns = row.integer(fact_column::duration),
          .exit_code = row.isNull(fact_column::exit_code) ? ds::none : ds::Option{static_cast<std::int32_t>(row.integer(fact_column::exit_code))},
          .status = status >= 0 && status <= static_cast<std::int64_t>(HistoryStatus::running) ? static_cast<HistoryStatus>(status) : HistoryStatus::completed,
          .author = author == static_cast<std::int64_t>(HistoryAuthor::agent) ? HistoryAuthor::agent : HistoryAuthor::human,
          .selected = static_cast<std::uint32_t>(std::clamp<std::int64_t>(row.integer(fact_column::selected), 0, std::numeric_limits<std::uint32_t>::max())),
      };
    }

    bool cancelledBy(const std::atomic<bool>* cancelled) noexcept {
      return cancelled != nullptr && cancelled->load(std::memory_order_relaxed);
    }

    // Lets the connection end a statement while `cancelled` is set, for as long as it lives.
    class InterruptScope {
    public:
      InterruptScope(Database& database, const std::atomic<bool>* cancelled) noexcept
          : database_(database) {
        database_.interruptWhen(cancelled);
      }

      ~InterruptScope() {
        database_.interruptWhen(nullptr);
      }

      InterruptScope(const InterruptScope&) = delete;
      InterruptScope& operator=(const InterruptScope&) = delete;
      InterruptScope(InterruptScope&&) = delete;
      InterruptScope& operator=(InterruptScope&&) = delete;

    private:
      Database& database_;
    };

    void superseded(const QueryHistory& request, EncodedReply<ConcurrentMemory>& reply) {
      reply.send(RequestFailed{.request_id = request.request_id, .code = FailureCode::internal, .message = "History query superseded"});
    }

    // Whether a listing by rank orders this query; automatic is by rank for a fuzzy search.
    bool ranked(const QueryHistory& request) noexcept {
      switch (request.sort) {
      case HistorySort::rank:
        return true;
      case HistorySort::time:
        return false;
      case HistorySort::automatic:
        break;
      }

      return request.match == HistoryMatch::fuzzy && !request.query.empty();
    }

    // The bytes of `text` from `start`, at most `size`, cut on characters.
    std::string_view slice(std::string_view text, std::size_t start, std::size_t size) {
      while (start > 0 && start < text.size() && utf8::isContinuation(static_cast<unsigned char>(text[start]))) {
        --start;
      }

      return utf8Prefix(text.substr(std::min(start, text.size())), size);
    }

  }

  namespace {

    using ImportSessions = ds::Vec<ds::Array<std::uint8_t, history_session_bytes>, ConcurrentMemory>;

    // An entry an older import numbered by its line, and what it takes now.
    struct LegacyEntry {
      std::int64_t id;
      std::int64_t started_at_ms;
      std::int64_t sequence;
    };

    using LegacyEntries = ds::Vec<LegacyEntry, ConcurrentMemory>;

    // The sessions an import made: those whose id is the identity of the source they name.
    void findImportSessions(Database& database, ImportSessions& imports) {
      Statement sessions{database, "SELECT id, shell FROM session WHERE location_kind = 0 AND workspace_path = '' AND pane_id = location_id AND pane_id = tab_id"};

      while (sessions.next()) {
        const ImportIdentity identity{sessions.text(1)};
        if (std::ranges::equal(byteView(sessions.text(0)), identity.session)) {
          imports.push(identity.session);
        }
      }
    }

    // A session's entries below first_entry, in the file's order, each with the time and identity
    // an import gives it now: runs of one command at one time count up as an import counts them.
    void findLegacyEntries(Database& database, std::span<const std::uint8_t> session, ConcurrentMemory& memory, LegacyEntries& entries) {
      ds::Map<std::uint64_t, std::uint32_t, ConcurrentMemory> runs{memory};
      Statement old{database, "SELECT c.id, c.started_at_ms, t.text FROM command c JOIN command_text t ON t.id = c.text_id WHERE c.session_id = ?1 AND c.sequence < ?2 ORDER BY c.sequence"};

      old.bind(1, session);
      old.bind(2, ImportIdentity::first_entry);
      while (old.next()) {
        const auto started = old.integer(1);
        const auto key = ImportIdentity::hash(static_cast<std::uint64_t>(started), old.text(2));
        auto* count = runs.findMut(key);
        const auto run = count == nullptr ? 0 : (*count)++;

        if (count == nullptr) {
          runs.insert(key, 1);
        }

        entries.push({.id = old.integer(0), .started_at_ms = started + run, .sequence = ImportIdentity::entry(started + run, old.text(2))});
      }
    }

    // Imports before content identity numbered an entry by its line in the file, so lines a
    // trimmed file moved landed on taken numbers and were lost. Each such entry takes the
    // identity an import gives it now, once.
    void rekeyImports(Database& database, ConcurrentMemory& memory) {
      ImportSessions imports{memory};
      LegacyEntries entries{memory};

      findImportSessions(database, imports);
      for (const auto& session : imports) {
        entries.clear();
        findLegacyEntries(database, session, memory, entries);
        if (entries.empty()) {
          continue;
        }

        WriteScope scope{database};
        Statement update{database, "UPDATE OR IGNORE command SET started_at_ms = ?2, sequence = ?3 WHERE id = ?1"};

        for (const auto& entry : entries) {
          update.reset();
          update.bind(1, entry.id);
          update.bind(2, entry.started_at_ms);
          update.bind(3, entry.sequence);
          update.finish();
        }

        scope.commit();
      }
    }

    // What a rewrite does to one entry: removes it, or replaces its text or its output with the
    // redaction kept in the page's texts at (offset, size).
    struct RewriteChange {
      std::int64_t id = 0;
      bool remove = false;
      ds::Option<std::pair<std::size_t, std::size_t>> command;
      ds::Option<std::pair<std::size_t, std::size_t>> output;
      std::uint64_t observed = 0;
    };

    // The statements that write a rewrite's changes; the output's index when the history keeps one.
    struct RewriteWriters {
      Statement remove;
      Statement command;
      Statement output;
      ds::Option<Statement> unindex;
      ds::Option<Statement> index;
    };

    // What today's filters make of the entry `rows` stands on, and of its output, which `output`
    // reads; the redactions join `texts`.
    RewriteChange decideRewrite(const HistoryFilters& filters, const HistoryRedaction& redaction, const Statement& rows, Statement& output, ds::String<ConcurrentMemory>& texts) {
      const auto id = rows.integer(0);
      const auto text = rows.text(1);
      const auto room = redaction.command();
      const auto filtered = rows.integer(3) == static_cast<std::int64_t>(HistoryAuthor::agent) ? filters.filterAgent(text, rows.text(2), room) : filters.filterPane(text, rows.text(2), room);
      RewriteChange change{.id = id, .remove = filtered.verdict == HistoryVerdict::drop};

      if (change.remove) {
        return change;
      }

      if (filtered.verdict == HistoryVerdict::redact) {
        change.command = std::pair{texts.size(), filtered.text.size()};
        texts.append(filtered.text);
      }

      output.reset();
      output.bind(1, id);
      if (!output.next()) {
        return change;
      }

      const auto stored = output.text(0);
      const auto kept = filters.filterOutput(stored, redaction.output(), HistoryOutput::maximum_content_bytes);
      if (kept.data() == stored.data() && kept.size() == stored.size()) {
        return change;
      }

      const auto observed = static_cast<std::uint64_t>(std::max<std::int64_t>(0, output.integer(1)));

      change.output = std::pair{texts.size(), kept.size()};
      change.observed = observed - std::min<std::uint64_t>(observed, stored.size()) + kept.size();
      texts.append(kept);
      return change;
    }

    // Writes one change: a redacted text is a text of its own, which the run then points at.
    void applyRewrite(RewriteWriters& writers, HistoryTexts& known, const RewriteChange& change, std::string_view texts, ds::String<ConcurrentMemory>& plain) {
      if (change.remove) {
        writers.remove.reset();
        writers.remove.bind(1, change.id);
        writers.remove.finish();
        return;
      }

      if (change.command) {
        writers.command.reset();
        writers.command.bind(1, change.id);
        writers.command.bind(2, known.idOf(texts.substr(change.command->first, change.command->second)));
        writers.command.finish();
      }

      if (!change.output) {
        return;
      }

      const auto content = texts.substr(change.output->first, change.output->second);

      writers.output.reset();
      writers.output.bind(1, change.id);
      writers.output.bind(2, content);
      writers.output.bind(3, static_cast<std::int64_t>(std::min<std::uint64_t>(change.observed, std::numeric_limits<std::int64_t>::max())));
      writers.output.finish();
      if (writers.unindex && writers.index) {
        writers.unindex.getMut().reset();
        writers.unindex.getMut().bind(1, change.id);
        writers.unindex.getMut().finish();
        plainHistoryOutput(content, plain);
        writers.index.getMut().reset();
        writers.index.getMut().bind(1, change.id);
        writers.index.getMut().bind(2, plain.view());
        writers.index.getMut().finish();
      }
    }

    // What a page of a rewrite reads, gathers and writes, and what it counted.
    struct RewritePage {
      const HistoryFilters& filters;
      const HistoryRedaction& redaction;
      Statement& rows;
      Statement& output;
      RewriteWriters& writers;
      HistoryTexts& known;
      ds::String<ConcurrentMemory>& texts;
      ds::String<ConcurrentMemory>& plain;
      ds::Vec<RewriteChange, ConcurrentMemory>& changes;
      HistoryRewritten& result;
      bool dry_run;
    };

    // Decides each entry of the page `rows` reads, the last of whose ids lands in `after`,
    // finishes its statements, then counts and writes what it decided; how many it read.
    std::int64_t rewritePage(RewritePage& page, std::int64_t& after) {
      std::int64_t read = 0;

      page.changes.clear();
      page.texts.clear();
      while (page.rows.next()) {
        ++read;
        after = page.rows.integer(0);
        if (const auto change = decideRewrite(page.filters, page.redaction, page.rows, page.output, page.texts); change.remove || change.command || change.output) {
          page.changes.push(change);
        }
      }

      page.rows.reset();
      page.output.reset();
      for (const auto& change : page.changes) {
        ++(change.remove ? page.result.removed : page.result.redacted);
        if (!page.dry_run) {
          applyRewrite(page.writers, page.known, change, page.texts.view(), page.plain);
        }
      }

      return read;
    }

  }

  HistoryStore::HistoryStore(ConcurrentMemory& memory, const char* path, const HistoryFilters& filters)
      : memory_(memory),
        filters_(filters),
        redaction_(memory),
        path_(memory, path),
        keys_(memory),
        database_(path),
        log_(memory),
        feed_(memory),
        notices_(memory),
        rows_(memory),
        index_(memory, std::max(1U, std::thread::hardware_concurrency())),
        applying_(memory),
        match_scratch_(memory),
        plain_(memory) {
    ds::Array<char, max_history_host_bytes + 1> host{};

    // The machine's name, which a run recorded here carries.
    if (::gethostname(host.dataMut(), host.size() - 1) == 0) {
      host_.assign(utf8Prefix(std::string_view{host.data()}, max_history_host_bytes));
    }

    // Only what is quick: an older file that needs its rows rewritten waits for upgrade().
    migrateHistory(database_);
    if (historyCurrent(database_)) {
      indexed_ = enableHistoryIndex(database_);
      upgraded_.store(true, std::memory_order_release);
    }

    if (path_.view() != ":memory:") {
      reader_.emplace(path, DatabaseAccess::read_only);
      registerHistoryFunctions(reader_.getMut());
    }
  }

  HistoryStore::~HistoryStore() {
    try {
      flush();
    } catch (...) { // NOLINT(bugprone-empty-catch): a batch that cannot commit as the history closes is lost with the process, as it would be in a crash
    }
  }

  void HistoryStore::separateLanes() {
    lanes_ = true;
  }

  void HistoryStore::upgrade() {
    if (prepared_) {
      return;
    }

    const auto lock = readLock();

    if (!upgraded_.load(std::memory_order_acquire)) {
      upgradeHistory(database_, memory_);
      indexed_ = enableHistoryIndex(database_);
    }

    reap();
    // Once the history is current, the entries older imports numbered by their line take content
    // identity; the check is one lookup per import once none are left.
    rekeyImports(database_, memory_);
    database_.tryExecute("PRAGMA optimize=0x10002");
    prepared_ = true;
    upgraded_.store(true, std::memory_order_release);
  }

  bool HistoryStore::readable(std::uint64_t request_id, EncodedReply<ConcurrentMemory>& reply) {
    // One thread does everything: it upgrades the file itself.
    if (!lanes_) {
      upgrade();
      return true;
    }

    if (upgraded_.load(std::memory_order_acquire)) {
      return true;
    }

    reply.send(RequestFailed{.request_id = request_id, .code = FailureCode::resource_limit, .message = "History is upgrading"});
    return false;
  }

  HistoryWriteOptions HistoryStore::writeOptions() noexcept {
    return {.host = host_.view(), .store_failed = filters_.store_failed, .keys = &keys_, .memory = &memory_};
  }

  PaneHistoryWriter& HistoryStore::paneWriter() {
    if (!pane_writer_) {
      pane_writer_.emplace(database_, &log_, writeOptions());
    }

    return pane_writer_.getMut();
  }

  void HistoryStore::forgetTexts() noexcept {
    if (pane_writer_) {
      pane_writer_.getMut().forgetTexts();
    }

    if (agent_commands_) {
      agent_commands_.getMut().forgetTexts();
    }
  }

  std::unique_lock<std::mutex> HistoryStore::readLock() {
    if (lanes_ && !reader_) {
      return std::unique_lock{shared_connection_};
    }

    return {};
  }

  Database& HistoryStore::readerOf(ds::Option<Database>& reader, Database& writer) noexcept {
    return reader ? reader.getMut() : writer;
  }

  template <typename Write>
  void HistoryStore::write(Write&& body) {
    const auto lock = readLock();
    const auto mark = log_.mark();

    try {
      std::forward<Write>(body)();
    } catch (...) {
      log_.rewind(mark);
      throw;
    }

    if (!batch_open_) {
      publish();
    }
  }

  void HistoryStore::beginBatch() {
    database_.execute("BEGIN IMMEDIATE");
    batch_open_ = true;
    batch_count_ = 0;
    batch_started_ = std::chrono::steady_clock::now();
  }

  void HistoryStore::flush() {
    if (!batch_open_) {
      return;
    }

    const auto lock = readLock();

    batch_open_ = false;
    try {
      database_.execute("COMMIT");
    } catch (...) {
      database_.tryExecute("ROLLBACK");
      log_.clear();
      forgetTexts();
      throw;
    }

    publish();
  }

  void HistoryStore::publish() {
    if (log_.empty()) {
      return;
    }

    ds::Vec<HistoryIndexFeed::Change, ConcurrentMemory> changes{memory_};

    if (log_.manyChanged()) {
      changes.emplace(memory_).kind = HistoryIndexFeed::Kind::reload;
      notices_.add(HistoryChange::many, 0, 0);
      log_.clear();
      feed_.publish(changes);
      return;
    }

    if (!facts_) {
      ds::String<ConcurrentMemory> sql{memory_, facts_sql};

      sql.append(" WHERE c.id = ?1");
      facts_.emplace(database_, sql.view());
    }

    auto& facts = facts_.getMut();

    for (const auto& item : log_.items()) {
      auto& change = changes.emplace(memory_);

      switch (item.kind) {
      case HistoryChangeLog::Kind::ran:
        facts.reset();
        facts.bind(1, item.id);
        if (!facts.next()) {
          // Gone again before the batch committed.
          static_cast<void>(changes.pop());
          break;
        }

        change.kind = HistoryIndexFeed::Kind::upsert;
        change.keep(factsOf(facts));
        notices_.add(HistoryChange::recorded, item.id, item.pane);
        break;
      case HistoryChangeLog::Kind::removed:
        change.kind = HistoryIndexFeed::Kind::remove;
        change.run.id = item.id;
        notices_.add(HistoryChange::removed, item.id, 0);
        break;
      case HistoryChangeLog::Kind::removed_text:
        change.kind = HistoryIndexFeed::Kind::remove_text;
        change.run.id = item.id;
        change.run.text_id = item.value;
        if (item.id != 0) {
          notices_.add(HistoryChange::removed_command, item.id, 0);
        }

        break;
      case HistoryChangeLog::Kind::session:
        change.kind = HistoryIndexFeed::Kind::session;
        change.run.pane = item.pane;
        change.run.started_ms = item.value;
        break;
      case HistoryChangeLog::Kind::selected:
        change.kind = HistoryIndexFeed::Kind::select;
        change.run.text_id = item.value;
        break;
      }
    }

    facts.reset();
    log_.clear();
    feed_.publish(changes);
  }

  HistoryNotices::HistoryNotices(ConcurrentMemory& memory)
      : changes_(memory) {}

  void HistoryNotices::add(HistoryChange change, std::int64_t entry, std::uint64_t pane) {
    const std::scoped_lock lock{mutex_};

    ++revision_;
    if (changes_.size() >= maximum_changes || (!changes_.empty() && changes_.back().change == HistoryChange::many)) {
      changes_.clear();
      change = HistoryChange::many;
      entry = 0;
      pane = 0;
    }

    changes_.push({.revision = revision_, .change = change, .entry_id = static_cast<std::uint64_t>(std::max<std::int64_t>(0, entry)), .pane_id = pane});
  }

  void HistoryNotices::take(ds::Vec<HistoryChanged, ConcurrentMemory>& out) {
    out.clear();
    const std::scoped_lock lock{mutex_};

    std::swap(out, changes_);
  }

  void HistoryStore::takeChanges(ds::Vec<HistoryChanged, ConcurrentMemory>& out) {
    notices_.take(out);
  }

  void HistoryStore::reap() {
    // A run still running when the runtime that recorded it stopped never finishes: it was
    // interrupted, when its session ended or, unknown, as it started.
    database_.execute(R"sql(
UPDATE command SET status = 1, duration_ns = CAST(MIN(9223372036854, MAX(0, COALESCE(
  (SELECT s.finished_at_ms FROM session s WHERE s.id = command.session_id), command.started_at_ms) - command.started_at_ms)) AS INTEGER) * 1000000
WHERE status = 2
)sql");
  }

  void HistoryStore::reportAgentCommand(const ReportAgentCommand& request, const RequestContext& context, EncodedReply<ConcurrentMemory>& reply) {
    upgrade();

    // A redacted command is copied out of the room, which the next write fills again; only a
    // command that held a secret is copied.
    ds::String<ConcurrentMemory> redacted{memory_};

    {
      const auto command = keptAgentCommand(filters_, request.command, request.cwd, redaction_.command());
      if (!command) {
        reply.send(RequestCompleted{.request_id = request.request_id});
        return;
      }

      if (command->data() != request.command.data()) {
        redacted.assign(*command);
      }
    }

    auto kept = request;

    if (!redacted.empty()) {
      kept.command = redacted.view();
    }

    flush();
    if (!agent_commands_) {
      agent_commands_.emplace(database_, &log_, writeOptions());
    }

    write([&] {
      agent_commands_.getMut().persist(kept, context);
    });

    reply.send(RequestCompleted{.request_id = request.request_id});
  }

  void HistoryStore::record(const HistoryEventView& event) {
    upgrade();

    // What the filters keep of the command and its output, redacted where they say: a redaction
    // is copied out of its room, which the next write fills again, so only what held a secret is.
    ds::String<ConcurrentMemory> command{memory_};
    ds::Vec<Byte, ConcurrentMemory> output{memory_};
    bool command_redacted = false;
    bool output_redacted = false;
    auto written = event;

    {
      const auto kept = keptPaneEvent(filters_, event, redaction_.command(), redaction_.output());
      if (!kept) {
        return;
      }

      command_redacted = kept->command.command.data() != event.command.command.data();
      output_redacted = kept->command.output.data() != event.command.output.data();
      if (command_redacted) {
        command.assign(kept->command.command);
      }

      if (output_redacted) {
        output.extend(kept->command.output);
      }

      written.command.output_observed = kept->command.output_observed;
    }

    if (command_redacted) {
      written.command.command = command.view();
    }

    if (output_redacted) {
      written.command.output = output;
    }

    if (written.kind == HistoryEventKind::launch_failed) {
      flush();
      if (!launch_writer_) {
        launch_writer_.emplace(database_);
      }

      write([&] {
        launch_writer_.getMut().persist(written);
      });

      return;
    }

    auto& writer = paneWriter();

    // Gathered with the events after it into one transaction, which a few events, a few
    // milliseconds or an idle writer commit.
    if (lanes_ && !batch_open_) {
      const auto lock = readLock();

      beginBatch();
    }

    write([&] {
      writer.persist(written);
    });

    if (batch_open_ && (++batch_count_ >= batch_events || std::chrono::steady_clock::now() - batch_started_ >= batch_age)) {
      flush();
    }
  }

  bool HistoryStore::accepts(const HistoryEventView& event) const noexcept {
    const bool command = event.kind == HistoryEventKind::command_finished || event.kind == HistoryEventKind::command_started;

    return !command || filters_.recordsPane(event.command.command, event.command.directory);
  }

  void HistoryStore::importEntries(const ImportHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    upgrade();
    flush();
    write([&] {
      const ImportIdentity identity{request.source};
      WriteScope scope{database_};
      HistoryTexts texts{database_};
      Statement session{database_, "INSERT OR IGNORE INTO session(id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms) VALUES(?1, ?2, 0, ?2, ?2, '', ?3, ?4)"};

      session.bind(1, std::span{identity.session});
      session.bind(2, integer(identity.pane));
      session.bind(3, request.source);
      session.bind(4, request.entries.front().started_at_ms);
      session.finish();

      // An entry is known by what it ran and when, not by where the file holds it, so importing
      // a file again, grown or trimmed, adds only the runs it did not have; base_sequence numbers
      // nothing. Two runs of one command at one time differ by the milliseconds the importer adds
      // to the later ones, or, sent in one request, by their order in it. A line passes the
      // filters a recorded command passes, with the directory its source knew.
      Statement command{database_, "INSERT OR IGNORE INTO command(session_id, pane_id, location_kind, location_id, tab_id, sequence, text_id, cwd, workspace_path, started_at_ms, duration_ns, exit_code, status, author, origin, host, shell, cwd_key) VALUES(?1, ?2, 0, ?2, ?2, ?3, ?4, ?7, '', ?5, ?9, ?10, 0, 0, 0, ?6, '', ?8) RETURNING id"};
      ds::Map<std::uint64_t, std::uint32_t, ConcurrentMemory> runs{memory_};
      FixedText<PATH_MAX> key;

      for (const auto& entry : request.entries) {
        const auto hash = ImportIdentity::hash(static_cast<std::uint64_t>(entry.started_at_ms), entry.command);
        auto* count = runs.findMut(hash);
        const auto run = count == nullptr ? 0 : (*count)++;

        if (count == nullptr) {
          runs.insert(hash, 1);
        }

        const auto kept = keptImportedCommand(filters_, entry.command, entry.cwd, redaction_.command());
        if (!kept) {
          continue;
        }

        keys_.key(entry.cwd, key);
        command.reset();
        command.bind(import_command_parameter::session, std::span{identity.session});
        command.bind(import_command_parameter::pane, integer(identity.pane));
        command.bind(import_command_parameter::sequence, ImportIdentity::entry(entry.started_at_ms, entry.command, run));
        command.bind(import_command_parameter::text, texts.idOf(*kept));
        command.bind(import_command_parameter::started_at, entry.started_at_ms);
        command.bind(import_command_parameter::host, host_.view());
        command.bind(import_command_parameter::cwd, writtenDirectory(entry.cwd));
        command.bind(import_command_parameter::cwd_key, entry.cwd.empty() ? std::string_view{} : key.view());
        command.bind(import_command_parameter::duration, std::max<std::int64_t>(0, entry.duration_ns));
        if (entry.exit_code) {
          command.bind(import_command_parameter::exit_code, *entry.exit_code);
        } else {
          command.bindNull(import_command_parameter::exit_code);
        }

        if (command.next()) {
          log_.ran(command.integer(0), identity.pane);
        }
      }

      command.reset();
      scope.commit();
    });

    reply.send(RequestCompleted{.request_id = request.request_id});
  }

  void HistoryStore::remove(const DeleteHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    upgrade();
    const auto id = integer(request.id);
    std::int64_t removed = 0;

    flush();
    write([&] {
      Statement statement{database_, "DELETE FROM command WHERE id = ?1"};

      statement.bind(1, id);
      statement.finish();
      removed = database_.changes();
      if (removed != 0) {
        log_.removed(id);
      }
    });

    reply.send(HistoryPruned{.request_id = request.request_id, .removed = static_cast<std::uint64_t>(removed)});
  }

  void HistoryStore::removeCommand(const DeleteHistoryCommand& request, EncodedReply<ConcurrentMemory>& reply) {
    upgrade();
    const auto id = integer(request.id);
    std::int64_t removed = 0;

    flush();
    write([&] {
      WriteScope scope{database_};
      Statement text{database_, "SELECT text_id FROM command WHERE id = ?1"};

      text.bind(1, id);
      if (!text.next()) {
        scope.commit();
        return;
      }

      // The runs refer to the text, so deleting them all is one lookup of an index.
      const auto text_id = text.integer(0);
      Statement runs{database_, "DELETE FROM command WHERE text_id = ?1"};
      Statement drop{database_, "DELETE FROM command_text WHERE id = ?1"};

      runs.bind(1, text_id);
      runs.finish();
      removed = database_.changes();
      drop.bind(1, text_id);
      drop.finish();
      scope.commit();
      forgetTexts();
      log_.removedText(text_id, id);
    });

    reply.send(HistoryPruned{.request_id = request.request_id, .removed = static_cast<std::uint64_t>(removed)});
  }

  void HistoryStore::appendPruneFilters(ds::String<ConcurrentMemory>& sql, const RewriteHistory& request) {
    if (!request.match.empty()) {
      // Each text once, folded as the matcher folds: a substring of any length.
      sql.append(" AND c.text_id IN (SELECT id FROM command_text WHERE instr(telar_fold(text), telar_fold(?3)) > 0)");
    }

    if (request.failed_only) {
      sql.append(" AND c.exit_code IS NOT NULL AND c.exit_code <> 0 AND c.status = 0");
    }

    if (request.before_ms != 0) {
      sql.append(" AND c.started_at_ms < ?4");
    }

    appendScope(sql, request.scope);
    sql.append(" AND c.status != 2");
  }

  void HistoryStore::bindPruneFilters(Statement& statement, const RewriteHistory& request, DirectoryKeys& keys, FixedText<PATH_MAX>& key) {
    if (!request.match.empty()) {
      statement.bind(query_parameter::match, request.match);
    }

    if (request.before_ms != 0) {
      statement.bind(query_parameter::before, request.before_ms);
    }

    bindScope(statement, request.scope, request.scope_value, keys, key);
  }

  void HistoryStore::prune(const PruneHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    const RewriteHistory matched{.scope = request.scope, .scope_value = request.scope_value, .before_ms = request.before_ms, .failed_only = request.failed_only, .match = request.match};

    upgrade();
    std::int64_t removed = 0;

    flush();
    write([&] {
      auto filters = string(" WHERE 1=1");

      appendPruneFilters(filters, matched);
      // A dry run counts what the same selection would remove, so a preview is exactly the prune.
      auto sql = string(request.dry_run ? "SELECT COUNT(*) FROM command WHERE id IN (" : "DELETE FROM command WHERE id IN (");

      if (request.keep_runs != 0) {
        // The newest keep_runs runs of each command in each directory on each machine stay.
        sql.append("SELECT id FROM (SELECT c.id, ROW_NUMBER() OVER (PARTITION BY c.text_id, c.cwd_key, c.host ORDER BY c.started_at_ms DESC, c.id DESC) AS kept FROM command c");
        sql.append(filters.view());
        sql.append(") WHERE kept > ?7)");
      } else {
        sql.append("SELECT c.id FROM command c");
        sql.append(filters.view());
        sql.append(")");
      }

      Statement statement{database_, sql};

      bindPruneFilters(statement, matched, keys_, scope_key_);
      if (request.keep_runs != 0) {
        statement.bind(query_parameter::keep, std::int64_t{request.keep_runs});
      }

      if (request.dry_run) {
        removed = statement.next() ? statement.integer(0) : 0;
        statement.reset();
        return;
      }

      statement.finish();
      removed = database_.changes();
      if (removed != 0) {
        log_.many();
      }
    });

    reply.send(HistoryPruned{.request_id = request.request_id, .removed = static_cast<std::uint64_t>(removed)});
  }

  void HistoryStore::rewrite(const RewriteHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    constexpr std::int64_t page_rows = 256;
    HistoryRewritten result{.request_id = request.request_id};

    upgrade();
    flush();
    write([&] {
      auto sql = string("SELECT c.id, t.text, c.cwd, c.author FROM command c JOIN command_text t ON t.id = c.text_id WHERE c.id > ?1");

      appendPruneFilters(sql, request);
      sql.append(" ORDER BY c.id LIMIT ?8");
      WriteScope scope{database_};
      HistoryTexts known{database_};
      Statement rows{database_, sql};
      Statement output{database_, "SELECT content, observed_bytes FROM command_output WHERE command_id = ?1"};
      Statement output_index{database_, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'command_output_fts'"};
      const bool indexed = output_index.next();
      ds::String<ConcurrentMemory> plain{memory_};

      output_index.reset();
      RewriteWriters writers{
          .remove = Statement{database_, "DELETE FROM command WHERE id = ?1"},
          .command = Statement{database_, "UPDATE command SET text_id = ?2 WHERE id = ?1"},
          .output = Statement{database_, "UPDATE command_output SET content = ?2, observed_bytes = ?3 WHERE command_id = ?1"},
          .unindex = indexed ? ds::Option<Statement>{std::in_place, database_, "DELETE FROM command_output_fts WHERE rowid = ?1"} : ds::none,
          .index = indexed ? ds::Option<Statement>{std::in_place, database_, "INSERT INTO command_output_fts(rowid, content) VALUES (?1, ?2)"} : ds::none,
      };

      ds::Vec<RewriteChange, ConcurrentMemory> changes{memory_};
      ds::String<ConcurrentMemory> texts{memory_};
      RewritePage page{.filters = filters_, .redaction = redaction_, .rows = rows, .output = output, .writers = writers, .known = known, .texts = texts, .plain = plain, .changes = changes, .result = result, .dry_run = request.dry_run};
      std::int64_t after = 0;

      // A page of entries past the last one read is decided, its statements finished, then written.
      for (std::int64_t read = page_rows; read == page_rows;) {
        page.rows.reset();
        page.rows.bind(rewrite_parameter::after, after);
        bindPruneFilters(page.rows, request, keys_, scope_key_);
        page.rows.bind(rewrite_parameter::limit, page_rows);
        read = rewritePage(page, after);
      }

      if (request.dry_run || result.removed + result.redacted == 0) {
        return;
      }

      // The texts no run points at any more go, and the index loads again.
      Statement orphans{database_, "DELETE FROM command_text WHERE NOT EXISTS (SELECT 1 FROM command WHERE command.text_id = command_text.id)"};

      orphans.finish();
      scope.commit();
      forgetTexts();
      log_.many();
    });

    reply.send(result);
  }

  void HistoryStore::choose(const ChooseHistoryEntry& request, EncodedReply<ConcurrentMemory>& reply) {
    upgrade();
    flush();

    auto& writer = paneWriter();
    const auto lock = readLock();
    Statement entry{database_, "SELECT text_id, cwd_key FROM command WHERE id = ?1"};

    entry.bind(1, integer(request.id));
    if (entry.next()) {
      writer.choose(request.pane_id, entry.integer(0), entry.text(1), wallMilliseconds());
    }

    reply.send(RequestCompleted{.request_id = request.request_id});
  }

  void HistoryStore::maintain(std::int64_t now_ms) {
    upgrade();
    constexpr std::int64_t interval_ms = std::int64_t{10} * 60 * 1000;

    flush();
    checkpoint();
    if (maintained_ms_ != 0 && now_ms - maintained_ms_ < interval_ms) {
      return;
    }

    maintained_ms_ = now_ms;
    retain(now_ms);

    const auto lock = readLock();

    // The texts no run refers to any more, and the indexed outputs of runs that went.
    {
      Statement orphans{database_, "DELETE FROM command_text WHERE NOT EXISTS (SELECT 1 FROM command c WHERE c.text_id = command_text.id) RETURNING id"};
      ds::Vec<HistoryIndexFeed::Change, ConcurrentMemory> changes{memory_};

      while (orphans.next()) {
        auto& change = changes.emplace(memory_);

        change.kind = HistoryIndexFeed::Kind::remove_text;
        change.run.text_id = orphans.integer(0);
      }

      if (!changes.empty()) {
        forgetTexts();
        feed_.publish(changes);
      }
    }

    database_.tryExecute("DELETE FROM command_output_fts WHERE rowid NOT IN (SELECT command_id FROM command_output)");
    convertVacuum();
    database_.tryExecute("PRAGMA incremental_vacuum(4096)");
    database_.tryExecute("PRAGMA optimize");
  }

  void HistoryStore::convertVacuum() {
    constexpr std::int64_t free_share = 4;

    if (vacuum_checked_) {
      return;
    }

    vacuum_checked_ = true;
    const auto pragma = [&](const char* sql) {
      Statement read{database_, sql};

      return read.next() ? read.integer(0) : 0;
    };

    // A file migrated from an older history, or one made before incremental vacuum, frees no
    // page it holds: converted once, while the writer idles rather than as the runtime starts,
    // and only when enough of it is free to be worth rewriting it whole.
    if (pragma("PRAGMA auto_vacuum") != 0 || pragma("PRAGMA freelist_count") * free_share < pragma("PRAGMA page_count")) {
      return;
    }

    database_.tryExecute("PRAGMA auto_vacuum = INCREMENTAL; VACUUM;");
  }

  void HistoryStore::retain(std::int64_t now_ms) {
    constexpr std::int64_t chunk = 10'000;
    const auto& kept = filters_.retention;

    const auto remove_oldest = [&](const char* sql, std::int64_t bound) {
      write([&] {
        Statement statement{database_, sql};

        statement.bind(1, bound);
        while (statement.next()) {
          log_.removed(statement.integer(0));
        }
      });
    };

    if (kept.max_age_days != 0) {
      remove_oldest("DELETE FROM command WHERE id IN (SELECT id FROM command WHERE started_at_ms < ?1 AND status != 2 ORDER BY started_at_ms LIMIT 10000) RETURNING id", now_ms - (std::int64_t{kept.max_age_days} * milliseconds_per_day));
    }

    if (kept.max_rows != 0) {
      std::int64_t rows = 0;

      {
        const auto lock = readLock();
        Statement count{database_, "SELECT COUNT(*) FROM command"};

        checkRow(count);
        rows = count.integer(0);
      }

      // A little past the bound before anything goes, so a history at its bound does not
      // delete a run for each one it records.
      const auto bound = static_cast<std::int64_t>(std::min<std::uint64_t>(kept.max_rows, std::numeric_limits<std::int64_t>::max() / 2));
      constexpr std::int64_t slack = 100;

      if (rows > bound + std::max<std::int64_t>(1, bound / slack)) {
        remove_oldest("DELETE FROM command WHERE id IN (SELECT id FROM command WHERE status != 2 ORDER BY started_at_ms, id LIMIT ?1) RETURNING id", std::min(chunk, rows - bound));
      }
    }

    if (kept.keep_runs != 0) {
      keepNewestRuns(kept.keep_runs);
    }

    if (kept.max_output_bytes != 0) {
      const auto lock = readLock();
      Statement total{database_, "SELECT COALESCE(SUM(length(CAST(content AS BLOB))), 0) FROM command_output"};

      checkRow(total);
      auto bytes = total.integer(0);
      const auto bound = static_cast<std::int64_t>(std::min<std::uint64_t>(kept.max_output_bytes, std::numeric_limits<std::int64_t>::max()));
      Statement oldest{database_, "DELETE FROM command_output WHERE command_id IN (SELECT command_id FROM command_output ORDER BY command_id LIMIT 1000) RETURNING length(CAST(content AS BLOB))"};

      // The oldest outputs go a thousand at a time, a few times at most for each maintenance.
      constexpr int rounds = 8;

      for (int round = 0; round < rounds && bytes > bound; ++round) {
        oldest.reset();
        while (oldest.next()) {
          bytes -= oldest.integer(0);
        }
      }
    }
  }

  // Only the newest `keep` runs of each command in each directory on each machine stay, as a
  // prune with keep_runs keeps them. Only a command run since the last pass can hold one too
  // many, so a pass reads those commands alone, through their index; a running run does not
  // count until it ends, so the mark stays before it.
  void HistoryStore::keepNewestRuns(std::uint32_t keep) {
    constexpr std::int64_t chunk = 10'000;

    if (keep != deduplicated_keep_) {
      deduplicated_keep_ = keep;
      deduplicated_id_ = 0;
    }

    std::int64_t removed = 0;
    std::int64_t newest = 0;

    write([&] {
      Statement mark{database_, "SELECT COALESCE((SELECT MIN(id) - 1 FROM command WHERE id > ?1 AND status = 2), (SELECT MAX(id) FROM command), 0)"};

      mark.bind(1, deduplicated_id_);
      checkRow(mark);
      newest = mark.integer(0);

      Statement statement{database_, "DELETE FROM command WHERE id IN (SELECT id FROM (SELECT c.id, ROW_NUMBER() OVER (PARTITION BY c.text_id, c.cwd_key, c.host ORDER BY c.started_at_ms DESC, c.id DESC) AS kept FROM command c WHERE c.status != 2 AND c.text_id IN (SELECT text_id FROM command WHERE id > ?2)) WHERE kept > ?1 LIMIT ?3) RETURNING id"};

      statement.bind(1, std::int64_t{keep});
      statement.bind(2, deduplicated_id_);
      statement.bind(3, chunk);
      while (statement.next()) {
        log_.removed(statement.integer(0));
        ++removed;
      }
    });

    // A pass that stopped at its chunk reads the same commands again at the next one.
    if (removed < chunk) {
      deduplicated_id_ = newest;
    }
  }

  void HistoryStore::checkpoint() noexcept {
    constexpr off_t wal_bound = off_t{32} * 1024 * 1024;

    if (path_.view() == ":memory:") {
      return;
    }

    ds::Array<char, PATH_MAX> wal{};
    const auto name = path_.view();
    constexpr std::string_view suffix = "-wal";
    if (name.size() + suffix.size() >= wal.size()) {
      return;
    }

    std::ranges::copy(suffix, std::ranges::copy(name, wal.dataMut()).out);
    const auto size = [&] {
      struct stat state{};

      return ::stat(wal.data(), &state) == 0 ? state.st_size : off_t{0};
    };

    // As atuin does: a checkpoint that waits for nobody, then one that restarts the log.
    if (size() > wal_bound) {
      const auto lock = readLock();

      database_.tryExecute("PRAGMA wal_checkpoint(PASSIVE)");
      if (size() > wal_bound) {
        database_.tryExecute("PRAGMA wal_checkpoint(RESTART)");
      }
    }
  }

  void HistoryStore::apply() {
    applyChanges(feed_, applying_, index_);
  }

  void HistoryStore::applyChanges(HistoryIndexFeed& feed, ds::Vec<HistoryIndexFeed::Change, ConcurrentMemory>& applying, HistoryIndex& index) {
    feed.drain(applying);
    for (const auto& change : applying.view()) {
      switch (change.kind) {
      case HistoryIndexFeed::Kind::upsert:
        index.upsert(change.facts());
        break;
      case HistoryIndexFeed::Kind::remove:
        index.remove(change.run.id);
        break;
      case HistoryIndexFeed::Kind::remove_text:
        index.removeText(change.run.text_id);
        break;
      case HistoryIndexFeed::Kind::session:
        index.session(change.run.pane, change.run.started_ms);
        break;
      case HistoryIndexFeed::Kind::select:
        index.select(change.run.text_id);
        break;
      case HistoryIndexFeed::Kind::reload:
        index.reset();
        break;
      }
    }

    applying.clear();
  }

  bool HistoryStore::loadIndex(std::size_t pages) {
    if (index_.complete() || index_.overflowed()) {
      return index_.complete();
    }

    auto& database = readerOf(reader_, database_);

    if (index_.loadedThrough() == 0) {
      Statement sessions{database, "SELECT pane_id, MIN(started_at_ms) FROM session GROUP BY pane_id"};

      while (sessions.next()) {
        index_.session(static_cast<std::uint64_t>(std::max<std::int64_t>(0, sessions.integer(0))), sessions.integer(1));
      }
    }

    ds::String<ConcurrentMemory> sql{memory_, facts_sql};

    sql.append(" WHERE c.id > ?1 ORDER BY c.id LIMIT ?2");
    Statement page{database, sql.view()};

    for (std::size_t loaded = 0; pages == 0 || loaded < pages; ++loaded) {
      page.reset();
      page.bind(1, index_.loadedThrough());
      page.bind(2, static_cast<std::int64_t>(index_page_rows));
      std::size_t rows = 0;

      while (page.next()) {
        ++rows;
        if (!index_.load(factsOf(page))) {
          return false;
        }
      }

      // What the writer committed while this page was read applies to the runs it holds.
      applyChanges(feed_, applying_, index_);
      if (rows < index_page_rows) {
        index_.loaded();
        return true;
      }
    }

    return false;
  }

  void HistoryStore::warm() {
    if (!upgraded_.load(std::memory_order_acquire)) {
      return;
    }

    const auto lock = readLock();

    apply();
    loadIndex(0);
  }

  std::int64_t HistoryStore::newestId() {
    Statement boundary{readerOf(reader_, database_), "SELECT COALESCE(MAX(id), 0) FROM command", Preparation::kept};

    checkRow(boundary);
    return boundary.integer(0);
  }

  void HistoryStore::query(QueryHistory request, EncodedReply<ConcurrentMemory>& reply, const std::atomic<bool>* cancelled) {
    TELAR_TRACE("history.query");
    if (!readable(request.request_id, reply)) {
      return;
    }

    const auto lock = readLock();

    rows_.clear();
    apply();
    if (!match_scratch_) {
      match_scratch_.emplace(memory_);
    }

    if (request.snapshot_id == 0) {
      request.snapshot_id = static_cast<std::uint64_t>(newestId());
    }

    if (request.entry_id != 0 || request.output) {
      if (request.output && request.entry_id == 0) {
        queryOutput(request, reply);
        return;
      }

      // The browser pastes the row it selected, whatever the other fields of the query say.
      ds::String<ConcurrentMemory> sql{memory_, "SELECT "};

      sql.append(HistoryRows::entry_columns);
      sql.append(" FROM command c JOIN command_text t ON t.id = c.text_id WHERE c.id = ?1");
      Statement statement{readerOf(reader_, database_), sql.view(), Preparation::kept};

      statement.bind(1, integer(request.entry_id));
      if (statement.next()) {
        rows_.append(statement);
      }

      reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .entries = rows_.entries()});
      return;
    }

    const HistoryMatcher matcher{memory_, request.match, request.query};

    loadIndex(0);
    if (index_.complete()) {
      queryIndex(request, matcher, reply, cancelled);
      return;
    }

    try {
      const InterruptScope interrupt{readerOf(reader_, database_), cancelled};

      querySql(request, matcher, reply);
    } catch (const RequestError&) {
      if (!cancelledBy(cancelled)) {
        throw;
      }

      rows_.clear();
      superseded(request, reply);
    }
  }

  HistoryIndexQuery HistoryStore::indexQuery(const QueryHistory& request, const HistoryMatcher& matcher, const std::atomic<bool>* cancelled) {
    return {
        .matcher = &matcher,
        .snapshot = integer(request.snapshot_id),
        .since_ms = request.since_ms,
        .until_ms = request.until_ms,
        .min_duration_ms = static_cast<std::int64_t>(std::min<std::uint64_t>(request.min_duration_ms, std::numeric_limits<std::uint32_t>::max())),
        .origin_pane = request.origin_pane,
        .now_ms = wallMilliseconds(),
        .after_started_ms = request.after_started_ms,
        .after_id = integer(request.after_id),
        .cancelled = cancelled,
        .host = request.host,
        .branch = request.branch,
        .shell = request.shell,
        .offset = request.offset,
        .exit_code = request.exit_code,
        .limit = request.limit,
        .distinct = request.distinct,
        .by_rank = ranked(request),
        .failed_only = request.failed_only,
        .author = request.author,
        .scope = request.scope,
        .preload = request.preload,
        .neighbours = request.neighbours,
    };
  }

  void HistoryStore::detailSql(ds::String<ConcurrentMemory>& sql) {
    // The details of up to detail_batch runs at once, in the order the page lists them.
    sql.append("SELECT ");
    sql.append(HistoryRows::entry_columns);
    sql.append(" FROM command c JOIN command_text t ON t.id = c.text_id WHERE c.id IN (");
    for (std::size_t parameter = 1; parameter <= detail_batch; ++parameter) {
      ds::formatTo(sql, "{}?{}", parameter == 1 ? "" : ",", parameter);
    }

    sql.append(") ORDER BY CASE c.id");
    for (std::size_t parameter = 1; parameter <= detail_batch; ++parameter) {
      ds::formatTo(sql, " WHEN ?{0} THEN {0}", parameter);
    }

    sql.append(" END");
  }

  void HistoryStore::queryIndex(const QueryHistory& request, const HistoryMatcher& matcher, EncodedReply<ConcurrentMemory>& reply, const std::atomic<bool>* cancelled) {
    auto query = indexQuery(request, matcher, cancelled);

    if (request.scope == HistoryScope::cwd || request.scope == HistoryScope::workspace) {
      // Matched by its key, however the query wrote it.
      keys_.key(std::get<std::string_view>(request.scope_value), scope_key_);
      query.scope_key = scope_key_.view();
    } else if (request.scope == HistoryScope::pane) {
      query.scope_pane = std::get<std::uint64_t>(request.scope_value);
    }

    if (!request.origin_cwd.empty()) {
      keys_.key(request.origin_cwd, origin_key_);
      query.origin_cwd_key = origin_key_.view();
    }

    const auto page = index_.query(query);
    if (page.cancelled) {
      superseded(request, reply);
      return;
    }

    if (!detail_) {
      ds::String<ConcurrentMemory> sql{memory_};

      detailSql(sql);
      detail_.emplace(readerOf(reader_, database_), sql.view());
    }

    auto& detail = detail_.getMut();
    ds::Array<HistoryRange, max_history_match_ranges> ranges{};
    bool more = page.more;
    bool full = false;

    for (std::size_t first = 0; first < page.hits.size() && !full; first += detail_batch) {
      const auto chunk = page.hits.subspan(first, std::min(detail_batch, page.hits.size() - first));
      std::size_t next = 0;

      detail.reset();
      for (std::size_t index = 0; index < chunk.size(); ++index) {
        detail.bind(static_cast<int>(index + 1), chunk[index].id);
      }

      // A run deleted since the index read it has no row: the hits before the row's are skipped.
      while (detail.next()) {
        const auto id = detail.integer(0);

        while (next < chunk.size() && chunk[next].id != id) {
          ++next;
        }

        if (next == chunk.size()) {
          break;
        }

        const auto& hit = chunk[next++];
        const auto count = hit.neighbour ? 0 : matcher.ranges(index_.text(hit.text), ranges.viewMut(), match_scratch_.getMut());

        if (!rows_.append(detail, {.run_count = hit.run_count, .last_exit = hit.last_exit, .ranges = ranges.view().first(count), .neighbour = hit.neighbour})) {
          full = true;
          more = true;
          break;
        }
      }
    }

    detail.reset();
    reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .has_more = more, .entries = rows_.entries()});
  }

  bool HistoryStore::listSqlByTime(const QueryHistory& request, const HistoryMatcher& matcher, Statement& statement, HistoryRows& rows, HistoryMatchWork& scratch, ConcurrentMemory& memory) { // NOLINT(readability-function-size): the store's parts it lends the scan, each borrowed apart
    HashSet seen{memory};
    ds::Array<HistoryRange, max_history_match_ranges> ranges{};
    const std::uint32_t skip = request.after_id != 0 ? 0 : request.offset;
    std::uint32_t skipped = 0;

    while (statement.next()) {
      const auto original = statement.text(6);
      const HistoryText text{.original = original, .folded = original};
      const bool repeated = request.distinct && seen.contains(static_cast<std::uint64_t>(statement.integer(text_id_column)));
      if (repeated || !matcher.score(text, scratch)) {
        continue;
      }

      if (request.distinct) {
        seen.insert(static_cast<std::uint64_t>(statement.integer(text_id_column)), true);
      }

      if (beforeCursor(request, statement)) {
        continue;
      }

      if (skipped < skip) {
        ++skipped;
        continue;
      }

      const auto count = matcher.ranges(text, ranges.viewMut(), scratch);

      if (rows.entries().size() == request.limit || !rows.append(statement, {.ranges = ranges.view().first(count)})) {
        return true;
      }
    }

    return false;
  }

  bool HistoryStore::rankSql(const QueryHistory& request, const HistoryMatcher& matcher, Statement& statement, ds::Vec<RankedEntry, ConcurrentMemory>& ranked, HistoryMatchWork& scratch, ConcurrentMemory& memory) { // NOLINT(readability-function-size): the store's parts it lends the scan, each borrowed apart
    HashSet seen{memory};
    std::uint32_t order = 0;

    while (statement.next()) {
      const auto original = statement.text(6);
      const auto score = matcher.score({.original = original, .folded = original}, scratch);
      if (!score || (request.distinct && !seen.insert(static_cast<std::uint64_t>(statement.integer(text_id_column)), true))) {
        continue;
      }

      // Past the cap there are commands the search did not read.
      if (ranked.size() == maximum_fuzzy_candidates) {
        return true;
      }

      ranked.push(RankedEntry{.id = statement.integer(0), .score = *score, .order = order++});
    }

    return false;
  }

  void HistoryStore::sqlOf(const QueryHistory& request, ds::String<ConcurrentMemory>& sql) const {
    // The snapshot is +id, so SQLite walks the start time's index and stops at the page instead
    // of reading the whole range of ids and sorting it.
    sql.append("SELECT ");
    sql.append(HistoryRows::entry_columns);
    if (request.output) {
      sql.append(", o.content FROM command c JOIN command_text t ON t.id = c.text_id JOIN command_output o ON o.command_id = c.id WHERE +c.id <= ?1");
      if (!request.query.empty() && useIndex(request.query)) {
        sql.append(" AND c.id IN (SELECT rowid FROM command_output_fts WHERE command_output_fts MATCH ?3)");
      } else if (!request.query.empty()) {
        sql.append(" AND instr(telar_fold(o.content), telar_fold(?3)) > 0");
      }
    } else {
      sql.append(" FROM command c JOIN command_text t ON t.id = c.text_id WHERE +c.id <= ?1");
    }

    appendFilters(sql, request);
    if (paged(request)) {
      sql.append(" AND (c.started_at_ms < ?16 OR (c.started_at_ms = ?16 AND c.id < ?17))");
    }

    sql.append(" ORDER BY c.started_at_ms DESC, c.id DESC");
  }

  bool HistoryStore::paged(const QueryHistory& request) noexcept {
    // A list of each command once reads the runs before the cursor too: see beforeCursor.
    return request.after_id != 0 && !request.distinct && (request.output || !ranked(request));
  }

  void HistoryStore::bindQuery(Statement& statement, const QueryHistory& request, bool indexed, DirectoryKeys& keys, FixedText<PATH_MAX>& key) {
    statement.bind(query_parameter::snapshot, integer(request.snapshot_id));
    if (request.output && indexed) {
      bindPhrase(statement, request.query);
    } else if (request.output && !request.query.empty()) {
      statement.bind(query_parameter::match, request.query);
    }

    bindFilters(statement, request, keys, key);
    if (paged(request)) {
      statement.bind(query_parameter::after_started, request.after_started_ms);
      statement.bind(query_parameter::after_id, integer(request.after_id));
    }
  }

  void HistoryStore::plan(QueryHistory request, ds::String<ConcurrentMemory>& out) {
    const auto lock = readLock();
    auto sql = string("EXPLAIN QUERY PLAN ");

    if (request.snapshot_id == 0) {
      request.snapshot_id = static_cast<std::uint64_t>(newestId());
    }

    sqlOf(request, sql);
    Statement statement{readerOf(reader_, database_), sql};
    const bool indexed = !request.query.empty() && useIndex(request.query);

    bindQuery(statement, request, indexed, keys_, scope_key_);
    out.clear();
    while (statement.next()) {
      constexpr int detail_column = 3;

      out.append(statement.text(detail_column));
      out.push('\n');
    }
  }

  void HistoryStore::querySql(const QueryHistory& request, const HistoryMatcher& matcher, EncodedReply<ConcurrentMemory>& reply) {
    // The runs newest first, matched as they are read: what answers while the index loads, and
    // once a history grew past the index's bounds.
    auto sql = string("");

    sqlOf(request, sql);
    const bool by_rank = ranked(request);
    Statement statement{readerOf(reader_, database_), sql, Preparation::kept};

    bindQuery(statement, request, false, keys_, scope_key_);

    if (!by_rank) {
      const auto more = listSqlByTime(request, matcher, statement, rows_, match_scratch_.getMut(), memory_);

      reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .has_more = more, .entries = rows_.entries()});
      return;
    }

    ds::Vec<RankedEntry, ConcurrentMemory> ranked_entries{memory_};
    ds::Array<HistoryRange, max_history_match_ranges> ranges{};
    const bool capped = rankSql(request, matcher, statement, ranked_entries, match_scratch_.getMut(), memory_);

    const auto precedes = [](const RankedEntry& left, const RankedEntry& right) {
      return left.score == right.score ? left.order < right.order : left.score > right.score;
    };

    const auto end = std::min(std::uint64_t{request.offset} + request.limit, static_cast<std::uint64_t>(ranked_entries.size()));
    auto ranking = ranked_entries.viewMut();

    std::ranges::partial_sort(ranking, ranking.begin() + static_cast<std::ptrdiff_t>(end), precedes);
    sql.assign("SELECT ");
    sql.append(HistoryRows::entry_columns);
    sql.append(" FROM command c JOIN command_text t ON t.id = c.text_id WHERE c.id = ?1");
    Statement detail{readerOf(reader_, database_), sql, Preparation::kept};
    const auto start = std::min<std::size_t>(request.offset, ranked_entries.size());

    for (std::size_t index = start; index < end; ++index) {
      detail.reset();
      detail.bind(1, ranked_entries[index].id);
      checkRow(detail);
      const auto original = detail.text(6);
      const auto count = matcher.ranges({.original = original, .folded = original}, ranges.viewMut(), match_scratch_.getMut());

      if (!rows_.append(detail, {.ranges = ranges.view().first(count)})) {
        break;
      }
    }

    // Past the cap there are commands the search did not read.
    reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .has_more = capped || start + rows_.entries().size() < ranked_entries.size(), .entries = rows_.entries()});
  }

  HistoryStore::Excerpt HistoryStore::excerptOf(const HistoryMatcher& matcher, std::string_view plain, HistoryMatchWork& scratch) {
    constexpr std::size_t excerpt_before = 120;
    ds::Array<HistoryRange, 1> first{};
    const bool matched = matcher.ranges({.original = plain, .folded = plain}, first.viewMut(), scratch) == 1;
    const auto found = first[0];
    const auto from = matched && found.start > excerpt_before ? found.start - excerpt_before : 0;
    Excerpt excerpt{.text = slice(plain, from, max_history_excerpt_bytes)};
    const auto offset = static_cast<std::uint32_t>(excerpt.text.data() - plain.data());

    if (matched && found.start >= offset && found.start < offset + excerpt.text.size()) {
      excerpt.ranges.atMut(0) = {.start = found.start - offset, .end = static_cast<std::uint32_t>(std::min<std::size_t>(found.end - offset, excerpt.text.size()))};
      excerpt.count = excerpt.ranges[0].end > excerpt.ranges[0].start ? 1 : 0;
    }

    return excerpt;
  }

  void HistoryStore::queryOutput(const QueryHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    // The runs whose captured output holds the query, newest first, each with a piece of its
    // output around the match: a substring, whatever the mode, as the output is not a command.
    auto sql = string("");

    sqlOf(request, sql);
    Statement statement{readerOf(reader_, database_), sql, Preparation::kept};
    const bool indexed = !request.query.empty() && useIndex(request.query);

    bindQuery(statement, request, indexed, keys_, scope_key_);

    const HistoryMatcher matcher{memory_, HistoryMatch::substring, request.query};
    HashSet seen{memory_};
    const std::uint32_t skip = request.after_id != 0 ? 0 : request.offset;
    std::uint32_t skipped = 0;
    bool more = false;

    while (statement.next()) {
      if ((request.distinct && !seen.insert(static_cast<std::uint64_t>(statement.integer(text_id_column)), true)) || beforeCursor(request, statement)) {
        continue;
      }

      if (skipped < skip) {
        ++skipped;
        continue;
      }

      if (rows_.entries().size() == request.limit) {
        more = true;
        break;
      }

      plainHistoryOutput(statement.text(content_column), plain_);
      const auto excerpt = excerptOf(matcher, plain_.view(), match_scratch_.getMut());

      if (!rows_.append(statement, {.excerpt = excerpt.text, .excerpt_ranges = excerpt.ranges.view().first(excerpt.count)})) {
        more = true;
        break;
      }
    }

    reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .has_more = more, .entries = rows_.entries()});
  }

  void HistoryStore::readOutput(const ReadHistoryOutput& request, EncodedReply<ConcurrentMemory>& reply) {
    // An older file's outputs may still hold the marks its upgrade strips.
    if (!readable(request.request_id, reply)) {
      return;
    }

    const auto lock = readLock();
    Statement statement{readerOf(reader_, database_), "SELECT content, truncated, observed_bytes FROM command_output WHERE command_id = ?1", Preparation::kept};

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
    const auto lock = readLock();

    rows_.clear();
    // The paths that name no directory are left out here, not counted against the limit.
    Statement recorded{readerOf(reader_, database_), "SELECT DISTINCT workspace_path FROM session WHERE workspace_path != '' AND length(CAST(workspace_path AS BLOB)) < ?2 AND instr(workspace_path, char(0)) = 0 LIMIT ?1", Preparation::kept};

    // One more than a reply lists, to tell a full reply from a truncated one.
    recorded.bind(1, static_cast<std::int64_t>(HistoryWorkspaces::maximum_paths) + 1);
    recorded.bind(2, static_cast<std::int64_t>(max_path_bytes));
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
    if (!readable(request.request_id, reply)) {
      return;
    }

    const auto lock = readLock();

    rows_.clear();
    apply();
    loadIndex(0);
    if (!index_.complete()) {
      statsSql(request, reply);
      return;
    }

    HistoryIndexStatsQuery query{.scope = request.scope, .since_ms = request.since_ms};

    if (request.scope == HistoryScope::cwd || request.scope == HistoryScope::workspace) {
      keys_.key(std::get<std::string_view>(request.scope_value), scope_key_);
      query.scope_key = scope_key_.view();
    } else if (request.scope == HistoryScope::pane) {
      query.pane = std::get<std::uint64_t>(request.scope_value);
    }

    const auto counted = index_.stats(query);
    ds::Array<HistoryStatsEntry, maximum_stats_results> top;
    const auto count = std::min(counted.top.size(), maximum_stats_results);

    for (std::size_t index = 0; index < count; ++index) {
      top.atMut(index) = {.count = counted.top[index].count, .command = rows_.copy(counted.top[index].group)};
    }

    reply.send(HistoryStatsResult{.request_id = request.request_id, .total = counted.total, .unique = counted.unique, .top = std::span{top}.first(count)});
  }

  void HistoryStore::statsSql(const HistoryStatsQuery& request, EncodedReply<ConcurrentMemory>& reply) {
    // Every command counts toward its group, not only the most frequent: a group spread over
    // many variants, as `git commit -m ...` is, has all its runs.
    auto sql = string("SELECT t.text, COUNT(*) FROM command c JOIN command_text t ON t.id = c.text_id WHERE 1=1");

    appendScope(sql, request.scope);
    if (request.since_ms != 0) {
      sql.append(" AND c.started_at_ms >= ?10");
    }

    sql.append(" GROUP BY c.text_id");
    Statement groups{readerOf(reader_, database_), sql, Preparation::kept};

    bindScope(groups, request.scope, request.scope_value, keys_, scope_key_);
    if (request.since_ms != 0) {
      groups.bind(query_parameter::since, request.since_ms);
    }

    // A command longer than a stats entry carries, a 16-bit length, groups under what of it fits.
    constexpr std::size_t entry_command_bytes = std::numeric_limits<std::uint16_t>::max();
    ds::Map<ds::String<ConcurrentMemory>, std::uint64_t, ConcurrentMemory> counts{memory_};
    HistoryStatsResult result{.request_id = request.request_id};

    while (groups.next()) {
      const auto group = utf8Prefix(historyGroup(groups.text(0)), entry_command_bytes);
      const auto runs = static_cast<std::uint64_t>(groups.integer(1));

      result.total += runs;
      ++result.unique;
      if (auto* known = counts.findMut(group)) {
        *known += runs;
      } else {
        counts.insert(ds::String<ConcurrentMemory>{memory_, group}, runs);
      }
    }

    ds::Vec<HistoryStatsEntry, ConcurrentMemory> top{memory_};

    for (const auto& entry : counts) {
      top.push({.count = entry.value, .command = rows_.copy(entry.key.view())});
    }

    const auto end = std::min(top.size(), maximum_stats_results);

    std::ranges::partial_sort(top.viewMut(), top.viewMut().begin() + static_cast<std::ptrdiff_t>(end), [](const auto& left, const auto& right) {
      return left.count == right.count ? left.command < right.command : left.count > right.count;
    });

    result.top = top.view().first(end);
    reply.send(result);
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

  void HistoryStore::bindPhrase(Statement& statement, std::string_view query) {
    // A phrase of the output index's trigrams: the query whole, its quotes doubled, at most
    // twice the bytes of the longest query.
    constexpr std::size_t phrase_bytes = (QueryHistory::maximum_query_bytes * 2) + 2;
    ds::Array<char, phrase_bytes> quoted{};
    std::size_t length = 0;

    quoted.atMut(length++) = '"';
    for (const char byte : query.substr(0, QueryHistory::maximum_query_bytes)) {
      quoted.atMut(length++) = byte;
      if (byte == '"') {
        quoted.atMut(length++) = '"';
      }
    }

    quoted.atMut(length++) = '"';
    statement.bind(query_parameter::match, std::string_view{quoted.data(), length});
  }

  void HistoryStore::appendScope(ds::String<ConcurrentMemory>& sql, HistoryScope scope, bool preload) {
    switch (scope) {
    case HistoryScope::global:
      break;
    case HistoryScope::cwd:
      sql.append(" AND c.cwd_key = ?6");
      break;
    case HistoryScope::workspace:
      sql.append(" AND c.workspace_key = ?6");
      break;
    case HistoryScope::pane:
      sql.append(preload ? " AND (c.pane_id = ?6 OR c.started_at_ms < COALESCE((SELECT MIN(s.started_at_ms) FROM session s WHERE s.pane_id = ?6), 9223372036854775807))" : " AND c.pane_id = ?6");
      break;
    }
  }

  void HistoryStore::bindScope(Statement& statement, HistoryScope scope, const HistoryScopeValue& value, DirectoryKeys& keys, FixedText<PATH_MAX>& key) {
    if (scope == HistoryScope::pane) {
      statement.bind(query_parameter::scope, integer(std::get<std::uint64_t>(value)));
    } else if (scope != HistoryScope::global) {
      // Matched by its key, however the query wrote it.
      keys.key(std::get<std::string_view>(value), key);
      statement.bind(query_parameter::scope, key.view());
    }
  }

  void HistoryStore::appendFilters(ds::String<ConcurrentMemory>& sql, const QueryHistory& request) {
    if (request.failed_only) {
      sql.append(" AND c.exit_code IS NOT NULL AND c.exit_code <> 0 AND c.status = 0");
    }

    if (request.exit_code) {
      sql.append(" AND c.exit_code = ?9");
    }

    if (request.author != HistoryAuthorFilter::all) {
      sql.append(" AND c.author = ?5");
    }

    if (request.since_ms != 0) {
      sql.append(" AND c.started_at_ms >= ?10");
    }

    if (request.until_ms != 0) {
      sql.append(" AND c.started_at_ms < ?11");
    }

    if (request.min_duration_ms != 0) {
      sql.append(" AND c.duration_ns >= ?12");
    }

    if (!request.host.empty()) {
      sql.append(" AND c.host = ?13");
    }

    if (!request.branch.empty()) {
      sql.append(" AND c.branch = ?14");
    }

    if (!request.shell.empty()) {
      // By the shell's name, as the index matches it.
      sql.append(" AND (c.shell IN (?15, '-' || ?15) OR substr(c.shell, -length(?15) - 1) = '/' || ?15)");
    }

    appendScope(sql, request.scope, request.preload);
  }

  void HistoryStore::bindFilters(Statement& statement, const QueryHistory& request, DirectoryKeys& keys, FixedText<PATH_MAX>& key) {
    if (request.exit_code) {
      statement.bind(query_parameter::exit_code, std::int64_t{*request.exit_code});
    }

    if (request.author != HistoryAuthorFilter::all) {
      statement.bind(query_parameter::author, static_cast<std::int64_t>(request.author == HistoryAuthorFilter::agent));
    }

    if (request.since_ms != 0) {
      statement.bind(query_parameter::since, request.since_ms);
    }

    if (request.until_ms != 0) {
      statement.bind(query_parameter::until, request.until_ms);
    }

    if (request.min_duration_ms != 0) {
      const auto bound = std::min<std::uint64_t>(request.min_duration_ms, static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max() / nanoseconds_per_millisecond));

      statement.bind(query_parameter::duration, static_cast<std::int64_t>(bound) * nanoseconds_per_millisecond);
    }

    if (!request.host.empty()) {
      statement.bind(query_parameter::host, request.host);
    }

    if (!request.branch.empty()) {
      statement.bind(query_parameter::branch, request.branch);
    }

    if (!request.shell.empty()) {
      statement.bind(query_parameter::shell, historyShellName(request.shell));
    }

    bindScope(statement, request.scope, request.scope_value, keys, key);
  }

}
