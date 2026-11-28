export module telar.gui.ui.app.chrome.components:pick_controller;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.process.surface_command;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.base.memory.allocators;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  struct PickOwner {
    application::machines::MachineClientKey source;
    std::uint64_t runtime = 0;
    std::uint64_t generation = 0;
  };

  template <typename Host, Allocator Memory, typename Source>
  class PickController {
  public:
    [[tbc::generic]] PickController(Host& host, Memory& memory, Source& source)
        : host_(host),
          memory_(memory),
          source_(source),
          items_() {}

    [[tbc::generic]] [[nodiscard]] bool isOpen() const noexcept {
      return index_.hasValue();
    }

    // Every choice the pick lists before a filter, which sizes the list so typing never resizes it.
    [[tbc::generic]] [[nodiscard]] std::size_t itemCount() const noexcept {
      return items_ ? items_->size() : 0;
    }

    [[tbc::generic]] [[nodiscard]] QVariantMap state() const {
      return {
          {u"open"_s, isOpen()},
          {u"title"_s, title_},
          {u"placeholder"_s, placeholder_},
          {u"rows"_s, rows_},
          {u"loading"_s, loading_},
          {u"selecting"_s, selection_.active()},
          {u"error"_s, error_},
          {u"identity"_s, QString::number(identity_)},
          {u"preferredRow"_s, preferred_row_},
      };
    }

    [[tbc::generic]] void open(std::size_t index) {
      const application::components::Definitions* definitions = source_.definitions();
      if (definitions == nullptr || index >= definitions->picks().size()) {
        throw std::invalid_argument{"Pick is no longer configured"};
      }

      close();
      items_ = ds::makeBox<application::components::PickItems>(memory_);
      const auto& definition = definitions->picks()[index];

      title_ = text(definition.heading.title.view());
      placeholder_ = u"Filter choices…"_s;
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

    [[tbc::generic]] void close() {
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

    [[tbc::generic]] void filter(const QString& query) {
      constexpr qsizetype maximum_query_bytes = 512;
      const auto encoded = query.toUtf8();
      if (encoded.size() > maximum_query_bytes || query_ == encoded || !isOpen()) {
        return;
      }

      query_ = encoded;
      project();
      host_.pickChanged();
    }

    [[tbc::generic]] void choose(int row, const QString& identity) {
      if (!index_ || identity != QString::number(identity_) || !host_.pickOwnerCurrent(owner_) || !items_) {
        return;
      }

      if (selection_.active()) {
        error_ = u"The previous choice is still running"_s;
        host_.pickChanged();

        return;
      }

      const auto matches = matches_.rows();
      if (row < 0 || static_cast<std::size_t>(row) >= matches.size()) {
        return;
      }

      const auto& definition = source_.definitions()->picks()[*index_];
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

      selection_.start(request, [this, owner, refresh, name](const SurfaceCommandResult& result) {
        if (host_.pickOwnerCurrent(owner)) {
          if (result.failure) {
            host_.pickFailed(u"Pick '"_s + name + u"': "_s + failure(*result.failure));
          } else if (refresh) {
            host_.pickCommitted();
          }
        }

        host_.pickChanged();
      });

      close();
    }

  private:
    [[tbc::generic]] static QString text(std::string_view value) {
      return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
    }

    [[tbc::generic]] static QString failure(SurfaceCommandFailure reason) {
      switch (reason) {
      case SurfaceCommandFailure::launch:
        return u"Could not launch command"_s;
      case SurfaceCommandFailure::process:
        return u"Command failed"_s;
      case SurfaceCommandFailure::timeout:
        return u"Command timed out"_s;
      case SurfaceCommandFailure::cancelled:
        return u"Command cancelled"_s;
      case SurfaceCommandFailure::invalid_output:
        return u"Command returned invalid text"_s;
      }

      return {};
    }

    [[tbc::generic]] void startListing() {
      if (!pending_ || !index_ || !host_.pickOwnerCurrent(owner_)) {
        return;
      }

      pending_ = false;
      try {
        const auto& definition = source_.definitions()->picks()[*index_];
        SurfaceCommandRequest request;

        request.arguments = source_.commandArguments(definition.reference, "command");
        request.timeout = definition.timeout;
        request.output = SurfaceOutputUse::options;
        const auto identity = identity_;
        const auto owner = owner_;

        listing_.start(request, [this, identity, owner](const SurfaceCommandResult& result) {
          listingFinished(identity, owner, result);
          startListing();
        });
      } catch (const std::exception& error) {
        fail(QString::fromUtf8(error.what()));
      }
    }

    [[tbc::generic]] void listingFinished(std::uint64_t identity, const PickOwner& owner, const SurfaceCommandResult& result) {
      if (!isOpen() || identity != identity_ || !host_.pickOwnerCurrent(owner)) {
        return;
      }

      if (result.failure) {
        fail(failure(*result.failure));
      } else {
        render(result.output);
      }
    }

    [[tbc::generic]] void render(const QByteArray& output) {
      if (!index_ || !items_) {
        return;
      }

      try {
        auto context = host_.pickContext();
        const auto& definition = source_.definitions()->picks()[*index_];
        if (definition.command) {
          context.output = std::string_view{output.constData(), static_cast<std::size_t>(output.size())};
        }

        // The items arrive from the Lua thread; a pick reopened meanwhile ignores them.
        source_.renderPick(*index_, context, [this, identity = identity_](auto outcome) {
          if (!isOpen() || identity != identity_ || outcome.stale) {
            return;
          }

          if (!outcome.value) {
            fail(outcome.error);
            return;
          }

          items_ = std::move(outcome.value.getMut());
          project();
          error_.clear();
          loading_ = false;
          host_.pickChanged();
        });
      } catch (const std::exception& error) {
        fail(QString::fromUtf8(error.what()));
      }
    }

    [[tbc::generic]] void fail(const QString& message) {
      error_ = message;
      loading_ = false;
      host_.pickChanged();
    }

    [[tbc::generic]] void project() {
      matches_.collect(*items_, {query_.constData(), static_cast<std::size_t>(query_.size())});
      rows_.clear();
      rows_.reserve(static_cast<qsizetype>(matches_.rows().size()));
      preferred_row_ = 0;
      bool selected = false;

      for (const auto& match : matches_.rows()) {
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

            swatch.append(u"#"_s + QString::number(rgb, hexadecimal).rightJustified(rgb_digits, QLatin1Char{'0'}));
          }
        }

        rows_.append(QVariantMap{
            {u"label"_s, text(option.label)},
            {u"detail"_s, text(option.detail)},
            {u"selected"_s, option.selected},
            {u"swatch"_s, swatch},
        });
      }
    }

    Host& host_;
    Memory& memory_;
    Source& source_;
    ds::Box<application::components::PickItems, Memory> items_;
    application::components::PickMatches matches_;
    QVariantList rows_;
    QByteArray query_;
    QString title_;
    QString placeholder_;
    QString error_;
    PickOwner owner_;
    ds::Option<std::size_t> index_ = ds::none;
    std::uint64_t identity_ = 0;
    int preferred_row_ = 0;
    bool loading_ = false;
    bool pending_ = false;
    // The commands report back to this controller.
    tbc::val_self<SurfaceCommand> listing_;
    tbc::val_self<SurfaceCommand> selection_;
  };

}
