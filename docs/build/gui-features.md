# Reparto de `src/gui` por casos de uso (propuesta)

Cada sección `// Interface:` de los módulos actuales de `src/gui` (fuera de `ui/`), con la carpeta a la que va. Una carpeta de `features/` es un módulo (`telar.gui.features.<ruta>`) y su namespace (`telar::gui::features::<ruta>`).

| destino | secciones | líneas |
|---|---:|---:|
| `foundation/core` | 19 | 829 |
| `foundation/drawing` | 7 | 197 |
| `foundation/fonts` | 33 | 1621 |
| `foundation/model` | 10 | 478 |
| `foundation/system` | 18 | 318 |
| `foundation/terminal` | 7 | 283 |
| `foundation/text` | 11 | 307 |
| `application` | 7 | 1356 |
| `features/activity` | 13 | 473 |
| `features/bindings` | 8 | 773 |
| `features/components` | 18 | 1042 |
| `features/configuration` | 24 | 1447 |
| `features/history` | 32 | 1476 |
| `features/machines` | 30 | 855 |
| `features/notifications` | 14 | 765 |
| `features/palette` | 7 | 278 |
| `features/paths` | 9 | 375 |
| `features/peek` | 6 | 124 |
| `features/prompt` | 8 | 880 |
| `features/suggestions` | 5 | 121 |
| `features/terminal/attachments` | 7 | 931 |
| `features/terminal/copy_mode` | 5 | 294 |
| `features/terminal/graphics` | 14 | 722 |
| `features/terminal/input` | 8 | 292 |
| `features/terminal/links` | 21 | 743 |
| `features/window` | 14 | 429 |
| `features/workbench` | 18 | 726 |

## `foundation/core`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| cosine | core.json_writer | Cosine, StandardCosine | core.json_writer, presentation.display_metrics |
| json_writer | core.json_writer | Container, JsonWriter, append, array, bytes, close … | config.gui_query, config.plugin_effects, config.plugin_query, core.json_writer, test |
| background_opacity | core.metrics | BackgroundOpacity, Surface | test, application.session, ui:app/panes, components.configuration, presentation.display_metrics |
| color | core.metrics | Color, DefaultTheme, Theme, hasAttribute, rgb | ui:foundation/scene, test, ui:app/panes, ui:design/controls, ui:design/elements |
| color_name | core.metrics | ColorName, Value | test, ui:foundation/config, application.session, components.builtin_content, components.configuration |
| configuration | core.metrics | Configuration, FontConfiguration, FontHinting, HistoryConfiguration, NotificationDelivery, PromptBinding … | test, ui:foundation/fonts, ui:app/panes, application.session, ui:app/chrome |
| geometry | core.metrics | Point, Rect, Viewport, intersectEach | ui:app/panes, test, ui:foundation/scene, ui:app/chrome, ui:app/overlays |
| metrics | core.metrics | CellMetrics, ChromeMetrics, WindowGeometry, measure, resolve | test, ui:app/panes, ui:design/controls, ui:app/chrome, presentation.display_metrics |
| terminal_surface | core.metrics | TerminalSurface | ui:app/panes, input.child_mouse, links.link_hover, test |
| theme_values | core.metrics | Appearance, PaletteRole, SyntaxRole, SyntaxStyleValues, TerminalThemeValues, ThemeName … | test, ui:app/chrome, ui:foundation/config, config.generation, config.gui_query |
| core.primitives (whole) | core.primitives |  |  |
| calendar_sample | core.unicode_scalar | CalendarSample | platform.wall_clock, presentation.history_inspection, ui:app/panes, ui:foundation/models |
| cell_rectangle | core.unicode_scalar | CellRectangle | test, ui:app/panes, layout.geometry, presentation.form_field_geometry, presentation.suggestion_labels |
| monotonic_clock | core.unicode_scalar | MonotonicClock | ui:foundation/timing |
| smoothstep | core.unicode_scalar | smoothstep |  |
| unicode_scalar | core.unicode_scalar | DecodeError, Decoded, Utf8Scalar | test, input.key_encoder, presentation.history_inspection, application.session, config.plugin_query |
| view_version | core.unicode_scalar | ViewVersion | ui:app/panes, application.session, links.link_hover, test |
| platform.progress_cosine (whole) | platform.progress_cosine | ProgressCosine | platform.progress_cosine, ui:design/controls |
| theme | presentation.suggestion_geometry | projectTheme, themeRgb |  |

## `foundation/drawing`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| progress_capsule | graphics.placeholder | ProgressCapsule, visit | graphics.placeholder, ui:design/controls |
| progress_ring | graphics.placeholder | ProgressRing, visit | ui:design/controls, graphics.placeholder, test |
| rounded_rectangle | graphics.placeholder | PaintSink, RoundedRectangle, RoundedRectanglePaint, RoundedRectangleStyle, of | ui:foundation/scene, ui:app/panes, ui:design/controls, graphics.placeholder, test |
| progress_geometry | presentation.activity_order | ProgressGeometry | graphics.placeholder, presentation.activity_order, test, ui:app/chrome, ui:app/panes |
| chrome_style | presentation.history_inspection_geometry | ChromeStyle | ui:app/chrome, ui:design/controls, ui:app/panes, ui:app/overlays, test |
| form_button_style | presentation.history_inspection_geometry | FormButtonStyle | ui:app/panes |
| modal_motion | presentation.suggestion_labels | ModalMotion | presentation.suggestion_labels, ui:design/controls |

