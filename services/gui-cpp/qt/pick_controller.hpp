#pragma once

#include "components/configuration.hpp"
#include "components/pick_items.hpp"
#include "components/pick_matches.hpp"
#include "core/memory.hpp"
#include "machine_client_key.hpp"
#include "surface_command.hpp"
#include <QByteArray>
#include <QString>
#include <QStringLiteral>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui::qt {

struct PickOwner {
  MachineClientKey source;
  std::uint64_t runtime = 0;
  std::uint64_t generation = 0;
};

template <typename Host, Allocator Memory, typename Source>
class PickController {
public:
  PickController(Host &host, Memory &memory, Source &source)
      : host_(host),
        memory_(memory),
        source_(source),
        items_(nullptr, AllocationDeleter<components::PickItems, Memory>{memory}) {}

  [[nodiscard]] bool isOpen() const noexcept {
    return index_.has_value();
  }

  [[nodiscard]] QVariantMap state() const {
    return {
        {QStringLiteral("open"), isOpen()},
        {QStringLiteral("title"), title_},
        {QStringLiteral("placeholder"), placeholder_},
        {QStringLiteral("rows"), rows_},
        {QStringLiteral("loading"), loading_},
        {QStringLiteral("selecting"), selection_.active()},
        {QStringLiteral("error"), error_},
        {QStringLiteral("identity"), QString::number(identity_)},
        {QStringLiteral("preferredRow"), preferred_row_},
    };
  }

  void open(std::size_t index) {
    const components::Configuration *configuration = source_.components();
    if (configuration == nullptr || index >= configuration->definitions().picks().size()) {
      throw std::invalid_argument{"Pick is no longer configured"};
    }

    close();
    items_ = makeOwned<components::PickItems>(memory_);
    const auto &definition = configuration->definitions().picks()[index];
    title_ = text(definition.heading.title.view());
    placeholder_ = QStringLiteral("Filter choices…");
    owner_ = host_.pickOwner();
    index_ = index;
    loading_ = true;
    pending_ = definition.command;
    host_.pickChanged();
    if (!definition.command) {
      render({});
    } else if (!listing_.active()) {
      startListing();
    }
  }

  void close() {
    ++identity_;
    index_.reset();
    pending_ = false;
    loading_ = false;
    listing_.cancel();
    rows_.clear();
    query_.clear();
    error_.clear();
    items_.reset();
    preferred_row_ = 0;
    host_.pickChanged();
  }

  void filter(const QString &query) {
    constexpr qsizetype maximum_query_bytes = 512;
    const auto encoded = query.toUtf8();
    if (encoded.size() > maximum_query_bytes || query_ == encoded || !isOpen()) {
      return;
    }

    query_ = encoded;
    project();
    host_.pickChanged();
  }

  void choose(int row, const QString &identity) {
    if (!index_ || identity != QString::number(identity_) || !host_.pickOwnerCurrent(owner_) || !items_) {
      return;
    }

    if (selection_.active()) {
      error_ = QStringLiteral("The previous choice is still running");
      host_.pickChanged();

      return;
    }

    const auto matches = matches_.rows();
    if (row < 0 || static_cast<std::size_t>(row) >= matches.size()) {
      return;
    }

    const auto &definition = source_.components()->definitions().picks()[*index_];
    const auto selected = items_->at(matches[static_cast<std::size_t>(row)].index);
    SurfaceCommandRequest request;
    request.arguments = source_.commandArguments(definition.reference, "on_select");
    const QByteArray value{selected.value.data(), static_cast<qsizetype>(selected.value.size())};
    for (qsizetype argument = 1; argument < request.arguments.size(); ++argument) {
      if (request.arguments[argument] == "{}") {
        request.arguments[argument] = value;
      }
    }

    request.timeout = definition.timeout;
    request.output = SurfaceOutputUse::ignored;
    const auto owner = owner_;
    const auto refresh = definition.refresh;
    const auto name = text(definition.heading.name.view());
    selection_.start(request, [this, owner, refresh, name](const SurfaceCommandResult &result) {
      if (host_.pickOwnerCurrent(owner)) {
        if (result.failure) {
          host_.pickFailed(QStringLiteral("Pick '") + name + QStringLiteral("': ") + failure(*result.failure));
        } else if (refresh) {
          host_.pickCommitted();
        }
      }

      host_.pickChanged();
    });
    close();
  }

private:
  static QString text(std::string_view value) {
    return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
  }

