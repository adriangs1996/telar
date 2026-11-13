#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../application/dependencies.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include "../qt/remote_bridge.hpp"
#include "../qt/runtime_connection.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <chrono>
#include <limits>
#include <QByteArray>
#include <QByteArrayView>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QLocalServer>
#include <QString>
#include <QStringLiteral>
#include <QTemporaryDir>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qstring.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <memory>
#include <vector>

#include "application/dependencies.hpp"
#include "remote_bridge.hpp"
#include "runtime_connection.hpp"


import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.client;
import telar.gui.transport.runtime_link;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;

class RemoteConnectionTest : public QObject {
  Q_OBJECT

private:
  template <typename Message>
  static QByteArray framedMessage(const Message &message) {
    std::vector<Byte> storage(Codec::encodedSize(message));
    const auto payload = textView(Codec::encode(message, storage));
    std::array<Byte, frame_prefix_size> prefix{};
    std::span<Byte> output{prefix};
    u32::encode(static_cast<std::uint32_t>(payload.size()), output);
    const auto prefix_text = textView(std::span<const Byte>{prefix});
    QByteArray result{prefix_text.data(), static_cast<qsizetype>(prefix_text.size())};
    result.append(payload.data(), static_cast<qsizetype>(payload.size()));

    return result;
  }

  static QByteArray readWithoutSenderEvents(QLocalSocket &peer, qsizetype expected) {
    constexpr int read_timeout_ms = 100;
    QElapsedTimer elapsed;
    elapsed.start();
    QByteArray received;
    while (received.size() < expected) {
      received.append(peer.readAll());
      const auto remaining = read_timeout_ms - elapsed.elapsed();
      if (received.size() >= expected || remaining <= 0 || !peer.waitForReadyRead(static_cast<int>(remaining))) {
        break;
      }
    }

    return received;
  }

  static qsizetype receiveAvailable(QLocalSocket &peer, QByteArray &received) {
    received.append(peer.readAll());

    return received.size();
  }

  Q_SLOT static void openingPaneFlushesTheCompleteOrderedRequest() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("open-flush.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> peer{listener.nextPendingConnection()};
    QVERIFY(peer != nullptr);
    const auto hello = framedHello(handshake::schema_id);
    QTRY_COMPARE(peer->bytesAvailable(), hello.size());
    QCOMPARE(peer->readAll(), hello);
    QVERIFY(sendHandshake(*peer, ServerAccept{handshake::schema_id}));
    QTRY_VERIFY(connection.ready());

    const DetachPane detach{.pane_id = 6};
    const OpenPane open{.request_id = 1, .target = {.kind = PaneTarget::Kind::pane, .id = 7}, .size = {.cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0}};
    const auto expected = framedMessage(detach) + framedMessage(open);
    connection.send(detach);
    QVERIFY(readWithoutSenderEvents(*peer, framedMessage(detach).size()).isEmpty());
    connection.send(open);
    QCOMPARE(readWithoutSenderEvents(*peer, expected.size()), expected);

    constexpr std::array<Byte, 3> bytes{'o', 'k', '\n'};
    const PaneInput input{.pane_id = 7, .bytes = bytes};
    connection.send(input);
    QTRY_COMPARE(peer->bytesAvailable(), framedMessage(input).size());
    QCOMPARE(peer->readAll(), framedMessage(input));
    QVERIFY(connection.ready());
    QVERIFY(connection.error().isEmpty());
  }