## `foundation/fonts`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| face | fonts.face | Face, FaceDeleter, LibraryDeleter, OwnedSize, ShapingBufferDeleter, ShapingFontDeleter … | ui:foundation/fonts, test, fonts.font_requests, fonts.row_text_layout, fonts.face:views |
| glyph_bitmap_view | fonts.face | GlyphBitmapView, GlyphHinting, GlyphRasterRequest, GlyphStyle | test, ui:foundation/scene, fonts.glyph_rasterizer, fonts.face, fonts.font_requests |
| ligature_coverage | fonts.face | LigatureCoverage, OwnedSet, SetDeleter | fonts.face, fonts.row_text_layout |
| ligature_role | fonts.face | LigatureRole | fonts.text_runs, fonts.face |
| native_match | fonts.face | FontMatch, FontVariation, sameFontMatch | test, ui:foundation/fonts, fonts.glyph_rasterizer, fonts.face |
| font_role | fonts.face:views | Face, FontProvider, FontRole, fallbackIndex, fallbackRole, fittedFont | test, ui:foundation/fonts, ui:foundation/scene, ui:design/controls, fonts.face |
| shaped_run_view | fonts.face:views | ShapedGlyph, ShapedRunView | test, fonts.face, fonts.row_text_layout, ui:foundation/scene |
| font_cascade | fonts.font_requests | FontCascade | test, ui:foundation/fonts |
| font_coverage | fonts.font_requests | FontCoverage | ui:foundation/fonts, fonts.font_requests, fonts.row_text_layout, test, ui:app/panes |
| font_query | fonts.font_requests | FontQuery | ui:foundation/fonts, test, fonts.font_requests |
| font_requests | fonts.font_requests | FontRequests, Misses, digest, remember, request | test, fonts.font_requests, ui:foundation/fonts |
| glyph_rasterization | fonts.font_requests | GlyphRasterization | ui:foundation/scene |
| fonts.glyph_rasterizer (whole) | fonts.glyph_rasterizer | Deleter, GlyphRasterizer | fonts.glyph_rasterizer, test, ui:foundation/scene |
| cell_text_layout | fonts.row_text_layout | CellTextLayout, Cluster, append, begin, shape | fonts.row_text_layout, ui:design/controls |
| font_runs | fonts.row_text_layout | CascadingFontProvider, FontRuns, FontSpan, fonts_ |  |
| glyph_transform | fonts.row_text_layout | GlyphTransform | fonts.row_text_layout, ui:foundation/scene |
| icon_layout | fonts.row_text_layout | IconGlyph, IconLayout, IconRequest, Run, appendRun, fitFallback … | ui:design/controls, ui:foundation/scene, fonts.row_text_layout |
| icon_placement | fonts.row_text_layout | IconPlacement | fonts.row_text_layout, ui:foundation/scene |
| ink_bounds | fonts.row_text_layout | InkBounds, include | fonts.row_text_layout, ui:foundation/scene |
| row_text_layout | fonts.row_text_layout | CellTextRange, Cluster, RowTextLayout, RowTextRequest, appendAlone, appendCluster … | ui:foundation/scene, fonts.row_text_layout, test |
| text_layout | fonts.row_text_layout | TextLayout, TextRequest, TextSpan, addAdvance, append, appendSpan … | ui:foundation/scene, ui:app/chrome, ui:design/controls, fonts.row_text_layout, test |
| text_runs | fonts.text_runs | Column, LigatureRoles, TextRun, TextRuns, append, clear … | ui:app/chrome, ui:app/panes, fonts.row_text_layout, ui:app/overlays, fonts.text_runs |
| box_edges | terminal.glyphs | BoxEdges, BoxWeight, simplifyDoubles | terminal.glyphs.curve_cache, terminal.glyphs |
| box_stroke | terminal.glyphs | BoxStroke | fonts.face, terminal.glyphs, test, ui:foundation/fonts |
| symbol | terminal.glyphs | Symbol, SymbolKind | terminal.glyphs.curve_cache, test, fonts.row_text_layout, fonts.text_runs, terminal.glyphs |
| block | terminal.glyphs.curve_cache | Block, Paint, Side | test, terminal.glyphs.curve_cache, ui:app/panes, ui:foundation/scene |
| box | terminal.glyphs.curve_cache | Axis, Box, Interval, Junction, Paint, add … | graphics.pauses, terminal.glyphs.curve_cache, test |
| box_curve | terminal.glyphs.curve_cache | BoxCurve, PixelBounds, Shape, halfEllipse, powerline, rasterize | ui:foundation/scene, components.configuration, terminal.glyphs.curve_cache, test |
| box_edge_table | terminal.glyphs.curve_cache |  |  |
| box_metrics | terminal.glyphs.curve_cache | BoxMetrics | terminal.glyphs.curve_cache, test, ui:foundation/scene |
| braille | terminal.glyphs.curve_cache | Braille, Grid, Paint | test, terminal.glyphs.curve_cache, ui:foundation/scene |
| curve_cache | terminal.glyphs.curve_cache | CurveCache, Entry, Key, reset | presentation.activity_order, prompt.completion, test, config.plugin_query, presentation.frame_pacer |
| ink | terminal.glyphs.curve_cache | Ink, appendMerged, push, translate, validateCell |  |

## `foundation/model`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| pane_bottom_reservation | layout.geometry | PaneBottomReservation | application.session, test, layout.geometry, ui:app/panes |
| pane_layout | layout.geometry | Divider, DividerPosition, FocusOrigin, FocusRequest, Metrics, PaneLayout … | test, ui:app/panes, application.session, layout.snapshots, presentation.frame_pacer |
| workbench_geometry | layout.geometry | WorkbenchGeometry | application.session, presentation.history_inspection_geometry, test, layout.geometry, ui:app/panes |
| agent_status_change | model.records | AgentStatusChange | model.replicas, presentation.notification_center, application.session, test |
| records | model.records | Agent, Tab, TabMember, Workspace, Worktree, decltype … | test, ui:app/chrome, application.session, model.replicas, presentation.activity_order |
| tab_leaves | model.records | forEachLeaf, visit |  |
| status_age | model.records | StatusAge, StatusAgeInterval, StatusAgeSample, observe | test, model.replicas, ui:design/controls, model.records, presentation.suggestion_labels |
| agent_replica | model.replicas | AgentReplica, apply, assign, prepareStaging, resetSource, validate | test, application.session, model.replicas, ui:app/overlays |
| pane_list_replica | model.replicas | ListedPane, PaneListReplica, apply, resetSource | application.session, ui:app/chrome, model.replicas |
| workspace_replica | model.replicas | WorkspaceReplica, apply, assign, holdsWorktree, prepare, resetSource … | test, application.session, presentation.activity_order, model.replicas, ui:app/chrome |

## `foundation/system`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| platform.awake_clock (whole) | platform.awake_clock | AwakeClock | test, ui:app/overlays, ui:app/panes, ui:design/controls, ui:foundation/machines |
| platform.background_effect (whole) | platform.background_effect | QWindow, configureBackgroundEffect | test, ui:app/panes, platform.background_effect, src/gui/platform/linux/window.cpp, src/gui/platform/macos/scroll_event.mm |
| platform.file_stamp (whole) | platform.file_stamp | FileStamp, FileSymlinks | ui:app/overlays, ui:foundation/config, platform.file_stamp |
| platform.keyboard (whole) | platform.keyboard | KeyboardConvention | test, ui:foundation/input |
| external_links | platform.login_shell | AppleExternalLinks, LinuxExternalLinks, NativeExternalLinks | test, ui:foundation/links |
| host_name | platform.login_shell | QByteArray, hostName | test, ui:app/panes, ui:design/controls, ui:app/chrome, ui:app/overlays |
| login_shell | platform.login_shell | Command | input.copy_mode, machines.picker, platform.login_shell, platform.runtime_endpoint, ui:app/activity_selection.cpp |
| platform.managed_directory (whole) | platform.managed_directory | prepareManagedDirectory |  |
| platform.path_limits (whole) | platform.path_limits | PathLimits | platform.profile_file, platform.managed_directory, ui:foundation/machines |
| platform.peer_identity (whole) | platform.peer_identity | currentUserId, isCurrentUser |  |
| platform.private_file_stamp (whole) | platform.private_file_stamp | PrivateFileStamp | ui:foundation/config, platform.private_file_stamp |
| platform.process_group (whole) | platform.process_group | signalProcessGroup |  |
| platform.runtime_endpoint (whole) | platform.runtime_endpoint | program, resolve |  |
| platform.secure_random (whole) | platform.secure_random | SecureRandom, fill | platform.profile_file, platform.secure_random, ui:app/overlays |
| platform.shared_image_source (whole) | platform.shared_image_source | SharedImageSource | application.host_effects, platform.shared_image_source, test, ui:foundation/machines |
| platform.stdio_socket (whole) | platform.stdio_socket | StdioSocket, bindStandardIo, openStdioSocket | platform.stdio_socket, ui:foundation/machines |
| platform.wall_clock (whole) | platform.wall_clock | WallClock | platform.wall_clock, test, ui:app/panes |
| platform.window_lease (whole) | platform.window_lease | WindowLease | platform.window_lease, test, ui:foundation/machines |

