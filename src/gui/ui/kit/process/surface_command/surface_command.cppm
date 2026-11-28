export module telar.gui.ui.kit.process.surface_command;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.base.ds;

export namespace telar::gui::qt {

  enum class SurfaceCommandFailure : std::uint8_t {
    launch,
    process,
    timeout,
    cancelled,
    invalid_output,
  };

  enum class SurfaceOutputUse : std::uint8_t {
    line,
    lines,
    options,
    ignored,
  };

  struct SurfaceCommandRequest {
    static constexpr std::size_t bar_output_bytes = std::size_t{64} * 1024;
    static constexpr std::size_t pick_output_bytes = std::size_t{256} * 1024;
    static constexpr std::chrono::milliseconds default_timeout{2000};
    QList<QByteArray> arguments;
    QString directory;
    std::chrono::milliseconds timeout = default_timeout;
    static constexpr std::size_t line_output_bytes = 4096;
    SurfaceOutputUse output = SurfaceOutputUse::lines;
  };

  struct SurfaceCommandResult {
    QByteArray output;
    ds::Option<SurfaceCommandFailure> failure = ds::none;
    bool truncated = false;
    int exit_code = -1;
    std::size_t observed_bytes = 0;
  };

  class SurfaceCommand {
  public:
    // Held inline, never on the heap; what it captures fits in sixteen pointers.
    static constexpr std::size_t completion_pointers = 16;
    using Completion = ds::Function<void(SurfaceCommandResult), completion_pointers * sizeof(void*)>;

    SurfaceCommand();
    ~SurfaceCommand();
    SurfaceCommand(const SurfaceCommand&) = delete;
    SurfaceCommand& operator=(const SurfaceCommand&) = delete;
    SurfaceCommand(SurfaceCommand&&) = delete;
    SurfaceCommand& operator=(SurfaceCommand&&) = delete;
    // The command keeps the completion, and what it captures, region `a`, until it runs.
    void start(const SurfaceCommandRequest& request, tbc::val_a<Completion> complete);
    void cancel();
    [[nodiscard]] bool active() const noexcept;

  private:
    void stop(ds::Option<SurfaceCommandFailure> failure);
    [[nodiscard]] std::size_t outputLimit() const noexcept;
    void normalizeOutput();
    void drain();
    void finish();
    void finishWhenDrained();
    QProcess process_;
    QTimer deadline_;
    QTimer grace_;
    SurfaceCommandRequest request_;
    SurfaceCommandResult result_;
    tbc::val_a<Completion> complete_;
    QByteArray payload_;
    qint64 group_ = 0;
    bool running_ = false;
    bool exited_ = false;
    bool normal_exit_ = true;
    QObject context_;
  };

}
