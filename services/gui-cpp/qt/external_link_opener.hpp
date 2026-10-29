#pragma once

#include "command_process.hpp"
#include "links/link_opening.hpp"
#include "links/link_target.hpp"
#include "platform/external_links.hpp"
#include "projection.hpp"
#include <QIODevice>
#include <QProcess>
#include <QStringList>
#include <chrono>
#include <concepts>
#include <optional>
#include <stdexcept>
#include <variant>

namespace telar::gui::qt {

using LinkOpeningFailure = CommandFailure;

struct NativeLinkHost {
  static constexpr auto timeout = std::chrono::seconds{5};

  static void start(QProcess &process, const LinkTarget &target) {
    process.start(toQString(platform::NativeExternalLinks::executable), {toQString(target.text())}, QIODevice::ReadOnly);
  }
};

#ifndef TELAR_GUI_LINK_HOST
#define TELAR_GUI_LINK_HOST ::telar::gui::qt::NativeLinkHost
#endif

using ApplicationLinkHost = TELAR_GUI_LINK_HOST;

template <typename Host>
concept ExternalLinkHost = CommandHost<Host, LinkTarget>;

template <typename Observer, typename Context>
concept LinkOpeningObserver = requires(Observer &observer, Context context, std::optional<LinkOpeningFailure> failure) {
  { observer.linkOpeningFinished(context, failure) } -> std::same_as<void>;
};

template <ExternalLinkHost Host, typename Observer, std::semiregular Context = std::monostate>
class ExternalLinkOpener final {
public:
  static constexpr std::size_t output_limit = CommandProcess<Host, LinkTarget, ExternalLinkOpener>::output_limit;

  explicit ExternalLinkOpener(Observer &observer)
      : observer_(observer),
        process_(*this) {
    static_assert(LinkOpeningObserver<Observer, Context>);
  }

  ~ExternalLinkOpener() = default;
  ExternalLinkOpener(const ExternalLinkOpener &) = delete;
  ExternalLinkOpener &operator=(const ExternalLinkOpener &) = delete;
  ExternalLinkOpener(ExternalLinkOpener &&) = delete;
  ExternalLinkOpener &operator=(ExternalLinkOpener &&) = delete;

  void request(const LinkTarget &target, Context context = {}) {
    if (target.scheme() == LinkScheme::file || target.scheme() == LinkScheme::path) {
      throw std::invalid_argument{"File links require the editor flow"};
    }

    if (opening_.request(target)) {
      current_context_ = context;
      process_.start(target);
    } else {
      pending_context_ = context;
    }
  }

  [[nodiscard]] bool active() const noexcept {
    return opening_.active();
  }

  void commandFinished(std::optional<CommandFailure> failure) {
    const auto completed = current_context_;
    if (const auto next = opening_.complete()) {
      current_context_ = pending_context_;
      process_.start(*next);
    }

    observer_.linkOpeningFinished(completed, failure);
  }

private:
  Observer &observer_;
  LinkOpening opening_;
  Context current_context_{};
  Context pending_context_{};
  CommandProcess<Host, LinkTarget, ExternalLinkOpener> process_;
};

}