## `foundation/terminal`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| copy_grid | terminal.font_grid | CopyDirection, CopyGranularity, CopyGrid, CopyPoint, CopyWordClass, WheelRoute … | application.session, ui:app/panes, input.copy_mode, input.copy_pointer, terminal.font_grid |
| copy_range | terminal.font_grid | CopyRangeParser, parse | application.session, terminal.font_grid, test |
| font_grid | terminal.font_grid | FontGrid, FontMetrics | test, ui:foundation/scene, ui:design/controls, ui:foundation/fonts, fonts.face |
| alpha_raster | terminal.font_grid | AlphaRaster, validate | terminal.glyphs.curve_cache, terminal.font_grid, test |
| terminal.row_cache (whole) | terminal.row_cache | Link, LinkView, Pending, Row, RowCache, Slot … | application.session, ui:app/chrome, test, application.host_effects, components.configuration |
| terminal.screen (whole) | terminal.screen |  |  |
| selection | terminal.selection | CellSelection | ui:app/panes, input.copy_mode, test, fonts.row_text_layout, terminal.selection |

## `foundation/text`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| placeholder_prefix | core.json_writer |  |  |
| bounded_editor | text.bounded_editor | BoundedEditor, backspace, clearSelection, deleteForward, deleteSelection, end … | ui:design/controls, test, text.bounded_editor |
| caption_runs | text.bounded_editor | CaptionRuns | fonts.row_text_layout, text.bounded_editor |
| cell_text_measure | text.bounded_editor | cellTextColumns |  |
| editor_view | text.bounded_editor | EditorColumns, EditorView | presentation.form_field_geometry, text.bounded_editor |
| grapheme_cursor | text.bounded_editor | GraphemeCursor | test, fonts.row_text_layout, presentation.form_field_geometry, presentation.history_inspection, presentation.history_meta_geometry |
| utf16_prefix | text.bounded_editor | Utf16Encoding, Utf16Prefix | ui:app/overlays, test, ui:app/panes, text.bounded_editor, ui:design/controls |
| wrapped_lines | text.bounded_editor | WrappedLines | presentation.history_inspection, presentation.form_field_geometry, presentation.history_meta_geometry, test, text.bounded_editor |
| bounded_text | text.json_unsigned_integer |  |  |
| label_text | text.json_unsigned_integer | LabelText | presentation.activity_order |
| text_fit | text.json_unsigned_integer | Buffer, LabelMeasure, Prefixes, TextFit | presentation.history_inspection, presentation.history_meta_geometry, presentation.notification_stack, test, ui:design/controls |

## `application`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| agent_acknowledgement | application.host_effects | AgentAcknowledgement, FocusedAgent | application.session, application.host_effects, test |
| command_handler | application.host_effects | ClientCommandHandler, UnsupportedClientCommand | application.session, application.host_effects, test, ui:app/window_commands.cpp, ui:app/window_commands.hpp |
| host_effects | application.host_effects | DiscardHostEffects, HostEffectLimits, HostEffects, RuntimeTransport, buffer, notePaneInput … | test, application.session, ui:foundation/machines, application.host_effects, ui:app/application_effects.hpp |
| host_metrics | application.host_effects | HostMetrics | application.session, test, application.host_effects, ui:app/chrome |
| session | application.session | Change, CommandChecks, CommandPresence, CommandRequest, CopySearchRows, CopySearchState … | test, application.session, ui:app/panes, prompt.editor, terminal.row_cache |
| records | application.workspace_replica | InlineDocument, Pane, PaneInputSource, PaneScrollDelta, ScrollDirection, TabCreationOutcome … | ui:app/panes, test, application.session, application.host_effects, presentation.frame_pacer |
| application.workspace_replica:fold_map (whole) | application.workspace_replica:fold_map |  |  |

## `features/activity`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| activity_order | presentation.activity_order | ActivityOrder, Children, Entry, Plan, Source, Visit … | ui:app/chrome, test, application.session, components.configuration, config.generation |
| agent_order | presentation.activity_order | AgentOrder, Attention, Entry, Plan, Priority | test, ui:app/chrome, presentation.frame_pacer, prompt.completion, application.session |
| agent_status | presentation.activity_order | Age, AgentStatusPresentation, Text | ui:app/chrome, ui:app/panes, ui:design/controls, prompt.editor, ui:app/overlays |
| project_activity | presentation.activity_order | Attention, ProjectActivity, Text | ui:app/chrome, ui:app/panes, ui:design/controls, prompt.editor, test |
| tab_activity | presentation.activity_order | Kind, TabActivity | test, application.session, ui:app/chrome, ui:app/panes, components.configuration |
| task_card_labels | presentation.activity_order | Activity, Facts, TaskCardLabels, Text, append, decimal | ui:app/chrome, ui:app/panes, ui:design/controls, prompt.editor, test |
| activity_card | presentation.application_mark | ActivityCard | presentation.activity_order, test |
| application_mark | presentation.application_mark | ApplicationMark | ui:design/controls, ui:app/chrome, ui:design/elements, presentation.application_mark, test |
| sidebar_columns | presentation.display_metrics | SidebarColumns | application.session, test, presentation.client_view_state, presentation.display_metrics |
| agent_card_geometry | presentation.history_inspection_geometry | AgentCardGeometry, Row | ui:app/chrome, presentation.history_inspection_geometry, test |
| agent_card_labels | presentation.notification_stack | AgentCardLabels, Project | ui:app/chrome, application.session, presentation.notification_stack |
| sidebar_geometry | presentation.suggestion_geometry | SidebarGeometry, SidebarMachines | ui:app/chrome, presentation.suggestion_geometry, test |
| agent_animation | presentation.suggestion_labels | AgentAnimation | test, presentation.suggestion_labels, ui:design/controls |

## `features/bindings`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| action_descriptions | input.binding_effects | DefinitionActionDescription, ExtendedActionDescription, Kind, NamedActionDescription, NotificationActionDescription, PluginActionDescription | test, application.session, ui:app/chrome, ui:app/panes, ui:foundation/config |
| callback | input.binding_effects | BindingContext, BindingEffects, InputExpression, Kind | test, application.session, ui:app/chrome, ui:app/panes, components.builtin_content |
| default_bindings | input.configuration | DefaultBinding |  |
| configuration | input.configuration | Binding, InputConfiguration, setPrefix | test, config.generation, config.plugin_query, ui:foundation/config, input.configuration |
| action | input.copy_pointer | BindingAction, BindingActionKind, builtinBindingAction | test, components.builtin_content, components.configuration, config.generation, config.plugin_effects |
| binding | input.key_encoder | BindingLimits, BindingMap, KeyBinding, Range, compareChords | components.builtin_content, components.configuration, config.generation, config.plugin_query, input.configuration |
| key_label | input.key_encoder | KeyLabel, KeyLabelStyle, KeyName, ModifierLabel, Text, append | ui:app/chrome, ui:app/panes, ui:design/controls, prompt.editor, ui:app/overlays |
| key_router | input.key_encoder | BindingInput, Context, Decision, KeyLeases, KeyRouter, Lease … | test, application.session, components.builtin_content, config.generation, input.copy_pointer |