  Q_SLOT static void openingPanePreservesBackpressureAndByteOrder() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("pressure.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> peer{listener.nextPendingConnection()};
    QVERIFY(peer != nullptr);
    const auto hello = framedHello(handshake::schema_id);
    QTRY_COMPARE(peer->bytesAvailable(), hello.size());
    QCOMPARE(peer->readAll(), hello);
    QVERIFY(sendHandshake(*peer, ServerAccept{handshake::schema_id}));
    QTRY_VERIFY(connection.ready());

    constexpr std::size_t chunk_size = 65'536;
    constexpr std::size_t maximum_chunks = 4 * static_cast<std::size_t>(RuntimeConnection::output_limit) / chunk_size;
    const std::vector<Byte> bytes(chunk_size, 'x');
    const PaneInput input{.pane_id = 7, .bytes = bytes};
    constexpr OpenPane initial_open{.request_id = 1, .target = {.kind = PaneTarget::Kind::pane, .id = 7}, .size = {.cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0}};
    auto open = initial_open;
    const auto chunk = framedMessage(input);
    QByteArray expected;
    bool limited = false;
    QElapsedTimer elapsed;
    elapsed.start();
    for (std::size_t index = 0; index < maximum_chunks; ++index) {
      try {
        connection.send(input);
        expected.append(chunk);
        open.request_id = index + 1;
        connection.send(open);
        expected.append(framedMessage(open));
      } catch (const std::length_error &) {
        limited = true;
        break;
      }
    }
    constexpr int nonblocking_timeout_ms = 2000;
    QVERIFY(elapsed.elapsed() < nonblocking_timeout_ms);
    QVERIFY(limited);
    QVERIFY(!expected.isEmpty());
    QVERIFY(connection.ready());

    QByteArray received;
    constexpr int drain_timeout_ms = 5000;
    QTRY_COMPARE_WITH_TIMEOUT(receiveAvailable(*peer, received), expected.size(), drain_timeout_ms);
    QCOMPARE(received, expected);
    connection.send(open);
    const auto recovery = framedMessage(open);
    QCOMPARE(readWithoutSenderEvents(*peer, recovery.size()), recovery);
    QVERIFY(connection.error().isEmpty());
  }

  Q_SLOT static void resumedSessionDiscardsThePreviousReadTail() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("resume.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    std::vector<QByteArray> delivered;
    QObject::connect(&connection, &RuntimeConnection::payloadReceived, &connection, [&](QByteArrayView payload) {
      delivered.push_back(payload.toByteArray());
      if (delivered.size() == 1) {
        connection.finishSession();
        connection.resumeSession();
      }
    });
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> peer{listener.nextPendingConnection()};
    QVERIFY(peer != nullptr);
    QVERIFY(sendHandshake(*peer, ServerAccept{handshake::schema_id}));
    QVERIFY(sendPayload(*peer, QByteArrayLiteral("FINISHED")));
    QVERIFY(sendPayload(*peer, QByteArrayLiteral("PREVIOUS_SESSION_TAIL")));
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> replacement{listener.nextPendingConnection()};
    QVERIFY(replacement != nullptr);
    QVERIFY(sendHandshake(*replacement, ServerAccept{handshake::schema_id}));
    QVERIFY(sendPayload(*replacement, QByteArrayLiteral("REPLACEMENT_SESSION")));
    constexpr int before_retry_ms = RuntimeLink::first_retry_ms / 2;
    QTRY_VERIFY_WITH_TIMEOUT(connection.ready(), before_retry_ms);
    QTRY_COMPARE_WITH_TIMEOUT(delivered.size(), 2, before_retry_ms);
    QCOMPARE(delivered.front(), QByteArrayLiteral("FINISHED"));
    QCOMPARE(delivered.back(), QByteArrayLiteral("REPLACEMENT_SESSION"));
    QVERIFY(connection.error().isEmpty());
    QCOMPARE(connection.link().sessions, 2);
  }

  Q_SLOT static void emptyHandshakePrefixKeepsOriginalError() {
    verifyHandshakePrefix(0, QStringLiteral("InvalidLength"));
  }

  Q_SLOT static void oversizedHandshakePrefixFailsBeforeItsBody() {
    verifyHandshakePrefix(static_cast<quint32>(HandshakeCodec::max_message_size + 1), QStringLiteral("BufferTooSmall"));
  }

  Q_SLOT static void oversizedTransportPrefixKeepsOriginalError() {
    verifyHandshakePrefix(static_cast<quint32>(max_payload_size + 1), QStringLiteral("FrameTooLarge"));
  }

