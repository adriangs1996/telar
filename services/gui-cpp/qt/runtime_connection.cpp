#include "runtime_connection.hpp"
#include "application/dependencies.hpp"
#include "machines/failure.hpp"
#include "machines/machine_row.hpp"
#include "platform/awake_clock.hpp"
#include "platform/file_descriptor.hpp"
#include "platform/peer_identity.hpp"
#include "remote_bridge.hpp"
#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "transport/frame_stream.hpp"
#include "transport/runtime_handshake.hpp"
#include "transport/runtime_protocol.hpp"
#include <QElapsedTimer>
#include <QScopedValueRollback>
#include <QStringLiteral>
#include <QTimer>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <span>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

RuntimeConnection::RuntimeConnection(ApplicationAllocator &memory, QObject *parent)
    : QObject(parent),
      stream_(memory),
      output_(AllocatorRef<Byte, ApplicationAllocator>{memory}) {
  socket_.setReadBufferSize(max_payload_size + frame_prefix_size);
  retry_.setSingleShot(true);
  deadline_.setSingleShot(true);
  deadline_.setInterval(handshake_timeout_ms);

  connect(&retry_, &QTimer::timeout, this, &RuntimeConnection::connectSocket);

  connect(&deadline_, &QTimer::timeout, this, [this] {
    fail(QStringLiteral("Runtime handshake timed out"));
  });

  connect(&socket_, &QLocalSocket::readyRead, this, &RuntimeConnection::read);

  connect(&socket_, &QLocalSocket::connected, this, &RuntimeConnection::beginHandshake);
  connect(&socket_, &QLocalSocket::disconnected, this, &RuntimeConnection::socketDisconnected);
  connect(&socket_, &QLocalSocket::errorOccurred, this, &RuntimeConnection::socketFailed);
}

RuntimeConnection::~RuntimeConnection() {
  socket_.disconnect(this);
  close();
}

void RuntimeConnection::open(const QString &path) {
  close();
  path_ = path;
  closed_ = false;
  link_.start("this machine");
  error_.clear();
  emit linkChanged();
  connectSocket();
}

void RuntimeConnection::openRemote(RemoteTarget target) {
  close();
  remote_target_ = std::move(target);
  if (!remote_) {
    remote_.emplace(*this);
  }

  closed_ = false;
  const auto destination = remote_target_->destination.toUtf8();
  link_.start({destination.constData(), static_cast<std::size_t>(destination.size())});
  error_.clear();
  emit linkChanged();
  connectSocket();
}

void RuntimeConnection::remoteDiscovered(const RemoteDiscovery &discovery) {
  if (closed_ || !remote_target_) {
    return;
  }

  schema_ = discovery.schema();
  emit discovered(discovery);
}

void RuntimeConnection::remoteChannelReady(runtime::FileDescriptor channel) {
  if (closed_ || !remote_target_) {
    return;
  }

  if (!socket_.setSocketDescriptor(channel.get(), QLocalSocket::ConnectedState)) {
    fail(socket_.errorString());

    return;
  }

  static_cast<void>(channel.release());
  deadline_.start();
  beginHandshake();
}

void RuntimeConnection::remoteFailed(MachineError error, std::string_view detail) {
  if (closed_ || session_finished_ || !remote_target_) {
    return;
  }

  remote_error_ = error;
  const std::string_view fallback = link_.phase == MachinePhase::connected ? "EndOfStream" : MachineFailure::name(error);
  const auto message = detail.empty() ? fallback : detail;
  if (dispatching_payload_) {
    RuntimeLink bounded;
    bounded.fail(message);
    const auto kept = bounded.failure().value_or(std::string_view{});
    pending_failure_ = QString::fromUtf8(kept.data(), static_cast<qsizetype>(kept.size()));
  } else {
    fail(message);
  }
}

std::optional<MachineError> RuntimeConnection::remoteError() const noexcept {
  return remote_error_;
}

void RuntimeConnection::retryNow() {
  if (session_finished_) {
    resumeSession();

    return;
  }

  if (closed_ || connecting_ || socket_.state() != QLocalSocket::UnconnectedState || !link_.retryNow()) {
    return;
  }

  retry_.stop();
  connectSocket();
}

// A terminal message ends reception while machine chrome retains the last
// connected summary. Selection starts another transport session.
void RuntimeConnection::finishSession() noexcept {
  session_finished_ = true;
  accepted_ = false;
  connecting_ = false;
  retry_.stop();
  deadline_.stop();
  pending_failure_.reset();
}

void RuntimeConnection::resumeSession() {
  if (closed_ || !session_finished_) {
    return;
  }

  {
    const QScopedValueRollback aborting{closed_, true};
    if (remote_) {
      remote_->close();
    }

    socket_.abort();
  }

  session_finished_ = false;
  link_.phase = MachinePhase::connecting;
  link_.attempt = 0;
  link_.clearFailure();
  connectSocket();
}

