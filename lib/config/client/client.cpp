module;
#include <lua.h>

module telar.config.client;

import std;
import telar.tbc;

namespace telar::runtime::config {

  std::size_t NamedDefinitionsValidator::sortedNames(const lua::Value& table, tbc::view<LimitReach, tbc::lt::b> reach, tbc::view<LimitNotices&, tbc::lt::b> limits, std::span<std::string_view, maximum_definitions> names) {
    std::size_t kept = 0;
    std::size_t total = 0;

    table.eachField([&](std::string_view name, const lua::Value&) {
      ++total;
      const auto end = names.begin() + kept;
      const auto insertion = std::lower_bound(names.begin(), end, name);
      if (kept == names.size() && insertion == end) {
        return;
      }

      const auto last = kept < names.size() ? end : end - 1;

      std::move_backward(insertion, last, last + 1);
      *insertion = name;
      kept = std::min(kept + 1, names.size());
    });

    if (total > kept) {
      reach.requested = total;
      limits.add(reach);
    }

    return kept;
  }

  tbc::view<std::string_view, tbc::lt::a> NamedDefinitionsValidator::heading(tbc::view<std::string_view, tbc::lt::a> name, const lua::Value& definition, LimitNotices& limits) {
    if (name.empty() || name.size() > maximum_name_bytes || !std::ranges::all_of(name, [](unsigned char byte) {
          return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
        })) {
      definition.fail("has an invalid name");
    }

    const auto title = definition.field("title");
    const auto text = fittedUiText(title.present() ? title.string() : name, {"panels.title_bytes", "title bytes", maximum_title_bytes, {}, {}}, limits);

    printableUiText(title, text);
    return text;
  }

  ClientDefinitions::ClientDefinitions(const lua::Value& client, const lua::Value* inherited)
      : client_(client),
        inherited_(inherited) {}

  bool ClientDefinitions::contains(const char* section, std::string_view name) const {
    return index(section, name).has_value();
  }

  std::optional<std::uint8_t> ClientDefinitions::index(const char* section, std::string_view name) const {
    if (client_.present()) {
      const auto definitions = client_.field(section);
      if (definitions.present()) {
        return indexOf(definitions, name);
      }
    }

    if (inherited_ != nullptr && inherited_->present()) {
      return indexOf(inherited_->field(section), name);
    }

    return std::nullopt;
  }

  std::optional<std::uint8_t> ClientDefinitions::indexOf(const lua::Value& definitions, std::string_view name) {
    if (!definitions.present()) {
      return std::nullopt;
    }

    bool found = false;
    std::size_t preceding = 0;

    definitions.eachField([&](std::string_view candidate, const lua::Value&) {
      found |= candidate == name;
      preceding += candidate < name;
    });

    if (!found) {
      return std::nullopt;
    }

    return preceding < NamedDefinitionsValidator::maximum_definitions ? static_cast<std::uint8_t>(preceding) : std::numeric_limits<std::uint8_t>::max();
  }

  std::span<const std::string_view> CommandTabView::argv() const noexcept {
    return std::span{arguments}.first(count);
  }

  std::string_view CommandTabView::label() const noexcept {
    if (!configured_label.empty() || count == 0) {
      return configured_label;
    }

    auto executable = arguments.front();
    const auto last = executable.find_last_not_of('/');
    if (last == std::string_view::npos) {
      return {};
    }

    executable.remove_suffix(executable.size() - last - 1);
    const auto separator = executable.find_last_of('/');
    if (separator != std::string_view::npos) {
      executable.remove_prefix(separator + 1);
    }

    return executable;
  }

  template <CommandTabLifetime Lifetime>
  bool CommandTabStorage<Lifetime>::keep(std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits) {
    return keepReference(arguments, label, limits).has_value();
  }

  template <CommandTabLifetime Lifetime>
  std::optional<CommandTabReference> CommandTabStorage<Lifetime>::keepReference(std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits) {
    std::array<Byte, maximum_encoded_bytes> encoded{};
    const auto length = encode(arguments, label, encoded);
    const auto row = std::span{encoded}.first(length);

    for (std::size_t index = 0; index < rows_; ++index) {
      const auto stored = rowBytes(index);
      if (stored.size() == row.size() && std::ranges::equal(stored, row)) {
        return reference(index);
      }
    }

    if (!admit(row.size(), limits)) {
      return std::nullopt;
    }

    const auto index = rows_++;

    offsets_[index] = static_cast<std::uint32_t>(used_);
    std::ranges::copy(row, bytes_.begin() + used_);
    used_ += row.size();

    return reference(index);
  }

  template <CommandTabLifetime Lifetime>
  std::optional<CommandTabView> CommandTabStorage<Lifetime>::load(CommandTabReference reference) const {
    if (reference.id >= rows_ || reference != this->reference(reference.id)) {
      return std::nullopt;
    }

    const auto row = rowBytes(reference.id);
    CommandTabView result;

    result.count = row[0];
    const auto label_length = row[1];
    auto offset = header_bytes + (result.count * argument_length_bytes);

    for (std::size_t argument = 0; argument < result.count; ++argument) {
      const auto entry = header_bytes + (argument * argument_length_bytes);
      const auto length = static_cast<std::size_t>(row[entry]) | (static_cast<std::size_t>(row[entry + 1]) << upper_byte_shift);

      result.arguments[argument] = textView(row.subspan(offset, length));
      offset += length;
    }

    result.configured_label = textView(row.subspan(offset, label_length));

    return result;
  }

  template <CommandTabLifetime Lifetime>
  void CommandTabStorage<Lifetime>::seal() noexcept
    requires(Lifetime == CommandTabLifetime::retained)
  {
    sealed_ = true;
    fixed_rows_ = rows_;
    fixed_bytes_ = used_;
  }

  template <CommandTabLifetime Lifetime>
  void CommandTabStorage<Lifetime>::beginRender() noexcept
    requires(Lifetime == CommandTabLifetime::retained)
  {
    if (!sealed_) {
      return;
    }

    const bool crowded = maximum_bytes - used_ < recent_bytes / 2 || maximum_rows - rows_ < recent_rows / 2;
    if (refused_ || crowded) {
      clearRecent();
    }

    refused_ = false;
    rendering_ = true;
  }

  template <CommandTabLifetime Lifetime>
  void CommandTabStorage<Lifetime>::endRender() noexcept
    requires(Lifetime == CommandTabLifetime::retained)
  {
    rendering_ = false;
  }

  template <CommandTabLifetime Lifetime>
  typename CommandTabStorage<Lifetime>::Checkpoint CommandTabStorage<Lifetime>::checkpoint() const noexcept {
    return {.rows = rows_, .bytes = used_};
  }

  template <CommandTabLifetime Lifetime>
  void CommandTabStorage<Lifetime>::restore(Checkpoint saved) noexcept {
    rows_ = saved.rows;
    used_ = saved.bytes;
  }

  template <CommandTabLifetime Lifetime>
  std::size_t CommandTabStorage<Lifetime>::encode(std::span<const std::string_view> arguments, std::string_view label, std::span<Byte> encoded) {
    if (arguments.empty() || arguments.size() > CommandTabView::maximum_arguments || label.size() > CommandTabView::maximum_label_bytes) {
      throw EncodingError{"Invalid command tab bounds"};
    }

    std::size_t argument_bytes = 0;

    for (const auto argument : arguments) {
      if (argument.empty() || argument.size() > CommandTabView::maximum_argument_bytes - argument_bytes || argument.contains('\0')) {
        throw EncodingError{"Invalid command tab argument"};
      }

      argument_bytes += argument.size();
    }

    std::size_t length = 0;

    encoded[length++] = static_cast<Byte>(arguments.size());
    encoded[length++] = static_cast<Byte>(label.size());
    for (const auto argument : arguments) {
      encoded[length++] = static_cast<Byte>(argument.size());
      encoded[length++] = static_cast<Byte>(argument.size() >> upper_byte_shift);
    }

    for (const auto argument : arguments) {
      std::memcpy(encoded.data() + length, argument.data(), argument.size());
      length += argument.size();
    }

    if (!label.empty()) {
      std::memcpy(encoded.data() + length, label.data(), label.size());
    }

    return length + label.size();
  }

  template <CommandTabLifetime Lifetime>
  bool CommandTabStorage<Lifetime>::admit(std::size_t length, LimitNotices& limits) noexcept {
    if (Lifetime == CommandTabLifetime::configuration || !sealed_) {
      if (rows_ >= fixed_row_limit) {
        limits.add({.name = "config.command_tab_rows", .noun = "command tabs", .value = fixed_row_limit});

        return false;
      }

      if (used_ + length > fixed_byte_limit) {
        limits.add({.name = "config.command_tab_bytes", .noun = "command tab bytes", .value = fixed_byte_limit});

        return false;
      }
    } else if (used_ + length > maximum_bytes || rows_ == maximum_rows) {
      if (rendering_) {
        refused_ = true;
        limits.add({.name = "config.recent_command_tab_bytes", .noun = "command tab bytes", .value = recent_bytes});

        return false;
      }

      clearRecent();
    }

    return true;
  }

  template <CommandTabLifetime Lifetime>
  CommandTabReference CommandTabStorage<Lifetime>::reference(std::size_t index) const noexcept {
    return {.epoch = Lifetime == CommandTabLifetime::retained && sealed_ && index >= fixed_rows_ ? epoch_ : 0, .id = static_cast<std::uint16_t>(index)};
  }

