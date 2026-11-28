module telar.gui.ui.design.controls;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.text;
import telar.base.ds;
import telar.base.text.utf8;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    QString fieldString(std::string_view value) {
      return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
    }

    QVariantMap emptyLayout(const QVariantMap& grid) {
      return {{u"available"_s, false}, {u"text"_s, QString{}}, {u"grid"_s, grid}, {u"content"_s, QRectF{}}, {u"caret"_s, QRectF{}}, {u"selection"_s, QRectF{}}, {u"underline"_s, QRectF{}}, {u"composing"_s, false}};
    }

  }

  NativeFormField::NativeFormField(QQuickItem* parent)
      : QQuickItem(parent),
        composition_events_(*this) {
    grid_ = {{u"family"_s, QString{}}, {u"style"_s, QString{}}, {u"cellWidth"_s, 1}, {u"cellHeight"_s, 1}, {u"pixelHeight"_s, 1}, {u"baseline"_s, 0}};
    layout_ = emptyLayout(grid_);
    setFlag(ItemAcceptsInputMethod);
    setAcceptedMouseButtons(Qt::LeftButton);
    setCursor(Qt::IBeamCursor);
  }

  QString NativeFormField::text() const {
    return text_;
  }

  void NativeFormField::setText(const QString& text) {
    if (text_ == text) {
      return;
    }

    cancelComposition();
    editor_.setText({});
    insertText(text);
    publish(false);
  }

  QVariantMap NativeFormField::typography() const {
    return typography_;
  }

  void NativeFormField::setTypography(const QVariantMap& typography) {
    if (typography_ != typography) {
      typography_ = typography;
      metrics_dirty_ = true;
      typographyChanged();
      invalidateLayout();
    }
  }

  qreal NativeFormField::ratio() const noexcept {
    return ratio_;
  }

  void NativeFormField::setRatio(qreal ratio) {
    if (std::isfinite(ratio) && ratio > 0 && !std::equal_to<>{}(ratio_, ratio)) {
      ratio_ = ratio;
      ratioChanged();
      invalidateLayout();
    }
  }

  int NativeFormField::maximumBytes() const noexcept {
    return maximum_bytes_;
  }

  bool NativeFormField::formControl() const noexcept {
    return form_control_;
  }

  void NativeFormField::setFormControl(bool enabled) {
    if (form_control_ != enabled) {
      form_control_ = enabled;
      metrics_dirty_ = true;
      formControlChanged();
      invalidateLayout();
    }
  }

  void NativeFormField::setMaximumBytes(int capacity) {
    if (capacity >= 0 && std::cmp_less_equal(capacity, text_capacity) && maximum_bytes_ != capacity) {
      maximum_bytes_ = capacity;
      maximumBytesChanged();
      if (editor_.text().size() > static_cast<std::size_t>(maximum_bytes_)) {
        const auto previous = text_;

        text_.clear();
        setText(previous);
      }
    }
  }

  int NativeFormField::utf16Position(std::string_view text, std::size_t offset) {
    return static_cast<int>(fieldString(text.substr(0, std::min(offset, text.size()))).size());
  }

  std::size_t NativeFormField::bytePosition(const QString& text, int offset) {
    auto position = std::clamp(offset, 0, static_cast<int>(text.size()));
    if (position > 0 && position < text.size() && text[position].isLowSurrogate() && text[position - 1].isHighSurrogate()) {
      --position;
    }

    return static_cast<std::size_t>(text.first(position).toUtf8().size());
  }

  int NativeFormField::cursorPosition() const {
    return utf16Position(editor_.text(), editor_.head());
  }

  void NativeFormField::setCursorPosition(int position) {
    select(position, position);
  }

  int NativeFormField::selectionStart() const {
    return utf16Position(editor_.text(), std::min(editor_.anchor(), editor_.head()));
  }

  int NativeFormField::selectionEnd() const {
    return utf16Position(editor_.text(), std::max(editor_.anchor(), editor_.head()));
  }

  QString NativeFormField::selectedText() const {
    return fieldString(editor_.selected());
  }

  void NativeFormField::select(int start, int end) {
    cancelComposition();
    editor_.selectRange(bytePosition(text_, start), bytePosition(text_, end));
    publish(false);
  }

  void NativeFormField::selectAll() {
    cancelComposition();
    editor_.selectAll();
    publish(false);
  }

  void NativeFormField::deselect() {
    cancelComposition();
    editor_.clearSelection();
    publish(false);
  }

  void NativeFormField::copy() const {
    QGuiApplication::clipboard()->setText(selectedText());
  }

  void NativeFormField::cut() {
    copy();
    cancelComposition();
    if (editor_.hasSelection()) {
      editor_.insert({});
      publish(true);
    }
  }

  void NativeFormField::paste() {
    cancelComposition();
    auto pasted = QGuiApplication::clipboard()->text();

    pasted.replace(u"\r\n"_s, u" "_s);
    pasted.replace(QLatin1Char('\r'), QLatin1Char(' '));
    pasted.replace(QLatin1Char('\n'), QLatin1Char(' '));
    insertText(pasted);
    publish(true);
  }

  void NativeFormField::insertText(const QString& text) {
    const auto retained = editor_.text().size() - editor_.selected().size();
    const auto remaining = static_cast<std::size_t>(maximum_bytes_) - retained;
    const auto measured = Utf16Prefix::fit(QStringView{text}, remaining, utf16Encoding());
    const auto prefix = text.first(static_cast<qsizetype>(measured.units));
    const auto encoded = prefix.toUtf8();
    const std::string_view source{encoded.constData(), static_cast<std::size_t>(encoded.size())};
    const auto kept = runtime::utf8Prefix(source, remaining);

    editor_.insert(kept);

    if (measured.bytes < measured.requested_bytes) {
      limitReached(static_cast<qulonglong>(retained) + static_cast<qulonglong>(measured.requested_bytes));
    }
  }

  void NativeFormField::publish(bool edited) {
    const auto value = fieldString(editor_.text());
    const auto changed = text_ != value;

    text_ = value;
    updateInputContext();
    if (changed) {
      textChanged();
      if (edited) {
        textEdited();
      }
    }

    selectionChanged();
    invalidateLayout();
    if (hasActiveFocus()) {
      QGuiApplication::inputMethod()->update(Qt::ImQueryInput);
    }
  }

  void NativeFormField::updateInputContext() {
    ds::Option<FormInputContext::Replacement> replacement;

    if (!composition_.isEmpty()) {
      replacement = FormInputContext::Replacement{.first = utf16Position(editor_.text(), composition_first_), .last = utf16Position(editor_.text(), composition_last_)};
    }

    input_context_ = FormInputContext::capture(text_, cursorPosition(), utf16Position(editor_.text(), editor_.anchor()), replacement);
    composition_events_.setActive(!composition_.isEmpty() && hasActiveFocus());
  }

  void NativeFormField::clearComposition() {
    composition_.clear();
    composition_anchor_ = 0;
    composition_head_ = 0;
  }

  bool NativeFormField::cancelComposition() {
    const auto composing = !composition_.isEmpty();

    clearComposition();
    if (composing) {
      updateInputContext();
    }

    if (composing && hasActiveFocus()) {
      {
        const QScopedValueRollback<bool> discarding{discarding_composition_, true};

        QGuiApplication::inputMethod()->reset();
      }

      QGuiApplication::inputMethod()->update(Qt::ImQueryInput);
    }

    if (composing) {
      invalidateLayout();
    }

    return composing;
  }

  void NativeFormField::invalidateLayout() {
    polish();
  }

  QVariantMap NativeFormField::layout() const {
    return layout_;
  }

  void NativeFormField::resolveGrid() {
    if (!form_control_) {
      grid_ = typography_.value(u"grid"_s).toMap();
      font_grid_ = CellTextGrid::resolve(grid_, density_).metrics;
      metrics_dirty_ = false;

      return;
    }

    const auto family = typography_.value(u"primaryFamily"_s).toString();
    const auto style = typography_.value(u"primaryStyle"_s).toString();
    const auto pixels = std::clamp(std::round(typography_.value(u"body"_s, 1).toDouble() * density_), qreal{1}, static_cast<qreal>(std::numeric_limits<std::uint16_t>::max()));
    const auto resolved = FormTextGrid::resolve(family, style, static_cast<std::uint16_t>(pixels));

    font_grid_ = resolved.metrics;
    grid_ = resolved.record(density_);
    metrics_dirty_ = false;
  }

  void NativeFormField::updatePolish() {
    density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    try {
      if (metrics_dirty_) {
        resolveGrid();
      }

      ChromeMetrics chrome;

      chrome.ratio = static_cast<float>(ratio_ * density_);
      const Rect bounds{.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)};

      geometry_ = form_control_ ? FormFieldGeometry::derive(bounds, chrome, font_grid_) : FormFieldGeometry::terminal(bounds, font_grid_);
      BoundedEditor<display_capacity> display;

      display.setText(editor_.text());
      display.selectRange(editor_.anchor(), editor_.head());
      if (!composition_.isEmpty()) {
        display.replace(composition_first_, composition_last_, {composition_.constData(), static_cast<std::size_t>(composition_.size())});
        display.selectRange(composition_first_ + composition_anchor_, composition_first_ + composition_head_);
      }

      const auto view = display.view(geometry_.columns);
      const auto logical = [this](Rect area) {
        return QRectF{static_cast<qreal>(area.x) / density_, static_cast<qreal>(area.y) / density_, static_cast<qreal>(area.width) / density_, static_cast<qreal>(area.height) / density_};
      };

      const auto underline = geometry_.underline(cellTextColumns(view.text));

      layout_ = {{u"available"_s, true}, {u"text"_s, fieldString(view.text)}, {u"grid"_s, grid_}, {u"content"_s, logical(geometry_.content)}, {u"caret"_s, logical(geometry_.caret(view.cursor))}, {u"selection"_s, logical(view.selection ? geometry_.selection(*view.selection) : Rect{})}, {u"underline"_s, logical(underline)}, {u"composing"_s, !composition_.isEmpty()}};
    } catch (const std::exception&) {
      layout_ = emptyLayout(grid_);
    }

    layoutChanged();
    if (hasActiveFocus()) {
      QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
    }
  }

  void NativeFormField::componentComplete() {
    QQuickItem::componentComplete();
    updatePolish();
  }

  void NativeFormField::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    invalidateLayout();
  }

  void NativeFormField::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      metrics_dirty_ = true;
      invalidateLayout();
    }

    if ((change == ItemVisibleHasChanged && !isVisible()) || (change == ItemEnabledHasChanged && !isEnabled())) {
      dragging_ = false;
      cancelComposition();
      invalidateLayout();
    }
  }

}