  static void verifyHandshakePrefix(quint32 length, const QString &detail) {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("prefix.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> peer{listener.nextPendingConnection()};
    QVERIFY(peer != nullptr);
    std::array<Byte, frame_prefix_size> prefix{};
    std::span<Byte> output{prefix};
    u32::encode(length, output);
    const auto bytes = textView(std::span<const Byte>{prefix});
    QCOMPARE(peer->write(bytes.data(), static_cast<qint64>(bytes.size())), static_cast<qint64>(bytes.size()));
    constexpr int before_retry_ms = RuntimeLink::first_retry_ms / 2;
    QTRY_COMPARE_WITH_TIMEOUT(connection.error(), detail, before_retry_ms);
    QCOMPARE(connection.link().phase, MachinePhase::lost);
  }

  Q_SLOT static void incompatibleRuntimeWaitsForExplicitRetry() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("schema.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> peer{listener.nextPendingConnection()};
    QVERIFY(peer != nullptr);
    constexpr SchemaId other_schema{'0', '0', '0', '0', '0', '0', '0', '0'};
    QVERIFY(sendHandshake(*peer, ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = other_schema}));
    QTRY_COMPARE(connection.link().phase, MachinePhase::failed);
    QCOMPARE(connection.remoteError(), std::optional{MachineError::incompatible_schema});
    const auto schema = QString::fromLatin1(textView(handshake::schema_id).data(), static_cast<qsizetype>(handshake::schema_id.size()));
    QCOMPARE(connection.error(), QStringLiteral("the runtime speaks wire schema 00000000; this telar speaks %1. Update telar on one side").arg(schema));
    constexpr int observe_retry_ms = RuntimeLink::first_retry_ms * 2;
    QTest::qWait(observe_retry_ms);
    QVERIFY(!listener.hasPendingConnections());
    connection.retryNow();
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> replacement{listener.nextPendingConnection()};
    QVERIFY(replacement != nullptr);
    QVERIFY(sendHandshake(*replacement, ServerAccept{handshake::schema_id}));
    QTRY_VERIFY(connection.ready());
    QVERIFY(!connection.link().failure());
  }

