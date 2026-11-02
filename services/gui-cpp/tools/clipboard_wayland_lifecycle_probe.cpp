#include "application/dependencies.hpp"
#include "platform/clipboard_image_pipe.hpp"
#include "platform/clipboard_image_source.hpp"
#include "platform/linux/wayland_clipboard_image_monitor.hpp"
#include <QCoreApplication>
#include <QFile>
#include <QIODevice>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QtCore/qtypes.h>
#include <QString>
#include <QtCore/qstringliteral.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <optional>
#include <sys/poll.h>
#include <stdexcept>
#include <string_view>
#include <unistd.h>
#include <wayland-client-core.h>
#include <wayland-client-protocol.h>

namespace {

using telar::gui::ApplicationAllocator;
using telar::gui::platform::ClipboardImageError;
using telar::gui::platform::ClipboardImageFailure;
using telar::gui::platform::ClipboardImagePipe;
using telar::gui::platform::WaylandClipboardImageMonitor;

struct Connection {
  Connection() = default;
  Connection(const Connection &) = delete;
  Connection &operator=(const Connection &) = delete;
  Connection(Connection &&) = delete;
  Connection &operator=(Connection &&) = delete;

  ~Connection() {
    if (seat != nullptr) {
      if (wl_seat_get_version(seat) >= WL_SEAT_RELEASE_SINCE_VERSION) {
        wl_seat_release(seat);
      } else {
        wl_seat_destroy(seat);
      }
    }

    if (registry != nullptr) {
      wl_registry_destroy(registry);
    }

    if (display != nullptr) {
      wl_display_disconnect(display);
    }
  }

  static void capabilities([[maybe_unused]] void *data, [[maybe_unused]] wl_seat *seat, [[maybe_unused]] std::uint32_t capabilities) {}
  static void name([[maybe_unused]] void *data, [[maybe_unused]] wl_seat *seat, [[maybe_unused]] const char *name) {}

  static void global(void *data, wl_registry *registry, std::uint32_t name, const char *interface, std::uint32_t version) {
    auto &self = *static_cast<Connection *>(data);
    if (std::string_view{interface} == "wl_seat" && self.seat == nullptr) {
      constexpr std::uint32_t supported_version = 8;
      self.seat = static_cast<wl_seat *>(wl_registry_bind(registry, name, &wl_seat_interface, std::min(version, supported_version)));
      static constexpr wl_seat_listener listener{.capabilities = capabilities, .name = Connection::name};
      wl_seat_add_listener(self.seat, &listener, &self);
    }
  }

  static void removed([[maybe_unused]] void *data, [[maybe_unused]] wl_registry *registry, [[maybe_unused]] std::uint32_t name) {}

  void connect() {
    display = wl_display_connect(nullptr);
    if (display == nullptr) {
      throw std::runtime_error{"OwnedWaylandDisplayUnavailable"};
    }

    registry = wl_display_get_registry(display);
    static constexpr wl_registry_listener listener{.global = global, .global_remove = removed};
    wl_registry_add_listener(registry, &listener, this);
    settle();
  }

  void settle() const {
    constexpr unsigned rounds = 3;
    for (unsigned round = 0; round < rounds; ++round) {
      if (wl_display_roundtrip(display) < 0) {
        throw std::runtime_error{"OwnedWaylandRoundTripFailed"};
      }
    }
  }

  void command(std::string_view value) const {
    if (::write(STDIN_FILENO, value.data(), value.size()) != static_cast<ssize_t>(value.size())) {
      throw std::runtime_error{"OwnedControlWriteFailed"};
    }

    pollfd incoming{.fd = STDIN_FILENO, .events = POLLIN, .revents = 0};
    constexpr int timeout_ms = 5000;
    char acknowledgment = 0;
    if (::poll(&incoming, 1, timeout_ms) != 1 || ::read(STDIN_FILENO, &acknowledgment, 1) != 1 || acknowledgment != 'K') {
      throw std::runtime_error{"OwnedControlReadFailed"};
    }

    settle();
  }

