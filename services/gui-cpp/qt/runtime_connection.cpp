#include "runtime_connection.hpp"
#include "application/dependencies.hpp"
#include "platform/peer_identity.hpp"
#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "transport/frame_stream.hpp"
#include <QElapsedTimer>
#include <QScopedValueRollback>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <span>
#include <string_view>
#include <utility>
#include <variant>

namespace telar::gui::qt {

RuntimeConnection::RuntimeConnection(ApplicationAllocator &memory, QObject *parent)
    : QObject(parent),
      stream_(memory),
      output_(AllocatorRef<Byte, ApplicationAllocator>{memory}) {
  socket_.setReadBufferSize(max_payload_size + frame_prefix_size);
  retry_.setSingleShot(true);
  retry_.setInterval(reconnect_delay_ms);
  deadline_.setSingleShot(true);
  deadline_.setInterval(handshake_timeout_ms);

  connect(&retry_, &QTimer::timeout, this, &RuntimeConnection::connectSocket);

  connect(&deadline_, &QTimer::timeout, this, [this] {
    fail(QStringLiteral("Runtime handshake timed out"));
  });

  connect(&socket_, &QLocalSocket::readyRead, this, &RuntimeConnection::read);

  connect(&socket_, &QLocalSocket::connected, this, [this] {
    if (!platform::isCurrentUser(socket_.socketDescriptor())) {
      fail(QStringLiteral("Runtime socket belongs to another user"));

      return;
    }

    write(HandshakeCodec::encode(ClientHello{}));
  });

  connect(&socket_, &QLocalSocket::disconnected, this, [this] {
    accepted_ = false;
    deadline_.stop();
    emit disconnected();

    if (!closed_) {
      retry_.start();
    }
  });

  connect(&socket_, &QLocalSocket::errorOccurred, this, [this](auto) {
    fail(socket_.errorString());
  });
}

RuntimeConnection::~RuntimeConnection() {
  socket_.disconnect(this);
  close();
}

void RuntimeConnection::open(const QString &path) {
  close();
  path_ = path;
  closed_ = false;
  connectSocket();
}

void RuntimeConnection::close() {
  closed_ = true;
  accepted_ = false;
  retry_.stop();
  deadline_.stop();
  socket_.abort();
}

bool RuntimeConnection::ready() const noexcept {
  return accepted_;
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
  if (closed_ || socket_.state() != QLocalSocket::UnconnectedState) {
    return;
  }

  stream_.reset();
  pending_failure_.reset();
  accepted_ = false;
  socket_.connectToServer(path_);
  deadline_.start();
}

void RuntimeConnection::read() {
  read_queued_ = false;
  try {
    drainInput();
  } catch (const std::exception &error) {
    fail(QString::fromUtf8(error.what()));
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

  const auto consume_payload = [this](std::span<const Byte> payload) {
    consume(payload);
  };

  stream_.feed(byteView({
                   read_buffer_.data(),
                   static_cast<std::size_t>(received),
               }),
               consume_payload);

  return true;
}

void RuntimeConnection::queueRead() {
  if (socket_.bytesAvailable() > 0 && !read_queued_) {
    read_queued_ = true;
    QMetaObject::invokeMethod(this, &RuntimeConnection::read, Qt::QueuedConnection);
  }
}

void RuntimeConnection::consume(std::span<const Byte> payload) {
  if (!accepted_) {
    const auto response = HandshakeCodec::decodeResponse(payload);
    const auto *accepted = std::get_if<ServerAccept>(&response);

    if (accepted == nullptr || accepted->schema != handshake::schema_id) {
      throw std::runtime_error{"Runtime rejected the wire schema or client capacity"};
    }

    accepted_ = true;
    deadline_.stop();
    error_.clear();
    emit errorChanged();
    emit connected();

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
  error_ = message;
  accepted_ = false;
  socket_.abort();
  deadline_.stop();
  emit errorChanged();
  emit disconnected();

  if (!closed_) {
    retry_.start();
  }
}

}