## `features/components`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| builtin_content | components.builtin_content | builtinContent, builtinSource |  |
| clock | components.builtin_content | Clock, Text, decimal, directive, named | ui:app/chrome, ui:app/panes, ui:design/controls, test, prompt.editor |
| elements | components.builtin_content | CanvasStep, Element, ElementColor, ElementKind, ElementText | components.builtin_content, config.generation, test, ui:app/window_commands.cpp, ui:design/elements |
| icon | components.builtin_content | Icon | ui:design/elements, components.builtin_content |
| invocation | components.builtin_content | Context, Invocation, Time, invoke, pushContext | ui:design/elements, application.host_effects, config.generation, test, ui:app/chrome |
| pick_items | components.builtin_content | Offered, PickInput, PickItems, PickOption, PickSwatch, Range … | test, components.configuration, config.generation, presentation.history_meta_geometry, ui:foundation/config |
| pick_items_reader | components.builtin_content | PickItemsReader, definition, keep, lines, read | components.builtin_content, config.generation, test |
| pick_matches | components.builtin_content | Match, PickMatches, collect | components.builtin_content, palette.navigation_label, test, ui:app/chrome |
| rendered_content | components.builtin_content | CommandTabCopy, RenderedContent, ResolvedAction, ResolvedActions, ResolvedEffects, View … | ui:foundation/config, config.generation, layout.snapshots, ui:design/elements, components.builtin_content |
| rendered_elements | components.builtin_content | RenderedElements | config.generation, components.builtin_content, ui:design/elements, ui:foundation/config |
| action_references | components.configuration | ActionReader, ActionReferences, ComponentActions, ComponentActionsOf, StagedActionReferences, clear … | components.configuration, test, ui:app/application_controller.hpp, ui:app/chrome, ui:foundation/plugins |
| configuration | components.configuration | Configuration, closePanel, readBar, readBarContent, readFixed, readFixedSources … | test, ui:app/panes, ui:app/chrome, ui:foundation/config, application.session |
| content | components.configuration | BarContent, Capacity, Content, PanelContent, Parents, StagedContent … | test, ui:app/overlays, ui:foundation/config, components.builtin_content, config.generation |
| content_reader | components.configuration | Builder, ContentReader, Parent, Place, Position, Shape … | test, application.session, ui:app/panes, ui:foundation/config, config.generation |
| node | components.configuration | Input, Kind, Mark, Node, Range, Style … | test, application.session, ui:app/chrome, ui:app/panes, components.builtin_content |
| snapshot | components.configuration | BarSnapshot, PanelSnapshot, Snapshot, clear, read | components.configuration, prompt.editor, prompt.editor:text |
| source | components.configuration | Definitions, Heading, Panel, Pick, Position, Slot … | ui:app/chrome, test, ui:foundation/config, application.host_effects, application.session |
| value_reader | components.configuration | Color, ComponentColors, ValueMapper, fraction, icon, iconName … | ui:foundation/scene, test, ui:app/panes, ui:design/controls, core.metrics |

## `features/configuration`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| action_description_reader | config.generation | ActionDescriptionReader, description, read | config.generation |
| action_reader | config.generation | BindingActionReader, builtin | config.generation |
| binding_reader | config.generation | BindingActionSource, BindingReader, Reader, apply | test, components.configuration, config.generation |
| generation | config.generation | ConfigurationGeneration, ConfigurationSourceText, ElementHandlers, closePanel, effects, elementAction … | test, ui:foundation/config, config.generation |
| reader | config.generation | ClientSettings, ConfigurationReader, client, cursorShape, font, gui … | config.generation, test |
| theme_reader | config.generation | Settings, ThemeReader, apply, applySyntax, applyTerminal, applyTheme … | config.generation |
| themes | config.generation | canonicalThemeName, themeByName, themeValuesByName |  |
| client_query | config.gui_query | ClientQuery, ClientQueryContext, writeOptionalBytes, writeSections, writeSound | config.gui_query, test, ui:foundation/config |
| gui_query | config.gui_query | GuiQuery, cursorStyle, writeFont, writeWindow | config.gui_query, test, ui:foundation/config |
| query | config.gui_query | ConfigurationQuery, Section | test, ui:foundation/config, config.gui_query, ui:app/window_commands.cpp |
| theme_presets | config.gui_query | ThemePreset |  |
| theme_query | config.gui_query | ThemeQuery, byteValue, writeColor, writeOptionalRgb, writeOptionalTheme, writePalette … | config.gui_query, test, ui:foundation/config |
| callback_invocation | config.plugin_effects | CallbackInvocation | config.generation |
| plugin_effects | config.plugin_effects | Effect, PluginEffects, Tag, authorize, capability, decodeEffect … | test, ui:foundation/config, ui:foundation/plugins, config.plugin_effects, ui:app/application_wiring.cpp |
| plugin_invocation | config.plugin_effects | PluginInvocation | ui:foundation/plugins, test, ui:foundation/config |
| runtime_query | config.plugin_effects | RuntimeQuery, nullablePath, writeProxy | config.plugin_effects, test, ui:foundation/config |
| action_descriptions | config.plugin_query | ActionDescriptions, registerCallback, replaceBindings, replaceDefinition, retain | config.generation, config.plugin_query |
| action_query | config.plugin_query | ActionQuery, NamedAction, emptyObject, write, writeArguments, writeCommand … | config.plugin_query |
| binding_query | config.plugin_query | BindingQuery, writeKeys | config.plugin_query, test, ui:foundation/config |
| command_tab_action | config.plugin_query | commandTabAction, commandTabReference |  |
| input_query | config.plugin_query | InputQuery, keyName, writeCharacter, writeCode, writeEmptyObject, writeKey | config.plugin_query, test, ui:foundation/config |
| plugin_catalog | config.plugin_query | PluginCatalog, validateGeneration | ui:foundation/config, config.plugin_query, test |
| plugin_overrides | config.plugin_query | Entry, PluginOverrides, apply, set | config.generation, presentation.activity_order, prompt.completion, ui:foundation/config, config.plugin_query |
| plugin_query | config.plugin_query | PluginPage, PluginQuery, digest, listEntry, metadata, writeCapabilities … | ui:foundation/config, config.plugin_query, test |

