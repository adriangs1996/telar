module telar.gui.ui.app.panes.attachments;

import std;
import telar.gui.qt;
import telar.gui.ui.app.panes.attachments.clipboard;
import telar.gui.application;
import telar.gui.foundation.actions;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.platform;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    bool editsLearnedMarkers(AttachmentMarkerPolicy policy, const TerminalKey& key) noexcept {
      if (key.phase == KeyPhase::release || policy == AttachmentMarkerPolicy::ordered) {
        return false;
      }

      const bool control = key.has(KeyChord::Modifier::control);
      const bool alt = key.has(KeyChord::Modifier::alt);
      const bool shift = key.has(KeyChord::Modifier::shift);
      const bool character_deletion = key.code == KeyChord::Key::backspace || key.code == KeyChord::Key::erase;

      if (!control && !alt && !shift) {
        return character_deletion;
      }

      if (policy != AttachmentMarkerPolicy::pasted_path || shift) {
        return false;
      }

      if (alt && !control) {
        return character_deletion || (key.code == KeyChord::Key::character && key.codepoint == 'd');
      }

      constexpr std::string_view control_deletions = "dhwuk";

      return control && !alt && key.code == KeyChord::Key::character && key.codepoint <= std::numeric_limits<unsigned char>::max() && control_deletions.contains(static_cast<char>(key.codepoint));
    }

  }

  AttachmentShelf::AttachmentShelf(ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        catalog_(delivery_),
        worker_(memory) {
    connect(&worker_, &ClipboardImages::ready, this, &AttachmentShelf::complete);
  }

  AttachmentShelf::Delivery::SlotState AttachmentShelf::Delivery::create() {
    if (!landing) {
      throw std::runtime_error{"MissingClipboardPreview"};
    }

    SlotState slot{.preview = std::move(landing.getMut())};

    landing.reset();

    return slot;
  }

  void AttachmentShelf::Delivery::retire([[maybe_unused]] SlotState& slot) noexcept {}

  bool AttachmentShelf::Delivery::canRelease([[maybe_unused]] const SlotState& slot) noexcept {
    return true;
  }

  void AttachmentShelf::setSource(AttachmentSource source) {
    if (source_ == source) {
      return;
    }

    if (source_) {
      catalog_.removeAll();
      if (captures_.current()) {
        static_cast<void>(captures_.cancel(captures_.current()->target));
      }
    }

    source_ = source;
    changed();
  }

  void AttachmentShelf::setPrompt(ds::Option<AttachmentPrompt> prompt, bool presented) {
    capture_prompt_ = prompt;
    prompt_ = presented ? prompt : ds::none;
    if (catalog_.setTarget(prompt_ ? ds::Option{prompt_->target} : ds::none)) {
      changed();
    }
  }

  void AttachmentShelf::requestCapture() {
    if (!prompt_) {
      return;
    }

    try {
      const auto capture = captures_.reserve(prompt_->target);
      if (capture) {
        worker_.capture({.source = prompt_->source, .runtime_generation = prompt_->runtime_generation, .attachment_generation = prompt_->attachment_generation, .request = {.capture = *capture, .marker_policy = prompt_->policy}});
      }
    } catch (const std::exception& error) {
      if (captures_.current()) {
        static_cast<void>(captures_.finish(captures_.current()->id));
      }

      failed(QString::fromUtf8(error.what()));
    }
  }

  bool AttachmentShelf::current(const ClipboardImageJob& job) const noexcept {
    return capture_prompt_ && capture_prompt_->source == job.source && capture_prompt_->runtime_generation == job.runtime_generation && capture_prompt_->attachment_generation == job.attachment_generation && capture_prompt_->target == job.request.capture.target;
  }

  void AttachmentShelf::complete() {
    auto result = worker_.takeResult();
    if (!result || !captures_.finish(result->job.request.capture.id) || !source_ || source_->source != result->job.source || source_->runtime_generation != result->job.runtime_generation) {
      return;
    }

    if (result->failure) {
      switch (*result->failure) {
      case platform::ClipboardImageError::no_image:
        return;
      case platform::ClipboardImageError::source_bytes:
      case platform::ClipboardImageError::png_bytes:
      case platform::ClipboardImageError::pixels:
        quotaReached(*result->failure);
        return;
      case platform::ClipboardImageError::changed:
      case platform::ClipboardImageError::invalid_image:
      case platform::ClipboardImageError::read_failed:
        failed(result->error);
        return;
      }

      // An error outside the enum reports the worker's message.
      failed(result->error);
      return;
    }

    if (!result->error.isEmpty()) {
      failed(result->error);

      return;
    }

    if (!current(result->job)) {
      return;
    }

    try {
      adopt(result.getMut());
    } catch (const std::exception& error) {
      delivery_.landing.reset();
      failed(QString::fromUtf8(error.what()));
    }
  }

  void AttachmentShelf::adopt(ClipboardImageResult& result) {
    if (!result.capture || !result.preview || result.capture->request.capture != result.job.request.capture || result.preview->sequence != result.job.request.capture.id) {
      return;
    }

    delivery_.landing = std::move(result.preview);
    const auto requested = catalog_.retainedBytes() + result.capture->png.size();
    const auto evicted = catalog_.adopt(result.capture.getMut());
    if (evicted) {
      this->evicted(*evicted, *evicted == application::terminal::attachments::AttachmentEviction::items ? AttachmentLimits::maximum_items + 1 : requested);
    }

    adopted(result.job.request.capture.target.pane_id);
    changed();
  }

  void AttachmentShelf::clearPrompt(AttachmentTarget target) {
    const bool cancelled = captures_.cancel(target);
    const bool removed = catalog_.removeVisible(target) != 0;

    catalog_.reapRetired();
    if (cancelled || removed) {
      changed();
    }
  }

  bool AttachmentShelf::remove(std::uint64_t id) {
    const bool removed = catalog_.remove(id);

    catalog_.reapRetired();
    if (removed) {
      changed();
    }

    return removed;
  }

  application::terminal::attachments::AttachmentMarkerPlan AttachmentShelf::removalPlan(std::uint64_t id, application::terminal::attachments::AttachmentMarkerScreen screen) const noexcept {
    return catalog_.planMarkerRemoval(id, screen);
  }

  void AttachmentShelf::reconcile(application::terminal::attachments::AttachmentMarkerScreen screen) {
    if (!capture_prompt_) {
      return;
    }

    const auto removed = catalog_.reconcileMarkers(capture_prompt_->target, screen);

    catalog_.reapRetired();
    if (removed != 0) {
      changed();
    }
  }

  void AttachmentShelf::observeKey(const TerminalKey& key, application::terminal::attachments::AttachmentMarkerScreen screen) {
    if (!prompt_) {
      return;
    }

    const auto target = prompt_->target;
    const auto policy = prompt_->policy;
    if (editsLearnedMarkers(policy, key)) {
      catalog_.expectMarkerDeletion(target);
    }

    if (key.phase == KeyPhase::release || key.has(KeyChord::Modifier::control) || key.has(KeyChord::Modifier::alt) || key.has(KeyChord::Modifier::shift)) {
      return;
    }

    if (key.code == KeyChord::Key::enter) {
      if (policy == AttachmentMarkerPolicy::ordered || !screen.promptContinues()) {
        clearPrompt(target);
      }
    } else if (key.code == KeyChord::Key::backspace || key.code == KeyChord::Key::erase) {
      const auto deletion = key.code == KeyChord::Key::backspace ? application::terminal::attachments::AttachmentMarkerDeletion::backward : application::terminal::attachments::AttachmentMarkerDeletion::forward;
      if (const auto id = catalog_.markerAtDeletion(screen, deletion)) {
        static_cast<void>(remove(*id));
      } else if (catalog_.pendingMarkerAtDeletion(screen, policy, deletion)) {
        static_cast<void>(captures_.cancel(target));
      }
    }
  }

  QVariantList AttachmentShelf::items() const {
    const auto snapshot = catalog_.snapshot();
    QVariantList result;

    for (std::size_t index = 0; index < snapshot.count; ++index) {
      const auto item = snapshot.items[index];

      result.append(QVariantMap{{u"id"_s, QString::number(item.id)}, {u"width"_s, item.width}, {u"height"_s, item.height}});
    }

    return result;
  }

  QString AttachmentShelf::paneId() const {
    const auto target = catalog_.target();

    return target && hasVisibleItems() ? QString::number(target->pane_id) : QString{};
  }

  QVariantMap AttachmentShelf::modal() const {
    const auto snapshot = catalog_.snapshot();
    if (!snapshot.modal) {
      return {};
    }

    const auto* const slot = catalog_.find(*snapshot.modal);
    if (slot == nullptr) {
      return {};
    }

    return {{u"id"_s, QString::number(*snapshot.modal)}, {u"width"_s, slot->capture.width}, {u"height"_s, slot->capture.height}};
  }

  const ds::Option<AttachmentPrompt>& AttachmentShelf::prompt() const noexcept {
    return prompt_;
  }

  const ds::Option<AttachmentPrompt>& AttachmentShelf::capturePrompt() const noexcept {
    return capture_prompt_;
  }

  bool AttachmentShelf::hasVisibleItems() const noexcept {
    return catalog_.snapshot().count != 0;
  }

  QImage AttachmentShelf::image(const QString& identity, bool full) const {
    bool valid = false;
    const auto id = identity.toULongLong(&valid);
    const auto* const slot = valid ? catalog_.find(id) : nullptr;
    if (slot == nullptr || !prompt_ || !slot->owns(prompt_->target)) {
      return {};
    }

    return full ? slot->delivery.preview.full : slot->delivery.preview.thumbnail;
  }

  bool AttachmentShelf::hoverReady() const noexcept {
    return hover_ready_;
  }

  bool AttachmentShelf::hoverKnown() const noexcept {
    return hover_recovery_.hasValue();
  }

  QPointF AttachmentShelf::hoverPosition() const noexcept {
    return hover_recovery_.valueOr(QPointF{});
  }

  void AttachmentShelf::observePointer(ds::Option<QPointF> position) {
    hover_pointer_ = position;
    if (!position) {
      hover_recovery_.reset();
      hoverRecoveryChanged();
    } else if (!hover_ready_ && !catalog_.snapshot().modal) {
      hover_ready_ = true;
      hoverReadyChanged();
    }
  }

  void AttachmentShelf::open(const QString& identity) {
    bool valid = false;
    const auto id = identity.toULongLong(&valid);
    if (valid && catalog_.openModal(id)) {
      hover_recovery_ = hover_pointer_;
      hover_ready_ = false;
      hoverRecoveryChanged();
      hoverReadyChanged();
      changed();
    }
  }

  void AttachmentShelf::close() {
    if (catalog_.closeModal()) {
      hover_recovery_ = hover_pointer_;
      hoverRecoveryChanged();
      changed();
    }
  }

  void AttachmentShelf::dismiss(const QString& identity) {
    bool valid = false;
    const auto id = identity.toULongLong(&valid);
    const auto* const slot = valid ? catalog_.find(id) : nullptr;
    if (slot != nullptr && prompt_ && slot->owns(prompt_->target)) {
      dismissRequested(id);
    }
  }

}
