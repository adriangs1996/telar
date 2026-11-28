module telar.config.client;

import std;
import telar.lua;
import telar.tbc;
import telar.wire.clients;
import telar.base.ds;

namespace telar::runtime::config {

  namespace {

    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_byte = 0x7f;
    // "#RRGGBB".
    constexpr std::size_t rgb_text_length = 7;

    // The last component of `path`, without the slashes after it; empty when it is all slashes.
    std::string_view executableName(std::string_view path) noexcept {
      const auto last = path.find_last_not_of('/');
      if (last == std::string_view::npos) {
        return {};
      }

      path.remove_suffix(path.size() - last - 1);
      const auto separator = path.find_last_of('/');
      if (separator != std::string_view::npos) {
        path.remove_prefix(separator + 1);
      }

      return path;
    }

    // Reads a whole number within bounds of an integer setting.
    std::uint64_t boundedWhole(const lua::Value& value, std::uint64_t fallback, Bounds<std::uint64_t> bounds) {
      return value.boundedInteger(fallback, bounds);
    }

    unsigned toneBonus(std::string_view tone) noexcept {
      constexpr unsigned danger_bonus = 40;
      constexpr unsigned warning_bonus = 20;

      if (tone == "danger") {
        return danger_bonus;
      }

      return tone == "warning" ? warning_bonus : 0;
    }

  }

