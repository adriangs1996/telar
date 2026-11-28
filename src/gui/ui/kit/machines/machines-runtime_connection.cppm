export module telar.gui.ui.kit.machines:runtime_connection;

import std;
import telar.gui.qt;
import :remote_bridge;
import telar.gui.application;
import telar.gui.foundation.system;
import telar.client;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.platform.primitives;
import telar.wire.vocabulary;
import telar.base.text.utf8;

export namespace telar::gui::qt {

  class [[qt::object]] RuntimeConnection final : public QObject, public application::RuntimeTransport {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    static constexpr qint64 output_limit = qint64{4} * 1024 * 1024;
    static constexpr std::size_t read_chunk_size = std::size_t{64} * 1024;
    static constexpr int handshake_timeout_ms = 5000;

    explicit RuntimeConnection(ApplicationAllocator& memory, QObject* parent = nullptr);
    ~RuntimeConnection() override;
    RuntimeConnection(const RuntimeConnection&) = delete;
    RuntimeConnection& operator=(const RuntimeConnection&) = delete;
    RuntimeConnection(RuntimeConnection&&) = delete;
    RuntimeConnection& operator=(RuntimeConnection&&) = delete;

    void open(const QString& path);
    void openRemote(RemoteTarget target);
    void remoteDiscovered(const RemoteDiscovery& discovery);
    void remoteChannelReady(runtime::FileDescriptor channel);
    void remoteFailed(application::machines::MachineError error, std::string_view detail);
    [[nodiscard]] ds::Option<application::machines::MachineError> remoteError() const noexcept;
    void close();
    void retryNow();
    void finishSession() noexcept;
    void resumeSession();
    [[nodiscard]] bool ready() const noexcept;

    [[tbc::hot_path]] [[nodiscard]] inline bool supportsSharedMemory() const noexcept override {
      return accepted_ && !remote_target_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline system::SharedImageSource sharedImage(std::string_view name) const override {
      if (!supportsSharedMemory()) {
        throw EncodingError{"Shared graphics requires a local runtime"};
      }

      return system::SharedImageSource{name};
    }

    [[tbc::hot_path]] [[nodiscard]] inline const SchemaId& schema() const noexcept {
      return schema_;
    }

    [[nodiscard]] const application::RuntimeLink& link() const noexcept;
    [[nodiscard]] QString error() const;
    void dismissError();
    void recover(std::string_view reason) override;
    bool report(std::span<const Byte> message) override;

    [[tbc::hot_path]] inline void willDetach(std::uint64_t pane_id) override {
      paneWillDetach(pane_id);
    }

    std::span<Byte> buffer(std::size_t size) override;
    void send(std::span<const Byte> message) override;

    template <typename Message>
      requires(!std::convertible_to<const Message&, std::span<const Byte>>)
    [[tbc::generic]] void send(const Message& message) {
      send(Codec::encode(message, buffer(Codec::encodedSize(message))));
    }

    [[qt::signal]] void discovered(const RemoteDiscovery& discovery);
    [[qt::signal]] void connected();
    [[qt::signal]] void disconnected();
    [[qt::signal]] void payloadReceived(QByteArrayView payload);
    [[qt::signal]] void errorChanged();
    [[qt::signal]] void linkChanged();
    [[qt::signal]] void paneWillDetach(qulonglong pane_id);

  private:
    void connectSocket();
    void beginHandshake();
    void retrySchema(const SchemaId& schema);
    void socketDisconnected();
    void socketFailed(QLocalSocket::LocalSocketError error);
    void read();
    void drainInput();
    bool readChunk();
    void queueRead();
    void consume(std::span<const Byte> payload);
    void write(std::span<const Byte> payload);
    void fail(const QString& message);
    void fail(std::string_view message);

    QLocalSocket socket_;
    QTimer retry_;
    QTimer deadline_;
    application::FrameStream<ApplicationAllocator> stream_;
    ds::Vec<Byte, ApplicationAllocator> output_;
    ds::Array<char, read_chunk_size> read_buffer_{};
    application::RuntimeLink link_;
    std::uint64_t read_generation_ = 0;
    QString path_;
    QString error_;
    ds::Option<QString> pending_failure_;
    bool dispatching_payload_ = false;
    bool accepted_ = false;
    bool connecting_ = false;
    bool handshake_sent_ = false;
    bool closed_ = true;
    bool session_finished_ = false;
    bool read_queued_ = false;
    SchemaId schema_ = handshake::schema_id;
    bool schema_retried_ = false;
    bool schema_retry_pending_ = false;
    ds::Option<RemoteTarget> remote_target_;
    ds::Option<application::machines::MachineError> remote_error_;
    ds::Option<RemoteBridge<NativeGatewayHost, RuntimeConnection>> remote_;
  };

}