## `features/history`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| browser | history.browser | Criteria, HistoryBrowser, PageRequest, apply, applyCommand, clearCommand … | test, application.session, ui:app/panes, history.browser |
| choice | history.browser | HistoryChoice | ui:app/panes, presentation.history_pointer, test, history.browser |
| entry | history.browser | HistoryFilters, HistoryPage, HistoryPhase, HistoryRow, HistoryViewState | ui:app/panes, application.session, test, presentation.history_filter_geometry, presentation.history_inspection |
| page_storage | history.browser | HistoryPageStorage, append, commandBytes, exchangeWith | test, history.browser |
| plain_text | history.browser | PlainText, State, advance, escapeState, strip | ui:app/chrome, ui:design/controls, test, ui:foundation/config, application.sound_playback |
| search | history.browser | HistorySearch | application.session, history.browser, test, ui:app/panes |
| history_scroll | input.child_mouse | HistoryScroll, HistoryScrollPosition, HistoryScrollState, HistoryScrollSurface | ui:app/panes, input.child_mouse |
| history_text | input.configuration | HistoryText, isControl, validate | application.session, input.configuration, test |
| history_command_line | presentation.display_metrics | HistoryCommandLine, HistoryCommandMetrics | presentation.display_metrics, ui:app/panes |
| history_loading | presentation.display_metrics | HistoryLoading | presentation.display_metrics, test, ui:app/panes |
| history_selection_motion | presentation.display_metrics | HistoryExpansion, HistoryPosition, HistorySelectionMotion | ui:app/panes, presentation.display_metrics |
| history_match_highlight | presentation.form_field_geometry | HistoryMatchHighlight, HistoryMatchSink, paint | ui:app/panes, presentation.form_field_geometry, test |
| history_actions | presentation.history_filter_geometry | HistoryActionLabel, HistoryActions, HistoryCardAction, HistoryInspectionAction, HistoryKeyStyle | ui:app/panes, test, presentation.history_meta_geometry, presentation.history_pointer |
| history_empty | presentation.history_filter_geometry | Action, HistoryEmpty, HistoryEmptyOptions | ui:app/panes, test, application.session, prompt.editor, prompt.line |
| history_empty_geometry | presentation.history_filter_geometry | HistoryEmptyGeometry, HistoryEmptyMeasurements | ui:app/panes, presentation.history_filter_geometry |
| history_filter_chip_geometry | presentation.history_filter_geometry | HistoryFilterChipGeometry, HistoryFilterChipMeasurements | ui:app/panes, presentation.history_filter_geometry |
| history_filter_geometry | presentation.history_filter_geometry | HistoryFilterGeometry, HistoryFilterMeasurements, placeGroup | ui:app/panes, presentation.history_filter_geometry |
| history_filter_labels | presentation.history_filter_geometry | Choice, HistoryFilterLabels | paths.label, prompt.completion, prompt.line, ui:app/overlays, ui:app/panes |
| history_inspection | presentation.history_inspection | HistoryInspectionDocument, HistoryInspectionEntry, HistoryInspectionFacts, HistoryInspectionLine, HistoryInspectionLines, Kind … | test, application.session, ui:app/chrome, ui:app/panes, components.configuration |
| history_labels | presentation.history_inspection | HistoryLabels, Status, Text, appendClockPart | ui:app/chrome, ui:app/panes, ui:design/controls, test, prompt.editor |
| history_path | presentation.history_inspection | HistoryPath, Limits, Text, append | ui:app/panes, ui:app/chrome, ui:design/controls, prompt.editor, test |
| history_inspection_geometry | presentation.history_inspection_geometry | HistoryInspectionGeometry | ui:app/panes, presentation.history_inspection_geometry |
| history_modal_geometry | presentation.history_inspection_geometry | HistoryModalGeometry, HistoryModalMetrics, offsetY, takeBottom, takeTop | ui:app/panes, presentation.history_inspection_geometry, test, ui:app/window_display.cpp, ui:app/window_display.hpp |
| history_card | presentation.history_meta_geometry | HistoryCard, HistoryCardLine, HistoryCardMetrics | ui:app/panes, test, presentation.history_meta_geometry |
| history_facts | presentation.history_meta_geometry | ErasedSink, HistoryFactData, HistoryFactSink, HistoryFacts, notice, sink … | presentation.history_meta_geometry, ui:app/panes |
| history_footer | presentation.history_meta_geometry | HistoryFooter, HistoryFooterAction, HistoryFooterHint, HistoryFooterOptions, Range | ui:app/panes, components.builtin_content, components.configuration, presentation.history_pointer, input.key_encoder |
| history_footer_geometry | presentation.history_meta_geometry | HistoryFooterGeometry, HistoryFooterMeasurements | ui:app/panes, presentation.history_meta_geometry |
| history_hint_geometry | presentation.history_meta_geometry | HistoryHintGeometry, HistoryHintMeasurements | presentation.history_meta_geometry, ui:design/history_hint_projection.hpp |
| history_meta_geometry | presentation.history_meta_geometry | HistoryMetaGeometry, HistoryMetaMeasurements | ui:app/panes, presentation.history_meta_geometry |
| history_row_geometry | presentation.history_meta_geometry | Facts, HistoryRowGeometry, HistoryRowMeasurements, Kind, Token, append … | test, application.session, ui:app/chrome, ui:app/panes, components.configuration |
| history_action_capture | presentation.history_pointer | HistoryActionCapture, HistoryActionPosition, HistoryActionSurface, HistoryActionTarget, cancel, present | ui:app/panes, presentation.history_pointer, test, ui:app/pointer_dispatcher.cpp, ui:app/pointer_dispatcher.hpp |
| history_hover | presentation.history_pointer | HistoryFilterAction, HistoryFooterIdentity, HistoryHover, HistoryHoverIdentity, HistoryHoverTarget, HistoryInspectionIdentity … | ui:app/panes, test, presentation.history_pointer, ui:app/pointer_dispatcher.cpp |

## `features/machines`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| connection_policy | machines.discovery | MachineConnectionPolicy, MachineSshResult | test, machines.discovery, transport.runtime_link, ui:foundation/machines |
| discovery | machines.discovery |  |  |
| failure | machines.discovery |  |  |
| identity | machines.discovery |  |  |
| limits | machines.discovery |  |  |
| messages | machines.discovery | MachineProfileMessages | machines.discovery, test, ui:app/overlays |
| runtime_location | machines.discovery | Lookup, MachineRuntimeEnvironment, MachineRuntimeLocation, resolveFrom, source_ | links.path_expansion, machines.discovery, test, ui:app/machine_roster.cpp |
| machine_activity_target | machines.picker | Agent, Command, MachineActivityTarget, Process, decltype | test, ui:app/chrome, application.session, ui:foundation/models, input.copy_mode |
| machine_client_key | machines.picker | MachineClientKey | ui:app/chrome, ui:app/panes, ui:foundation/links, ui:foundation/machines, ui:foundation/store |
| machine_row | machines.picker | MachineFields, MachineMetrics, MachineObservation, MachinePhase, MachineRow, write | test, ui:app/chrome, presentation.history_filter_geometry, transport.runtime_link, ui:app/overlays |
| machine_token | machines.picker | MachineToken | ui:app/chrome, ui:app/overlays, machines.picker, test, ui:app/application_controller.cpp |
| machines | machines.picker | Machines, Slot, pin, remove, require, requireRemote … | test, ui:app/chrome, application.host_effects, application.session, components.configuration |
| opening | machines.picker | MachineOpening | machines.picker, src/gui/main.cpp, test, ui:app/machine_roster.cpp |
| picker | machines.picker | Intent, MachinePicker, Matches | ui:app/overlays, machines.picker, test, ui:app/machine_roster.cpp |
| picker_target | machines.picker | MachinePickerTarget | ui:app/overlays, ui:app/application_wiring.cpp, ui:app/machine_roster.cpp, ui:app/machine_roster.hpp |
| edit | machines.profile_store | MachineEdit, MachineEditKind, MachineProfileEdits, add, apply, change … | test, ui:app/overlays, machines.profile_store, ui:app/machine_roster.cpp, ui:app/window_commands.cpp |
| field_rules | machines.profile_store |  |  |
| owned_edit | machines.profile_store | OwnedMachineEdit | ui:app/overlays, machines.profile_store |
| profile | machines.profile_store |  |  |
| profile_codec | machines.profile_store |  |  |
| profile_store | machines.profile_store | MachineProfileSource, MachineProfileStorage, MachineProfileStore, memory_, read | test, ui:app/overlays |
| profiles | machines.profile_store |  |  |
| remote_command | machines.profile_store |  |  |
| platform.profile_file (whole) | platform.profile_file | InsecureProfileFile, ProfileFile, ProfileFileTransaction, ProfileOperationCancelled, readProfileSource, replace | test, src/gui/main.cpp, platform.profile_file, ui:app/overlays |
| machine_facts | presentation.history_filter_geometry | CpuText, Geometry, MachineFacts, Widths | test, ui:app/chrome, presentation.history_filter_geometry |
| machine_chrome_geometry | presentation.suggestion_geometry | Control, Kind, ListRow, MachineChromeGeometry | test, ui:app/chrome, application.session, ui:app/panes, components.configuration |
| frame_stream | transport.runtime_link | FrameStream, consume, feed, reset, setMaximum | test, transport.runtime_link, ui:foundation/machines |
| runtime_handshake | transport.runtime_link | Detail, Result, RuntimeHandshake | graphics.pauses, ui:app/overlays, test, transport.runtime_link, ui:foundation/machines |
| runtime_link | transport.runtime_link | ControlByte, Headline, Label, RuntimeLink, adopt, clearFailure … | test, ui:foundation/machines, transport.runtime_link, ui:app/overlays |
| runtime_protocol | transport.runtime_link | RuntimeProtocol | test, ui:foundation/machines, transport.runtime_link, ui:app/machines_coordinator.cpp |

