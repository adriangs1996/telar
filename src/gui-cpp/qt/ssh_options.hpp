#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <string_view>
#include "telar_client/codecs/telar_wire.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <QByteArray>
#include <QByteArrayView>
#include <QCryptographicHash>
#include <QString>
#include <QStringList>
#include <QtCore/qchar.h>
#include <QtCore/qtypes.h>
#include <limits>

#pragma once


import telar.gui.machines.profile_store;
import telar.platform;

namespace telar::gui::qt {

struct SshOptions {
  static constexpr int keepalive_seconds = 15;
  static constexpr int keepalive_misses = 4;
  static constexpr int control_persist_seconds = 600;
  static constexpr int control_hash_digits = 12;
  static constexpr unsigned bits_per_hex_digit = 4;
  static constexpr unsigned digest_prefix_bits = std::numeric_limits<std::uint64_t>::digits;
  static constexpr int hexadecimal_base = 16;
  static constexpr unsigned control_hash_shift = digest_prefix_bits - (control_hash_digits * bits_per_hex_digit);

  [[nodiscard]] static QString controlName(QByteArrayView destination) {
    MachineFieldRules::destination({destination.data(), static_cast<std::size_t>(destination.size())});
    const auto digest = QCryptographicHash::hash(destination, QCryptographicHash::Sha256);
    auto prefix = byteView({digest.constData(), static_cast<std::size_t>(digest.size())}).first(sizeof(std::uint64_t));
    const auto hash = u64::decode(prefix) >> control_hash_shift;

    // CLI dispatch and Git use ssh-* masters; never queue the GUI behind their transfers.
    return QStringLiteral("ssh-i-") + QString::number(hash, hexadecimal_base).rightJustified(control_hash_digits, QLatin1Char('0'));
  }

  [[nodiscard]] static QStringList prepare(const QString &local_endpoint, QByteArrayView destination) {
    const auto endpoint = local_endpoint.toUtf8();
    const auto parent = runtime::openPrivateParent({endpoint.constData(), static_cast<std::size_t>(endpoint.size())});
    const auto directory = local_endpoint.first(local_endpoint.lastIndexOf(QLatin1Char('/')));
    const auto control = QStringLiteral("ControlPath=") + directory + QLatin1Char('/') + controlName(destination);

    return {
        QStringLiteral("-o"),
        QStringLiteral("BatchMode=yes"),
        QStringLiteral("-o"),
        QStringLiteral("ServerAliveInterval=") + QString::number(keepalive_seconds),
        QStringLiteral("-o"),
        QStringLiteral("ServerAliveCountMax=") + QString::number(keepalive_misses),
        QStringLiteral("-o"),
        QStringLiteral("ForwardAgent=no"),
        QStringLiteral("-o"),
        QStringLiteral("ControlMaster=auto"),
        QStringLiteral("-o"),
        QStringLiteral("ControlPersist=") + QString::number(control_persist_seconds),
        QStringLiteral("-o"),
        control,
    };
  }
};

}
