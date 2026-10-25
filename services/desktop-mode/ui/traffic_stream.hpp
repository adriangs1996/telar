#pragma once

#include "lua_value.hpp"
#include "../../runtime-cpp/traffic/protocol.hpp"
#include <QByteArray>
#include <QLocalSocket>
#include <QObject>
#include <functional>

namespace ui {

class TrafficStream final : public QObject {
public:
  struct Subscription {
    QString endpoint;
    std::string filter;
    telar::runtime::traffic::Selection selection = telar::runtime::traffic::Selection::packets;
  };

  using Consumer = std::function<void(lua::Value)>;
  using Failure = std::function<void(std::string)>;

  TrafficStream(Subscription subscription, Consumer consumer, Failure failure, QObject *parent = nullptr);
  void stop();

private:
  void drain();
  void fail(std::string message);

  QLocalSocket socket_;
  QByteArray greeting_;
  QByteArray input_;
  Consumer consumer_;
  Failure failure_;
  std::uint64_t dropped_ = 0;
  std::size_t expected_ = 0;
  bool stopped_ = false;
};

}
