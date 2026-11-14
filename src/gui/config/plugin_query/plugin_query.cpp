module telar.gui.config.plugin_query;

namespace telar::gui {

  template <Allocator Memory>
  ActionDescriptions<Memory>::ActionDescriptions(Memory& memory)
      : extended_(AllocatorRef<ExtendedActionDescription, Memory>{memory}) {}

  template <Allocator Memory>
  void ActionDescriptions<Memory>::replaceBindings() noexcept {
    extended_.clear();
  }

  template <Allocator Memory>
  const ExtendedActionDescription& ActionDescriptions<Memory>::at(std::int32_t index) const {
    if (index < 0 || static_cast<std::size_t>(index) >= extended_.size()) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return extended_[static_cast<std::size_t>(index)];
  }

  template <Allocator Memory>
  void ActionDescriptions<Memory>::replaceDefinition(std::int32_t index, DefinitionActionDescription definition) {
    if (!std::holds_alternative<DefinitionActionDescription>(at(index))) {
      throw std::invalid_argument{"Action does not name a panel or pick"};
    }

    extended_[static_cast<std::size_t>(index)] = definition;
  }

  template <Allocator Memory>
  std::int32_t ActionDescriptions<Memory>::retain(const ExtendedActionDescription& description) {
    if (extended_.size() == BindingLimits::bindings) {
      throw std::length_error{"Too many configured actions"};
    }

    const auto index = extended_.size();

    extended_.push_back(description);

    return static_cast<std::int32_t>(index);
  }

  template <Allocator Memory>
  std::int32_t ActionDescriptions<Memory>::registerCallback() {
    if (callbacks_ == maximum_callbacks) {
      throw std::length_error{"Too many Lua callbacks"};
    }

    return static_cast<std::int32_t>(callbacks_++);
  }

  template class ActionDescriptions<telar::Memory>;
  template class ActionDescriptions<telar::ConcurrentMemory>;

  BindingAction commandTabAction(runtime::config::CommandTabReference reference, std::uint64_t generation) noexcept {
    return {.kind = BindingActionKind::command_tab, .parameter = std::bit_cast<std::int32_t>(reference.epoch), .reference = reference.id, .generation = generation};
  }

  std::optional<runtime::config::CommandTabReference> commandTabReference(BindingAction action) noexcept {
    if (action.kind != BindingActionKind::command_tab || !std::in_range<std::uint16_t>(action.reference)) {
      return std::nullopt;
    }

    return runtime::config::CommandTabReference{.epoch = std::bit_cast<std::uint32_t>(action.parameter), .id = static_cast<std::uint16_t>(action.reference)};
  }

  template <typename Value>
  void ActionQuery::writeValue(JsonWriter& writer, std::string_view type, const Value& value) {
    writer.object([&](JsonWriter& object) {
      object.member("type", type);
      object.member("value", value);
    });
  }

  template <Allocator Memory>
  void ActionQuery::write(JsonWriter& writer, BindingAction action, const ActionDescriptions<Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands) {
    if (action.kind == BindingActionKind::command_tab) {
      const auto reference = commandTabReference(action);
      if (!reference) {
        throw std::runtime_error{"BindingNotFound"};
      }

      writeStoredCommand(writer, *reference, commands);
    } else if (action.kind == BindingActionKind::extended) {
      std::visit([&](const auto& description) {
        writeExtended(writer, description);
      },
          descriptions.at(action.parameter));
    } else if (action.kind == BindingActionKind::callback || action.kind == BindingActionKind::expression) {
      writeValue(writer, action.kind == BindingActionKind::callback ? "lua_callback" : "lua_expr", [&](JsonWriter& value) {
        value.object([&](JsonWriter& reference) {
          reference.member("generation", action.generation);
          reference.member("id", action.parameter);
        });
      });
    } else if (!writeNamed(writer, action.kind)) {
      writeNumeric(writer, action);
    }
  }

  template void ActionQuery::write<telar::Memory>(JsonWriter& writer, BindingAction action, const ActionDescriptions<telar::Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);
  template void ActionQuery::write<telar::ConcurrentMemory>(JsonWriter& writer, BindingAction action, const ActionDescriptions<telar::ConcurrentMemory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);