void RuntimeConnection::close() {
  ++read_generation_;
  closed_ = true;
  accepted_ = false;
  connecting_ = false;
  handshake_sent_ = false;
  session_finished_ = false;
  schema_ = handshake::schema_id;
  schema_retried_ = false;
  schema_retry_pending_ = false;
  retry_.stop();
  deadline_.stop();
  if (remote_) {
    remote_->close();
  }

  remote_target_.reset();
  remote_error_.reset();
  link_.stop();
  socket_.abort();
}

bool RuntimeConnection::ready() const noexcept {
  return accepted_;
}

const RuntimeLink &RuntimeConnection::link() const noexcept {
  return link_;
}

QString RuntimeConnection::error() const {
  return error_;
}

void RuntimeConnection::dismissError() {
  if (!error_.isEmpty()) {
    error_.clear();
    emit errorChanged();
  }
}

void RuntimeConnection::recover(std::string_view reason) {
  const auto message = QString::fromUtf8(reason.data(), static_cast<qsizetype>(reason.size()));
  if (dispatching_payload_) {
    pending_failure_ = message;
  } else {
    fail(message);
  }
}

bool RuntimeConnection::report(const ReportLimit &message) {
  constexpr qint64 reserved_input_messages = 8;
  constexpr auto reserved_input_bytes = reserved_input_messages * static_cast<qint64>(read_chunk_size);
  if (socket_.bytesToWrite() >= output_limit - reserved_input_bytes) {
    return false;
  }

  send(message);

  return true;
}

void RuntimeConnection::connectSocket() {
  if (closed_ || connecting_ || session_finished_) {
    return;
  }

  if (socket_.state() != QLocalSocket::UnconnectedState) {
    if (link_.phase == MachinePhase::lost) {
      retry_.start(link_.retryDelayMilliseconds());
    }

    return;
  }

  if (link_.phase == MachinePhase::lost) {
    static_cast<void>(link_.retry());
  } else if (link_.phase != MachinePhase::connecting) {
    return;
  }

  ++read_generation_;
  connecting_ = true;
  stream_.reset();
  stream_.setMaximum(HandshakeCodec::max_message_size);
  socket_.setReadBufferSize(HandshakeCodec::max_message_size + frame_prefix_size);
  pending_failure_.reset();
  remote_error_.reset();
  accepted_ = false;
  handshake_sent_ = false;
  if (remote_target_) {
    if (!remote_) {
      throw std::logic_error{"Remote transport was not initialized"};
    }

    remote_->open(*remote_target_);
    emit linkChanged();

    return;
  }

  deadline_.start();
  socket_.connectToServer(path_);
  emit linkChanged();
}

void RuntimeConnection::beginHandshake() {
  if (closed_ || handshake_sent_ || socket_.state() != QLocalSocket::ConnectedState) {
    return;
  }

  if (!remote_target_ && !platform::isCurrentUser(socket_.socketDescriptor())) {
    fail(QStringLiteral("Runtime socket belongs to another user"));

    return;
  }

  handshake_sent_ = true;
  try {
    write(HandshakeCodec::encode(ClientHello{.schema = schema_}));
  } catch (const std::exception &error) {
    fail(QString::fromUtf8(error.what()));
  }
}

void RuntimeConnection::retrySchema(const SchemaId &schema) {
  schema_ = schema;
  schema_retried_ = true;
  schema_retry_pending_ = true;
  connecting_ = false;
  const auto generation = ++read_generation_;
  deadline_.stop();
  socket_.abort();
  QTimer::singleShot(std::chrono::milliseconds::zero(), this, [this, generation] {
    if (!closed_ && generation == read_generation_ && schema_retry_pending_) {
      schema_retry_pending_ = false;
      connectSocket();
    }
  });
}

void RuntimeConnection::socketDisconnected() {
  if (closed_ || session_finished_ || schema_retry_pending_) {
    return;
  }

  if (remote_ && remote_->active()) {
    accepted_ = false;
    deadline_.start();

    return;
  }

  fail(std::string_view{"EndOfStream"});
}

void RuntimeConnection::socketFailed(QLocalSocket::LocalSocketError error) {
  if (closed_ || session_finished_ || schema_retry_pending_) {
    return;
  }

  if (remote_ && remote_->active() && error == QLocalSocket::PeerClosedError) {
    return;
  }

  fail(error == QLocalSocket::PeerClosedError ? QStringLiteral("EndOfStream") : socket_.errorString());
}

void RuntimeConnection::read() {
  read_queued_ = false;
  if (closed_ || session_finished_) {
    return;
  }

  try {
    drainInput();
  } catch (const MachineFailure &error) {
    if (!accepted_) {
      const auto detail = link_.failure_storage;
      fail(detail.view());
    } else {
      fail(std::string_view{error.what()});
    }
  } catch (const std::exception &error) {
    fail(std::string_view{error.what()});
  }
}