## `features/notifications`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| limit_reports | application.host_effects | LimitReports, Recorded, Row, Slot, Time, appendNoun … | ui:app/chrome, application.session, test, ui:design/elements, components.builtin_content |
| sound_playback | application.sound_playback | SoundPlayback, SoundRequestOutcome, State, configure, schedulingFailed | ui:foundation/config, application.session, history.browser, test, application.sound_playback |
| command_line | platform.notification_commands | CommandLine | platform.notification_commands, ui:foundation/process |
| notification_commands | platform.notification_commands | AppleNotificationCommand, LinuxNotificationCommand, NativeNotificationCommand | platform.notification_commands, test, ui:app/overlays |
| socket_limits | platform.notification_commands | SocketLimits | test |
| sound_commands | platform.notification_commands | AppleSoundCommands, Backend, LinuxSoundCommands, NativeSoundCommands, SoundAttempt | test, platform.notification_commands, ui:app/overlays |
| notification_text | presentation.history_meta_geometry | Measured, NotificationText, fitTail, measure, wrap, wrapMeasured | presentation.history_meta_geometry, test, ui:app/overlays |
| agent_alerts | presentation.notification_center | AgentAlertLabel, AgentAlerts, Message, NotificationPublisher, add, appendCount … | test, application.session, presentation.notification_center, ui:foundation/machines |
| notification_center | presentation.notification_center | NotificationCenter, advance, dismiss, push | test, ui:app/overlays, application.session, presentation.notification_center, presentation.notification_stack |
| notification_item | presentation.notification_center | NotificationId, NotificationInput, NotificationItem, Phase, advance, advanceEntering … | test, application.session, ui:app/overlays, presentation.history_inspection, presentation.notification_stack |
| notification_action_label | presentation.notification_stack | Buffer, NotificationActionLabel, format | presentation.history_inspection, test, ui:design/controls, presentation.history_meta_geometry, presentation.notification_stack |
| notification_geometry | presentation.notification_stack | NotificationCardGeometry, NotificationMetrics | ui:app/overlays, presentation.notification_stack, test |
| notification_stack | presentation.notification_stack | Cards, Motion, NotificationHeight, NotificationHidden, NotificationPlacement, NotificationStack … | presentation.frame_pacer, prompt.editor, ui:app/panes, presentation.notification_stack, test |
| notification_payload | text.notification_payload | NotificationPayload | test, application.host_effects, platform.notification_commands, ui:foundation/machines, application.session |

## `features/palette`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| palette_actions | config.gui_query | PaletteAction | ui:app/overlays, ui:app/application_controller.cpp, ui:app/application_wiring.cpp |
| navigation_label | palette.navigation_label | NavigationLabel, append, appendDetail | palette.navigation_label, test, ui:app/overlays |
| navigation_target | palette.navigation_label | AgentNavigationTarget, NavigationTarget | ui:app/overlays, machines.picker, peek.screen |
| query | palette.navigation_label | PaletteMode, PaletteQuery | test, ui:app/overlays, ui:app/dialogs.cpp, ui:app/dialogs.hpp, ui:app/window_commands.cpp |
| ranked_matches | palette.navigation_label | Match, RankedMatches, add, addScored, clear | components.builtin_content, machines.picker, test, ui:app/overlays |
| palette_geometry | presentation.suggestion_geometry | Options, PaletteGeometry, takeTop | test, presentation.suggestion_geometry, ui:app/overlays |
| palette_row_window | presentation.suggestion_geometry | PaletteRowKind, PaletteRowWindow, Row | ui:app/overlays, presentation.suggestion_geometry, test |

## `features/paths`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| directory_completion | paths.label | DirectoryCompletion, TypedDirectory, keep | ui:app/overlays, paths.label, test |
| insertion | paths.label | AbsolutePath, Choice, JoinParts, PathInsertion, Quoted, Text | ui:app/panes, ui:app/chrome, ui:design/controls, ui:app/overlays, test |
| label | paths.label | PathLabel, PathLabelRun, PathLabelTone, Span, appendSpan, layout … | ui:app/panes, test, graphics.pauses, application.session, paths.label |
| labels | paths.label | Count, PathPickerLabels, Status | ui:app/panes, components.builtin_content, presentation.history_filter_geometry, test, machines.discovery |
| limits | paths.label | PathPickerLimits | application.session, test, paths.label, ui:app/panes |
| page | paths.label | PathPickerMatch, PathPickerPage, PathPickerPhase, begin, close, expect … | application.session, test, ui:app/panes, paths.label |
| path_picker_footer | presentation.form_field_geometry | PathPickerFooter, PathPickerHint, PathPickerHintPlacement, TextColumnMeasure | test, ui:app/panes |
| path_picker_geometry | presentation.form_field_geometry | PathPickerFieldColumns, PathPickerGeometry, PathPickerRowPlacement | presentation.form_field_geometry, test, ui:app/panes |
| path_picker_placement | presentation.form_field_geometry | PathPickerPlacement | ui:app/panes, presentation.form_field_geometry, test |

## `features/peek`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| command | peek.screen | PeekCommand, PeekInput | application.session, peek.screen, test |
| limits | peek.screen | PeekLimits | application.session, peek.screen, test, ui:app/overlays |
| screen | peek.screen | PeekScreen, close, fail, show | application.session, peek.screen, test, ui:app/overlays |
| target | peek.screen | PeekTarget, decltype | application.session, peek.screen, test, ui:app/overlays |
| peek_labels | presentation.notification_stack | Facts, PeekLabels, append, decimal | presentation.activity_order, presentation.history_meta_geometry, presentation.notification_stack, ui:app/overlays |
| peek_geometry | presentation.suggestion_labels | PeekGeometry | presentation.suggestion_labels, test, ui:app/overlays |

## `features/prompt`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| form_field_geometry | presentation.form_field_geometry | FormFieldGeometry | ui:design/controls, presentation.form_field_geometry, test |
| name_prompt_geometry | presentation.suggestion_labels | NamePromptGeometry | presentation.suggestion_labels, ui:app/overlays |
| prompt.completion (whole) | prompt.completion | Choice, Completion, CompletionContext, Entry, Hash, Specs … | ui:app/chrome, application.session, paths.label, presentation.activity_order, prompt.line |
| prompt.editor (whole) | prompt.editor | Action, Clipboard, Editor, Key, KeyPress, Keymap … | ui:app/panes, test, application.session, ui:app/overlays, ui:app/chrome |
| prompt.editor:text (whole) | prompt.editor:text | CharacterClass, Group, Snapshot, Text, anchor, assign … | ui:app/chrome, ui:app/panes, ui:design/controls, prompt.editor, test |
| prompt.layout (whole) | prompt.layout | CellRange, Layout, Run, Style | application.session, layout.snapshots, test, ui:app/panes, components.configuration |
| prompt.line (whole) | prompt.line | Continuation, ContinuationOf, Line, Menu, Outcome, accept … | application.session, ui:app/panes, input.copy_pointer, test, input.key_encoder |
| prompt.routing (whole) | prompt.routing | PendingPrompt, Surface, likely | test, application.session, ui:app/panes, components.configuration, core.metrics |

