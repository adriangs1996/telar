#include "traffic_stream.hpp"
#include "../../runtime-cpp/traffic/protocol.hpp"
#include "../../runtime-cpp/plugins/protocol.hpp"
#include <QTimer>
#include <sys/socket.h>
#include <unistd.h>

namespace ui {
namespace {
  namespace traffic = telar::runtime::traffic;

  lua::Value halfValue(const std::optional<telar::runtime::plugins::HalfView> &half) {
    if (!half) {
      return {};
    }
    const std::string_view head{reinterpret_cast<const char *>(half->head.data()), half->head.size()};
    lua::Value::Array fields;
    auto remaining = head;
    while (!remaining.empty()) {
      const auto end = remaining.find("\r\n");
      const auto line = remaining.substr(0, end);
      const auto colon = line.find(':', line.starts_with(':') ? 1 : 0);
      if (colon != std::string_view::npos) {
        auto value = line.substr(colon + 1);
        const auto first = value.find_first_not_of(" \t");
        value = first == std::string_view::npos ? std::string_view{} : value.substr(first);
        fields.push_back(lua::Value{lua::Value::Object{
            {"name", lua::Value{std::string{line.substr(0, colon)}}},
            {"value", lua::Value{std::string{value}}},
        }});
      }
      if (end == std::string_view::npos) {
        break;
      }
      remaining.remove_prefix(end + 2);
    }

    constexpr std::array outcomes{"finished", "failed", "reset"};
    return lua::Value{lua::Value::Object{
        {"head", lua::Value{lua::Value::Object{{"raw", lua::Value{std::string{head}}}, {"fields", lua::Value{std::move(fields)}}}}},
        {"body", lua::Value{std::string{reinterpret_cast<const char *>(half->body.data()), half->body.size()}}},
        {"head_truncated", lua::Value{half->head_truncated}},
        {"body_truncated", lua::Value{half->body_truncated}},
        {"body_encoding", lua::Value{std::string{half->encoding}}},
        {"body_decoded", lua::Value{half->decoded}},
        {"status", lua::Value{static_cast<double>(half->status_code)}},
        {"outcome", lua::Value{std::string{outcomes[static_cast<std::size_t>(half->outcome)]}}},
        {"finished_at_ms", lua::Value{static_cast<double>(half->finished_at_ms)}},
    }};
  }