void RuntimeConnection::drainInput() {
  constexpr qint64 read_budget_ms = 4;
  QElapsedTimer budget;
  budget.start();
  while (socket_.bytesAvailable() > 0) {
    if (!readChunk()) {
      return;
    }

    if (budget.elapsed() >= read_budget_ms) {
      queueRead();

      return;
    }
  }
}

bool RuntimeConnection::readChunk() {
  const auto received = socket_.read(read_buffer_.data(), static_cast<qint64>(read_buffer_.size()));
  if (received <= 0) {
    return false;
  }

  const auto generation = read_generation_;
  const auto consume_payload = [this, generation](std::span<const Byte> payload) {
    consume(payload);

    return generation == read_generation_ && !closed_ && !session_finished_;
  };

  stream_.feed(byteView({
                   read_buffer_.data(),
                   static_cast<std::size_t>(received),
               }),
               consume_payload);

  return generation == read_generation_ && !closed_ && !session_finished_;
}

void RuntimeConnection::queueRead() {
  if (socket_.bytesAvailable() > 0 && !read_queued_) {
    read_queued_ = true;
    QTimer::singleShot(std::chrono::milliseconds::zero(), this, &RuntimeConnection::read);
  }
}

void RuntimeConnection::consume(std::span<const Byte> payload) {
  if (!accepted_) {
    if (!remote_target_ && !schema_retried_) {
      if (const auto retry = RuntimeProtocol::retry(payload, schema_)) {
        retrySchema(*retry);

        return;
      }
    }

    const auto negotiation = RuntimeHandshake::inspect(payload, schema_);
    if (negotiation.error) {
      remote_error_ = negotiation.error;
      link_.fail(negotiation.detail.view());
      throw MachineFailure{*negotiation.error};
    }

    accepted_ = true;
    schema_retried_ = false;
    stream_.setMaximum(max_payload_size);
    socket_.setReadBufferSize(max_payload_size + frame_prefix_size);
    connecting_ = false;
    link_.adopt(platform::AwakeClock::nowNanoseconds());
    deadline_.stop();
    error_.clear();
    emit errorChanged();
    emit connected();
    emit linkChanged();

    return;
  }

  const QScopedValueRollback dispatching{dispatching_payload_, true};
  emit payloadReceived(QByteArrayView{
      payload.data(),
      static_cast<qsizetype>(payload.size()),
  });
  if (const auto failure = std::exchange(pending_failure_, std::nullopt)) {
    throw std::runtime_error{failure->toStdString()};
  }
}

void RuntimeConnection::write(std::span<const Byte> payload) {
  if (accepted_ && !payload.empty() && !RuntimeProtocol::supports(schema_, static_cast<ClientTag>(payload.front()))) {
    throw std::runtime_error{"The runtime schema does not support this request"};
  }

  const auto total_size = payload.size() + frame_prefix_size;

  if (socket_.bytesToWrite() + static_cast<qint64>(total_size) > output_limit) {
    throw std::length_error{"Runtime output queue capacity reached"};
  }

  std::array<Byte, frame_prefix_size> prefix{};
  std::span<Byte> output{prefix};
  u32::encode(static_cast<std::uint32_t>(payload.size()), output);
  const QByteArrayView prefix_view{prefix.data(), static_cast<qsizetype>(prefix.size())};
  const QByteArrayView payload_view{payload.data(), static_cast<qsizetype>(payload.size())};
  const auto prefix_written = socket_.write(prefix_view.data(), static_cast<qint64>(prefix_view.size()));
  const auto payload_written = socket_.write(payload_view.data(), static_cast<qint64>(payload_view.size()));
  if (std::cmp_not_equal(prefix_written, prefix.size()) || std::cmp_not_equal(payload_written, payload.size())) {
    throw std::runtime_error{"Could not queue runtime frame"};
  }
}

void RuntimeConnection::fail(const QString &message) {
  const auto utf8 = message.toUtf8();
  fail(std::string_view{utf8.constData(), static_cast<std::size_t>(utf8.size())});
}

void RuntimeConnection::fail(std::string_view message) {
  if (session_finished_) {
    return;
  }

  if (link_.phase == MachinePhase::connected) {
    link_.lose(message, platform::AwakeClock::nowNanoseconds());
  } else {
    link_.connectionFailed(remote_error_.value_or(MachineError::endpoint_unavailable), message);
  }

  const auto detail = link_.failure().value_or(std::string_view{});
  error_ = QString::fromUtf8(detail.data(), static_cast<qsizetype>(detail.size()));
  accepted_ = false;
  connecting_ = false;
  if (remote_) {
    remote_->close();
  }

  {
    const QScopedValueRollback aborting{closed_, true};
    socket_.abort();
  }

  deadline_.stop();
  emit errorChanged();
  emit disconnected();
  emit linkChanged();

  if (!closed_ && link_.phase == MachinePhase::lost) {
    retry_.start(link_.retryDelayMilliseconds());
  }
}

}