  bool ActionQuery::writeNamed(JsonWriter& writer, BindingActionKind kind) {
    constexpr auto directions = std::to_array<NamedAction>({
        {.kind = BindingActionKind::scroll_pane_up, .type = "scroll_pane", .value = "up"},
        {.kind = BindingActionKind::scroll_pane_down, .type = "scroll_pane", .value = "down"},
        {.kind = BindingActionKind::split_horizontal, .type = "split_pane", .value = "horizontal"},
        {.kind = BindingActionKind::split_vertical, .type = "split_pane", .value = "vertical"},
        {.kind = BindingActionKind::focus_left, .type = "focus_pane", .value = "left"},
        {.kind = BindingActionKind::focus_right, .type = "focus_pane", .value = "right"},
        {.kind = BindingActionKind::focus_up, .type = "focus_pane", .value = "up"},
        {.kind = BindingActionKind::focus_down, .type = "focus_pane", .value = "down"},
        {.kind = BindingActionKind::navigate_left, .type = "navigate_pane", .value = "left"},
        {.kind = BindingActionKind::navigate_right, .type = "navigate_pane", .value = "right"},
        {.kind = BindingActionKind::navigate_up, .type = "navigate_pane", .value = "up"},
        {.kind = BindingActionKind::navigate_down, .type = "navigate_pane", .value = "down"},
        {.kind = BindingActionKind::resize_left, .type = "resize_pane", .value = "left"},
        {.kind = BindingActionKind::resize_right, .type = "resize_pane", .value = "right"},
        {.kind = BindingActionKind::resize_up, .type = "resize_pane", .value = "up"},
        {.kind = BindingActionKind::resize_down, .type = "resize_pane", .value = "down"},
        {.kind = BindingActionKind::resize_sidebar_left, .type = "resize_sidebar", .value = "left"},
        {.kind = BindingActionKind::resize_sidebar_right, .type = "resize_sidebar", .value = "right"},
        {.kind = BindingActionKind::move_tab_previous, .type = "move_tab", .value = "previous"},
        {.kind = BindingActionKind::move_tab_next, .type = "move_tab", .value = "next"},
    });

    for (const auto& description : directions) {
      if (description.kind == kind) {
        writeValue(writer, description.type, description.value);

        return true;
      }
    }

    constexpr auto voids = std::to_array<std::pair<BindingActionKind, std::string_view>>({
        {BindingActionKind::toggle_pane_fullscreen, "toggle_pane_fullscreen"},
        {BindingActionKind::toggle_sidebar, "toggle_sidebar"},
        {BindingActionKind::toggle_workspace_list, "toggle_workspace_list"},
        {BindingActionKind::leave_worktree, "leave_worktree"},
        {BindingActionKind::forget_gone_worktrees, "forget_gone_worktrees"},
        {BindingActionKind::new_workspace, "new_workspace"},
        {BindingActionKind::rename_workspace, "rename_workspace"},
        {BindingActionKind::close_pane, "close_pane"},
        {BindingActionKind::new_tab, "new_tab"},
        {BindingActionKind::rename_tab, "rename_tab"},
        {BindingActionKind::close_tab, "close_tab"},
        {BindingActionKind::detach, "detach"},
        {BindingActionKind::goto_picker, "goto_picker"},
        {BindingActionKind::history_palette, "history_palette"},
        {BindingActionKind::path_picker, "path_picker"},
        {BindingActionKind::suggest_command, "suggest_command"},
        {BindingActionKind::close_panel, "close_panel"},
        {BindingActionKind::refresh_panel, "refresh_panel"},
        {BindingActionKind::machine_picker, "machine_picker"},
        {BindingActionKind::add_machine, "add_machine"},
        {BindingActionKind::copy_mode, "enter_copy_mode"},
    });

    for (const auto& [action_kind, type] : voids) {
      if (kind == action_kind) {
        writeValue(writer, type, nullptr);

        return true;
      }
    }

    return false;
  }