  template <CommandTabLifetime Lifetime>
  std::span<const Byte> CommandTabStorage<Lifetime>::rowBytes(std::size_t index) const noexcept {
    const auto start = offsets_[index];
    const auto end = index + 1 == rows_ ? used_ : offsets_[index + 1];

    return std::span{bytes_}.subspan(start, end - start);
  }

  template <CommandTabLifetime Lifetime>
  void CommandTabStorage<Lifetime>::clearRecent() noexcept {
    rows_ = fixed_rows_;
    used_ = fixed_bytes_;
    if (++epoch_ == 0) {
      ++epoch_;
    }
  }

  ExtendedActionSetting ExtendedActionReader::read(const lua::Value& action, const ClientDefinitions& definitions) {
    const auto kind = action.field("kind").string();
    if (kind == "notification") {
      return notification(action);
    }

    if (kind == "plugin") {
      return PluginActionSetting{.plugin = action.field("plugin").string(), .action = action.field("action").string()};
    }

    const bool panel = kind == "open-panel";
    const auto selected = action.field(panel ? "panel" : "pick");
    const auto index = definitions.index(panel ? "panels" : "picks", selected.string());
    if (!index) {
      selected.fail("names an unknown client definition");
    }

    return DefinitionActionSetting{.panel = panel, .index = *index};
  }

  NotificationActionSetting ExtendedActionReader::notification(const lua::Value& action) {
    NotificationActionSetting result;

    result.title = utf8Prefix(action.field("title").string(), max_notification_title_bytes);
    const auto body = action.field("body");
    if (body.present()) {
      result.body = utf8Prefix(body.string(), max_notification_message_bytes);
    }

    result.level = optionalChoice<NotificationLevel>(action.field("level"), notification_level_names).value_or(NotificationLevel::info);
    result.duration_ms = static_cast<std::uint32_t>(action.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms));
    constexpr std::array targets{"pane_id", "tab_id", "workspace_id"};

    for (std::size_t index = 0; index < targets.size(); ++index) {
      const auto target = action.field(targets[index]);
      if (target.present()) {
        result.target = {.kind = static_cast<NotificationTarget::Kind>(index + 1), .id = static_cast<std::uint64_t>(target.integer())};
      }
    }

