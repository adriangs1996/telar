#pragma once

#include "application/dependencies.hpp"
#include "machines/failure.hpp"
#include "platform/file_descriptor.hpp"
#include "remote_bridge.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include "transport/frame_stream.hpp"
#include "transport/runtime_link.hpp"
#include <QByteArrayView>
#include <QLocalSocket>
#include <QTimer>
#include <array>
#include <optional>
#include <string_view>

namespace telar::gui::qt {

class RuntimeConnection final : public QObject {
  Q_OBJECT

public:
  static constexpr qint64 output_limit = qint64{4} * 1024 * 1024;
  static constexpr std::size_t read_chunk_size = std::size_t{64} * 1024;
  static constexpr int handshake_timeout_ms = 5000;

  explicit RuntimeConnection(ApplicationAllocator &memory, QObject *parent = nullptr);
  ~RuntimeConnection() override;
  RuntimeConnection(const RuntimeConnection &) = delete;
  RuntimeConnection &operator=(const RuntimeConnection &) = delete;
  RuntimeConnection(RuntimeConnection &&) = delete;
  RuntimeConnection &operator=(RuntimeConnection &&) = delete;

  void open(const QString &path);
  void openRemote(RemoteTarget target);
  void remoteDiscovered(const RemoteDiscovery &discovery);
  void remoteChannelReady(runtime::FileDescriptor channel);
  void remoteFailed(MachineError error, std::string_view detail);
  [[nodiscard]] std::optional<MachineError> remoteError() const noexcept;
  void close();
  void retryNow();
  void finishSession() noexcept;
  void resumeSession();
  [[nodiscard]] bool ready() const noexcept;
  [[nodiscard]] const SchemaId &schema() const noexcept {
    return schema_;
  }
  [[nodiscard]] const RuntimeLink &link() const noexcept;
  [[nodiscard]] QString error() const;
  void dismissError();
  void recover(std::string_view reason);
  bool report(const ReportLimit &message);

  void willDetach(std::uint64_t pane_id) {
    emit paneWillDetach(pane_id);
  }

  template <typename Message>
  void send(const Message &message) {
    if (!accepted_) {
      throw std::runtime_error{"Runtime is not connected"};
    }

    output_.resize(Codec::encodedSize(message));
    write(Codec::encode(message, output_));
  }

signals:
  void discovered(const RemoteDiscovery &discovery);
  void connected();
  void disconnected();
  void payloadReceived(QByteArrayView payload);
  void errorChanged();
  void linkChanged();
  void paneWillDetach(qulonglong pane_id);

private:
  void connectSocket();
  void beginHandshake();
  void retrySchema(const SchemaId &schema);
  void socketDisconnected();
  void socketFailed(QLocalSocket::LocalSocketError error);
  void read();
  void drainInput();
  bool readChunk();
  void queueRead();
  void consume(std::span<const Byte> payload);
  void write(std::span<const Byte> payload);
  void fail(const QString &message);
  void fail(std::string_view message);

  QLocalSocket socket_;
  QTimer retry_;
  QTimer deadline_;
  FrameStream<ApplicationAllocator> stream_;
  Vector<Byte, ApplicationAllocator> output_;
  std::array<char, read_chunk_size> read_buffer_{};
  RuntimeLink link_;
  std::uint64_t read_generation_ = 0;
  QString path_;
  QString error_;
  std::optional<QString> pending_failure_;
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
  std::optional<RemoteTarget> remote_target_;
  std::optional<MachineError> remote_error_;
  std::optional<RemoteBridge<NativeSshHost, RuntimeConnection>> remote_;
};

}
