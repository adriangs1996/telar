#include "agent_report_fixture.hpp"
#include "application/dependencies.hpp"
#include "qt/runtime_connection.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <QByteArrayView>
#include <QCoreApplication>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QSocketNotifier>
#include <QtCore/qtypes.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

enum class Argument : std::uint8_t {
  executable,
  mode,
  socket,
  pane,
  generation,
  count,
};

enum class Request : std::uint8_t {
  verify = 1,
  report,
};

constexpr int timeout_ms = 5000;
constexpr std::size_t response_capacity = 1024;

bool consume(telar::gui::qt::RuntimeConnection &connection, const telar::ReportAgent &report, QByteArrayView payload) {
  try {
    std::array<telar::Byte, response_capacity> bytes{};
    telar::DecodeStorage storage{bytes};
    const auto message = telar::byteView({payload.data(), static_cast<std::size_t>(payload.size())});
    if (message.front() == static_cast<telar::Byte>(telar::ServerTag::request_failed)) {
      throw std::runtime_error{std::string{telar::Codec::decode<telar::RequestFailed>(message, storage).message}};
    }

    if (message.front() != static_cast<telar::Byte>(telar::ServerTag::request_completed)) {
      return false;
    }

    const auto completed = telar::Codec::decode<telar::RequestCompleted>(message, storage);
    if (completed.request_id == static_cast<std::uint64_t>(Request::verify)) {
      connection.send(report);
    } else if (completed.request_id == report.request_id) {
      if (!report.event.empty()) {
        std::cout << report.event << '\n' << std::flush;
      }

      return true;
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    QCoreApplication::exit(1);
  }

  return false;
}

}

int telar::gui::test::runAgentReportFixture(int &argc, char **argv) {
  const QCoreApplication application{argc, argv};
  const auto arguments = QCoreApplication::arguments();
  if (arguments.size() != static_cast<qsizetype>(Argument::count)) {
    return 1;
  }

  bool valid_pane = false;
  bool valid_generation = false;
  const auto pane = arguments[static_cast<qsizetype>(Argument::pane)].toULongLong(&valid_pane);
  const auto generation = arguments[static_cast<qsizetype>(Argument::generation)].toULongLong(&valid_generation);
  if (!valid_pane || !valid_generation || pane == 0 || generation == 0) {
    return 1;
  }

  ApplicationAllocator memory;
  qt::RuntimeConnection connection{memory};
  QTimer deadline;
  deadline.setSingleShot(true);
  ReportAgent report{.request_id = static_cast<std::uint64_t>(Request::report), .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::claude, .state = AgentReportState::blocked, .session = "gui-attention", .blocked_reason = AgentBlockedReason::question, .event = "GUI_ATTENTION_READY"};
  QSocketNotifier input{0, QSocketNotifier::Read};
  QObject callbacks;
  QObject::connect(&input, &QSocketNotifier::activated, &callbacks, [&] {
    std::string command;
    if (!std::getline(std::cin, command)) {
      QCoreApplication::quit();
      return;
    }
    if (command != "ready" && command != "question") {
      return;
    }
    ++report.request_id;
    report.state = command == "ready" ? AgentReportState::ready : AgentReportState::blocked;
    report.blocked_reason = command == "ready" ? AgentBlockedReason::none : AgentBlockedReason::question;
    report.event = {};
    deadline.start(timeout_ms);
    connection.send(report);
  });
  QObject::connect(&connection, &qt::RuntimeConnection::connected, &callbacks, [&] {
    connection.send(VerifyPaneDescent{.request_id = static_cast<std::uint64_t>(Request::verify), .pane_id = pane, .pane_generation = generation});
  });
  QObject::connect(&connection, &qt::RuntimeConnection::payloadReceived, &callbacks, [&](QByteArrayView payload) {
    if (consume(connection, report, payload)) {
      deadline.stop();
    }
  });
  QObject::connect(&connection, &qt::RuntimeConnection::errorChanged, &callbacks, [&] {
    if (!connection.error().isEmpty()) {
      std::cerr << connection.error().toStdString() << '\n';
      QCoreApplication::exit(1);
    }
  });
  QObject::connect(&deadline, &QTimer::timeout, &callbacks, [] {
    QCoreApplication::exit(1);
  });
  deadline.start(timeout_ms);
  connection.open(arguments[static_cast<qsizetype>(Argument::socket)]);

  return QCoreApplication::exec();
}