  wl_display *display = nullptr;
  wl_registry *registry = nullptr;
  wl_seat *seat = nullptr;
};

std::uint32_t readGeneration(ApplicationAllocator &memory, int descriptor) {
  const auto bytes = ClipboardImagePipe::read(memory, descriptor);
  if (bytes.size() != sizeof(std::uint32_t)) {
    throw std::runtime_error{"UnexpectedTransferSize"};
  }

  std::uint32_t generation = 0;
  std::memcpy(&generation, bytes.view().data(), sizeof(generation));

  return generation;
}

void observe(QJsonArray &rows, WaylandClipboardImageMonitor &monitor, ApplicationAllocator &memory, const QString &name, std::optional<std::uint32_t> expected) {
  QJsonObject row{{QStringLiteral("name"), name}, {QStringLiteral("expected"), expected ? QJsonValue{static_cast<qint64>(*expected)} : QJsonValue{QStringLiteral("NoImageOnClipboard")}}};
  try {
    const auto descriptor = monitor.capture();
    const auto actual = readGeneration(memory, descriptor.get());
    row.insert(QStringLiteral("actual"), static_cast<qint64>(actual));
    row.insert(QStringLiteral("passed"), expected && actual == *expected);
  } catch (const ClipboardImageFailure &error) {
    row.insert(QStringLiteral("actual"), QString::fromUtf8(error.what()));
    row.insert(QStringLiteral("passed"), !expected && error.code() == ClipboardImageError::no_image);
  }

  rows.append(row);
}

}

int main(int argc, char **argv) try {
  const QCoreApplication application{argc, argv};
  if (argc < 2 || argc > 3) {
    return 1;
  }

  const bool late_seat = argc == 3 && std::string_view{argv[2]} == "late";
  ApplicationAllocator memory;
  Connection connection;
  connection.connect();
  WaylandClipboardImageMonitor monitor{memory, connection.display};
  connection.settle();
  QJsonArray rows;
  if (late_seat) {
    observe(rows, monitor, memory, QStringLiteral("before-seat-arrival"), std::nullopt);
    connection.command("restore-seat");
  }

  const std::uint32_t initial_generation = late_seat ? 2 : 1;
  observe(rows, monitor, memory, QStringLiteral("initial"), initial_generation);
  const auto pinned = monitor.capture();
  connection.command("remove-manager");
  observe(rows, monitor, memory, QStringLiteral("manager-removed"), std::nullopt);
  const auto pinned_generation = readGeneration(memory, pinned.get());
  rows.append(QJsonObject{{QStringLiteral("name"), QStringLiteral("detached-transfer")}, {QStringLiteral("actual"), static_cast<qint64>(pinned_generation)}, {QStringLiteral("passed"), pinned_generation == initial_generation}});
  connection.command("restore-manager");
  observe(rows, monitor, memory, QStringLiteral("manager-restored"), initial_generation + 1);
  connection.command("remove-seat");
  observe(rows, monitor, memory, QStringLiteral("seat-removed"), std::nullopt);
  connection.command("restore-seat");
  observe(rows, monitor, memory, QStringLiteral("seat-restored"), initial_generation + 2);
  connection.command("clear");
  observe(rows, monitor, memory, QStringLiteral("selection-cleared"), std::nullopt);
  connection.command("select");
  observe(rows, monitor, memory, QStringLiteral("selected-again"), initial_generation + 3);
  connection.command("flood8");
  constexpr std::uint32_t first_flood_offset = 4;
  const auto first_flood_generation = initial_generation + first_flood_offset;
  observe(rows, monitor, memory, QStringLiteral("eight-pending-offers"), first_flood_generation);
  connection.command("clear");
  observe(rows, monitor, memory, QStringLiteral("clear-after-eight"), std::nullopt);
  connection.command("flood20");
  observe(rows, monitor, memory, QStringLiteral("overflow-selection"), std::nullopt);
  connection.command("clear");
  connection.command("select");
  constexpr std::uint32_t recovered_offset = 6;
  const auto recovered_generation = initial_generation + recovered_offset;
  observe(rows, monitor, memory, QStringLiteral("overflow-recovered"), recovered_generation);
  const auto failed = std::ranges::count_if(rows, [](const auto &value) { return !value.toObject().value(QStringLiteral("passed")).toBool(); });
  const QJsonObject record{{QStringLiteral("cases"), rows}, {QStringLiteral("failed"), static_cast<qint64>(failed)}, {QStringLiteral("scope"), QStringLiteral("Raw Wayland protocol component; no GUI/window instantiated")}};
  QFile output{QString::fromUtf8(argv[1])};
  const auto encoded = QJsonDocument{record}.toJson(QJsonDocument::Indented);
  if (!output.open(QIODevice::WriteOnly) || output.write(encoded) != encoded.size()) {
    return 1;
  }

  std::cout << "Wayland lifecycle cases=" << rows.size() << " failed=" << failed << '\n';

  return failed == 0 ? 0 : 1;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