  void ActionQuery::writeNumeric(JsonWriter& writer, BindingAction action) {
    switch (action.kind) {
    case BindingActionKind::select_tab:
      writeValue(writer, "select_tab", action.parameter);
      break;
    case BindingActionKind::select_workspace:
      writeValue(writer, "select_workspace", action.parameter);
      break;
    case BindingActionKind::select_tab_offset:
      writeValue(writer, "select_tab_offset", action.parameter);
      break;
    case BindingActionKind::next_tab:
    case BindingActionKind::previous_tab:
      writeValue(writer, "select_tab_offset", action.kind == BindingActionKind::next_tab ? 1 : -1);
      break;
    case BindingActionKind::next_machine:
    case BindingActionKind::previous_machine:
      writeValue(writer, "select_machine_offset", action.kind == BindingActionKind::next_machine ? 1 : -1);
      break;
    default:
      throw std::runtime_error{"BindingNotFound"};
    }
  }

  void ActionQuery::writeStoredCommand(JsonWriter& writer, runtime::config::CommandTabReference reference, const runtime::config::RetainedCommandTabRegistry& commands) {
    const auto command = commands.load(reference);
    if (!command) {
      throw std::runtime_error{"BindingNotFound"};
    }

    writeValue(writer, "command_tab", [&](JsonWriter& value) {
      writeCommand(value, *command);
    });
  }

  void ActionQuery::writeCommand(JsonWriter& writer, const runtime::config::CommandTabView& command) {
    writer.object([&](JsonWriter& object) {
      object.member("label", [&](JsonWriter& value) {
        value.bytes(byteView(command.label()));
      });

      object.member("argv", [&](JsonWriter& value) {
        writeArguments(value, command.argv());
      });
    });
  }

  void ActionQuery::writeArguments(JsonWriter& writer, std::span<const std::string_view> arguments) {
    writer.array([&](JsonWriter& array) {
      for (const auto argument : arguments) {
        array.element([&](JsonWriter& value) {
          value.bytes(byteView(argument));
        });
      }
    });
  }

  void ActionQuery::writeExtended(JsonWriter& writer, const NotificationActionDescription& description) {
    writeValue(writer, "notification", [&](JsonWriter& value) {
      writeNotification(value, description);
    });
  }

  void ActionQuery::writeNotification(JsonWriter& writer, const NotificationActionDescription& description) {
    constexpr std::array levels{"info", "success", "warning", "failure"};

    writer.object([&](JsonWriter& object) {
      object.member("title", description.title.view());
      object.member("message", description.message.view());
      object.member("level", std::string_view{levels[static_cast<std::size_t>(description.level)]});
      object.member("duration_ms", description.duration_ms);
      object.member("target", [&](JsonWriter& value) {
        writeTarget(value, description.target);
      });
    });
  }

  void ActionQuery::emptyObject(JsonWriter& writer) {
    writer.object([](JsonWriter&) {
    });
  }

  void ActionQuery::writeTarget(JsonWriter& writer, NotificationTarget target) {
    constexpr std::array targets{"none", "pane", "tab", "workspace"};

    writer.object([&](JsonWriter& object) {
      const auto name = std::string_view{targets[static_cast<std::size_t>(target.kind)]};

      if (target.kind == NotificationTarget::Kind::none) {
        object.member(name, emptyObject);
      } else {
        object.member(name, target.id);
      }
    });
  }

  void ActionQuery::writeExtended(JsonWriter& writer, DefinitionActionDescription description) {
    writeValue(writer, description.kind == DefinitionActionDescription::Kind::panel ? "open_panel" : "pick", description.index);
  }

  void ActionQuery::writeExtended(JsonWriter& writer, PluginActionDescription description) {
    writeValue(writer, "plugin", [&](JsonWriter& value) {
      value.object([&](JsonWriter& object) {
        object.member("plugin", description.plugin);
        object.member("action", description.action);
      });
    });
  }

