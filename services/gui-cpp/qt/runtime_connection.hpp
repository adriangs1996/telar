#pragma once

#include "application/dependencies.hpp"
#include "machines/failure.hpp"
#include "platform/file_descriptor.hpp"
#include "remote_bridge.hpp"
#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "transport/frame_stream.hpp"
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
  static constexpr int reconnect_delay_ms = 1000;
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
  void remoteFailed(MachineError error, const QString &detail);
  [[nodiscard]] std::optional<MachineError> remoteError() const noexcept;
  void close();
  [[nodiscard]] bool ready() const noexcept;
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
  void discovered(QByteArrayView home, QByteArrayView shell, QByteArrayView endpoint);
  void connected();
  void disconnected();
  void payloadReceived(QByteArrayView payload);
  void errorChanged();
  void paneWillDetach(qulonglong pane_id);

private:
  void connectSocket();
  void beginHandshake();
  void socketDisconnected();
  void socketFailed(QLocalSocket::LocalSocketError error);
  void read();
  void drainInput();
  bool readChunk();
  void queueRead();
  void consume(std::span<const Byte> payload);
  void write(std::span<const Byte> payload);
  void fail(const QString &message);

  QLocalSocket socket_;
  QTimer retry_;
  QTimer deadline_;
  FrameStream<ApplicationAllocator> stream_;
  Vector<Byte, ApplicationAllocator> output_;
  std::array<char, read_chunk_size> read_buffer_{};
  QString path_;
  QString error_;
  std::optional<QString> pending_failure_;
  bool dispatching_payload_ = false;
  bool accepted_ = false;
  bool handshake_sent_ = false;
  bool retry_permitted_ = true;
  bool closed_ = true;
  bool read_queued_ = false;
  std::optional<RemoteTarget> remote_target_;
  std::optional<MachineError> remote_error_;
  std::optional<RemoteBridge<NativeSshHost, RuntimeConnection>> remote_;
};

}
