#pragma once

#include "terminal_screen.hpp"
#include "../../telar_client/codecs/telar_codec.hpp"
#include "../../telar_client/serializers/telar_protocol.hpp"
#include <QLocalSocket>
#include <QTimer>
#include <QElapsedTimer>
#include <functional>
#include <map>
#include <set>
#include "clipboard_task.hpp"

namespace workbench {
  struct DesktopClipboardOperation;
  // One asynchronous attachment session per visible workspace, shared by its panes.
  class RuntimeConnection final : public QObject {
  public:
    RuntimeConnection(QString socket, telar::WorkspaceLocation workspace);
    ~RuntimeConnection() override;
    std::function<void()> changed;
    std::function<void(std::uint64_t)> painted;
    // A tab this session created, with its root pane attached.
    std::function<void(std::uint64_t)> created;
    void selectTab(std::uint64_t tab);
    void setVisible(bool visible);
    // Fetches a hidden workspace's tabs and their panes once, attaching none, so its windows can
    // be prepared before it is shown; the session closes once every tab has arrived.
    void load();
    void refresh();
    void attach(std::uint64_t pane);
    void input(std::uint64_t pane, const QByteArray &bytes);
    void resize(std::uint64_t pane, telar::TerminalSize size);
    void viewport(std::uint64_t pane, std::uint32_t offset);
    void desktop(std::uint64_t pane, telar::ConfigurePaneDesktop state);
    void paste(std::uint64_t pane, const QString &text, const QStringList &available);
    void split(std::uint64_t source);
    // Opens a tab whose shell starts in the source pane's directory, or in $HOME without one.
    void createTab(std::uint64_t source);
    void close(std::uint64_t pane);
    std::shared_ptr<TerminalScreen> screen(std::uint64_t pane);
    const std::map<std::uint64_t, std::vector<std::uint64_t>> &tabs() const;
    std::uint64_t activeTab() const;
    bool ready() const;
    bool hasSnapshot(std::uint64_t tab) const;
    const QString &error() const;

  private:
    friend struct ClipboardConnectionTest;

    static constexpr qsizetype output_limit = telar::max_payload_size + telar::frame_prefix_size;
    QString path_;
    telar::WorkspaceLocation workspace_;
    QLocalSocket socket_;
    QTimer retry_, refresh_, deadline_, resize_timer_, linger_;
    QByteArray input_;
    std::vector<telar::Byte> arena_;
    std::map<std::uint64_t, std::vector<std::uint64_t>> tabs_;
    std::map<std::uint64_t, std::shared_ptr<TerminalScreen>> screens_;
    std::map<std::uint64_t, telar::TerminalSize> sizes_, sent_sizes_;
    std::set<std::uint64_t> attached_;
    std::map<std::uint64_t, std::unique_ptr<DesktopClipboardOperation>> clipboard_operations_;
    std::map<std::uint64_t, std::uint64_t> generations_;
    std::map<std::uint64_t, telar::ConfigurePaneDesktop> desktop_;
    std::set<std::uint64_t> snapshots_;
    enum class RequestKind {
      workspace,
      tab,
      attach,
      create,
      close
    };

    struct Pending {
      RequestKind kind;
      std::uint64_t target;
      qint64 started;
    };

    std::map<std::uint64_t, Pending> pending_;
    QElapsedTimer clock_;
    std::uint64_t identity_ = 0, request_ = 1, active_tab_ = 0;
    std::uint64_t clipboard_epoch_ = 1;
    bool handshake_ = false, visible_ = false, reading_ = false, loading_ = false;
    QString error_;

    void connect();
    void disconnected();
    void read();
    void consume(std::span<const telar::Byte> payload);
    void write(std::span<const telar::Byte> payload);
    void synchronizeAttachments();
    void sendDesktop(std::uint64_t pane);
    void clipboardRequest(const telar::ClipboardDesktopRequest &request);
    void completeClipboard(telar::ClipboardTicket ticket, std::uint64_t epoch, ClipboardConsent consent);
    void executeClipboardTask(telar::ClipboardDesktopExecute execution, std::uint64_t epoch);
    void cancelClipboardTask(const telar::CancelClipboardDesktop &cancellation);
    void cancelClipboard(std::uint64_t pane);
    void notify();
    std::uint64_t request(RequestKind kind, std::uint64_t target = 0);
    bool waiting(RequestKind kind, std::uint64_t target = 0) const;
    void requestTab(std::uint64_t tab);
    void finishLoading();
    static const char *describe(RequestKind kind);

    template <typename Message> void send(const Message &message) {
      std::vector<telar::Byte> bytes(telar::Codec::encodedSize(message));
      write(telar::Codec::encode(message, bytes));
    }
  };
} // namespace workbench
