export module telar.cli.commands.history.sources;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.ds;

// What `telar history import` reads: the histfiles of the shells, and the databases of the
// history tools that keep one, as the commands they hold in the order they ran.
export namespace telar::runtime::cli::history {

  enum class ImportFormat : std::uint8_t {
    zsh,
    bash,
    fish,
    nushell,
    xonsh,
    powershell,
    atuin,
    mcfly,
    histdb,
    nushell_sqlite,
  };

  // The name a source key and a message give the format.
  std::string_view formatName(ImportFormat format) noexcept;

  // What a source knew of how a command ran besides when: the directory, empty when unknown, the
  // exit status and the duration, 0 when unknown.
  struct ImportedRun {
    std::string_view cwd;
    ds::Option<std::int32_t> exit_code;
    std::int64_t duration_ns = 0;
  };

  // What a source hands the importer, one command at a time, in the order it ran. The texts view
  // the reader's buffers only for the call: they may not be valid UTF-8 yet, nor short enough.
  class ImportSink {
  public:
    virtual void command(std::int64_t started_at_ms, std::string_view command, const ImportedRun& run) = 0;
    // A command the reader could not hold, of `bytes` bytes.
    virtual void skipped(std::size_t bytes) = 0;

  protected:
    ImportSink() = default;
    ImportSink(const ImportSink&) = default;
    ImportSink(ImportSink&&) = default;
    ImportSink& operator=(const ImportSink&) = default;
    ImportSink& operator=(ImportSink&&) = default;
    ~ImportSink() = default;
  };

  inline constexpr std::size_t max_histfile_bytes = std::size_t{32} * 1024 * 1024;
  inline constexpr std::size_t max_command_bytes = 65535;
  // A database of another tool is read row by row; past this size it is refused rather than read.
  inline constexpr std::uint64_t max_database_bytes = std::uint64_t{4} * 1024 * 1024 * 1024;
  inline constexpr std::size_t max_session_files = 100000;

  // The newest max_histfile_bytes of a regular file, from the start of a line, and whether it
  // holds more. A symlink is followed only through the real path the caller resolved.
  struct Histfile {
    ds::String<Memory> text;
    bool truncated = false;
  };

  tbc::val_a<Histfile> readHistfile(tbc::mut_a<Memory> memory, const char* path);

  // The commands of a text histfile. A truncated one starts at its first whole entry.
  void parseHistfile(Memory& memory, ImportFormat format, std::string_view text, bool truncated, ImportSink& sink);

  // The commands of xonsh's JSON history: one session file, or a directory of them.
  void readXonsh(Memory& memory, const char* path, ImportSink& sink);

  // The commands of a SQLite database, opened read only, its schema distrusted.
  void readDatabase(ImportFormat format, const char* path, ImportSink& sink);

  // Whether the file starts as a SQLite database does.
  bool sqliteFile(const char* path) noexcept;

}