## `features/suggestions`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| suggestion_preview | presentation.form_field_geometry | SuggestionPreview, SuggestionPreviewLine | presentation.form_field_geometry, test, ui:app/overlays |
| suggestion_geometry | presentation.suggestion_geometry | SuggestionGeometry | presentation.suggestion_geometry, test, ui:app/overlays |
| suggestion_labels | presentation.suggestion_labels | SuggestionLabels | presentation.suggestion_labels, test, ui:app/overlays |
| limits | suggestions.state | SuggestionLimits | application.session, peek.screen, suggestions.state, test |
| state | suggestions.state | SuggestionPhase, SuggestionState, begin, expect, invalidate, receive | application.session, presentation.suggestion_labels, test, suggestions.state, ui:app/overlays |

## `features/terminal/attachments`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| attachments.catalog (whole) | attachments.catalog | AttachmentCatalog, AttachmentEviction, AttachmentItem, AttachmentMarkerDeletion, AttachmentMarkerDirection, AttachmentMarkerPlan … | test, ui:app/chrome, ui:app/panes, application.host_effects, application.session |
| capture_state | attachments.marker_input | ClipboardCaptureState, cancel | attachments.marker_input, test, ui:app/panes |
| marker_input | attachments.marker_input | AttachmentMarkerInput, append | attachments.marker_input, ui:app/panes |
| preview_size | attachments.marker_input | AttachmentPreviewBounds, AttachmentPreviewSize | attachments.marker_input, test, ui:app/panes |
| platform.clipboard_image_pipe (whole) | platform.clipboard_image_pipe | Chunk, ClipboardImagePipe, ClipboardImagePipeLimits, waitReadable | test, platform.clipboard_image_pipe, src/gui/platform/linux/clipboard_image_source.cpp, src/gui/platform/linux/xcb_clipboard_image_monitor.cpp |
| platform.clipboard_image_transfer (whole) | platform.clipboard_image_transfer | ClipboardImageTransfer, fail | src/gui/platform/clipboard_image_source.hpp, src/gui/platform/linux/clipboard_image_source.cpp, src/gui/platform/linux/xcb_clipboard_image_monitor.cpp |
| attachment_modal_geometry | presentation.suggestion_labels | AttachmentModalGeometry | presentation.suggestion_labels, ui:app/panes |

## `features/terminal/copy_mode`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| copy_mode | input.copy_mode | CopyMode, CopyPlan, beginPointer, clearPointer, commit, enter … | application.session, input.copy_mode, test |
| copy_navigation | input.copy_mode | Command, CopyEffect, CopyNavigation, apply, characterCommand, command … | application.session, platform.login_shell, input.copy_mode, machines.picker, platform.runtime_endpoint |
| copy_state | input.copy_mode | CopyPointer, CopyState, applyMatches, beginPointer, clearSelection, gotoMatch … | ui:app/panes, input.copy_mode, test |
| click_tracker | input.copy_pointer | ClickTracker, press | test, input.copy_mode, input.copy_pointer |
| copy_pointer | input.copy_pointer | CopyPointerAuthority, CopyPointerDecision, CopyPointerInput, CopyPointerKind, CopyPointerOwner, CopyPress … | test, application.session, ui:app/panes, ui:app/chrome, components.configuration |

## `features/terminal/graphics`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| artwork_resize | graphics.pauses | ArtworkResize, Axis, RgbaImageView, Sample, Span, Tap … | test, ui:app/panes, paths.label, terminal.glyphs.curve_cache, application.session |
| pauses | graphics.pauses | Focus, GraphicsPauses, PaneCall, Row, focus, forgetClosed … | test, application.session, graphics.pauses |
| display_box | graphics.placeholder | Cell, ImageDisplayBox | test, ui:app/panes, graphics.placeholder, src/gui/terminal/screen.hpp |
| placeholder | graphics.placeholder | PlaceholderCell, PlaceholderRun, begin, extend, parsePlaceholder, placeholderColor … | ui:app/panes, graphics.placeholder, test |
| placement | graphics.placeholder | ImageGeometry, placementOrder, resolve | ui:app/panes, test, graphics.placeholder |
| source_rect | graphics.placeholder | ImageSourceRect | ui:app/panes, graphics.placeholder |
| image_draw_budget | graphics.texture_cache | ImageDrawBudget | ui:app/panes, graphics.texture_cache |
| image_residency | graphics.texture_cache | ImageAdmission, ImageResidency, ImageResidencyTable, ImageTextureHandle, ImageTextureIdentity, ImageTextureReleases … | ui:app/panes, test, graphics.texture_cache |
| lifetime | graphics.texture_cache | GraphicsLifetime | ui:app/panes, graphics.texture_cache |
| limit | graphics.texture_cache | GraphicsLimitError, GraphicsLimitKind | application.session, graphics.texture_cache, test |
| placement_selection | graphics.texture_cache | Candidate, Identity, ImageIdentity, ImagePlacementSelection, Layer, begin … | test, ui:app/panes, graphics.texture_cache |
| resync_required | graphics.texture_cache | GraphicsResyncRequired | application.session, graphics.texture_cache |
| store | graphics.texture_cache | GraphicsBudget, GraphicsStore, Image, accept, append, chunk … | test, ui:app/panes, application.workspace_replica, application.session, graphics.texture_cache |
| texture_cache | graphics.texture_cache |  |  |

## `features/terminal/input`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| child_mouse | input.child_mouse | ChildMouseGesture, ChildMouseProjection, ChildMouseReport, ChildMouseSample, ChildMouseView, MouseButton … | ui:app/panes, test, input.child_mouse, ui:app/pointer_dispatcher.cpp, ui:app/pointer_dispatcher.hpp |
| mouse_encoder | input.configuration | MouseEncoder, append, character, encode, number | ui:app/panes, application.session, input.configuration, test |
| key_character | input.key_encoder | KeyCharacter | application.session, input.key_encoder, presentation.history_inspection, test, ui:foundation/input |
| key_encoder | input.key_encoder | Code, Encoding, KeyEncoder, Modifier, SequenceCode, altText … | test, ui:app/panes, application.session, ui:foundation/input, attachments.marker_input |
| key_event | input.key_encoder | BindingEvent, BindingRepeat, KeyPhase | test, ui:app/panes, input.key_encoder, ui:app/key_bindings.cpp, ui:app/key_bindings.hpp |
| paste_encoding | input.key_encoder | PasteEncoding | application.session, paths.label, test |
| terminal_key | input.key_encoder | KittyCodepoints, KittyKeyboardFlag, TerminalKey | ui:app/panes, application.session, input.copy_mode, test, ui:foundation/input |
| input.wheel_accumulator (whole) | input.wheel_accumulator |  |  |