  static QString failure(SurfaceCommandFailure reason) {
    switch (reason) {
    case SurfaceCommandFailure::launch:
      return QStringLiteral("Could not launch command");
    case SurfaceCommandFailure::process:
      return QStringLiteral("Command failed");
    case SurfaceCommandFailure::timeout:
      return QStringLiteral("Command timed out");
    case SurfaceCommandFailure::cancelled:
      return QStringLiteral("Command cancelled");
    case SurfaceCommandFailure::invalid_output:
      return QStringLiteral("Command returned invalid text");
    }

    return {};
  }

  void startListing() {
    if (!pending_ || !index_ || !host_.pickOwnerCurrent(owner_)) {
      return;
    }

    pending_ = false;
    try {
      const auto &definition = source_.components()->definitions().picks()[*index_];
      SurfaceCommandRequest request;
      request.arguments = source_.commandArguments(definition.reference, "command");
      request.timeout = definition.timeout;
      request.output = SurfaceOutputUse::options;
      const auto identity = identity_;
      const auto owner = owner_;
      listing_.start(request, [this, identity, owner](const SurfaceCommandResult &result) {
        listingFinished(identity, owner, result);
        startListing();
      });
    } catch (const std::exception &error) {
      fail(QString::fromUtf8(error.what()));
    }
  }

  void listingFinished(std::uint64_t identity, const PickOwner &owner, const SurfaceCommandResult &result) {
    if (!isOpen() || identity != identity_ || !host_.pickOwnerCurrent(owner)) {
      return;
    }

    if (result.failure) {
      fail(failure(*result.failure));
    } else {
      render(result.output);
    }
  }

  void render(const QByteArray &output) {
    if (!index_ || !items_) {
      return;
    }

    try {
      auto context = host_.pickContext();
      const auto &definition = source_.components()->definitions().picks()[*index_];
      if (definition.command) {
        context.output = std::string_view{output.constData(), static_cast<std::size_t>(output.size())};
      }

      source_.renderPick(*index_, context, *items_);
      project();
      error_.clear();
      loading_ = false;
      host_.pickChanged();
    } catch (const std::exception &error) {
      fail(QString::fromUtf8(error.what()));
    }
  }

  void fail(const QString &message) {
    error_ = message;
    loading_ = false;
    host_.pickChanged();
  }

  void project() {
    matches_.collect(*items_, {query_.constData(), static_cast<std::size_t>(query_.size())});
    rows_.clear();
    rows_.reserve(static_cast<qsizetype>(matches_.rows().size()));
    preferred_row_ = 0;
    bool selected = false;
    for (const auto &match : matches_.rows()) {
      const auto option = items_->at(match.index);
      if (option.selected && !selected) {
        selected = true;
        preferred_row_ = static_cast<int>(rows_.size());
      }

      QVariantList swatch;
      if (option.swatch) {
        for (const auto rgb : *option.swatch) {
          constexpr int hexadecimal = 16;
          constexpr int rgb_digits = 6;
          swatch.append(QStringLiteral("#") + QString::number(rgb, hexadecimal).rightJustified(rgb_digits, QLatin1Char{'0'}));
        }
      }

      rows_.append(QVariantMap{
          {QStringLiteral("label"), text(option.label)},
          {QStringLiteral("detail"), text(option.detail)},
          {QStringLiteral("selected"), option.selected},
          {QStringLiteral("swatch"), swatch},
      });
    }
  }

  Host &host_;
  Memory &memory_;
  Source &source_;
  Owned<components::PickItems, Memory> items_;
  components::PickMatches matches_;
  QVariantList rows_;
  QByteArray query_;
  QString title_;
  QString placeholder_;
  QString error_;
  PickOwner owner_;
  std::optional<std::size_t> index_ = std::nullopt;
  std::uint64_t identity_ = 0;
  int preferred_row_ = 0;
  bool loading_ = false;
  bool pending_ = false;
  SurfaceCommand listing_;
  SurfaceCommand selection_;
};

}