  Q_SLOT static void auditedLegacyRefusalRetriesOnANewConnection() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("legacy.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    std::vector<QByteArray> delivered;
    QObject::connect(&connection, &RuntimeConnection::payloadReceived, &connection, [&](QByteArrayView payload) {
      delivered.push_back(payload.toByteArray());
    });
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> first{listener.nextPendingConnection()};
    QVERIFY(first != nullptr);
    const auto current_hello = framedHello(handshake::schema_id);
    QTRY_COMPARE(first->bytesAvailable(), current_hello.size());
    QCOMPARE(first->readAll(), current_hello);
    QVERIFY(sendHandshake(*first, ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = RuntimeProtocol::schema87}));
    QVERIFY(sendPayload(*first, QByteArrayLiteral("OLD_CONNECTION_TAIL")));
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> legacy{listener.nextPendingConnection()};
    QVERIFY(legacy != nullptr);
    const auto legacy_hello = framedHello(RuntimeProtocol::schema87);
    QTRY_COMPARE(legacy->bytesAvailable(), legacy_hello.size());
    QCOMPARE(legacy->readAll(), legacy_hello);
    QVERIFY(sendHandshake(*legacy, ServerAccept{RuntimeProtocol::schema87}));
    QVERIFY(sendPayload(*legacy, QByteArrayLiteral("CURRENT_LEGACY_DATA")));
    QTRY_VERIFY(connection.ready());
    QTRY_COMPARE(delivered.size(), std::size_t{1});
    QCOMPARE(delivered.front(), QByteArrayLiteral("CURRENT_LEGACY_DATA"));
    QVERIFY(connection.error().isEmpty());
    QCOMPARE(connection.link().sessions, 1);
    const HoldTab hold{.request_id = 1, .location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1}, .held = true};
    std::vector<Byte> storage(Codec::encodedSize(hold));
    QVERIFY(!Codec::encode(hold, storage).empty());
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, connection.send(hold));
    QVERIFY(connection.ready());
    const ReportLimit report{.reach = {.name = "legacy.limit", .noun = "cells", .value = 1, .requested = 2, .route = "gui"}, .hits = 1};
    connection.send(report);
    QTRY_VERIFY(legacy->bytesAvailable() > 0);
    const auto traffic = legacy->readAll();
    storage.resize(Codec::encodedSize(report));
    const auto encoded = textView(Codec::encode(report, storage));
    QCOMPARE(traffic.sliced(static_cast<qsizetype>(frame_prefix_size)), QByteArray(encoded.data(), static_cast<qsizetype>(encoded.size())));
  }

  Q_SLOT static void auditedFallbackCannotAlternateSchemasForever() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("alternating.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> first{listener.nextPendingConnection()};
    QVERIFY(first != nullptr);
    QVERIFY(sendHandshake(*first, ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = RuntimeProtocol::schema87}));
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> second{listener.nextPendingConnection()};
    QVERIFY(second != nullptr);
    QTRY_VERIFY(second->bytesAvailable() > 0);
    QVERIFY(sendHandshake(*second, ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = handshake::schema_id}));
    QTRY_COMPARE(connection.link().phase, MachinePhase::failed);
    QCOMPARE(connection.remoteError(), std::optional{MachineError::incompatible_schema});
    constexpr int observe_retry_ms = RuntimeLink::first_retry_ms * 2;
    QTest::qWait(observe_retry_ms);
    QVERIFY(!listener.hasPendingConnections());
    QVERIFY(!connection.ready());
  }

  static QByteArray framedHello(const SchemaId &schema) {
    const auto payload = HandshakeCodec::encode(ClientHello{.schema = schema});
    std::array<Byte, frame_prefix_size> prefix{};
    std::span<Byte> output{prefix};
    u32::encode(static_cast<std::uint32_t>(payload.size()), output);
    const auto prefix_text = textView(std::span<const Byte>{prefix});
    const auto body = textView(std::span<const Byte>{payload});
    QByteArray result{prefix_text.data(), static_cast<qsizetype>(prefix_text.size())};
    result.append(body.data(), static_cast<qsizetype>(body.size()));

    return result;
  }

  Q_SLOT static void acceptedRuntimeCanPipelineLargerFrames() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("pipeline.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    QByteArray received;
    QObject::connect(&connection, &RuntimeConnection::payloadReceived, &connection, [&](QByteArrayView payload) {
      received = payload.toByteArray();
    });
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> peer{listener.nextPendingConnection()};
    QVERIFY(peer != nullptr);
    constexpr qsizetype payload_bytes = qsizetype{20} * 1024;
    const QByteArray payload{payload_bytes, 'U'};
    QVERIFY(sendHandshake(*peer, ServerAccept{handshake::schema_id}));
    QVERIFY(sendPayload(*peer, payload));
    QTRY_VERIFY(connection.ready());
    QTRY_COMPARE(received, payload);
  }

  Q_SLOT static void clientCapacityRefusalKeepsAutomaticRetry() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("capacity.sock"))));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> peer{listener.nextPendingConnection()};
    QVERIFY(peer != nullptr);
    QVERIFY(sendHandshake(*peer, ServerReject{.reason = HandshakeRejectReason::client_limit_reached, .expected_schema = handshake::schema_id}));
    QTRY_COMPARE(connection.link().phase, MachinePhase::lost);
    QCOMPARE(connection.error(), QStringLiteral("clients.max_clients: the runtime holds its limit of 32 clients (windows, CLI calls and agent hooks); close a window or retry once running commands finish"));
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> replacement{listener.nextPendingConnection()};
    QVERIFY(replacement != nullptr);
    QVERIFY(sendHandshake(*replacement, ServerAccept{handshake::schema_id}));
    QTRY_VERIFY(connection.ready());
    QCOMPARE(connection.link().attempt, 1);
  }

  template <typename Reply>
  static bool sendHandshake(QLocalSocket &peer, const Reply &reply) {
    const auto payload = HandshakeCodec::encode(reply);
    const auto bytes = textView(std::span<const Byte>{payload});

    return sendPayload(peer, QByteArrayView{bytes.data(), static_cast<qsizetype>(bytes.size())});
  }

  static bool sendPayload(QLocalSocket &peer, QByteArrayView payload) {
    std::array<Byte, frame_prefix_size> prefix{};
    std::span<Byte> output{prefix};
    u32::encode(static_cast<std::uint32_t>(payload.size()), output);

    const auto prefix_text = textView(std::span<const Byte>{prefix});

    return peer.write(prefix_text.data(), static_cast<qint64>(prefix_text.size())) == static_cast<qint64>(prefix_text.size()) && peer.write(payload.data(), payload.size()) == payload.size();
  }

  Q_SLOT static void retryBackoffKeepsAnInProgressHandshake() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    QElapsedTimer elapsed;
    elapsed.start();

    struct Attempt {
      std::uint16_t number;
      qint64 started_ms;
    };

    std::vector<Attempt> attempts;
    QObject::connect(&connection, &RuntimeConnection::linkChanged, &connection, [&] {
      const auto &link = connection.link();
      if (link.phase == MachinePhase::lost && (attempts.empty() || attempts.back().number != link.attempt)) {
        attempts.push_back({.number = link.attempt, .started_ms = elapsed.elapsed()});
      }
    });
    connection.open(directory.filePath(QStringLiteral("missing.sock")));
    QTRY_COMPARE(connection.link().phase, MachinePhase::lost);
    QTRY_COMPARE(connection.link().attempt, 2);
    QCOMPARE(attempts.size(), std::size_t{3});
    constexpr qint64 earliest_first_ms = (qint64{RuntimeLink::first_retry_ms} * 9) / 10;
    QVERIFY(attempts[1].started_ms - attempts[0].started_ms >= earliest_first_ms);
    QVERIFY(attempts[2].started_ms - attempts[1].started_ms >= earliest_first_ms * 2);

    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("waiting.sock"))));
    const auto attempt = connection.link().attempt;
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> peer{listener.nextPendingConnection()};
    QVERIFY(peer != nullptr);
    QTRY_VERIFY(peer->bytesAvailable() > 0);
    connection.retryNow();
    constexpr int observe_handshake_ms = RuntimeLink::first_retry_ms * 2;
    QTest::qWait(observe_handshake_ms);
    QCOMPARE(connection.link().phase, MachinePhase::connecting);
    QCOMPARE(connection.link().attempt, attempt);
    QVERIFY(!listener.hasPendingConnections());
    QVERIFY(connection.error().isEmpty());
  }

  Q_SLOT static void explicitRetryFromFailureDoesNotArmAnOlderTimer() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    QLocalServer listener;
    QVERIFY(listener.listen(directory.filePath(QStringLiteral("waiting.sock"))));
    connection.open(listener.fullServerName());
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> first{listener.nextPendingConnection()};
    QVERIFY(first != nullptr);
    std::size_t failures = 0;
    QObject::connect(&connection, &RuntimeConnection::disconnected, &connection, [&] {
      ++failures;
      connection.retryNow();
    });
    connection.recover("fixture failure");
    QTRY_VERIFY(listener.hasPendingConnections());
    const std::unique_ptr<QLocalSocket> second{listener.nextPendingConnection()};
    QVERIFY(second != nullptr);
    QTRY_VERIFY(second->bytesAvailable() > 0);
    constexpr int observe_handshake_ms = RuntimeLink::first_retry_ms * 2;
    QTest::qWait(observe_handshake_ms);
    QCOMPARE(failures, std::size_t{1});
    QCOMPARE(connection.link().phase, MachinePhase::connecting);
    QCOMPARE(connection.link().attempt, 0);
    QCOMPARE(connection.link().failure(), std::optional<std::string_view>{"fixture failure"});
    QVERIFY(!listener.hasPendingConnections());
  }

  Q_SLOT static void framedSshTransportUsesTheAuditedDiscoverySchema() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QVERIFY(QFile::link(QCoreApplication::applicationDirPath() + QStringLiteral("/gui-ssh-runtime-fixture"), directory.filePath(QStringLiteral("ssh"))));
    const auto previous_path = qgetenv("PATH");
    const auto restore_path = qScopeGuard([&] { qputenv("PATH", previous_path); });
    qputenv("PATH", directory.path().toUtf8() + ":" + previous_path);
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    QByteArray received;
    QObject::connect(&connection, &RuntimeConnection::payloadReceived, &connection, [&](QByteArrayView payload) { received = payload.toByteArray(); });
    connection.openRemote({.destination = QStringLiteral("legacy"), .program = {}, .local_endpoint = directory.filePath(QStringLiteral("runtime.sock"))});
    QTRY_VERIFY2(connection.ready(), qPrintable(connection.error()));
    QCOMPARE(connection.schema(), RuntimeProtocol::schema87);
    const ReportLimit report{.reach = {.name = "legacy.ssh", .noun = "cells", .value = 1, .requested = 2, .route = "gui"}, .hits = 1};
    connection.send(report);
    QTRY_VERIFY(!received.isEmpty());
    std::vector<Byte> storage(Codec::encodedSize(report));
    const auto expected = textView(Codec::encode(report, storage));
    QCOMPARE(received, QByteArray(expected.data(), static_cast<qsizetype>(expected.size())));
    QVERIFY(connection.error().isEmpty());
    connection.close();
  }

  Q_SLOT static void framedSshTransportAndPermanentFailure() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QVERIFY(QFile::link(QCoreApplication::applicationDirPath() + QStringLiteral("/gui-ssh-runtime-fixture"), directory.filePath(QStringLiteral("ssh"))));
    const auto previous_path = qgetenv("PATH");
    const auto restore = qScopeGuard([previous_path] {
      static_cast<void>(qputenv("PATH", previous_path));
    });
    QVERIFY(qputenv("PATH", directory.path().toUtf8()));
    ApplicationAllocator memory;
    RuntimeConnection connection{memory};
    std::size_t handshakes = 0;
    std::size_t disconnects = 0;
    QByteArray received;
    QByteArray home;
    QStringList errors;
    QObject::connect(&connection, &RuntimeConnection::errorChanged, &connection, [&] {
      errors.append(connection.error());
    });
    QObject::connect(&connection, &RuntimeConnection::connected, &connection, [&] {
      ++handshakes;
    });
    QObject::connect(&connection, &RuntimeConnection::disconnected, &connection, [&] {
      ++disconnects;
    });
    QObject::connect(&connection, &RuntimeConnection::discovered, &connection, [&](const RemoteDiscovery &discovery) {
      const auto remote_home = discovery.home();
      home = QByteArray{remote_home.data(), static_cast<qsizetype>(remote_home.size())};
    });
    QObject::connect(&connection, &RuntimeConnection::payloadReceived, &connection, [&](QByteArrayView payload) {
      received = payload.toByteArray();
    });
    connection.openRemote({.destination = QStringLiteral("remote"), .program = {}, .local_endpoint = directory.filePath(QStringLiteral("runtime.sock"))});
    QTRY_VERIFY2(connection.ready(), qPrintable(errors.join(QStringLiteral("; "))));
    QCOMPARE(handshakes, std::size_t{1});
    QCOMPARE(home, QByteArray{"/home/remote"});
    const ReportLimit report{.reach = {.name = "fixture.limit", .noun = "cells", .value = 1, .requested = 2, .route = "gui"}, .hits = 1};
    connection.send(report);
    QTRY_VERIFY(!received.isEmpty());
    std::vector<Byte> storage(Codec::encodedSize(report));
    const auto expected = textView(Codec::encode(report, storage));
    QCOMPARE(received, QByteArray(expected.data(), static_cast<qsizetype>(expected.size())));
    connection.close();
    QVERIFY(!connection.ready());
    connection.openRemote({.destination = QStringLiteral("denied"), .program = {}, .local_endpoint = directory.filePath(QStringLiteral("runtime.sock"))});
    QTRY_VERIFY(connection.remoteError().has_value());
    QCOMPARE(connection.remoteError(), std::optional{MachineError::authentication_failed});
    QVERIFY(connection.error().contains(QStringLiteral("Permission denied")));
    QCOMPARE(disconnects, std::size_t{1});
    constexpr int beyond_retry_ms = (RuntimeLink::first_retry_ms * 2) + 100;
    QTest::qWait(beyond_retry_ms);
    QCOMPARE(disconnects, std::size_t{1});
    QCOMPARE(handshakes, std::size_t{1});
    QVERIFY(!connection.ready());
    connection.retryNow();
    QTRY_COMPARE(disconnects, std::size_t{2});
    QCOMPARE(connection.link().phase, MachinePhase::failed);
    QCOMPARE(connection.link().attempt, 0);
    connection.remoteFailed(MachineError::authentication_failed, "\xff");
    QCOMPARE(connection.link().phase, MachinePhase::failed);
    QVERIFY(!connection.link().failure());
    QVERIFY(connection.error().isEmpty());
  }
};

}

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  RemoteConnectionTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "remote_connection_test.moc"