## `features/terminal/links`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| cell_links | links.cell_links | CellLinks, Window | ui:app/chrome, ui:app/panes, config.generation, test, links.cell_links |
| file_path | links.cell_links | EscapePolicy, FilePath, validateHost | application.session, test, links.cell_links, ui:foundation/links |
| link_match | links.cell_links | LinkMatch | links.link_hover, links.cell_links, test, ui:app/panes |
| link_target | links.cell_links | LinkTarget | test, ui:foundation/links, links.link_hover, ui:app/chrome, links.cell_links |
| markdown_links | links.cell_links | MarkdownLinks | links.cell_links, test |
| path_recognizer | links.cell_links | PathLocation, PathRecognizer | links.cell_links, test |
| uri_recognizer | links.cell_links | Prefix, UriRecognizer | links.cell_links, test |
| uri_view | links.cell_links | UriView, authority | links.cell_links |
| link_gesture | links.link_hover | LinkGesture, begin, cancel, validate | links.link_hover, test, ui:app/panes |
| link_hit | links.link_hover | LinkHit | ui:app/panes, test, links.link_hover |
| link_hover | links.link_hover | LinkHover, LinkPresentation, clear, present | links.link_hover, test, ui:app/panes |
| link_opening | links.link_hover | LinkOpening, schedulingFailed | links.link_hover, ui:foundation/links |
| link_regions | links.link_hover | LinkRegion, LinkRegions, Viewport | test, core.metrics, presentation.display_metrics, links.link_hover, terminal.font_grid |
| presented_link | links.link_hover | PresentedLink | ui:app/panes, presentation.frame_pacer |
| editor_launch | links.path_expansion | Convention, EditorLaunch, Position, writePosition | test, ui:foundation/config, components.configuration, config.generation, presentation.tab_drop |
| editor_opening | links.path_expansion | EditorOpening, EditorRequest, EditorSource, EditorTarget, begin, reset | application.session, links.path_expansion, test |
| link_grid | links.path_expansion | LinkGrid | test, links.cell_links, links.link_hover, links.path_expansion, ui:app/panes |
| link_text | links.path_expansion | LinkScheme, LinkText, LinkTextMatch, TextRange, control, digit | links.cell_links, test, ui:foundation/links, links.path_expansion |
| path_expansion | links.path_expansion | Lookup, PathEnvironment, PathExpansion, PathExpansionInput, PathText, Variables … | application.session, links.path_expansion, machines.discovery, test, ui:app/overlays |
| pointer_policy | links.path_expansion | LinkAffordance, LinkButton, LinkModifiers, LinkPointerPolicy, LinkPress, LinkPressInput | ui:app/panes, test |
| link_status_geometry | presentation.suggestion_geometry | LinkStatusGeometry | presentation.suggestion_geometry, ui:app/overlays |

## `features/window`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| cpu_history | core.json_writer | CpuHistory, Samples, push | application.host_effects, test, core.json_writer, ui:app/chrome |
| metric_levels | core.json_writer | BarMetric, MetricAlerts, MetricLevels, MetricSeverity, State, update | test, ui:app/chrome, ui:foundation/config, application.host_effects, application.sound_playback |
| loading_cue | presentation.application_mark | LoadingCue | presentation.application_mark, test, ui:app/panes |
| window_title | presentation.application_mark | Tokens, WindowTitle, append, appendSuffix, expand, filter … | application.session, presentation.application_mark, test, ui:app/panes |
| client_view_state | presentation.client_view_state | ClientViewState | application.session, ui:foundation/config, config.gui_query, test |
| chrome_surfaces | presentation.display_metrics | ChromeSurfaces | presentation.display_metrics, test, ui:foundation/models |
| display_metrics | presentation.display_metrics | DisplayMetrics | ui:app/overlays, ui:app/chrome, ui:app/panes, test, presentation.display_metrics |
| frame_pacer | presentation.frame_pacer | FramePacer, InputGrace, Pane, configure, noteInput, record | ui:app/panes, test, application.session, application.host_effects, application.workspace_replica |
| terminal_preparation | presentation.frame_pacer | TerminalPreparation | ui:app/panes, ui:app/frame_presenter.hpp |
| bar_metrics | presentation.history_filter_geometry | BarMetrics, Value | test, ui:foundation/config, application.session, components.builtin_content, components.configuration |
| mode_bar_labels | presentation.history_inspection | ModeBarHint, ModeBarLabels, append | presentation.history_inspection, test, ui:app/chrome |
| mode_hints | presentation.history_inspection | ModeHint, ModeHints, PrefixHintRouter, StatusMode, append | test, ui:app/chrome, presentation.history_inspection, ui:app/key_bindings.cpp, ui:app/key_bindings.hpp |
| mode_key_label | presentation.history_inspection | ModeKeyLabel, Text | ui:app/chrome, ui:app/panes, ui:design/controls, prompt.editor, test |
| mode_bar_geometry | presentation.history_meta_geometry | ModeBarGeometry, ModeBarMeasurements | presentation.history_meta_geometry, ui:app/chrome |

## `features/workbench`

| sección | módulo actual | exporta | usada por |
|---|---|---|---|
| layout_token | layout.snapshots | LayoutToken, TabLayoutPreset, decodeHexadecimal, read, write | application.session, test, layout.snapshots |
| navigation_history | layout.snapshots | Bookmark, Layout, NavigationHistory, clear, forget, remember | application.session, prompt.layout, test, ui:app/panes, layout.snapshots |
| saved_layouts | layout.snapshots | Row, SavedLayouts, View, clear, forget, remember … | components.builtin_content, application.session, layout.snapshots, test |
| pane_chrome | presentation.activity_order | PaneHeaderGeometry, PaneHeaderMeasurements, PaneHeaderMetrics, PaneProgressPresentation, PaneStatusChip, Text | ui:app/panes, ui:app/chrome, ui:design/controls, prompt.editor, ui:app/overlays |
| progress_animation | presentation.display_metrics | Frame, ProgressAnimation | ui:app/panes, ui:design/controls, presentation.display_metrics, test, ui:app/frame_presenter.hpp |
| progress_motion | presentation.display_metrics | ProgressMotion, ProgressSample | test, ui:design/controls, ui:foundation/models, presentation.display_metrics |
| attention_fades | presentation.frame_pacer | AttentionFades, AttentionFrame, Entry, PaneAttentionKey, begin, end | test, presentation.activity_order, prompt.completion, ui:app/panes, config.plugin_query |
| pane_motions | presentation.frame_pacer | Motion, PaneMotionSlot, PaneMotions, TabCardInput, TabCardMotion, TabCardMotions … | ui:app/panes, ui:app/chrome, presentation.notification_stack, prompt.editor, presentation.frame_pacer |
| tab_motion_frame | presentation.frame_pacer | TabMotionFrame, add, begin, request | test, ui:app/chrome, presentation.frame_pacer, ui:app/panes |
| tab_motions | presentation.frame_pacer | TabMotion, TabMotionSlot, TabMotions, begin, finish | ui:app/chrome, presentation.frame_pacer, test |
| tab_strip_geometry | presentation.frame_pacer | Captioned, Fit, Measure, Metrics, Plan, Room … | test, ui:app/chrome, layout.geometry, presentation.activity_order, presentation.form_field_geometry |
| tab_caption | presentation.history_inspection | Buffer, Content, TabCaption | components.configuration, config.generation, presentation.notification_stack, test, ui:app/overlays |
| workspace_mark | presentation.history_inspection | WorkspaceMark | test, presentation.history_inspection, ui:foundation/models |
| pane_attention_geometry | presentation.history_inspection_geometry | PaneAttentionGeometry | presentation.history_inspection_geometry, ui:app/panes |
| pane_decoration_geometry | presentation.history_inspection_geometry | PaneDecorationGeometry | test, ui:app/panes, presentation.history_inspection_geometry, ui:foundation/models |
| tab_drag | presentation.tab_drop | Position, TabDrag, TabDragMove, TabDropTarget, begin, cancel … | test, ui:app/chrome, ui:foundation/config, application.session, components.configuration |
| tab_drop_slots | presentation.tab_drop | TabDropSlot, TabDropSlots, capture | ui:app/chrome, presentation.tab_drop, test |
| tab_drop_surface | presentation.tab_drop | TabDropSurface | ui:app/chrome, presentation.tab_drop, ui:app/frame_presenter.hpp |