  std::size_t NamedDefinitionsValidator::sortedNames(const lua::Value& table, tbc::val_b<LimitReach> reach, tbc::mut_b<LimitNotices> limits, std::span<std::string_view, maximum_definitions> names) {
    std::size_t kept = 0;
    std::size_t total = 0;

    table.eachField([&](std::string_view name, const lua::Value&) {
      ++total;
      const auto end = names.begin() + static_cast<std::ptrdiff_t>(kept);
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

  tbc::val_a<std::string_view> NamedDefinitionsValidator::heading(tbc::val_a<std::string_view> name, const lua::Value& definition, LimitNotices& limits) {
    if (name.empty() || name.size() > maximum_name_bytes || !std::ranges::all_of(name, [](unsigned char byte) {
          return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
        })) {
      definition.fail("has an invalid name");
    }

    const auto title = definition.field("title");
    const auto text = fittedUiText(title.present() ? title.string() : name, {.name = "panels.title_bytes", .noun = "title bytes", .value = maximum_title_bytes, .requested = {}, .route = {}}, limits);

    printableUiText(title, text);
    return text;
  }

  ClientDefinitions::ClientDefinitions(const lua::Value& client, const lua::Value* inherited)
      : client_(client),
        inherited_(inherited) {}

  bool ClientDefinitions::contains(const char* section, std::string_view name) const {
    return index(section, name).hasValue();
  }

  ds::Option<std::uint8_t> ClientDefinitions::index(const char* section, std::string_view name) const {
    if (client_.present()) {
      const auto definitions = client_.field(section);
      if (definitions.present()) {
        return indexOf(definitions, name);
      }
    }

    if (inherited_ != nullptr && inherited_->present()) {
      return indexOf(inherited_->field(section), name);
    }

    return ds::none;
  }

  ds::Option<std::uint8_t> ClientDefinitions::indexOf(const lua::Value& definitions, std::string_view name) {
    if (!definitions.present()) {
      return ds::none;
    }

    bool found = false;
    std::size_t preceding = 0;

    definitions.eachField([&](std::string_view candidate, const lua::Value&) {
      found |= candidate == name;
      preceding += candidate < name;
    });

    if (!found) {
      return ds::none;
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

    return executableName(arguments.front());
  }

  template <CommandTabLifetime Lifetime>
  bool CommandTabStorage<Lifetime>::keep(std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits) {
    return keepReference(arguments, label, limits).hasValue();
  }

  template <CommandTabLifetime Lifetime>
  ds::Option<CommandTabReference> CommandTabStorage<Lifetime>::keepReference(std::span<const std::string_view> arguments, std::string_view label, LimitNotices& limits) {
    ds::Array<Byte, maximum_encoded_bytes> encoded{};
    const auto length = encode(arguments, label, encoded.viewMut());
    const auto row = std::span{encoded}.first(length);

    for (std::size_t index = 0; index < rows_; ++index) {
      const auto stored = rowBytes(index);
      if (stored.size() == row.size() && std::ranges::equal(stored, row)) {
        return reference(index);
      }
    }

    if (!admit(row.size(), limits)) {
      return ds::none;
    }

    const auto index = rows_++;

    offsets_.atMut(index) = static_cast<std::uint32_t>(used_);
    std::ranges::copy(row, bytes_.viewMut().subspan(used_).begin());
    used_ += row.size();

    return reference(index);
  }

  template <CommandTabLifetime Lifetime>
  ds::Option<CommandTabView> CommandTabStorage<Lifetime>::load(CommandTabReference reference) const {
    if (reference.id >= rows_ || reference != this->reference(reference.id)) {
      return ds::none;
    }

    const auto row = rowBytes(reference.id);
    CommandTabView result;

    result.count = row[0];
    const auto label_length = row[1];
    auto offset = header_bytes + (result.count * argument_length_bytes);

    for (std::size_t argument = 0; argument < result.count; ++argument) {
      const auto entry = header_bytes + (argument * argument_length_bytes);
      const auto length = static_cast<std::size_t>(row[entry]) | (static_cast<std::size_t>(row[entry + 1]) << upper_byte_shift);

      result.arguments.atMut(argument) = textView(row.subspan(offset, length));
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
  CommandTabStorage<Lifetime>::Checkpoint CommandTabStorage<Lifetime>::checkpoint() const noexcept {
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
      std::ranges::copy(byteView(argument), encoded.subspan(length).begin());
      length += argument.size();
    }

    std::ranges::copy(byteView(label), encoded.subspan(length).begin());

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

  tbc::val_a<ExtendedActionSetting> ExtendedActionReader::read(const lua::Value& action, const ClientDefinitions& definitions) {
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

  tbc::val_a<NotificationActionSetting> ExtendedActionReader::notification(const lua::Value& action) {
    NotificationActionSetting result;

    result.title = utf8Prefix(action.field("title").string(), max_notification_title_bytes);
    const auto body = action.field("body");
    if (body.present()) {
      result.body = utf8Prefix(body.string(), max_notification_message_bytes);
    }

    result.level = optionalChoice<NotificationLevel>(action.field("level"), notification_level_names).valueOr(NotificationLevel::info);
    result.duration_ms = static_cast<std::uint32_t>(action.field("duration_ms").boundedInteger(default_notification_duration_ms, {.minimum = min_notification_duration_ms, .maximum = max_notification_duration_ms}));
    constexpr ds::Array targets{"pane_id", "tab_id", "workspace_id"};

    for (std::size_t index = 0; index < targets.size(); ++index) {
      const auto target = action.field(targets[index]);
      if (target.present()) {
        result.target = {.kind = static_cast<NotificationTarget::Kind>(index + 1), .id = static_cast<std::uint64_t>(target.integer())};
      }
    }

    return result;
  }

  template <CommandTabStore Commands>
  BasicActionValidator<Commands>::BasicActionValidator(tbc::ref_b<ClientDefinitions> definitions, tbc::mut_b<LimitNotices> limits, tbc::mut_b<Commands> commands)
      : definitions_(definitions),
        limits_(limits),
        commands_(commands) {}

  template <CommandTabStore Commands>
  bool BasicActionValidator<Commands>::validate(const lua::Value& action, bool expression) {
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
      constexpr lua_Integer maximum_index = 256;

      action.onlyFields({"kind", "index"});
      requiredInteger(action.field("index"), 1, maximum_index);
    } else if (kind == "select-tab-offset") {
      action.onlyFields({"kind", "offset"});
      requiredInteger(action.field("offset"), std::numeric_limits<std::int8_t>::min(), std::numeric_limits<std::int8_t>::max());
    } else if (kind == "command-tab") {
      return commandTab(action);
    } else if (kind == "notification") {
      notification(action);
    } else if (kind == "open-panel") {
      reference(action, {.field = "panel", .section = "panels"});
    } else if (kind == "pick") {
      reference(action, {.field = "pick", .section = "picks"});
    } else if (kind == "plugin") {
      action.onlyFields({"kind", "plugin", "action"});
      static_cast<void>(action.field("plugin").string());
      static_cast<void>(action.field("action").string());
    } else {
      builtin(kind_value);
      action.onlyFields({"kind"});
    }

    return true;
  }

  template <CommandTabStore Commands>
  bool BasicActionValidator<Commands>::component(const lua::Value& action) {
    if (action.is(LUA_TFUNCTION)) {
      action.fail("cannot be a callback in a static component");
    }

    return validate(action);
  }

  template <CommandTabStore Commands>
  tbc::val_a<ds::Option<ActionSetting>> BasicActionValidator<Commands>::read(const lua::Value& action, bool expression) {
    if (!validate(action, expression)) {
      return ds::none;
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
  void BasicActionValidator<Commands>::command(const lua::Value& action, tbc::mut_a<CommandTabView> command) {
    const auto arguments = action.field("command");

    command.count = arguments.listLength();
    for (std::size_t index = 0; index < command.count; ++index) {
      command.arguments.atMut(index) = arguments.element(static_cast<lua_Integer>(index) + 1).string();
    }

    const auto label = action.field("label");

    command.configured_label = label.is(LUA_TSTRING) ? label.string() : std::string_view{};
  }

  template <CommandTabStore Commands>
  tbc::val_a<std::string_view> BasicActionValidator<Commands>::builtinName(const lua::Value& action, tbc::val_a<std::string_view> kind) {
    constexpr auto stems = ds::Array<std::pair<std::string_view, std::string_view>, 7>{
        {
            {"scroll-pane", "scroll-pane-"},
            {"split-pane", "split-"},
            {"focus-pane", "focus-"},
            {"navigate-pane", "navigate-"},
            {"resize-pane", "resize-"},
            {"resize-sidebar", "resize-sidebar-"},
            {"move-tab", "move-tab-"},
        },
    };

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

    static_cast<void>(direction.string());
    optionalChoice(direction, choices);
  }

  template <CommandTabStore Commands>
  void BasicActionValidator<Commands>::reference(const lua::Value& action, DefinitionField definition) const {
    action.onlyFields({"kind", definition.field});
    const auto value = action.field(definition.field);
    if (!definitions_.contains(definition.section, value.string())) {
      value.fail("names an unknown client definition");
    }
  }

  template <CommandTabStore Commands>
  bool BasicActionValidator<Commands>::commandTab(const lua::Value& action) {
    action.onlyFields({"kind", "command", "label"});
    const auto command = action.field("command");
    const auto count = command.listLength();
    constexpr std::size_t maximum_arguments = 32;
    constexpr std::size_t maximum_bytes = 4096;

    if (count == 0) {
      command.fail("requires a command");
    }

    if (count > maximum_arguments) {
      limits_.add({.name = "command_tab.max_arguments", .noun = "arguments", .value = maximum_arguments, .requested = count, .route = {}});
      return false;
    }

    static_cast<void>(command.arraySize());
    ds::Array<std::string_view, maximum_arguments> arguments;
    std::size_t total_bytes = 0;

    for (std::size_t index = 0; index < count; ++index) {
      const auto argument = command.element(static_cast<lua_Integer>(index) + 1);

      arguments.atMut(index) = argument.string();
      if (arguments[index].empty()) {
        argument.fail("must be nonempty");
      }

      total_bytes += arguments[index].size();
    }

    const auto label = action.field("label");
    if (label.is(LUA_TSTRING) && label.string().size() > CommandTabView::maximum_label_bytes) {
      label.fail("exceeds the label limit");
    }

    std::size_t kept_bytes = 0;

    for (const auto argument : std::span{arguments}.first(count)) {
      if (argument.contains('\0')) {
        command.fail("contains NUL");
      }

      kept_bytes += argument.size();
      if (kept_bytes > maximum_bytes) {
        limits_.add({.name = "command_tab.max_command_bytes", .noun = "argv bytes", .value = maximum_bytes, .requested = total_bytes, .route = {}});
        return false;
      }
    }

    return commands_.keep(std::span{arguments}.first(count), label.is(LUA_TSTRING) ? label.string() : std::string_view{}, limits_);
  }

  template <CommandTabStore Commands>
  void BasicActionValidator<Commands>::notification(const lua::Value& action) {
    action.onlyFields({"kind", "title", "body", "level", "duration_ms", "pane_id", "tab_id", "workspace_id"});
    optionalChoice(action.field("level"), {"info", "success", "warning", "failure"});
    NotificationBody body{.duration_ms = static_cast<std::uint32_t>(action.field("duration_ms").boundedInteger(default_notification_duration_ms, {.minimum = min_notification_duration_ms, .maximum = max_notification_duration_ms}))};
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

    constexpr std::size_t notification_frame_bytes = 1024;

    ds::Array<Byte, notification_frame_bytes> storage{};

    Codec::encode(ShowNotification{.request_id = 1, .notification = body}, storage.viewMut());
  }

  template <CommandTabStore Commands>
  tbc::val_a<std::string_view> BasicActionValidator<Commands>::fitted(tbc::val_a<std::string_view> text, tbc::val_b<LimitReach> limit) {
    if (text.size() > limit.value) {
      limit.requested = text.size();
      limits_.add(limit);
    }

    return utf8Prefix(text, limit.value);
  }

  ComponentBudget::Usage ComponentBudget::Usage::operator+(Usage other) const noexcept {
    return {.nodes = nodes + other.nodes, .text = text + other.text, .actions = actions + other.actions, .samples = samples + other.samples};
  }

  ComponentBudget::Usage ComponentBudget::Usage::operator-(Usage other) const noexcept {
    return {.nodes = nodes - other.nodes, .text = text - other.text, .actions = actions - other.actions, .samples = samples - other.samples};
  }

  bool ComponentBudget::Usage::fits(Usage room) const noexcept {
    return nodes <= room.nodes && text <= room.text && actions <= room.actions && samples <= room.samples;
  }

  void ComponentBudget::count(const ComponentShape& shape, unsigned rank) noexcept {
    const auto needed = usage(shape);

    offered_ = offered_ + needed;
    ranked_.atMut(rank) = ranked_[rank] + needed;
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
    const ds::Array<LimitReach, 4> reaches{
        {
            {.name = "bars.max_bar_nodes", .noun = "components", .value = 64, .requested = offered_.nodes, .route = {}},
            {.name = "bars.max_bar_text_bytes", .noun = "text bytes", .value = 4096, .requested = offered_.text, .route = {}},
            {.name = "bars.max_bar_actions", .noun = "click actions", .value = 32, .requested = offered_.actions, .route = {}},
            {.name = "bars.max_samples", .noun = "sparkline samples", .value = 256, .requested = offered_.samples, .route = {}},
        },
    };

    for (const auto& reach : reaches) {
      if (reach.requested > reach.value) {
        limits.add(reach);
      }
    }
  }

  ComponentBudget::Usage ComponentBudget::usage(const ComponentShape& shape) noexcept {
    return {.nodes = 1, .text = shape.text.size() + shape.detail.size() + shape.url.size(), .actions = shape.action_field != nullptr ? 1U : 0U, .samples = shape.samples};
  }

  namespace {

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
          static_cast<void>(component.field(name).boolean(false));
        }
      }

    private:
      inline static void color(const lua::Value& value) {
        if (const auto index = value.asInteger()) {
          if (!std::in_range<std::uint8_t>(*index)) {
            value.fail("is outside the color index range");
          }

          return;
        }

        constexpr ds::Array names{std::string_view{"default"}, "accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};
        const auto text = value.string();
        if (std::ranges::any_of(names, [text](std::string_view name) {
              return equalUiName(text, name);
            })) {
          return;
        }

        if (text.size() == rgb_text_length && text.front() == '#' && hexadecimal(text.substr(1))) {
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

  }

  tbc::val_a<ComponentShape> ComponentShapeReader::read(const lua::Value& value, unsigned inherited_priority, LimitNotices& limits) {
    constexpr double maximum_priority = 100;

    ComponentShape shape;

    shape.kind = kind(value.field("ui"));
    shape.form = ComponentForm::component;
    fields(value, shape.kind);
    shape.priority = static_cast<unsigned>(std::round(value.field("priority").boundedNumber(inherited_priority, {.minimum = 0, .maximum = maximum_priority})));
    const auto tone = value.field("tone");

    optionalChoice(tone, {"neutral", "muted", "accent", "success", "warning", "danger"});
    if (tone.present()) {
      shape.tone_bonus = toneBonus(tone.string());
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
      static_cast<void>(value.field("name").string());
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
      static_cast<void>(value.field("primary").boolean(false));
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
    constexpr ds::Array names{std::string_view{"label"}, "icon", "mark", "meter", "sparkline", "badge", "clock", "metric", "machines", "group", "heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"};
    const auto* const found = std::ranges::find(names, value.string());
    if (found == names.end()) {
      value.fail("names an unknown component");
    }

    return static_cast<ComponentKind>(found - names.begin());
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

  tbc::val_a<std::string_view> ComponentShapeReader::text(const lua::Value& value, const char* name, tbc::val_a<std::string_view> fallback) {
    const auto field = value.field(name);

    return field.present() ? field.string() : fallback;
  }

  void ComponentShapeReader::optionalIcon(const lua::Value& value) {
    if (value.present()) {
      uiIcon(value);
    }
  }

  void ComponentShapeReader::finiteNumber(const lua::Value& value) {
    static_cast<void>(value.boundedNumber(0, {.minimum = std::numeric_limits<double>::lowest(), .maximum = std::numeric_limits<double>::max()}));
  }

  std::size_t ComponentShapeReader::samples(const lua::Value& value, LimitNotices& limits) {
    finiteNumber(value.field("max"));
    const auto values = value.field("values");
    const auto total = values.listLength();
    const auto kept = std::min(total, maximum_samples);
    if (total > kept) {
      limits.add({.name = "bars.max_node_samples", .noun = "sparkline values", .value = maximum_samples, .requested = total, .route = {}});
    }

    for (std::size_t index = total - kept + 1; index <= total; ++index) {
      const auto sample = values.element(static_cast<lua_Integer>(index));
      if (!sample.present()) {
        sample.fail("must be a number");
      }

      static_cast<void>(sample.boundedNumber(0, {.minimum = 0, .maximum = std::numeric_limits<double>::max()}));
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

  tbc::val_a<ds::Option<std::string_view>> ComponentValuesReader::icon(const lua::Value& value) {
    if (!value.present()) {
      return ds::none;
    }

    uiIcon(value);
    return value.string();
  }

  ds::Option<UiMark> ComponentValuesReader::mark(const lua::Value& value) {
    if (!value.present()) {
      return ds::none;
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

  ds::Option<double> ComponentValuesReader::number(const lua::Value& value) {
    if (!value.present()) {
      return ds::none;
    }

    return value.boundedNumber(0, {.minimum = std::numeric_limits<double>::lowest(), .maximum = std::numeric_limits<double>::max()});
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

  void ComponentTreeWalker::walk(const lua::Value& value, ComponentPosition position, ComponentPlacer& placer) {
    const auto original_top = lua_gettop(&state_);

    value.pushCopy();
    try {
      push(position);
      while (frame_count_ != 0) {
        advance(placer);
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

    const auto index = lua_gettop(&state_);
    auto& frame = frames_.atMut(frame_count_++);

    frame.index = index;
    frame.value.emplace(&state_, index, "component");
    frame.position = position;
    frame.phase = Phase::visit;
    frame.tooltip = false;
    frame.next = 0;
    frame.count = 0;
  }

  void ComponentTreeWalker::pop() noexcept {
    auto& frame = frames_.atMut(--frame_count_);

    frame.value.reset();
    lua_settop(&state_, frame.index - 1);
  }

  void ComponentTreeWalker::advance(ComponentPlacer& placer) {
    auto& frame = frames_.atMut(frame_count_ - 1);

    switch (frame.phase) {
    case Phase::visit:
      visit(placer);
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

  // The frame's value is read through the stack, which stays shared while a node is placed; the
  // frame changes only once the value is done with.
  void ComponentTreeWalker::visit(ComponentPlacer& placer) {
    const auto top = frame_count_ - 1;
    const auto position = frames_[top].position;

    frames_.atMut(top).phase = Phase::done;

    const auto& value = frameValue(frames_[top]);
    if (!value.present()) {
      return;
    }

    if (value.is(LUA_TSTRING)) {
      static_cast<void>(node(placer, value, {.text = value.string(), .priority = position.priority}, position));
      return;
    }

    if (!value.is(LUA_TTABLE)) {
      value.fail("components must be text, a component or a list");
    }

    if (value.field("ui").present()) {
      component(placer);
      return;
    }

    if (value.field("text").present() || value.field("icon").present()) {
      static_cast<void>(node(placer, value, ComponentShapeReader::segment(value, position.priority), position));
      return;
    }

    if (position.depth == maximum_list_depth) {
      value.fail("exceeds the component nesting limit");
    }

    const auto count = value.arraySize();
    auto& frame = frames_.atMut(top);

    frame.child = position;
    ++frame.child.depth;
    frame.count = count;
    frame.phase = Phase::list;
  }

  void ComponentTreeWalker::component(ComponentPlacer& placer) {
    const auto top = frame_count_ - 1;
    const auto position = frames_[top].position;
    const auto& value = frameValue(frames_[top]);
    const auto shape = ComponentShapeReader::read(value, position.priority, limits_);
    const auto parent = node(placer, value, shape, position);
    if (!parent) {
      return;
    }

    const bool lists = shape.kind == ComponentKind::group || shape.kind == ComponentKind::actions;
    const auto count = lists ? value.listLength() : 0;
    auto& frame = frames_.atMut(top);

    frame.child = {.parent = parent->index, .rank = parent->rank};
    switch (shape.kind) {
    case ComponentKind::group:
      frame.child.place = ComponentPlace::group;
      frame.child.priority = shape.priority;
      frame.tooltip = true;
      frame.count = count;
      frame.phase = Phase::children;
      break;
    case ComponentKind::actions:
      frame.child.place = ComponentPlace::buttons;
      frame.count = count;
      frame.phase = Phase::children;
      break;
    case ComponentKind::callout:
      frame.phase = Phase::button;
      break;
    case ComponentKind::label:
    case ComponentKind::icon:
    case ComponentKind::mark:
    case ComponentKind::meter:
    case ComponentKind::sparkline:
    case ComponentKind::badge:
    case ComponentKind::clock:
    case ComponentKind::metric:
    case ComponentKind::machines:
    case ComponentKind::heading:
    case ComponentKind::text:
    case ComponentKind::meter_row:
    case ComponentKind::key_value:
    case ComponentKind::button:
    case ComponentKind::divider:
      break;
    }
  }

  ds::Option<ComponentParent> ComponentTreeWalker::node(ComponentPlacer& placer, const lua::Value& value, const ComponentShape& shape, const ComponentPosition& position) {
    if (!componentAllowed(shape.kind, position.place)) {
      value.fail("contains a component unsupported in this position");
    }

    return placer.place(value, shape, position);
  }

  namespace {

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
          const auto value = command.element(static_cast<lua_Integer>(index) + 1);
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

  }

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
      setting.every_ms = static_cast<std::uint32_t>(boundedWhole(every, SourceSetting::default_every_ms, SourceSetting::every_ms_bounds));
    }

    setting.render = source.field("render").present();
    setting.timeout_ms = static_cast<std::uint32_t>(boundedWhole(source.field("timeout_ms"), SourceSetting::default_timeout_ms, SourceSetting::timeout_ms_bounds));
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

  namespace {

    template <CommandTabStore Commands>
    class ComponentValidator {
    public:
      inline explicit ComponentValidator(BasicActionValidator<Commands>& actions, LimitNotices& limits)
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
        unsigned priority = default_priority;
        unsigned rank = std::numeric_limits<std::uint8_t>::max();
        unsigned depth = 0;
      };

      // Lists nest at most maximum_list_depth deep, and componentAllowed bounds how components nest.
      inline void walk(const lua::Value& value, Position position) { // NOLINT(misc-no-recursion): bounded; an explicit stack of Lua slots, as ComponentTreeWalker keeps, needs the lua_State this validator does not get.
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
          walk(value.element(static_cast<lua_Integer>(index)), position);
        }
      }

      inline void component(const lua::Value& value, Position position) { // NOLINT(misc-no-recursion): bounded, as walk is.
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

      inline void children(const lua::Value& value, Position position) { // NOLINT(misc-no-recursion): bounded, as walk is.
        const auto count = value.listLength();

        for (std::size_t index = 1; index <= count; ++index) {
          walk(value.element(static_cast<lua_Integer>(index)), position);
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
      BasicActionValidator<Commands>& actions_;
      LimitNotices& limits_;
      ComponentBudget budget_;
      bool counting_ = true;
    };

    template <CommandTabStore Commands>
    class BarsValidator {
    public:
      inline explicit BarsValidator(BasicActionValidator<Commands>& actions, LimitNotices& limits)
          : actions_(actions),
            limits_(limits) {}

      inline void validate(const lua::Value& bars) {
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
            if (source(footer.element(static_cast<lua_Integer>(index))) == Source::tabs) {
              footer.fail("cannot contain tabs");
            }
          }
        }
      }

    private:
      enum class Source : std::uint8_t {
        content,
        tabs,
      };

      inline void bottom(const lua::Value& bar) {
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

      inline Source source(const lua::Value& value) {
        const auto kind_value = value.field("bar_kind");
        const auto kind = kind_value.string();
        if (kind == "tabs" || kind == "metrics" || kind == "machines") {
          value.onlyFields({"bar_kind"});
          return kind == "tabs" ? Source::tabs : Source::content;
        }

        if (kind == "static") {
          value.onlyFields({"bar_kind", "value"});
          ComponentValidator<Commands>{actions_, limits_}.validate(value.field("value"));
        } else {
          static_cast<void>(SourceReader::dynamic(value));
        }

        return Source::content;
      }

      static constexpr std::size_t maximum_footer_slots = 3;
      BasicActionValidator<Commands>& actions_;
      LimitNotices& limits_;
    };

  }

  lua::Value BarsReader::content(const lua::Value& source) {
    return source.field("value");
  }

  bool KeyChord::has(Modifier modifier) const noexcept {
    return (modifiers & static_cast<unsigned>(modifier)) != 0;
  }

  void BindingKeymap::setPrefix(KeyChord prefix) noexcept {
    prefix_ = prefix;
    for (auto& binding : bindings_.viewMut().first(count_)) {
      if (binding.prefixed) {
        binding.keys.atMut(0) = prefix;
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
    bindings_.atMut(count_++) = sequence;
  }

  void BindingKeymap::report(LimitNotices& limits) const noexcept {
    std::size_t wanted = count_;

    for (const auto suffix : defaultSuffixes()) {
      const bool overridden = std::ranges::any_of(std::span{bindings_}.first(count_), [&](const Sequence& binding) {
        return binding.keys[0] == prefix_ && (binding.length == 1 || binding.keys[1] == suffix);
      });

      wanted += static_cast<std::size_t>(!overridden);
    }

    if (wanted > maximum_bindings) {
      limits.add({.name = "config.max_bindings", .noun = "key bindings", .value = maximum_bindings, .requested = wanted, .route = {}});
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
    constexpr ds::Array<std::pair<std::string_view, Key>, 19> named_keys{{{"up", Key::up}, {"down", Key::down}, {"left", Key::left}, {"right", Key::right}, {"home", Key::home}, {"end", Key::end}, {"delete", Key::erase}, {"del", Key::erase}, {"pageup", Key::page_up}, {"page-up", Key::page_up}, {"pagedown", Key::page_down}, {"page-down", Key::page_down}, {"enter", Key::enter}, {"return", Key::enter}, {"escape", Key::escape}, {"esc", Key::escape}, {"backspace", Key::backspace}, {"tab", Key::tab}, {"backtab", Key::back_tab}}};

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

    // A UTF-8 continuation byte is 10xxxxxx.
    constexpr unsigned continuation_mask = 0xc0U;
    constexpr unsigned continuation_tag = 0x80U;

    validateUtf8(name);
    const auto codepoints = std::ranges::count_if(name, [](unsigned char byte) {
      return (byte & continuation_mask) != continuation_tag;
    });
    if (codepoints != 1) {
      value.fail("must name one key");
    }

    // The key's UTF-8 bytes, packed into the character as they sit in memory.
    auto packed = std::bit_cast<ds::Array<char, sizeof(chord.character)>>(chord.character);

    std::ranges::copy(name, packed.viewMut().begin());
    chord.character = std::bit_cast<std::uint32_t>(packed);
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
      setting.keys.atMut(0) = prefix;
    }

    setting.length = key_count + offset;
    for (std::size_t key = 0; key < key_count; ++key) {
      setting.keys.atMut(key + offset) = KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(key) + 1));
    }

    setting.expression = binding.field("expression").boolean(false);
    return setting;
  }

  namespace {

    template <CommandTabStore Commands>
    void validateBindingEntries(const lua::Value& bindings, BasicActionValidator<Commands>& actions, BindingKeymap& keymap) {
      BindingReader::read(bindings, keymap.prefix(), [&](const BindingSetting& binding, const lua::Value& action) {
        BindingKeymap::Sequence sequence{.length = binding.length, .prefixed = binding.prefixed};

        std::ranges::copy(std::span{binding.keys}.first(std::min(binding.length, sequence.keys.size())), sequence.keys.viewMut().begin());
        if (actions.validate(action, binding.expression)) {
          keymap.append(sequence);
        }
      });
    }

  }

  template <CommandTabStore Commands>
  void BindingValidator::validate(const lua::Value& bindings, BasicActionValidator<Commands>& actions, BindingKeymap& keymap, LimitNotices& limits) {
    if (!bindings.present()) {
      return;
    }

    constexpr auto maximum_bindings = BindingReader::maximum_bindings;
    const auto listed = bindings.listLength();

    keymap.clear();
    if (listed > maximum_bindings) {
      limits.add({.name = "config.max_bindings", .noun = "key bindings", .value = maximum_bindings, .requested = listed, .route = {}});
    }

    validateBindingEntries(bindings, actions, keymap);
  }

  PluginWorkerOptions PluginWorkerOptions::parse(std::span<char* const> arguments) {
    if (arguments.size() != argument_count) {
      throw std::invalid_argument{"Expected plugin-worker ENTRY ACTION SIDEBAR TAB_COUNT ACTIVE_TAB_INDEX PANE_COUNT FOCUSED_PANE_ID"};
    }

    ds::Array<char*, argument_count> fields = {};

    std::ranges::copy(arguments, fields.viewMut().begin());
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
    lua::setField(state, "active_tab_index", static_cast<lua_Integer>(context_.active_tab_index) + 1);
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
      decision.keys.atMut(index) = KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(index) + 1));
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

  ds::Option<PickItemSetting::Swatch> PickItemsReader::swatch(const lua::Value& value) {
    if (!value.present()) {
      return ds::none;
    }

    PickItemSetting::Swatch result{};
    if (value.arraySize() != result.size()) {
      value.fail("must contain three RGB colors");
    }

    constexpr int hexadecimal_base = 16;

    for (std::size_t index = 0; index < result.size(); ++index) {
      const auto color = value.element(static_cast<lua_Integer>(index) + 1);

      hexadecimalColor(color);
      const auto digits = color.string().substr(1);
      const auto* const end = std::to_address(digits.end());
      const auto parsed = std::from_chars(digits.data(), end, result.atMut(index), hexadecimal_base);
      if (std::make_error_code(parsed.ec) || parsed.ptr != end) {
        color.fail("must be an RGB color");
      }
    }

    return result;
  }

  namespace {

    class PickItemsValidator {
    public:
      inline explicit PickItemsValidator(LimitNotices& limits)
          : limits_(limits) {}

      inline void validate(const lua::Value& items) {
        std::size_t count = 0;

        PickItemsReader::read(items, [&](const PickItemSetting& option, const lua::Value& item) {
          keep(item, option.label, option.value.valueOr(option.label), option.detail.valueOr(std::string_view{}));
          ++count;
        });

        if (count > maximum_items) {
          limits_.add({.name = "picks.max_items", .noun = "options", .value = maximum_items, .requested = count, .route = {}});
        }

        if (text_full_) {
          limits_.add({.name = "picks.max_text_bytes", .noun = "option text bytes", .value = maximum_text_bytes, .requested = offered_text_bytes_, .route = {}});
        }

        const ds::Array<LimitReach, 3> text_limits{
            {
                {.name = "picks.max_label_bytes", .noun = "label bytes", .value = maximum_label_bytes, .requested = longest_label_, .route = {}},
                {.name = "picks.max_value_bytes", .noun = "value bytes", .value = maximum_value_bytes, .requested = longest_value_, .route = {}},
                {.name = "picks.max_detail_bytes", .noun = "detail bytes", .value = maximum_detail_bytes, .requested = longest_detail_, .route = {}},
            },
        };

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
      static constexpr std::size_t maximum_text_bytes = std::size_t{256} * 1024;
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

  }

  tbc::val_a<PanelSetting> ClientDefinitionsReader::panelSetting(tbc::val_a<std::string_view> name, const lua::Value& definition, LimitNotices& limits) {
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

    setting.width = static_cast<std::uint16_t>(boundedWhole(definition.field("width"), PanelSetting::default_width, PanelSetting::width_bounds));
    setting.source = SourceReader::dynamic(definition.field("source"), true);
    return setting;
  }

  tbc::val_a<PickSetting> ClientDefinitionsReader::pickSetting(tbc::val_a<std::string_view> name, const lua::Value& definition, LimitNotices& limits) {
    definition.onlyFields({"pick_kind", "title", "command", "items", "on_select", "timeout_ms", "refresh"});
    PickSetting setting;

    setting.heading = {.name = name, .title = NamedDefinitionsValidator::heading(name, definition, limits)};
    setting.timeout_ms = static_cast<std::uint32_t>(boundedWhole(definition.field("timeout_ms"), SourceSetting::default_timeout_ms, PickSetting::timeout_ms_bounds));
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

  tbc::val_a<lua::Value> PromptReader::begin(const lua::Value& table, PromptSettings& settings) {
    table.onlyFields({"mode", "skin", "motion", "ghost", "macos_option_as_alt", "keymap", "max_lines", "up_scope", "expand_aliases", "bindings"});
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
    const auto* const found = std::ranges::find(prompt_action_names, action.string());
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
    settings.macos_option_as_alt = optionalBoolean(table.field("macos_option_as_alt"));
    settings.up_scope = optionalChoice<PromptUpScope>(table.field("up_scope"), prompt_up_scope_names);
    settings.expand_aliases = optionalBoolean(table.field("expand_aliases"));
    if (const auto lines = table.field("max_lines"); lines.present()) {
      settings.max_lines = static_cast<std::uint8_t>(boundedWhole(lines, PromptBounds::max_lines.minimum, PromptBounds::max_lines));
    }
  }

  tbc::val_a<ClientSettings> ClientReader::readSettings(const lua::Value& client) {
    ClientSettings settings;

    if (!client.present()) {
      return settings;
    }

    client.onlyFields({"prefix", "theme", "icons", "sidebar", "pane_gaps", "editor", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "panels", "picks", "history", "components", "prompt", "explorer", "theme_picker"});
    settings.input = input(client);
    settings.pane_gaps = optionalBoolean(client.field("pane_gaps"));
    settings.editor = printableText(client.field("editor"), maximum_editor_bytes, false);
    settings.window_title = printableText(client.field("window_title"), maximum_window_title_bytes, true);
    sidebar(client.field("sidebar"), settings);
    sound(client.field("sound"), settings.sound);
    notifications(client.field("notifications"), settings);
    history(client.field("history"), settings.history);
    explorer(client.field("explorer"), settings.explorer_keys);
    themePicker(client.field("theme_picker"), settings.theme_picker);
    return settings;
  }

  void ClientReader::themePicker(const lua::Value& table, ClientSettings::ThemePicker& picker) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"on_select", "timeout_ms"});
    const auto on_select = table.field("on_select");
    if (on_select.present()) {
      if (!CommandArgumentsValidator::validate(on_select)) {
        on_select.fail("requires a theme placeholder after the program");
      }

      picker.on_select = true;
    }

    const auto timeout = table.field("timeout_ms");
    if (timeout.present()) {
      picker.timeout_ms = static_cast<std::uint32_t>(boundedWhole(timeout, SourceSetting::default_timeout_ms, PickSetting::timeout_ms_bounds));
    }
  }

  std::size_t ClientReader::slot(std::string_view name, const lua::Value& entry) {
    const auto* const found = std::ranges::find(component_slots, name);
    if (found == component_slots.end()) {
      entry.fail("names an unknown component slot \"", name, "\"");
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

        settings.sequence_timeout_ms = static_cast<std::uint16_t>(boundedWhole(timeout, bounds.minimum, bounds));
      }
    }

    return settings;
  }

  tbc::val_a<ds::Option<std::string_view>> ClientReader::printableText(const lua::Value& value, std::size_t maximum, bool allow_empty) {
    if (!value.present()) {
      return ds::none;
    }

    optionalUtf8Text(value, maximum);
    const auto text = value.string();
    if ((!allow_empty && text.empty()) || std::ranges::any_of(text, [](unsigned char byte) {
          return byte < first_printable || byte == delete_byte;
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
      table.onlyFields({"delivery", "long_commands"});
      settings.delivery = optionalChoice<ClientSettings::Delivery>(table.field("delivery"), ds::Array<std::string_view, 3>{"telar", "system", "terminal"});

      const auto commands = table.field("long_commands");
      if (commands.present()) {
        constexpr auto bounds = ClientSettings::LongCommands::after_ms_bounds;

        commands.onlyFields({"enabled", "after_ms"});
        settings.long_commands.enabled = optionalBoolean(commands.field("enabled"));
        if (const auto after = commands.field("after_ms"); after.present()) {
          settings.long_commands.after_ms = static_cast<std::uint32_t>(boundedWhole(after, bounds.minimum, bounds));
        }
      }
    }
  }

  void ClientReader::history(const lua::Value& table, ClientSettings::History& history) {
    if (table.present()) {
      table.onlyFields({"show_agent_commands", "enter", "match", "columns", "time"});
      history.show_agent_commands = optionalBoolean(table.field("show_agent_commands"));
      history.enter = optionalChoice<ClientSettings::HistoryEnter>(table.field("enter"), ds::Array<std::string_view, 2>{"paste", "run"});
      history.match = optionalChoice<ClientSettings::HistoryMatch>(table.field("match"), ds::Array<std::string_view, 2>{"fuzzy", "fts"});
      history.time = optionalChoice<ClientSettings::HistoryTime>(table.field("time"), ds::Array<std::string_view, 2>{"clock", "relative"});
      if (const auto columns = table.field("columns"); columns.present()) {
        columns.onlyFields({"duration", "exit", "directory", "host"});
        history.duration = optionalBoolean(columns.field("duration"));
        history.exit = optionalBoolean(columns.field("exit"));
        history.directory = optionalBoolean(columns.field("directory"));
        history.host = optionalBoolean(columns.field("host"));
      }
    }
  }

  namespace {

    // The bytes of the character `keys` starts with: as many as its first one says, and none for
    // a control or for a byte that starts no character.
    std::size_t explorerCharacterBytes(std::string_view keys) noexcept {
      constexpr ds::Array<unsigned char, 5> leads{0x80, 0xC0, 0xE0, 0xF0, 0xF8};
      constexpr unsigned char space = ' ';
      const unsigned char lead = keys.empty() ? static_cast<unsigned char>(0) : static_cast<unsigned char>(keys.front());
      if (lead < space || (lead >= leads[0] && lead < leads[1]) || lead >= leads[4]) {
        return 0;
      }

      return std::size_t{1} + static_cast<std::size_t>(lead >= leads[1]) + static_cast<std::size_t>(lead >= leads[2]) + static_cast<std::size_t>(lead >= leads[3]);
    }

    // The bytes of the key `keys` starts with, as Neovim spells one; 0 for none a person types.
    std::size_t explorerKeyBytes(std::string_view keys) noexcept {
      constexpr ds::Array<std::string_view, 7> named{"<CR>", "<Esc>", "<Tab>", "<S-Tab>", "<BS>", "<Del>", "<lt>"};
      constexpr std::size_t modified_prefix = 3;

      if (keys.front() != '<') {
        return explorerCharacterBytes(keys);
      }

      for (const auto name : named) {
        if (keys.starts_with(name)) {
          return name.size();
        }
      }

      // `<C-x>`, `<D-x>`, `<M-x>`: one character with a modifier.
      if (keys.size() <= modified_prefix + 1 || !std::string_view{"CDM"}.contains(keys[1]) || keys[2] != '-') {
        return 0;
      }

      auto character = keys;

      character.remove_prefix(modified_prefix);

      const auto bytes = explorerCharacterBytes(character);
      const bool closed = bytes != 0 && character.size() > bytes && character[bytes] == '>';

      return closed ? modified_prefix + bytes + 1 : 0;
    }

  }

  bool typeableExplorerKeys(std::string_view keys) noexcept {
    if (keys.empty() || keys.size() > explorer_keys_bytes || (keys.front() >= '0' && keys.front() <= '9')) {
      return false;
    }

    while (!keys.empty()) {
      const auto bytes = explorerKeyBytes(keys);
      if (bytes == 0 || bytes > keys.size()) {
        return false;
      }

      keys.remove_prefix(bytes);
    }

    return true;
  }

  bool ExplorerKey::operator==(const ExplorerKey& other) const noexcept {
    return keys.view() == other.keys.view() && command == other.command && visual == other.visual;
  }

  std::span<const ExplorerKey> ExplorerKeys::view() const noexcept {
    return items.view().first(count);
  }

  bool ExplorerKeys::put(const ExplorerKey& key) noexcept {
    for (std::size_t index = 0; index < count; ++index) {
      if (items[index].visual == key.visual && items[index].keys.view() == key.keys.view()) {
        // The later change of a sequence is the one that applies, after the ones before it.
        std::ranges::rotate(items.viewMut().subspan(index, count - index), items.viewMut().subspan(index + 1).begin());
        items.atMut(count - 1) = key;
        return true;
      }
    }

    if (count == capacity) {
      return false;
    }

    items.atMut(count++) = key;
    return true;
  }

  bool ExplorerKeys::operator==(const ExplorerKeys& other) const noexcept {
    return std::ranges::equal(view(), other.view());
  }

  void ClientReader::explorer(const lua::Value& table, ExplorerKeys& keys) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"keys"});
    const auto modes = table.field("keys");
    if (!modes.present()) {
      return;
    }

    modes.onlyFields({"normal", "visual"});
    explorerKeys(modes.field("normal"), false, keys);
    explorerKeys(modes.field("visual"), true, keys);
  }

  void ClientReader::explorerKeys(const lua::Value& table, bool visual, ExplorerKeys& keys) {
    if (!table.present()) {
      return;
    }

    if (!table.is(LUA_TTABLE)) {
      table.fail("must be a table from a sequence of keys to a command of the explorer, or to false");
    }

    const auto first = keys.count;

    table.eachField([&](std::string_view sequence, const lua::Value& value) {
      if (!typeableExplorerKeys(sequence)) {
        value.fail("is bound to \"", sequence, "\", which is no sequence of keys the explorer takes");
      }

      ExplorerKey key{.visual = visual};

      key.keys.assign(sequence);
      if (value.is(LUA_TSTRING)) {
        const auto name = value.string();
        const auto* const found = std::ranges::find(explorer_command_names, name);
        if (found == explorer_command_names.end() || found == explorer_command_names.begin()) {
          value.fail("names \"", name, "\", which is no command of the explorer");
        }

        key.command = static_cast<ExplorerCommand>(found - explorer_command_names.begin());
      } else if (!value.is(LUA_TBOOLEAN) || value.boolean(true)) {
        value.fail("must be the name of a command of the explorer, or false to unbind the keys");
      }

      if (!keys.put(key)) {
        value.fail("is one change more than the explorer's keys take");
      }
    });

    // A table has no order: the changes apply by their sequence, the same on every load.
    const auto changed = keys.items.viewMut().subspan(first, keys.count - first);

    std::ranges::sort(changed, {}, [](const ExplorerKey& key) {
      return key.keys.view();
    });

    // A sequence that starts another bound in the same table would never let it be typed.
    for (const auto& shorter : changed) {
      for (const auto& longer : changed) {
        const bool both = shorter.command != ExplorerCommand::none && longer.command != ExplorerCommand::none;
        if (both && longer.keys.view().size() > shorter.keys.view().size() && longer.keys.view().starts_with(shorter.keys.view())) {
          table.fail("binds \"", shorter.keys.view(), "\", which starts \"", longer.keys.view(), "\": the longer one could not be typed");
        }
      }
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
    const auto keybindings = client.field("keybindings");
    const bool has_keybindings = keybindings.present();
    if (has_keybindings) {
      constexpr auto maximum_bindings = BindingReader::maximum_bindings;
      const auto listed = keybindings.listLength();

      state.keymap.clear();
      if (listed > maximum_bindings) {
        limits.add({.name = "config.max_bindings", .noun = "key bindings", .value = maximum_bindings, .requested = listed, .route = {}});
      }
    }

    const ClientDefinitions definitions{client, inherited};
    BasicActionValidator<Commands> actions{definitions, limits, state.commands};

    if (has_keybindings) {
      validateBindingEntries(keybindings, actions, state.keymap);
    }

    BarsValidator<Commands>{actions, limits}.validate(client.field("bars"));
    ClientReader::slots(client, [](std::size_t, const lua::Value&) {});
  }

  template class CommandTabStorage<CommandTabLifetime::configuration>;
  template class CommandTabStorage<CommandTabLifetime::retained>;
  template class BasicActionValidator<CommandTabRegistry>;
  template class BasicActionValidator<RetainedCommandTabRegistry>;
  template void BindingValidator::validate<CommandTabRegistry>(const lua::Value& bindings, BasicActionValidator<CommandTabRegistry>& actions, BindingKeymap& keymap, LimitNotices& limits);
  template void BindingValidator::validate<RetainedCommandTabRegistry>(const lua::Value& bindings, BasicActionValidator<RetainedCommandTabRegistry>& actions, BindingKeymap& keymap, LimitNotices& limits);
  template void ClientValidator::validate<CommandTabRegistry>(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<CommandTabRegistry>& state, const lua::Value* inherited);
  template void ClientValidator::validate<RetainedCommandTabRegistry>(const lua::Value& client, LimitNotices& limits, BasicClientValidationState<RetainedCommandTabRegistry>& state, const lua::Value* inherited);

}
