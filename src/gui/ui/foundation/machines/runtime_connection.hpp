#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "foundation/core/memory.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_wire/codecs/telar_codec.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_serializer.hpp"
#include "ui/foundation/machines/remote_bridge.hpp"
#include <QByteArrayView>
#include <QLocalSocket>
#include <QTimer>
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <type_traits>
#include <variant>

#pragma once

import telar.gui.application;
import telar.gui.foundation.system;
import telar.client;
import telar.base.ds;

namespace telar::gui::qt {

  class RuntimeConnection final : public QObject, public application::RuntimeTransport {
    Q_OBJECT

  public:
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

    [[nodiscard]] bool supportsSharedMemory() const noexcept override {
      return accepted_ && !remote_target_;
    }

    [[nodiscard]] system::SharedImageSource sharedImage(std::string_view name) const override {
      if (!supportsSharedMemory()) {
        throw EncodingError{"Shared graphics requires a local runtime"};
      }

      return system::SharedImageSource{name};
    }

    [[nodiscard]] const SchemaId& schema() const noexcept {
      return schema_;
    }

    [[nodiscard]] const application::RuntimeLink& link() const noexcept;
    [[nodiscard]] QString error() const;
    void dismissError();
    void recover(std::string_view reason) override;
    bool report(std::span<const Byte> message) override;

    void willDetach(std::uint64_t pane_id) override {
      emit paneWillDetach(pane_id);
    }

    std::span<Byte> buffer(std::size_t size) override;
    void send(std::span<const Byte> message) override;

    template <typename Message>
      requires(!std::convertible_to<const Message&, std::span<const Byte>>)
    void send(const Message& message) {
      send(Codec::encode(message, buffer(Codec::encodedSize(message))));
    }

  signals:
    void discovered(const RemoteDiscovery& discovery);
    void connected();
    void disconnected();
    void payloadReceived(QByteArrayView payload);
    void errorChanged();
    void linkChanged();
    void paneWillDetach(qulonglong pane_id);

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
    Vector<Byte, ApplicationAllocator> output_;
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
    ds::Option<RemoteBridge<NativeSshHost, RuntimeConnection>> remote_;
  };

}
