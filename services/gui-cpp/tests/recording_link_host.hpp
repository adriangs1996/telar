#pragma once

#include "links/link_target.hpp"
#include <QIODevice>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QtCore/qglobal.h>
#include <chrono>
#include <stdexcept>

namespace telar::gui::qt {

struct RecordingLinkHost {
  static constexpr auto timeout = std::chrono::seconds{5};

  static void start(QProcess &process, const LinkTarget &target) {
    const auto record = qEnvironmentVariable("TELAR_GUI_TEST_LINK_RECORD");
    if (record.isEmpty()) {
      throw std::runtime_error{"The test link recorder is not configured"};
    }

    const auto text = target.text();
    const auto uri = QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
    process.start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QStringLiteral(R"(printf '%s\n' "$1" >> "$2")"), QStringLiteral("telar-link-recorder"), uri, record}, QIODevice::ReadOnly);
  }
};

}

#define TELAR_GUI_LINK_HOST ::telar::gui::qt::RecordingLinkHost