  tbc::view<std::string_view, tbc::lt::a> InputQuery::write(const InputConfiguration& input, tbc::view<std::span<char>, tbc::lt::a> output) {
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("prefix", [&](JsonWriter& value) {
        writeKey(value, input.prefix);
      });

      object.member("sequence_timeout_ns", input.sequence_timeout_ns);
      object.member("binding_count", input.length);
    });

    return writer.view();
  }

  void InputQuery::writeKey(JsonWriter& writer, KeyChord key) {
    writer.object([&](JsonWriter& object) {
      object.member("code", [&](JsonWriter& value) {
        writeCode(value, key);
      });

      object.member("mods", [&](JsonWriter& value) {
        value.object([&](JsonWriter& modifiers) {
          modifiers.member("shift", key.has(KeyChord::Modifier::shift));
          modifiers.member("alt", key.has(KeyChord::Modifier::alt));
          modifiers.member("ctrl", key.has(KeyChord::Modifier::control));
          modifiers.member("super", key.has(KeyChord::Modifier::super));
        });
      });

      object.member("phase", "press");
      object.member("physical", nullptr);
      object.member("kitty", nullptr);
    });
  }

  void InputQuery::writeCode(JsonWriter& writer, KeyChord key) {
    writer.object([&](JsonWriter& object) {
      if (key.key != KeyChord::Key::character) {
        object.member(keyName(key.key), writeEmptyObject);

        return;
      }

      object.member("char", [&](JsonWriter& value) {
        writeCharacter(value, key);
      });
    });
  }

  void InputQuery::writeEmptyObject(JsonWriter& writer) {
    writer.object([](JsonWriter&) {
    });
  }

  void InputQuery::writeCharacter(JsonWriter& writer, KeyChord key) {
    const auto bytes = std::bit_cast<std::array<char, sizeof(key.character)>>(key.character);
    const auto first = static_cast<unsigned char>(bytes.front());
    std::size_t length = 1;

    while (length < Utf8Scalar::leading_prefixes.size() && first >= Utf8Scalar::leading_prefixes[length]) {
      ++length;
    }

    writer.object([&](JsonWriter& character) {
      character.member("bytes", std::string_view{bytes.data(), bytes.size()});
      character.member("len", length);
    });
  }

  std::string_view InputQuery::keyName(KeyChord::Key key) {
    constexpr std::array names{"char", "up", "down", "left", "right", "home", "end", "delete", "page_up", "page_down", "enter", "escape", "backspace", "tab", "back_tab"};
    const auto index = static_cast<std::size_t>(key);
    if (index >= names.size()) {
      throw std::invalid_argument{"Unknown key code"};
    }

    return names[index];
  }

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::a> BindingQuery::write(const InputConfiguration& input, std::size_t index, const ActionDescriptions<Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output) {
    if (index >= input.length) {
      throw std::runtime_error{"BindingNotFound"};
    }

    const auto& binding = input.configured[index];
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("index", index);
      object.member("prefixed", binding.prefixed);
      object.member("keys", [&](JsonWriter& value) {
        writeKeys(value, binding.sequence());
      });

      object.member("action", [&](JsonWriter& value) {
        ActionQuery::write(value, binding.action, descriptions, commands);
      });
    });

    return writer.view();
  }

  template tbc::view<std::string_view, tbc::lt::a> BindingQuery::write<telar::Memory>(const InputConfiguration& input, std::size_t index, const ActionDescriptions<telar::Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);
  template tbc::view<std::string_view, tbc::lt::a> BindingQuery::write<telar::ConcurrentMemory>(const InputConfiguration& input, std::size_t index, const ActionDescriptions<telar::ConcurrentMemory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);

  void BindingQuery::writeKeys(JsonWriter& writer, std::span<const KeyChord> keys) {
    writer.array([&](JsonWriter& array) {
      for (const auto key : keys) {
        array.element([&](JsonWriter& value) {
          InputQuery::writeKey(value, key);
        });
      }
    });
  }

  void PluginOverrides::set(const runtime::plugins::ConfiguredPlugin& specification, std::optional<std::uint64_t> identity) {
    for (auto& entry : std::span{entries_}.first(count_)) {
      if (entry.specification.path.view() == specification.path.view()) {
        entry.specification = specification;
        if (identity) {
          entry.identity = identity;
        }

        return;
      }
    }

    if (count_ == entries_.size()) {
      throw std::length_error{"TooManyPluginOverrides"};
    }

    entries_[count_] = {.specification = specification, .identity = identity};
    ++count_;
  }

  std::optional<bool> PluginOverrides::requested(std::string_view path) const noexcept {
    for (const auto& entry : std::span{entries_}.first(count_)) {
      if (entry.specification.path.view() == path) {
        return entry.specification.enabled;
      }
    }

    return std::nullopt;
  }

  void PluginOverrides::apply(runtime::plugins::Specifications& specifications) const noexcept {
    for (auto& specification : std::span{specifications.entries}.first(specifications.count)) {
      if (const auto enabled = requested(specification.path.view())) {
        specification.enabled = *enabled;
      }
    }
  }

  bool PluginOverrides::disabled(std::uint64_t identity, std::span<const runtime::plugins::ConfiguredPlugin> specifications) const noexcept {
    for (const auto& entry : std::span{entries_}.first(count_)) {
      if (entry.specification.enabled || entry.identity != identity) {
        continue;
      }

      for (const auto& specification : specifications) {
        if (!specification.enabled && specification.path.view() == entry.specification.path.view()) {
          return true;
        }
      }
    }

    return false;
  }

  PluginCatalog::PluginCatalog(std::uint64_t generation, std::span<const runtime::plugins::ConfiguredPlugin> specifications, std::span<const runtime::plugins::Package> packages, const PluginOverrides* overrides) noexcept
      : generation_(generation),
        specifications_(specifications),
        packages_(packages),
        overrides_(overrides) {}

  std::uint64_t PluginCatalog::generation() const noexcept {
    return generation_;
  }

  std::size_t PluginCatalog::size() const noexcept {
    return specifications_.size();
  }

  const runtime::plugins::ConfiguredPlugin& PluginCatalog::specification(std::size_t index) const {
    if (index >= size()) {
      throw std::invalid_argument{"PluginNotConfigured"};
    }

    return specifications_[index];
  }

  const runtime::plugins::Package* PluginCatalog::package(std::size_t index) const noexcept {
    if (index >= size() || !specifications_[index].enabled) {
      return nullptr;
    }

    std::size_t loaded = 0;

    for (const auto& specification : specifications_.first(index)) {
      loaded += static_cast<std::size_t>(specification.enabled);
    }

    return loaded < packages_.size() ? &packages_[loaded] : nullptr;
  }

  bool PluginCatalog::requestedEnabled(std::size_t index) const {
    const auto& configured = specification(index);

    return overrides_ == nullptr ? configured.enabled : overrides_->requested(configured.path.view()).value_or(configured.enabled);
  }

  std::size_t PluginCatalog::find(std::string_view name) const {
    for (std::size_t index = 0; index < size(); ++index) {
      if (specifications_[index].path.view() == name) {
        return index;
      }

      if (const auto* loaded = package(index); loaded != nullptr && loaded->manifest.id.view() == name) {
        return index;
      }
    }

    throw std::invalid_argument{"PluginNotConfigured"};
  }

  void PluginCatalog::validateGeneration(std::uint64_t requested) const {
    if (requested != 0 && requested != generation_) {
      throw std::invalid_argument{"StaleConfiguration"};
    }
  }

  const runtime::plugins::Package& PluginCatalog::resolve(const PluginActionDescription& requested) const {
    for (const auto& package : packages_) {
      if (runtime::plugins::stableId(package.manifest.id.view()) != requested.plugin) {
        continue;
      }

      for (const auto& name : std::span{package.manifest.actions}.first(package.manifest.action_count)) {
        if (runtime::plugins::stableId(name.view()) == requested.action) {
          return package;
        }
      }

      throw std::invalid_argument{"UnknownPluginAction"};
    }

    throw std::invalid_argument{"PluginNotConfigured"};
  }

  template <typename Entries>
  void PluginQuery::writePage(JsonWriter& writer, std::uint64_t generation, Entries&& entries) {
    writer.object([&](JsonWriter& object) {
      object.member("generation", generation);
      object.member("entries", [&](JsonWriter& value) {
        value.array(std::forward<Entries>(entries));
      });
    });
  }

  tbc::view<PluginPage, tbc::lt::a> PluginQuery::list(const PluginCatalog& catalog, const ClientCommand& request, tbc::view<std::span<char>, tbc::lt::a> output) {
    catalog.validateGeneration(request.target_id);
    const auto index = page(request.value, catalog.size());
    JsonWriter writer{output};

    writePage(writer, catalog.generation(), [&](JsonWriter& array) {
      if (index < catalog.size()) {
        array.element([&](JsonWriter& value) {
          listEntry(value, catalog, index);
        });
      }
    });

    return {.text = writer.view(), .next = index + 1 < catalog.size() ? static_cast<std::int64_t>(index + 1) : -1};
  }

  tbc::view<PluginPage, tbc::lt::a> PluginQuery::get(const PluginCatalog& catalog, const ClientCommand& request, tbc::view<std::span<char>, tbc::lt::a> output) {
    catalog.validateGeneration(request.target_id);
    const auto index = catalog.find(request.text);
    const auto* package = catalog.package(index);
    const auto count = package == nullptr ? 0 : package->manifest.action_count;
    const auto selected = page(request.value, count);
    JsonWriter writer{output};

    writePage(writer, catalog.generation(), [&](JsonWriter& array) {
      if (selected == 0) {
        array.element([&](JsonWriter& value) {
          metadata(value, catalog, index);
        });
      } else {
        array.element(package->manifest.actions[selected - 1].view());
      }
    });

    return {.text = writer.view(), .next = selected < count ? static_cast<std::int64_t>(selected + 1) : -1};
  }

  std::size_t PluginQuery::page(std::int64_t value, std::size_t maximum) {
    if (value < 0 || std::cmp_greater(value, maximum)) {
      throw std::invalid_argument{"InvalidPage"};
    }

    return static_cast<std::size_t>(value);
  }

  void PluginQuery::listEntry(JsonWriter& writer, const PluginCatalog& catalog, std::size_t index) {
    const auto& specification = catalog.specification(index);
    const auto* package = catalog.package(index);

    writer.object([&](JsonWriter& object) {
      object.member("index", index);
      object.member("path", specification.path.view());
      object.member("id", package == nullptr ? std::nullopt : std::optional{package->manifest.id.view()});
      object.member("version", package == nullptr ? std::nullopt : std::optional{package->manifest.version.view()});
      object.member("requested_enabled", catalog.requestedEnabled(index));
      object.member("enabled", specification.enabled);
    });
  }

  void PluginQuery::metadata(JsonWriter& writer, const PluginCatalog& catalog, std::size_t index) {
    const auto& specification = catalog.specification(index);
    const auto* package = catalog.package(index);

    writer.object([&](JsonWriter& object) {
      object.member("path", specification.path.view());
      object.member("requested_enabled", catalog.requestedEnabled(index));
      object.member("enabled", specification.enabled);
      if (package == nullptr) {
        object.member("id", nullptr);

        return;
      }

      const auto& manifest = package->manifest;

      object.member("id", manifest.id.view());
      object.member("version", manifest.version.view());
      object.member("entry", manifest.entry.view());
      object.member("source", manifest.source.view());
      object.member("revision", manifest.revision.view());
      object.member("digest", [&](JsonWriter& value) {
        digest(value, package->digest);
      });

      object.member("capabilities", [&](JsonWriter& value) {
        writeCapabilities(value, manifest.capabilities);
      });
    });
  }

  void PluginQuery::writeCapabilities(JsonWriter& writer, runtime::plugins::Capabilities capabilities) {
    using runtime::plugins::Capability;

    writer.array([&](JsonWriter& array) {
      for (unsigned bit = 0; bit <= static_cast<unsigned>(Capability::runtime_control); ++bit) {
        const auto capability = static_cast<Capability>(bit);
        if (capabilities.contains(capability)) {
          array.element(runtime::plugins::Capabilities::name(capability));
        }
      }
    });
  }

  void PluginQuery::digest(JsonWriter& writer, const runtime::plugins::PackageDigest& digest) {
    constexpr std::string_view digits = "0123456789abcdef";
    constexpr std::size_t characters_per_byte = 2;
    constexpr unsigned nibble_bits = 4;
    constexpr unsigned nibble_mask = 0xf;
    std::array<char, runtime::plugins::PackageDigest{}.size() * characters_per_byte> encoded{};
    std::size_t offset = 0;

    for (const auto byte : digest) {
      encoded[offset++] = digits[byte >> nibble_bits];
      encoded[offset++] = digits[byte & nibble_mask];
    }

    writer.value(std::string_view{encoded.data(), encoded.size()});
  }

}