  lua::Value eventValue(const traffic::Event &event, std::uint64_t dropped) {
    lua::Value::Object result{
        {"kind", lua::Value{std::string{traffic::Protocol::name(event.kind)}}},
        {"session_id", lua::Value{std::to_string(event.session)}},
        {"sequence", lua::Value{std::to_string(event.sequence)}},
        {"timestamp_us", lua::Value{static_cast<double>(event.timestamp_us)}},
        {"interface", lua::Value{std::string{event.interface}}},
        {"interface_index", lua::Value{static_cast<double>(event.interface_index)}},
        {"link_type", lua::Value{static_cast<double>(event.link_type)}},
        {"original_bytes", lua::Value{static_cast<double>(event.original_bytes)}},
        {"captured_bytes", lua::Value{static_cast<double>(event.bytes.size())}},
        {"truncated", lua::Value{event.kind == traffic::Kind::packet && event.bytes.size() < event.original_bytes}},
        {"bytes", lua::Value{event.kind == traffic::Kind::exchange ? std::string{} : std::string{reinterpret_cast<const char *>(event.bytes.data()), event.bytes.size()}}},
        {"offline", lua::Value{event.offline}},
        {"subscriber_drops", lua::Value{std::to_string(dropped)}},
        {"kernel_drops", lua::Value{std::to_string(event.kernel_drops)}},
        {"capture_drops", lua::Value{std::to_string(event.capture_drops)}},
        {"runtime_drops", lua::Value{std::to_string(event.runtime_drops)}},
        {"visibility", lua::Value{std::string{event.kind == traffic::Kind::exchange ? "plaintext" : "wire"}}},
    };
    if (event.kind == traffic::Kind::exchange) {
      const auto exchange = telar::runtime::plugins::Protocol::decodeExchange(event.bytes);
      constexpr std::array protocols{"http11", "h2", "upgraded"};
      result.emplace("exchange", lua::Value{lua::Value::Object{
          {"id", lua::Value{std::to_string(exchange.identity.id)}},
          {"connection_id", lua::Value{std::to_string(exchange.key.connection)}},
          {"stream_id", lua::Value{static_cast<double>(exchange.key.stream)}},
          {"host", lua::Value{std::string{exchange.host}}},
          {"method", lua::Value{std::string{exchange.method}}},
          {"target", lua::Value{std::string{exchange.target}}},
          {"protocol", lua::Value{std::string{protocols[static_cast<std::size_t>(exchange.protocol)]}}},
          {"started_at_ms", lua::Value{static_cast<double>(exchange.started_at_ms)}},
          {"request", halfValue(exchange.request)},
          {"response", halfValue(exchange.response)},
      }});
    }
    return lua::Value{std::move(result)};
  }
}

TrafficStream::TrafficStream(Subscription subscription, Consumer consumer, Failure failure, QObject *parent)
    : QObject(parent), consumer_(std::move(consumer)), failure_(std::move(failure)), expected_(traffic::Protocol::prefix_bytes) {
  std::array<telar::Byte, traffic::Protocol::greeting_bytes + traffic::Limits::filter_bytes> bytes;
  const auto greeting = traffic::Protocol::greeting(bytes, traffic::Role::subscribe, subscription.filter, subscription.selection);
  greeting_ = QByteArray{reinterpret_cast<const char *>(greeting.data()), static_cast<qsizetype>(greeting.size())};
  socket_.setReadBufferSize(traffic::Limits::frame_bytes + traffic::Protocol::prefix_bytes);
  connect(&socket_, &QLocalSocket::connected, this, [this] {
#ifdef __APPLE__
    uid_t uid;
    gid_t gid;
    const bool authorized = ::getpeereid(static_cast<int>(socket_.socketDescriptor()), &uid, &gid) == 0 && uid == ::geteuid();
#else
    ucred credentials{};
    socklen_t size = sizeof(credentials);
    const bool authorized = ::getsockopt(static_cast<int>(socket_.socketDescriptor()), SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0 && credentials.uid == ::geteuid();
#endif
    if (!authorized) {
      fail("Traffic runtime identity does not match the user");
      return;
    }
    socket_.write(greeting_);
    greeting_.clear();
  });
  connect(&socket_, &QLocalSocket::readyRead, this, [this] { drain(); });
  connect(&socket_, &QLocalSocket::disconnected, this, [this] { fail("Traffic runtime disconnected"); });
  connect(&socket_, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError) { fail(socket_.errorString().toStdString()); });
  QTimer::singleShot(0, this, [this, endpoint = std::move(subscription.endpoint)] {
    if (!stopped_) {
      socket_.connectToServer(endpoint);
    }
  });
}

void TrafficStream::stop() {
  stopped_ = true;
  socket_.abort();
  input_.fill('\0');
  input_.clear();
}

void TrafficStream::fail(std::string message) {
  if (stopped_) {
    return;
  }
  stop();
  failure_(std::move(message));
}

void TrafficStream::drain() {
  constexpr std::size_t events_per_turn = 32;
  try {
    for (std::size_t event = 0; event < events_per_turn && !stopped_; ++event) {
      const auto needed = static_cast<qint64>(expected_) - input_.size();
      input_.append(socket_.read(needed));
      if (static_cast<std::size_t>(input_.size()) < expected_) {
        return;
      }

      const std::span<const telar::Byte> bytes{reinterpret_cast<const telar::Byte *>(input_.constData()), static_cast<std::size_t>(input_.size())};
      if (expected_ == traffic::Protocol::prefix_bytes) {
        telar::runtime::plugins::FrameReader reader{bytes};
        expected_ = reader.integer<std::uint32_t>();
        dropped_ = reader.integer<std::uint64_t>();
        if (expected_ <= traffic::Protocol::prefix_bytes || expected_ > traffic::Limits::frame_bytes) {
          throw std::runtime_error{"Invalid traffic frame length"};
        }
        input_.clear();
      } else {
        auto value = eventValue(traffic::Protocol::decode(bytes), dropped_);
        input_.fill('\0');
        input_.clear();
        expected_ = traffic::Protocol::prefix_bytes;
        consumer_(std::move(value));
      }
    }
    if (!stopped_ && socket_.bytesAvailable() != 0) {
      QTimer::singleShot(0, this, [this] { drain(); });
    }
  } catch (const std::exception &error) {
    fail(error.what());
  }
}

}
