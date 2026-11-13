#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../application/dependencies.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include "telar_platform/file_descriptor.hpp"
#include <span>
#include <string_view>
#include "remote_bridge.hpp"
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "../core/memory.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include <concepts>
#include <type_traits>
#include <algorithm>
#include <optional>
#include <charconv>
#include <cstring>
#include <system_error>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <chrono>
#include <limits>
#include <QByteArrayView>
#include <QLocalSocket>
#include <QTimer>

#pragma once

#include "application/dependencies.hpp"


import telar.gui.machines.discovery;
import telar.gui.platform.profile_file;
import telar.client;
import telar.gui.transport.runtime_link;

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
  [[nodiscard]] bool supportsSharedMemory() const noexcept {
    return accepted_ && !remote_target_;
  }
  [[nodiscard]] platform::SharedImageSource sharedImage(std::string_view name) const {
    if (!supportsSharedMemory()) {
      throw EncodingError{"Shared graphics requires a local runtime"};
    }

    return platform::SharedImageSource{name};
  }
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

    if constexpr (std::same_as<Message, OpenPane>) {
      if (accepted_) {
        static_cast<void>(socket_.flush());
      }
    }
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