    return result;
  }

  template <CommandTabStore Commands>
  BasicActionValidator<Commands>::BasicActionValidator(tbc::view<const ClientDefinitions&, tbc::lt::b> definitions, tbc::view<LimitNotices&, tbc::lt::b> limits, tbc::view<Commands&, tbc::lt::b> commands)
      : definitions_(definitions),
        limits_(limits),
        commands_(commands) {}

  template <CommandTabStore Commands>
  bool BasicActionValidator<Commands>::validate(const lua::Value& action, bool expression) const {
    if (action.is(LUA_TFUNCTION)) {
      return true;
    }

    if (expression) {
      action.fail("requires a function for an expression binding");
    }

    if (action.is(LUA_TSTRING)) {
      builtin(action);
      return true;
    }

    const auto kind_value = action.field("kind");
    const auto kind = kind_value.string();
    if (kind == "scroll-pane") {
      direction(action, {"up", "down"});
    } else if (kind == "split-pane") {
      direction(action, {"horizontal", "vertical"});
    } else if (kind == "focus-pane" || kind == "navigate-pane" || kind == "resize-pane") {
      direction(action, {"left", "right", "up", "down"});
    } else if (kind == "resize-sidebar") {
      direction(action, {"left", "right"});
    } else if (kind == "move-tab") {
      direction(action, {"previous", "next"});
    } else if (kind == "select-tab" || kind == "select-workspace") {
      action.onlyFields({"kind", "index"});
      requiredInteger(action.field("index"), 1, 256);
    } else if (kind == "select-tab-offset") {
      action.onlyFields({"kind", "offset"});
      requiredInteger(action.field("offset"), std::numeric_limits<std::int8_t>::min(), std::numeric_limits<std::int8_t>::max());
    } else if (kind == "command-tab") {
      return commandTab(action);
    } else if (kind == "notification") {
      notification(action);
    } else if (kind == "open-panel") {
      reference(action, "panel", "panels");
    } else if (kind == "pick") {
      reference(action, "pick", "picks");
    } else if (kind == "plugin") {
      action.onlyFields({"kind", "plugin", "action"});
      action.field("plugin").string();
      action.field("action").string();
    } else {
      builtin(kind_value);
      action.onlyFields({"kind"});
    }

    return true;
  }

  template <CommandTabStore Commands>
  bool BasicActionValidator<Commands>::component(const lua::Value& action) const {
    if (action.is(LUA_TFUNCTION)) {
      action.fail("cannot be a callback in a static component");
    }

    return validate(action);
  }

  template <CommandTabStore Commands>
  tbc::view<std::optional<ActionSetting>, tbc::lt::a> BasicActionValidator<Commands>::read(const lua::Value& action, bool expression) const {
    if (!validate(action, expression)) {
      return std::nullopt;
    }

    ActionSetting setting;

    if (action.is(LUA_TFUNCTION)) {
      setting.kind = ActionKind::function;
      return setting;
    }

    if (action.is(LUA_TSTRING)) {
      setting.name = action.string();
      return setting;
    }

    const auto kind = action.field("kind").string();
    if (kind == "select-tab" || kind == "select-workspace") {
      setting.kind = kind == "select-tab" ? ActionKind::select_tab : ActionKind::select_workspace;
      setting.number = static_cast<std::int32_t>(action.field("index").integer());
    } else if (kind == "select-tab-offset") {
      setting.kind = ActionKind::select_tab_offset;
      setting.number = static_cast<std::int32_t>(action.field("offset").integer());
    } else if (kind == "command-tab") {
      setting.kind = ActionKind::command_tab;
      command(action, setting.command);
    } else if (kind == "notification") {
      setting.kind = ActionKind::notification;
    } else if (kind == "open-panel") {
      setting.kind = ActionKind::panel;
    } else if (kind == "pick") {
      setting.kind = ActionKind::pick;
    } else if (kind == "plugin") {
      setting.kind = ActionKind::plugin;
    } else {
      setting.name = builtinName(action, kind);
    }

    return setting;
  }

  template <CommandTabStore Commands>
  void BasicActionValidator<Commands>::command(const lua::Value& action, tbc::view<CommandTabView&, tbc::lt::a> command) {
    const auto arguments = action.field("command");

    command.count = arguments.listLength();
    for (std::size_t index = 0; index < command.count; ++index) {
      command.arguments[index] = arguments.element(static_cast<lua_Integer>(index) + 1).string();
    }

    const auto label = action.field("label");

    command.configured_label = label.is(LUA_TSTRING) ? label.string() : std::string_view{};
  }

  template <CommandTabStore Commands>
  tbc::view<std::string_view, tbc::lt::a> BasicActionValidator<Commands>::builtinName(const lua::Value& action, tbc::view<std::string_view, tbc::lt::a> kind) {
    constexpr auto stems = std::to_array<std::pair<std::string_view, std::string_view>>({
        {"scroll-pane", "scroll-pane-"},
        {"split-pane", "split-"},
        {"focus-pane", "focus-"},
        {"navigate-pane", "navigate-"},
        {"resize-pane", "resize-"},
        {"resize-sidebar", "resize-sidebar-"},
        {"move-tab", "move-tab-"},
    });

    const auto* const found = std::ranges::find(stems, kind, &decltype(stems)::value_type::first);
    if (found == stems.end()) {
      return kind;
    }

    const auto direction = action.field("direction").string();
    const auto* const joined = std::ranges::find_if(builtin_names, [&](std::string_view name) {
      return name.size() == found->second.size() + direction.size() && name.starts_with(found->second) && name.ends_with(direction);
    });
    if (joined == builtin_names.end()) {
      action.fail("names an unknown action");
    }

    return *joined;
  }

  template <CommandTabStore Commands>
  void BasicActionValidator<Commands>::builtin(const lua::Value& value) {
    const auto name = value.string();
    if (std::ranges::find(builtin_names, name) != builtin_names.end()) {
      return;
    }

    for (const std::string_view prefix : {"select-tab-", "select-workspace-"}) {
      if (name.starts_with(prefix)) {
        const auto number = name.substr(prefix.size());
        if (validIndex(number)) {
          return;
        }
      }
    }

    value.fail("names an unknown action");
  }

  template <CommandTabStore Commands>
  bool BasicActionValidator<Commands>::validIndex(std::string_view number) noexcept {
    return unsignedNumber<unsigned>(number, std::numeric_limits<std::uint8_t>::max()).value_or(0) != 0;
  }

  template <CommandTabStore Commands>
  void BasicActionValidator<Commands>::requiredInteger(const lua::Value& value, lua_Integer minimum, lua_Integer maximum) {
    const auto integer = value.integer();
    if (integer < minimum || integer > maximum) {
      value.fail("is outside its bounds");
    }
  }

  template <CommandTabStore Commands>
  void BasicActionValidator<Commands>::direction(const lua::Value& action, std::initializer_list<std::string_view> choices) {
    action.onlyFields({"kind", "direction"});
    const auto direction = action.field("direction");

    direction.string();
    optionalChoice(direction, choices);
  }

  template <CommandTabStore Commands>
  void BasicActionValidator<Commands>::reference(const lua::Value& action, const char* field, const char* section) const {
    action.onlyFields({"kind", field});
    const auto value = action.field(field);
    if (!definitions_.contains(section, value.string())) {
      value.fail("names an unknown client definition");
    }
  }

  template <CommandTabStore Commands>
  bool BasicActionValidator<Commands>::commandTab(const lua::Value& action) const {
    action.onlyFields({"kind", "command", "label"});
    const auto command = action.field("command");
    const auto count = command.listLength();
    constexpr std::size_t maximum_arguments = 32;
    constexpr std::size_t maximum_bytes = 4096;

    if (count == 0) {
      command.fail("requires a command");
    }

    if (count > maximum_arguments) {
      limits_.add({"command_tab.max_arguments", "arguments", maximum_arguments, count, {}});
      return false;
    }

    command.arraySize();
    std::array<std::string_view, maximum_arguments> arguments;
    std::size_t total_bytes = 0;

    for (std::size_t index = 0; index < count; ++index) {
      const auto argument = command.element(index + 1);

      arguments[index] = argument.string();
      if (arguments[index].empty()) {
        argument.fail("must be nonempty");
      }

      total_bytes += arguments[index].size();
    }

    const auto label = action.field("label");
    if (label.is(LUA_TSTRING) && label.string().size() > 32) {
      label.fail("exceeds the label limit");
    }

    std::size_t kept_bytes = 0;

    for (const auto argument : std::span{arguments}.first(count)) {
      if (argument.contains('\0')) {
        command.fail("contains NUL");
      }

      kept_bytes += argument.size();
      if (kept_bytes > maximum_bytes) {
        limits_.add({"command_tab.max_command_bytes", "argv bytes", maximum_bytes, total_bytes, {}});
        return false;
      }
    }

    return commands_.keep(std::span{arguments}.first(count), label.is(LUA_TSTRING) ? label.string() : std::string_view{}, limits_);
  }

  template <CommandTabStore Commands>
  void BasicActionValidator<Commands>::notification(const lua::Value& action) const {
    action.onlyFields({"kind", "title", "body", "level", "duration_ms", "pane_id", "tab_id", "workspace_id"});
    optionalChoice(action.field("level"), {"info", "success", "warning", "failure"});
    NotificationBody body{.duration_ms = static_cast<std::uint32_t>(action.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms))};
    const auto title = action.field("title");
    const auto message = action.field("body");

    body.title = fitted(title.string(), {"notifications.max_title_bytes", "bytes", max_notification_title_bytes, {}, {}});
    body.message = message.present() ? fitted(message.string(), {"notifications.max_message_bytes", "bytes", max_notification_message_bytes, {}, {}}) : std::string_view{};
    unsigned target_count = 0;

    for (const auto* name : {"pane_id", "tab_id", "workspace_id"}) {
      const auto target = action.field(name);
      if (target.present()) {
        requiredInteger(target, 1, std::numeric_limits<std::int64_t>::max());
        ++target_count;
      }
    }

    if (target_count > 1) {
      action.fail("accepts only one notification target");
    }

    std::array<Byte, 1024> storage;

    Codec::encode(ShowNotification{.request_id = 1, .notification = body}, storage);
  }

  template <CommandTabStore Commands>
  tbc::view<std::string_view, tbc::lt::a> BasicActionValidator<Commands>::fitted(tbc::view<std::string_view, tbc::lt::a> text, tbc::view<LimitReach, tbc::lt::b> limit) const {
    if (text.size() > limit.value) {
      limit.requested = text.size();
      limits_.add(limit);
    }

    return utf8Prefix(text, limit.value);
  }

  ComponentBudget::Usage ComponentBudget::Usage::operator+(Usage other) const noexcept {
    return {nodes + other.nodes, text + other.text, actions + other.actions, samples + other.samples};
  }

  ComponentBudget::Usage ComponentBudget::Usage::operator-(Usage other) const noexcept {
    return {nodes - other.nodes, text - other.text, actions - other.actions, samples - other.samples};
  }

  bool ComponentBudget::Usage::fits(Usage room) const noexcept {
    return nodes <= room.nodes && text <= room.text && actions <= room.actions && samples <= room.samples;
  }

  void ComponentBudget::count(const ComponentShape& shape, unsigned rank) noexcept {
    const auto needed = usage(shape);

    offered_ = offered_ + needed;
    ranked_[rank] = ranked_[rank] + needed;
  }

  void ComponentBudget::prepare() noexcept {
    Usage above;

    for (unsigned rank = rank_count; rank-- > 0;) {
      const auto next = above + ranked_[rank];
      if (!next.fits(staging_capacity)) {
        cutoff_ = rank;
        room_ = staging_capacity - above;
        return;
      }

      above = next;
    }

    room_ = staging_capacity;
  }

  bool ComponentBudget::admit(const ComponentShape& shape, unsigned rank) noexcept {
    if (rank < cutoff_) {
      return false;
    }

    if (rank > cutoff_) {
      return true;
    }

    const auto next = taken_ + usage(shape);
    if (!next.fits(room_)) {
      return false;
    }

    taken_ = next;
    return true;
  }

  void ComponentBudget::release(const ComponentShape& shape, unsigned rank) noexcept {
    if (rank == cutoff_) {
      taken_ = taken_ - usage(shape);
    }
  }

  bool ComponentBudget::stage(const ComponentShape& shape) noexcept {
    const auto next = staged_ + usage(shape);
    if (!next.fits(staging_capacity)) {
      return false;
    }

    staged_ = next;
    return true;
  }

  bool ComponentBudget::nodesFull() const noexcept {
    return staged_.nodes == staging_capacity.nodes;
  }

  void ComponentBudget::report(LimitNotices& limits) const noexcept {
    const std::array<LimitReach, 4> reaches{{
        {"bars.max_bar_nodes", "components", 64, offered_.nodes, {}},
        {"bars.max_bar_text_bytes", "text bytes", 4096, offered_.text, {}},
        {"bars.max_bar_actions", "click actions", 32, offered_.actions, {}},
        {"bars.max_samples", "sparkline samples", 256, offered_.samples, {}},
    }};

    for (const auto& reach : reaches) {
      if (reach.requested > reach.value) {
        limits.add(reach);
      }
    }
  }

  ComponentBudget::Usage ComponentBudget::usage(const ComponentShape& shape) noexcept {
    return {1, shape.text.size() + shape.detail.size() + shape.url.size(), shape.action_field != nullptr ? 1u : 0u, shape.samples};
  }

  class ComponentStyleValidator {
  public:
    inline static void validate(const lua::Value& component) {
      for (const auto* name : {"fg", "bg"}) {
        const auto value = component.field(name);
        if (value.present()) {
          color(value);
        }
      }

      for (const auto* name : {"bold", "italic", "faint", "underline", "strikethrough"}) {
        component.field(name).boolean(false);
      }
    }

  private:
    inline static void color(const lua::Value& value) {
      if (const auto index = value.asInteger()) {
        if (*index < 0 || *index > 255) {
          value.fail("is outside the color index range");
        }

        return;
      }

      constexpr std::string_view names[]{"default", "accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};
      const auto text = value.string();
      if (std::ranges::any_of(names, [text](std::string_view name) {
            return equalUiName(text, name);
          })) {
        return;
      }

      if (text.size() == 7 && text.front() == '#' && hexadecimal(text.substr(1))) {
        return;
      }

      value.fail("is not a supported color");
    }

    inline static bool hexadecimal(std::string_view digits) noexcept {
      const bool negative = digits.front() == '-';
      if (negative || digits.front() == '+') {
        digits.remove_prefix(1);
      }

      // At most six digits follow '#', so the value never reaches the limit.
      const auto value = unsignedNumber<unsigned>(digits, std::numeric_limits<unsigned>::max(), 16);

      return value && (!negative || *value == 0);
    }
  };

  tbc::view<ComponentShape, tbc::lt::a> ComponentShapeReader::read(const lua::Value& value, unsigned inherited_priority, LimitNotices& limits) {
    ComponentShape shape;

    shape.kind = kind(value.field("ui"));
    shape.form = ComponentForm::component;
    fields(value, shape.kind);
    shape.priority = static_cast<unsigned>(std::round(value.field("priority").boundedNumber(inherited_priority, 0, 100)));
    const auto tone = value.field("tone");

    optionalChoice(tone, {"neutral", "muted", "accent", "success", "warning", "danger"});
    if (tone.present()) {
      shape.tone_bonus = tone.string() == "danger" ? 40 : tone.string() == "warning" ? 20
                                                                                     : 0;
    }

    switch (shape.kind) {
    case ComponentKind::label:
      shape.text = text(value, "text");
      ComponentStyleValidator::validate(value);
      break;
    case ComponentKind::icon:
      optionalIcon(value.field("name"));
      shape.text = text(value, "glyph");
      if (shape.text.size() > maximum_glyph_bytes || (shape.text.empty() && !value.field("name").present())) {
        value.fail("requires an icon name or a glyph of at most 16 bytes");
      }

      break;
    case ComponentKind::mark:
      uiMark(value.field("name"));
      break;
    case ComponentKind::meter:
    case ComponentKind::meter_row:
      finiteNumber(value.field("value"));
      finiteNumber(value.field("marker"));
      shape.text = text(value, "label");
      shape.detail = text(value, shape.kind == ComponentKind::meter ? "text" : "detail");
      break;
    case ComponentKind::sparkline:
      shape.samples = samples(value, limits);
      break;
    case ComponentKind::badge:
    case ComponentKind::heading:
    case ComponentKind::text:
      shape.text = text(value, "text");
      break;
    case ComponentKind::clock:
      shape.text = text(value, "format", "%H:%M");
      if (shape.text.size() > maximum_clock_bytes) {
        value.fail("exceeds the clock format limit");
      }

      break;
    case ComponentKind::metric:
      value.field("name").string();
      optionalChoice(value.field("name"), {"cpu", "memory", "battery"});
      break;
    case ComponentKind::group:
      optionalIcon(value.field("icon"));
      if (const auto mark = value.field("mark"); mark.present()) {
        uiMark(mark);
      }

      shape.action_field = value.field("on_click").present() ? "on_click" : nullptr;
      shape.url = text(value, "url");
      // A summary group shows one indicator for its metrics and meters, named by this text.
      shape.text = text(value, "summary");
      break;
    case ComponentKind::key_value:
      shape.text = text(value, "key");
      shape.detail = text(value, "value");
      break;
    case ComponentKind::callout:
      optionalIcon(value.field("icon"));
      shape.text = text(value, "text");
      shape.detail = text(value, "detail");
      break;
    case ComponentKind::button:
      shape.text = text(value, "text");
      shape.action_field = value.field("action").present() ? "action" : nullptr;
      shape.url = text(value, "url");
      value.field("primary").boolean(false);
      if (shape.action_field == nullptr && shape.url.empty()) {
        value.fail("requires an action or URL");
      }

      break;
    case ComponentKind::machines:
    case ComponentKind::actions:
    case ComponentKind::divider:
      break;
    }

    return shape;
  }

  ComponentShape ComponentShapeReader::segment(const lua::Value& value, unsigned priority) {
    value.onlyFields({"text", "icon", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough"});
    ComponentShape shape;

    shape.form = ComponentForm::segment;
    shape.text = text(value, "text");
    shape.kind = shape.text.empty() ? ComponentKind::icon : ComponentKind::label;
    shape.priority = priority;
    optionalIcon(value.field("icon"));
    ComponentStyleValidator::validate(value);
    return shape;
  }

  ComponentKind ComponentShapeReader::kind(const lua::Value& value) {
    constexpr std::string_view names[]{"label", "icon", "mark", "meter", "sparkline", "badge", "clock", "metric", "machines", "group", "heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"};
    const auto found = std::ranges::find(names, value.string());
    if (found == std::end(names)) {
      value.fail("names an unknown component");
    }

    return static_cast<ComponentKind>(found - std::begin(names));
  }

  void ComponentShapeReader::fields(const lua::Value& value, ComponentKind kind) {
    switch (kind) {
    case ComponentKind::label:
      value.onlyFields({"ui", "text", "tone", "priority", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough"});
      break;
    case ComponentKind::icon:
      value.onlyFields({"ui", "name", "glyph", "tone", "priority"});
      break;
    case ComponentKind::mark:
    case ComponentKind::metric:
      value.onlyFields({"ui", "name", "priority"});
      break;
    case ComponentKind::meter:
      value.onlyFields({"ui", "value", "label", "text", "marker", "tone", "priority"});
      break;
    case ComponentKind::meter_row:
      value.onlyFields({"ui", "value", "label", "detail", "marker", "tone", "priority"});
      break;
    case ComponentKind::sparkline:
      value.onlyFields({"ui", "values", "max", "tone", "priority"});
      break;
    case ComponentKind::badge:
    case ComponentKind::heading:
    case ComponentKind::text:
      value.onlyFields({"ui", "text", "tone", "priority"});
      break;
    case ComponentKind::clock:
      value.onlyFields({"ui", "format", "tone", "priority"});
      break;
    case ComponentKind::machines:
    case ComponentKind::divider:
      value.onlyFields({"ui", "priority"});
      break;
    case ComponentKind::group:
      value.onlyFields({"ui", "mark", "icon", "tooltip", "on_click", "url", "priority", "tone", "summary"}, true);
      break;
    case ComponentKind::key_value:
      value.onlyFields({"ui", "key", "value", "tone", "priority"});
      break;
    case ComponentKind::callout:
      value.onlyFields({"ui", "icon", "text", "detail", "button", "tone", "priority"});
      break;
    case ComponentKind::button:
      value.onlyFields({"ui", "text", "action", "url", "primary", "tone", "priority"});
      break;
    case ComponentKind::actions:
      value.onlyFields({"ui", "priority"}, true);
      break;
    }
  }

  tbc::view<std::string_view, tbc::lt::a> ComponentShapeReader::text(const lua::Value& value, const char* name, tbc::view<std::string_view, tbc::lt::a> fallback) {
    const auto field = value.field(name);

    return field.present() ? field.string() : fallback;
  }

  void ComponentShapeReader::optionalIcon(const lua::Value& value) {
    if (value.present()) {
      uiIcon(value);
    }
  }

  void ComponentShapeReader::finiteNumber(const lua::Value& value) {
    value.boundedNumber(0, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());
  }

  std::size_t ComponentShapeReader::samples(const lua::Value& value, LimitNotices& limits) {
    finiteNumber(value.field("max"));
    const auto values = value.field("values");
    const auto total = values.listLength();
    const auto kept = std::min(total, maximum_samples);
    if (total > kept) {
      limits.add({"bars.max_node_samples", "sparkline values", maximum_samples, total, {}});
    }

    for (std::size_t index = total - kept + 1; index <= total; ++index) {
      const auto sample = values.element(index);
      if (!sample.present()) {
        sample.fail("must be a number");
      }

      sample.boundedNumber(0, 0, std::numeric_limits<double>::max());
    }

    return kept;
  }

  ComponentTone ComponentValuesReader::tone(const lua::Value& value) {
    if (!value.present()) {
      return ComponentTone::neutral;
    }

    const auto* const found = std::ranges::find(component_tone_names, value.string());
    if (found == component_tone_names.end()) {
      value.fail("names an unknown component tone");
    }

    return static_cast<ComponentTone>(found - component_tone_names.begin());
  }

  std::optional<std::string_view> ComponentValuesReader::icon(const lua::Value& value) {
    if (!value.present()) {
      return std::nullopt;
    }

    uiIcon(value);
    return value.string();
  }

  std::optional<UiMark> ComponentValuesReader::mark(const lua::Value& value) {
    if (!value.present()) {
      return std::nullopt;
    }

    uiMark(value);
    return static_cast<UiMark>(std::ranges::find(ui_mark_names, value.string()) - ui_mark_names.begin());
  }

  ComponentMetric ComponentValuesReader::metric(const lua::Value& value) {
    const auto* const found = std::ranges::find(component_metric_names, value.string());
    if (found == component_metric_names.end()) {
      value.fail("names an unknown component metric");
    }

    return static_cast<ComponentMetric>(found - component_metric_names.begin());
  }

  std::optional<double> ComponentValuesReader::number(const lua::Value& value) {
    if (!value.present()) {
      return std::nullopt;
    }

    return value.boundedNumber(0, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());
  }

  bool componentAllowed(ComponentKind kind, ComponentPlace place) noexcept {
    switch (place) {
    case ComponentPlace::bar:
      return kind <= ComponentKind::group;
    case ComponentPlace::panel:
      return true;
    case ComponentPlace::group:
      return kind < ComponentKind::group;
    case ComponentPlace::tooltip:
      return kind != ComponentKind::group && kind != ComponentKind::callout && kind != ComponentKind::actions && kind != ComponentKind::button;
    case ComponentPlace::buttons:
      return kind == ComponentKind::button;
    }

    return false;
  }

  ComponentTreeWalker::ComponentTreeWalker(lua_State& state, LimitNotices& limits) noexcept
      : state_(state),
        limits_(limits) {}

  void ComponentTreeWalker::walk(const lua::Value& value, ComponentPosition position) {
    const auto original_top = lua_gettop(&state_);

    value.pushCopy();
    try {
      push(position);
      while (frame_count_ != 0) {
        advance();
      }
    } catch (...) {
      while (frame_count_ != 0) {
        pop();
      }

      lua_settop(&state_, original_top);

      throw;
    }

    lua_settop(&state_, original_top);
  }

  void ComponentTreeWalker::push(ComponentPosition position) {
    if (frame_count_ == frames_.size()) {
      throw std::length_error{"Component traversal stack exceeded"};
    }

    auto& frame = frames_[frame_count_++];

    frame.index = lua_gettop(&state_);
    frame.value.emplace(&state_, frame.index, "component");
    frame.position = position;
    frame.phase = Phase::visit;
    frame.tooltip = false;
    frame.next = 0;
    frame.count = 0;
  }

  void ComponentTreeWalker::pop() noexcept {
    auto& frame = frames_[--frame_count_];

    frame.value.reset();
    lua_settop(&state_, frame.index - 1);
  }

  void ComponentTreeWalker::advance() {
    auto& frame = frames_[frame_count_ - 1];

    switch (frame.phase) {
    case Phase::visit:
      visit();
      break;
    case Phase::list:
    case Phase::children:
      if (frame.next == frame.count) {
        frame.phase = frame.tooltip ? Phase::tooltip : Phase::done;
      } else {
        lua_rawgeti(&state_, frame.index, static_cast<lua_Integer>(++frame.next));
        push(frame.child);
      }

      break;
    case Phase::tooltip:
    case Phase::button: {
      const bool tooltip = frame.phase == Phase::tooltip;

      frame.phase = Phase::done;
      lua_getfield(&state_, frame.index, tooltip ? "tooltip" : "button");
      auto child = frame.child;

      child.place = tooltip ? ComponentPlace::tooltip : ComponentPlace::buttons;
      child.priority = ComponentPosition::default_priority;
      push(child);
    } break;
    case Phase::done:
      pop();
      break;
    }
  }

  const lua::Value& ComponentTreeWalker::frameValue(const Frame& frame) {
    if (!frame.value) {
      throw std::logic_error{"Component traversal frame has no value"};
    }

    return *frame.value;
  }

  void ComponentTreeWalker::visit() {
    auto& frame = frames_[frame_count_ - 1];
    const auto& value = frameValue(frame);
    const auto position = frame.position;

    frame.phase = Phase::done;
    if (!value.present()) {
      return;
    }

    if (value.is(LUA_TSTRING)) {
      static_cast<void>(node(value, {.text = value.string(), .priority = position.priority}, position));
      return;
    }

    if (!value.is(LUA_TTABLE)) {
      value.fail("components must be text, a component or a list");
    }

    if (value.field("ui").present()) {
      component();
      return;
    }

    if (value.field("text").present() || value.field("icon").present()) {
      static_cast<void>(node(value, ComponentShapeReader::segment(value, position.priority), position));
      return;
    }

    if (position.depth == maximum_list_depth) {
      value.fail("exceeds the component nesting limit");
    }

    frame.child = position;
    ++frame.child.depth;
    frame.count = value.arraySize();
    frame.phase = Phase::list;
  }

  void ComponentTreeWalker::component() {
    auto& frame = frames_[frame_count_ - 1];
    const auto& value = frameValue(frame);
    const auto shape = ComponentShapeReader::read(value, frame.position.priority, limits_);
    const auto parent = node(value, shape, frame.position);
    if (!parent) {
      return;
    }

    frame.child = {.parent = parent->index, .rank = parent->rank};
    switch (shape.kind) {
    case ComponentKind::group:
      frame.child.place = ComponentPlace::group;
      frame.child.priority = shape.priority;
      frame.tooltip = true;
      frame.count = value.listLength();
      frame.phase = Phase::children;
      break;
    case ComponentKind::actions:
      frame.child.place = ComponentPlace::buttons;
      frame.count = value.listLength();
      frame.phase = Phase::children;
      break;
    case ComponentKind::callout:
      frame.phase = Phase::button;
      break;
    default:
      break;
    }
  }

  std::optional<ComponentParent> ComponentTreeWalker::node(const lua::Value& value, const ComponentShape& shape, const ComponentPosition& position) const {
    if (!componentAllowed(shape.kind, position.place)) {
      value.fail("contains a component unsupported in this position");
    }

    return place(value, shape, position);
  }

  class CommandArgumentsValidator {
  public:
    inline static bool validate(const lua::Value& command) {
      const auto count = command.arraySize();
      if (count == 0 || count > maximum_arguments) {
        command.fail("must contain 1..32 arguments");
      }

      std::size_t bytes = 0;
      bool receives_choice = false;

      for (std::size_t index = 0; index < count; ++index) {
        const auto value = command.element(index + 1);
        const auto argument = value.string();

        bytes += argument.size();
        if ((index == 0 && argument.empty()) || argument.contains('\0') || bytes > maximum_bytes) {
          value.fail("is not a valid bounded command argument");
        }

        receives_choice |= index > 0 && argument == "{}";
      }

      return receives_choice;
    }

  private:
    static constexpr std::size_t maximum_arguments = 32;
    static constexpr std::size_t maximum_bytes = 4096;
  };

  SourceSetting SourceReader::read(const lua::Value& source, bool panel) {
    const auto kind = source.field("bar_kind");
    const auto* const found = std::ranges::find(source_kind_names, kind.string());
    if (found == source_kind_names.end()) {
      source.fail("names an unsupported bar source");
    }

    SourceSetting setting;

    setting.kind = static_cast<SourceKind>(found - source_kind_names.begin());
    if (setting.kind != SourceKind::dynamic && setting.kind != SourceKind::command) {
      return setting;
    }

    const auto every = source.field("every_ms");
    if (!panel || every.present()) {
      setting.every_ms = static_cast<std::uint32_t>(every.boundedInteger(SourceSetting::default_every_ms, SourceSetting::every_ms_bounds.minimum, SourceSetting::every_ms_bounds.maximum));
    }

    setting.render = source.field("render").present();
    setting.timeout_ms = static_cast<std::uint32_t>(source.field("timeout_ms").boundedInteger(SourceSetting::default_timeout_ms, SourceSetting::timeout_ms_bounds.minimum, SourceSetting::timeout_ms_bounds.maximum));
    return setting;
  }

  SourceSetting SourceReader::dynamic(const lua::Value& source, bool panel) {
    const auto kind = source.field("bar_kind");
    const bool command = kind.string() == "command";
    if (command) {
      source.onlyFields({"bar_kind", "command", "every_ms", "timeout_ms", "render"});
      CommandArgumentsValidator::validate(source.field("command"));
    } else {
      if (kind.string() != "dynamic") {
        kind.fail("requires a render function or a command");
      }

      source.onlyFields({"bar_kind", "every_ms", "render"});
    }

    const auto setting = read(source, panel);
    const auto render = source.field("render");
    if ((!command || render.present()) && !render.is(LUA_TFUNCTION)) {
      render.fail("must be a function");
    }

    return setting;
  }

  template <CommandTabStore Commands>
  class ComponentValidator {
  public:
    inline explicit ComponentValidator(const BasicActionValidator<Commands>& actions, LimitNotices& limits)
        : actions_(actions),
          limits_(limits) {}

    inline void validate(const lua::Value& value) {
      // Rank the whole result before validating actions: components excluded
      // from staging must not retain commands or reject the configuration.
      walk(value, {});
      budget_.prepare();
      counting_ = false;
      walk(value, {});
      budget_.report(limits_);
    }

  private:
    using Place = ComponentPlace;

    struct Position {
      Place place = Place::bar;
      unsigned priority = 50;
      unsigned rank = std::numeric_limits<std::uint8_t>::max();
      unsigned depth = 0;
    };

    inline void walk(const lua::Value& value, Position position) {
      if (!value.present()) {
        return;
      }

      if (value.is(LUA_TSTRING)) {
        append(value, {.text = value.string(), .priority = position.priority}, position);
        return;
      }

      if (value.field("ui").present()) {
        component(value, position);
        return;
      }

      if (value.field("text").present() || value.field("icon").present()) {
        append(value, ComponentShapeReader::segment(value, position.priority), position);
        return;
      }

      if (position.depth == maximum_list_depth) {
        value.fail("exceeds the component nesting limit");
      }

      ++position.depth;
      const auto count = value.arraySize();

      for (std::size_t index = 1; index <= count; ++index) {
        walk(value.element(index), position);
      }
    }

    inline void component(const lua::Value& value, Position position) {
      const auto shape = ComponentShapeReader::read(value, position.priority, limits_);
      if (!append(value, shape, position)) {
        return;
      }

      const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);

      if (shape.kind == ComponentKind::group) {
        children(value, {Place::group, shape.priority, rank});
        walk(value.field("tooltip"), {Place::tooltip, default_priority, rank});
      } else if (shape.kind == ComponentKind::callout) {
        walk(value.field("button"), {Place::buttons, default_priority, rank});
      } else if (shape.kind == ComponentKind::actions) {
        children(value, {Place::buttons, default_priority, rank});
      }
    }

    inline void children(const lua::Value& value, Position position) {
      const auto count = value.listLength();

      for (std::size_t index = 1; index <= count; ++index) {
        walk(value.element(index), position);
      }
    }

    inline bool append(const lua::Value& value, const ComponentShape& shape, Position position) {
      if (!componentAllowed(shape.kind, position.place)) {
        value.fail("contains a component unsupported in this position");
      }

      const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);

      if (counting_) {
        budget_.count(shape, rank);
        return true;
      }

      if (!budget_.admit(shape, rank)) {
        return false;
      }

      if (shape.action_field != nullptr && !actions_.component(value.field(shape.action_field))) {
        budget_.release(shape, rank);
        return false;
      }

      if (budget_.nodesFull()) {
        return false;
      }

      validateUrl(value, shape.url);
      if (!budget_.stage(shape)) {
        return false;
      }

      printableUiText(value, shape.text);
      printableUiText(value, shape.detail);
      return true;
    }

    inline static void validateUrl(const lua::Value& value, std::string_view url) {
      if (url.empty()) {
        return;
      }

      if (url.size() > maximum_url_bytes || url.contains(' ') || (!url.starts_with("https://") && !url.starts_with("http://"))) {
        value.fail("requires an HTTP or HTTPS URL without spaces");
      }

      printableUiText(value, url);
    }

    static constexpr unsigned maximum_list_depth = 4;
    static constexpr unsigned default_priority = 50;
    static constexpr std::size_t maximum_url_bytes = 1024;
    const BasicActionValidator<Commands>& actions_;
    LimitNotices& limits_;
    ComponentBudget budget_;
    bool counting_ = true;
  };

  template <CommandTabStore Commands>
  class BarsValidator {
  public:
    inline explicit BarsValidator(const BasicActionValidator<Commands>& actions, LimitNotices& limits)
        : actions_(actions),
          limits_(limits) {}

    inline void validate(const lua::Value& bars) const {
      if (!bars.present()) {
        return;
      }

      bars.onlyFields({"bottom", "top", "sidebar_footer"});
      bottom(bars.field("bottom"));
      const auto top = bars.field("top");
      if (top.present()) {
        top.onlyFields({"right"});
        const auto right = top.field("right");
        if (right.present() && source(right) == Source::tabs) {
          right.fail("cannot contain tabs");
        }
      }

      const auto footer = bars.field("sidebar_footer");
      if (footer.present()) {
        const auto count = footer.arraySize();
        if (count > maximum_footer_slots) {
          footer.fail(std::format("accepts at most {} slots", maximum_footer_slots).c_str());
        }

        for (std::size_t index = 1; index <= count; ++index) {
          if (source(footer.element(index)) == Source::tabs) {
            footer.fail("cannot contain tabs");
          }
        }
      }
    }

  private:
    enum class Source {
      content,
      tabs,
    };

    inline void bottom(const lua::Value& bar) const {
      if (!bar.present()) {
        return;
      }

      bar.onlyFields({"left", "center", "right"});
      unsigned tabs = 0;

      for (const auto* name : {"left", "center", "right"}) {
        const auto value = bar.field(name);
        if (value.present() && source(value) == Source::tabs) {
          ++tabs;
        }
      }

      if (tabs != 1) {
        bar.fail("must contain exactly one tabs source");
      }
    }

    inline Source source(const lua::Value& value) const {
      const auto kind_value = value.field("bar_kind");
      const auto kind = kind_value.string();
      if (kind == "tabs" || kind == "metrics" || kind == "machines") {
        value.onlyFields({"bar_kind"});
        return kind == "tabs" ? Source::tabs : Source::content;
      }

      if (kind == "static") {
        value.onlyFields({"bar_kind", "value"});
        ComponentValidator{actions_, limits_}.validate(value.field("value"));
      } else {
        static_cast<void>(SourceReader::dynamic(value));
      }

      return Source::content;
    }

    static constexpr std::size_t maximum_footer_slots = 3;
    const BasicActionValidator<Commands>& actions_;
    LimitNotices& limits_;
  };

  lua::Value BarsReader::content(const lua::Value& source) {
    return source.field("value");
  }

  bool KeyChord::has(Modifier modifier) const noexcept {
    return (modifiers & static_cast<unsigned>(modifier)) != 0;
  }

  void BindingKeymap::setPrefix(KeyChord prefix) noexcept {
    prefix_ = prefix;
    for (auto& binding : std::span{bindings_}.first(count_)) {
      if (binding.prefixed) {
        binding.keys[0] = prefix;
      }
    }
  }

  KeyChord BindingKeymap::prefix() const noexcept {
    return prefix_;
  }

  void BindingKeymap::clear() noexcept {
    count_ = 0;
  }

  void BindingKeymap::append(Sequence sequence) noexcept {
    bindings_[count_++] = sequence;
  }

  void BindingKeymap::report(LimitNotices& limits) const noexcept {
    std::size_t wanted = count_;

    for (const auto suffix : defaultSuffixes()) {
      const bool overridden = std::ranges::any_of(std::span{bindings_}.first(count_), [&](const Sequence& binding) {
        return binding.keys[0] == prefix_ && (binding.length == 1 || binding.keys[1] == suffix);
      });

      wanted += !overridden;
    }

    if (wanted > maximum_bindings) {
      limits.add({"config.max_bindings", "key bindings", maximum_bindings, wanted, {}});
    }
  }

  void KeyChordValidator::validate(const lua::Value& value) {
    parse(value);
  }

  KeyChord KeyChordValidator::parse(const lua::Value& value) {
    auto remaining = value.string();
    KeyChord chord;
    bool has_key = false;

    for (;;) {
      const auto separator = remaining.find('+');
      const auto part = remaining.substr(0, separator);
      if (part.empty() || has_key) {
        value.fail("contains an empty key or a modifier after its key");
      }

      const auto modifier = identifyModifier(part);
      if (modifier != Modifier::none) {
        const auto bit = static_cast<unsigned>(modifier);
        if ((chord.modifiers & bit) != 0) {
          value.fail("repeats a modifier");
        }

        chord.modifiers |= bit;
      } else {
        parseKey(value, part, chord);
        has_key = true;
      }

      if (separator == std::string_view::npos) {
        break;
      }

      remaining.remove_prefix(separator + 1);
    }

    if (!has_key) {
      value.fail("has no key");
    }

    return chord;
  }

  bool KeyChordValidator::matches(std::string_view text, std::string_view name) noexcept {
    return text.size() == name.size() && std::equal(text.begin(), text.end(), name.begin(), [](char left, char right) {
      return asciiLower(left) == right;
    });
  }

  KeyChord::Modifier KeyChordValidator::identifyModifier(std::string_view name) noexcept {
    if (matches(name, "ctrl") || matches(name, "control")) {
      return Modifier::control;
    }

    if (matches(name, "alt")) {
      return Modifier::alt;
    }

    if (matches(name, "shift")) {
      return Modifier::shift;
    }

    if (matches(name, "super") || matches(name, "cmd") || matches(name, "command")) {
      return Modifier::super;
    }

    return Modifier::none;
  }

  void KeyChordValidator::parseKey(const lua::Value& value, std::string_view name, KeyChord& chord) {
    constexpr std::pair<std::string_view, Key> named_keys[]{{"up", Key::up}, {"down", Key::down}, {"left", Key::left}, {"right", Key::right}, {"home", Key::home}, {"end", Key::end}, {"delete", Key::erase}, {"del", Key::erase}, {"pageup", Key::page_up}, {"page-up", Key::page_up}, {"pagedown", Key::page_down}, {"page-down", Key::page_down}, {"enter", Key::enter}, {"return", Key::enter}, {"escape", Key::escape}, {"esc", Key::escape}, {"backspace", Key::backspace}, {"tab", Key::tab}, {"backtab", Key::back_tab}};

    for (const auto& [known, key] : named_keys) {
      if (matches(name, known)) {
        chord.key = key;
        if (key == Key::tab && chord.modifiers == static_cast<unsigned>(Modifier::shift)) {
          chord.key = Key::back_tab;
          chord.modifiers = 0;
        }

        return;
      }
    }

    if (matches(name, "space")) {
      name = " ";
    } else if (matches(name, "plus")) {
      name = "+";
    }

    validateUtf8(name);
    const auto codepoints = std::ranges::count_if(name, [](unsigned char byte) {
      return (byte & 0xc0) != 0x80;
    });
    if (codepoints != 1) {
      value.fail("must name one key");
    }

    std::memcpy(&chord.character, name.data(), name.size());
    if (name.size() == 1 && (chord.has(Modifier::control) || chord.has(Modifier::super))) {
      chord.character = static_cast<unsigned char>(asciiLower(name.front()));
    }

    if (chord.has(Modifier::shift) && !chord.has(Modifier::super)) {
      const bool letter = name.size() == 1 && asciiLower(name.front()) >= 'a' && asciiLower(name.front()) <= 'z';
      if (chord.has(Modifier::control) || (!letter && name != " ")) {
        value.fail("cannot represent this shifted character");
      }

      chord.character = letter ? static_cast<unsigned char>(asciiLower(name.front()) - ('a' - 'A')) : ' ';
      chord.modifiers &= ~static_cast<unsigned>(Modifier::shift);
    }
  }

  BindingSetting BindingReader::setting(const lua::Value& binding, KeyChord prefix) {
    binding.onlyFields({"keys", "action", "expression", "prefixed"});
    const auto prefixed = binding.field("prefixed");
    if (!prefixed.present()) {
      prefixed.fail("must be a boolean");
    }

    BindingSetting setting{.prefixed = prefixed.boolean(false)};
    const auto offset = static_cast<std::size_t>(setting.prefixed);
    const auto keys = binding.field("keys");
    const auto key_count = keys.listLength();
    if (key_count == 0 || key_count > BindingSetting::maximum_keys - offset) {
      keys.fail("has an invalid number of keys");
    }

    if (setting.prefixed) {
      setting.keys[0] = prefix;
    }

    setting.length = key_count + offset;
    for (std::size_t key = 0; key < key_count; ++key) {
      setting.keys[key + offset] = KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(key) + 1));
    }

    setting.expression = binding.field("expression").boolean(false);
    return setting;
  }

  template <CommandTabStore Commands>
  void BindingValidator::validate(const lua::Value& bindings, const BasicActionValidator<Commands>& actions, BindingKeymap& keymap, LimitNotices& limits) {
    if (!bindings.present()) {
      return;
    }

    constexpr auto maximum_bindings = BindingReader::maximum_bindings;
    const auto listed = bindings.listLength();

    keymap.clear();
    if (listed > maximum_bindings) {
      limits.add({"config.max_bindings", "key bindings", maximum_bindings, listed, {}});
    }

    BindingReader::read(bindings, keymap.prefix(), [&](const BindingSetting& binding, const lua::Value& action) {
      BindingKeymap::Sequence sequence{.length = binding.length, .prefixed = binding.prefixed};

      std::ranges::copy(std::span{binding.keys}.first(std::min(binding.length, sequence.keys.size())), sequence.keys.begin());
      if (actions.validate(action, binding.expression)) {
        keymap.append(sequence);
      }
    });
  }

  PluginWorkerOptions PluginWorkerOptions::parse(std::span<char* const> arguments) {
    if (arguments.size() != argument_count) {
      throw std::invalid_argument{"Expected plugin-worker ENTRY ACTION SIDEBAR TAB_COUNT ACTIVE_TAB_INDEX PANE_COUNT FOCUSED_PANE_ID"};
    }

    std::array<char*, argument_count> fields = {};

    std::ranges::copy(arguments, fields.begin());
    const auto [entry_arg, action_arg, sidebar_arg, tab_count_arg, active_tab_index_arg, pane_count_arg, focused_pane_id_arg] = fields;

    const std::string_view sidebar = {sidebar_arg};
    if (sidebar != "0" && sidebar != "1") {
      throw std::invalid_argument{"Invalid plugin worker sidebar flag"};
    }

    const std::string_view action = {action_arg};
    if (action.empty()) {
      throw std::invalid_argument{"Empty plugin action"};
    }

    for (const char byte : action) {
      if ((byte < 'a' || byte > 'z') && (byte < 'A' || byte > 'Z') && (byte < '0' || byte > '9') && byte != '_' && byte != '-' && byte != '.') {
        throw std::invalid_argument{"Invalid plugin action name"};
      }
    }

    const BindingContext context = {
        .sidebar_visible = sidebar == "1",
        .tab_count = number<std::uint16_t>(tab_count_arg),
        .active_tab_index = number<std::uint16_t>(active_tab_index_arg),
        .pane_count = number<std::uint16_t>(pane_count_arg),
        .focused_pane_id = number<std::uint64_t>(focused_pane_id_arg),
    };

    return {
        .entry = entry_arg,
        .action = action_arg,
        .context = context,
    };
  }

  template <std::unsigned_integral Integer>
  Integer PluginWorkerOptions::number(std::string_view text) {
    const auto value = unsignedNumber<Integer>(text);
    if (!value) {
      throw std::invalid_argument{value.error() == NumberError::overflow ? "Plugin worker integer exceeds its bounds" : "Invalid plugin worker integer"};
    }

    return *value;
  }

  CallbackInvocation::CallbackInvocation(int reference, BindingContext context)
      : reference_(reference),
        context_(context) {}

  int CallbackInvocation::invoke(lua_State* state) {
    const auto& invocation = *static_cast<CallbackInvocation*>(lua_touserdata(state, 1));

    lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.reference_);
    invocation.pushContext(state);
    lua_call(state, 1, 1);

    return 1;
  }

  void CallbackInvocation::pushContext(lua_State* state) const {
    lua_newtable(state);
    lua::setField(state, "sidebar_visible", static_cast<bool>(context_.sidebar_visible));
    lua::setField(state, "tab_count", static_cast<lua_Integer>(context_.tab_count));
    lua::setField(state, "active_tab_index", static_cast<lua_Integer>(static_cast<std::uint32_t>(context_.active_tab_index) + 1));
    lua::setField(state, "pane_count", static_cast<lua_Integer>(context_.pane_count));
    lua::setField(state, "focused_pane_id", static_cast<lua_Integer>(context_.focused_pane_id));
    lua::pushReadOnly(state, "callback context is immutable");
  }

  InputDecisionSetting CallbackResultReader::decision(const lua::Value& result) {
    using Kind = InputDecisionSetting::Kind;

    const auto kind_value = result.field("input_kind");
    const auto kind = kind_value.string();
    InputDecisionSetting decision;

    if (kind == "consume" || kind == "forward") {
      result.onlyFields({"input_kind"});
      decision.kind = kind == "consume" ? Kind::consume : Kind::forward;
    } else if (kind == "keys") {
      result.onlyFields({"input_kind", "keys"});
      decision.kind = Kind::keys;
      keys(result.field("keys"), decision);
    } else if (kind == "paste") {
      result.onlyFields({"input_kind", "text"});
      decision.kind = Kind::paste;
      decision.text = result.field("text").string();
    } else {
      kind_value.fail("names an unknown input decision");
    }

    return decision;
  }

  void CallbackResultReader::keys(const lua::Value& keys, InputDecisionSetting& decision) {
    const auto count = keys.listLength();
    if (count == 0 || count > InputDecisionSetting::maximum_keys) {
      keys.fail("must contain one to sixteen keys");
    }

    for (std::size_t index = 0; index < count; ++index) {
      decision.keys[index] = KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(index) + 1));
    }

    decision.length = count;
  }

  PickItemSetting PickItemsReader::option(const lua::Value& item) {
    PickItemSetting setting;

    if (item.is(LUA_TSTRING)) {
      setting.label = item.string();
      return setting;
    }

    item.onlyFields({"label", "value", "detail", "selected", "swatch"});
    setting.label = item.field("label").string();
    if (const auto value = item.field("value"); value.present()) {
      setting.value = value.string();
    }

    if (const auto detail = item.field("detail"); detail.present()) {
      setting.detail = detail.string();
    }

    setting.selected = item.field("selected").boolean(false);
    setting.swatch = swatch(item.field("swatch"));
    return setting;
  }

  std::optional<PickItemSetting::Swatch> PickItemsReader::swatch(const lua::Value& value) {
    if (!value.present()) {
      return std::nullopt;
    }

    PickItemSetting::Swatch result{};
    if (value.arraySize() != result.size()) {
      value.fail("must contain three RGB colors");
    }

    constexpr int hexadecimal_base = 16;

    for (std::size_t index = 0; index < result.size(); ++index) {
      const auto color = value.element(static_cast<lua_Integer>(index) + 1);

      hexadecimalColor(color);
      const auto text = color.string();
      const auto parsed = std::from_chars(text.data() + 1, text.data() + text.size(), result[index], hexadecimal_base);
      if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
        color.fail("must be an RGB color");
      }
    }

    return result;
  }

  class PickItemsValidator {
  public:
    inline explicit PickItemsValidator(LimitNotices& limits)
        : limits_(limits) {}

    inline void validate(const lua::Value& items) {
      std::size_t count = 0;

      PickItemsReader::read(items, [&](const PickItemSetting& option, const lua::Value& item) {
        keep(item, option.label, option.value.value_or(option.label), option.detail.value_or(std::string_view{}));
        ++count;
      });

      if (count > maximum_items) {
        limits_.add({"picks.max_items", "options", maximum_items, count, {}});
      }

      if (text_full_) {
        limits_.add({"picks.max_text_bytes", "option text bytes", maximum_text_bytes, offered_text_bytes_, {}});
      }

      const std::array<LimitReach, 3> text_limits{{
          {"picks.max_label_bytes", "label bytes", maximum_label_bytes, longest_label_, {}},
          {"picks.max_value_bytes", "value bytes", maximum_value_bytes, longest_value_, {}},
          {"picks.max_detail_bytes", "detail bytes", maximum_detail_bytes, longest_detail_, {}},
      }};

      for (const auto& reach : text_limits) {
        if (reach.requested > reach.value) {
          limits_.add(reach);
        }
      }
    }

  private:
    inline void keep(const lua::Value& item, std::string_view label, std::string_view value, std::string_view detail) {
      offered_text_bytes_ += label.size() + value.size() + detail.size();
      longest_label_ = std::max(longest_label_, label.size());
      longest_detail_ = std::max(longest_detail_, detail.size());
      longest_value_ = std::max(longest_value_, value.size());
      label = utf8Prefix(label, maximum_label_bytes);
      detail = utf8Prefix(detail, maximum_detail_bytes);
      if (value.size() > maximum_value_bytes) {
        return;
      }

      if (kept_items_ == maximum_items || text_full_) {
        return;
      }

      if (label.empty() || value.empty()) {
        item.fail("needs a nonempty label and value");
      }

      printableUiText(item, label);
      printableUiText(item, detail);
      printableUiText(item, value, true);

      const auto needed = label.size() + detail.size() + (label == value ? 0 : value.size());
      if (text_bytes_ + needed > maximum_text_bytes) {
        text_full_ = true;
        return;
      }

      text_bytes_ += needed;
      ++kept_items_;
    }

    static constexpr std::size_t maximum_items = 4096;
    static constexpr std::size_t maximum_text_bytes = 256 * 1024;
    static constexpr std::size_t maximum_label_bytes = 128;
    static constexpr std::size_t maximum_value_bytes = 512;
    static constexpr std::size_t maximum_detail_bytes = 128;

    LimitNotices& limits_;
    std::size_t kept_items_ = 0;
    std::size_t text_bytes_ = 0;
    std::size_t offered_text_bytes_ = 0;
    std::size_t longest_label_ = 0;
    std::size_t longest_value_ = 0;
    std::size_t longest_detail_ = 0;
    bool text_full_ = false;
  };

  tbc::view<PanelSetting, tbc::lt::a> ClientDefinitionsReader::panelSetting(tbc::view<std::string_view, tbc::lt::a> name, const lua::Value& definition, LimitNotices& limits) {
    definition.onlyFields({"panel_kind", "title", "mark", "icon", "width", "source", "refresh"});
    PanelSetting setting;

    setting.heading = {.name = name, .title = NamedDefinitionsValidator::heading(name, definition, limits)};
    const auto mark = definition.field("mark");
    if (mark.present()) {
      uiMark(mark);
      setting.mark = static_cast<UiMark>(std::ranges::find(ui_mark_names, mark.string()) - ui_mark_names.begin());
    }

    const auto icon = definition.field("icon");
    if (icon.present()) {
      uiIcon(icon);
      setting.icon = icon.string();
    }

    setting.width = static_cast<std::uint16_t>(definition.field("width").boundedInteger(PanelSetting::default_width, PanelSetting::width_bounds.minimum, PanelSetting::width_bounds.maximum));
    setting.source = SourceReader::dynamic(definition.field("source"), true);
    return setting;
  }

  tbc::view<PickSetting, tbc::lt::a> ClientDefinitionsReader::pickSetting(tbc::view<std::string_view, tbc::lt::a> name, const lua::Value& definition, LimitNotices& limits) {
    definition.onlyFields({"pick_kind", "title", "command", "items", "on_select", "timeout_ms", "refresh"});
    PickSetting setting;

    setting.heading = {.name = name, .title = NamedDefinitionsValidator::heading(name, definition, limits)};
    setting.timeout_ms = static_cast<std::uint32_t>(definition.field("timeout_ms").boundedInteger(SourceSetting::default_timeout_ms, PickSetting::timeout_ms_bounds.minimum, PickSetting::timeout_ms_bounds.maximum));
    const auto command = definition.field("command");
    if (command.present()) {
      CommandArgumentsValidator::validate(command);
    }

    const auto items = definition.field("items");
    if (items.present()) {
      if (command.present()) {
        if (!items.is(LUA_TFUNCTION)) {
          items.fail("must be a function when a command is provided");
        }
      } else {
        PickItemsValidator{limits}.validate(items);
      }
    } else if (!command.present()) {
      definition.fail("requires items or a command");
    }

    if (!CommandArgumentsValidator::validate(definition.field("on_select"))) {
      definition.fail("requires a choice placeholder after the program");
    }

    setting.command = command.present();
    setting.render = items.is(LUA_TFUNCTION);
    setting.refresh = definition.field("refresh").boolean(true);
    return setting;
  }

  tbc::view<lua::Value, tbc::lt::a> PromptReader::begin(const lua::Value& table, PromptSettings& settings) {
    table.onlyFields({"mode", "skin", "motion", "ghost", "keymap", "max_lines", "bindings"});
    settings.mode = optionalChoice<PromptMode>(table.field("mode"), prompt_mode_names);
    return table.field("bindings");
  }

  std::size_t PromptReader::countBindings(const lua::Value& bindings, PromptSettings& settings) {
    if (!bindings.present()) {
      return 0;
    }

    settings.bindings = true;
    const auto count = bindings.listLength();
    if (count > PromptBounds::bindings) {
      bindings.fail("has more than 256 bindings");
    }

    return count;
  }

  PromptBindingSetting PromptReader::readBinding(const lua::Value& entry) {
    entry.onlyFields({"keys", "action", "mode"});
    const auto chord = KeyChordValidator::parse(entry.field("keys"));
    const auto action = entry.field("action");
    const auto found = std::ranges::find(prompt_action_names, action.string());
    if (found == prompt_action_names.end()) {
      action.fail("names an unknown prompt action");
    }

    const auto mode = optionalChoice<std::uint8_t>(entry.field("mode"), prompt_binding_mode_names);

    return PromptBindingSetting{.chord = chord, .action = static_cast<std::uint8_t>(found - prompt_action_names.begin()), .normal = mode == 1};
  }

  void PromptReader::finish(const lua::Value& table, PromptSettings& settings) {
    settings.skin = optionalChoice<PromptSkin>(table.field("skin"), prompt_skin_names);
    settings.motion = optionalChoice<PromptMotion>(table.field("motion"), prompt_motion_names);
    settings.keymap = optionalChoice<PromptKeymap>(table.field("keymap"), prompt_keymap_names);
    settings.ghost = optionalBoolean(table.field("ghost"));
    if (const auto lines = table.field("max_lines"); lines.present()) {
      settings.max_lines = static_cast<std::uint8_t>(lines.boundedInteger(PromptBounds::max_lines.minimum, PromptBounds::max_lines.minimum, PromptBounds::max_lines.maximum));
    }
  }

  ClientSettings ClientReader::readSettings(const lua::Value& client) {
    ClientSettings settings;

    if (!client.present()) {
      return settings;
    }

    client.onlyFields({"prefix", "theme", "icons", "sidebar", "pane_gaps", "editor", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "panels", "picks", "history", "components", "prompt"});
    settings.input = input(client);
    settings.pane_gaps = optionalBoolean(client.field("pane_gaps"));
    settings.editor = printableText(client.field("editor"), maximum_editor_bytes, false);
    settings.window_title = printableText(client.field("window_title"), maximum_window_title_bytes, true);
    sidebar(client.field("sidebar"), settings);
    sound(client.field("sound"), settings.sound);
    notifications(client.field("notifications"), settings);
    history(client.field("history"), settings.history);
    return settings;
  }

  std::size_t ClientReader::slot(std::string_view name, const lua::Value& entry) {
    const auto* const found = std::ranges::find(component_slots, name);
    if (found == component_slots.end()) {
      const auto message = std::string{"names an unknown component slot \""} + std::string{name} + "\"";

      entry.fail(message.c_str());
    }

    if (!entry.is(LUA_TFUNCTION)) {
      entry.fail("must be a function from the context and the item to an element");
    }

    return static_cast<std::size_t>(found - component_slots.begin());
  }

  bool ClientReader::listsBindings(const lua::Value& client) {
    return client.present() && client.field("keybindings").present();
  }

  ClientInputSettings ClientReader::input(const lua::Value& client) {
    ClientInputSettings settings;

    if (!client.present()) {
      return settings;
    }

    const auto prefix = client.field("prefix");
    if (prefix.present()) {
      settings.prefix = KeyChordValidator::parse(prefix);
    }

    const auto table = client.field("input");
    if (table.present()) {
      table.onlyFields({"escape_timeout_ms", "sequence_timeout_ms"});
      const auto timeout = table.field("sequence_timeout_ms");
      if (timeout.present()) {
        constexpr auto bounds = ClientInputSettings::sequence_timeout_bounds;

        settings.sequence_timeout_ms = static_cast<std::uint16_t>(timeout.boundedInteger(bounds.minimum, bounds.minimum, bounds.maximum));
      }
    }

    return settings;
  }

  tbc::view<std::optional<std::string_view>, tbc::lt::a> ClientReader::printableText(const lua::Value& value, std::size_t maximum, bool allow_empty) {
    if (!value.present()) {
      return std::nullopt;
    }

    optionalUtf8Text(value, maximum);
    const auto text = value.string();
    if ((!allow_empty && text.empty()) || std::ranges::any_of(text, [](unsigned char byte) {
          return byte < 0x20 || byte == 0x7f;
        })) {
      value.fail("must contain printable text");
    }

    return text;
  }

  void ClientReader::sidebar(const lua::Value& table, ClientSettings& settings) {
    if (table.present()) {
      table.onlyFields({"visible", "renderer"});
      settings.sidebar_visible = optionalBoolean(table.field("visible"));
    }
  }

  void ClientReader::sound(const lua::Value& table, ClientSettings::Sound& sound) {
    if (table.present()) {
      table.onlyFields({"enabled", "ready", "needs_input"});
      sound.enabled = optionalBoolean(table.field("enabled"));
      sound.ready = optionalBoolean(table.field("ready"));
      sound.needs_input = optionalBoolean(table.field("needs_input"));
    }
  }

  void ClientReader::notifications(const lua::Value& table, ClientSettings& settings) {
    if (table.present()) {
      table.onlyFields({"delivery"});
      settings.delivery = optionalChoice<ClientSettings::Delivery>(table.field("delivery"), std::array<std::string_view, 3>{"telar", "system", "terminal"});
    }
  }

  void ClientReader::history(const lua::Value& table, ClientSettings::History& history) {
    if (table.present()) {
      table.onlyFields({"show_agent_commands", "enter", "match"});
      history.show_agent_commands = optionalBoolean(table.field("show_agent_commands"));
      history.enter = optionalChoice<ClientSettings::HistoryEnter>(table.field("enter"), std::array<std::string_view, 2>{"paste", "run"});
      history.match = optionalChoice<ClientSettings::HistoryMatch>(table.field("match"), std::array<std::string_view, 2>{"fuzzy", "fts"});
    }
  }

  template <CommandTabStore Commands>
  void ClientValidator::validate(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<Commands>& state, const lua::Value* inherited) {
    if (!client.present()) {
      return;
    }

    const auto settings = ClientReader::read(client, [](const PromptBindingSetting&) {});
    if (settings.input.prefix) {
      state.keymap.setPrefix(*settings.input.prefix);
    }

    static_cast<void>(ClientDefinitionsReader::read(client, limits, [](std::size_t, const PanelSetting&, const lua::Value&) {}, [](std::size_t, const PickSetting&, const lua::Value&) {}));
    const ClientDefinitions definitions{client, inherited};
    const BasicActionValidator actions{definitions, limits, state.commands};

    BindingValidator::validate(client.field("keybindings"), actions, state.keymap, limits);
    BarsValidator{actions, limits}.validate(client.field("bars"));
    ClientReader::slots(client, [](std::size_t, const lua::Value&) {});
  }

  template class CommandTabStorage<CommandTabLifetime::configuration>;
  template class CommandTabStorage<CommandTabLifetime::retained>;
  template class BasicActionValidator<CommandTabRegistry>;
  template class BasicActionValidator<RetainedCommandTabRegistry>;
  template void BindingValidator::validate<CommandTabRegistry>(const lua::Value& bindings, const BasicActionValidator<CommandTabRegistry>& actions, BindingKeymap& keymap, LimitNotices& limits);
  template void BindingValidator::validate<RetainedCommandTabRegistry>(const lua::Value& bindings, const BasicActionValidator<RetainedCommandTabRegistry>& actions, BindingKeymap& keymap, LimitNotices& limits);
  template void ClientValidator::validate<CommandTabRegistry>(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<CommandTabRegistry>& state, const lua::Value* inherited);
  template void ClientValidator::validate<RetainedCommandTabRegistry>(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<RetainedCommandTabRegistry>& state, const lua::Value* inherited);

}
