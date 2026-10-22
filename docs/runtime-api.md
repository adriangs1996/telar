# API binaria del runtime de Telar

Catálogo del protocolo IPC de este checkout: **62 mensajes cliente → runtime,
50 mensajes runtime → cliente y 3 mensajes de handshake**. Es una referencia
para implementar los esquemas y codecs de un cliente, no una descripción de
la representación en memoria de las structs de Zig.

La generación actual es `88`; el identificador del esquema es los ocho bytes
ASCII `886b480d`. El runtime exige coincidencia exacta, no negocia un rango de
versiones. Fuente: [handshake.zig](../src/core/schema/handshake.zig).

## Convenciones de codificación

Cada fila de las tablas describe el **body**, en orden de transmisión. El tag
se añade delante del body; el prefijo de transporte se añade delante del
payload completo. No hay padding, alineación ni nombres de campos en el wire.

| Notación | Bytes transmitidos |
| --- | --- |
| `u8`, `u16`, `u32`, `u64` | Entero sin signo del ancho indicado, little-endian |
| `i32`, `i64` | Entero con signo del ancho indicado, little-endian |
| `bool` | Un byte: exclusivamente `0` o `1` |
| `B16` | `length:u16`, seguido de exactamente `length` bytes |
| `B32` | `length:u32`, seguido de exactamente `length` bytes |
| `raw[N]` | Exactamente `N` bytes, sin prefijo |
| `tail` | Todos los bytes restantes del payload, sin prefijo interno |
| `opt<T>` | `present:bool`; si vale `1`, sigue `value:T`; si vale `0`, no sigue nada |
| `items[count]:T` | Exactamente `count` elementos consecutivos de tipo `T`; no añade otro contador |
| `{ field:T, ... }` | Estructura anidada, serializada en el orden escrito |
| `empty` | Cero bytes de body; el payload de aplicación todavía contiene su tag |

`B16` y `B32` cuentan **bytes**, no caracteres, y no transmiten un terminador
NUL. No implican por sí mismos UTF-8: hay campos binarios y campos con
validaciones adicionales de texto. Todos los enums del catálogo ocupan `u8`,
salvo `FailureCode`, que ocupa `u16`, y `ClientIdentity`, que ocupa `u64`.

Los IDs de pane, workspace, worktree, tab y request son `u64`. Normalmente
cero es inválido; las excepciones y los sentinelas se indican más abajo.

Fuentes: [GenericDerived.zig](../src/core/schema/GenericDerived.zig),
[codec.zig](../src/core/schema/codec.zig),
[id.zig](../src/core/schema/id.zig).

## Frame de transporte

```text
Application frame:
length:u32 | tag:u8 | body:raw[length - 1]

Handshake frame:
length:u32 | magic:raw[8] | handshake_tag:u8 | handshake_body
```

`length` excluye sus propios cuatro bytes. En un mensaje de aplicación incluye
el tag; en un handshake incluye el magic, el tag y el body. El payload completo
admite como máximo `4 * 1024 * 1024` bytes. El canal es un stream: una lectura
del socket no tiene por qué coincidir con un frame entero.

Fuente: [transport.zig](../lib/localsocket/transport.zig).

Por ejemplo, `request_runtime_state` tiene body de 9 bytes, payload de 10 y
frame de 14. `system_metrics` tiene body de 17, payload de 18 y frame de 22.
Estos son los tamaños que deben corresponderse con los `payload_size` del
cliente C++ actual: el tag cuenta; el prefijo `length` no.

## Handshake

El handshake precede a los mensajes de aplicación. Sus tags pertenecen a otro
formato y no deben interpretarse como `ClientTag` o `ServerTag`.

| Tag | Dirección | Mensaje | Body después del magic y el tag | Payload total |
| --- | --- | --- | --- | --- |
| `0x01` | cliente → runtime | `client_hello` | `schema:raw[8]` | 17 bytes |
| `0x02` | runtime → cliente | `server_accept` | `schema:raw[8]` | 17 bytes |
| `0x03` | runtime → cliente | `server_reject` | `reason:RejectReason, expected_schema:raw[8]` | 18 bytes |

`magic` es exactamente `TELARIPC`. `RejectReason` vale
`incompatible_schema=1` o `client_limit_reached=2`.

Fuente: [handshake.zig](../src/core/schema/handshake.zig).

## Mensajes cliente → runtime

Los tags proceden de [ClientTag](../src/core/schema/messages/tags.zig).
Los nombres corresponden a las variantes de
[ClientMessage](../src/core/schema/messages/messages.zig).
Los tipos compuestos se expanden en las secciones siguientes.

| Tag | Mensaje | Body en orden de transmisión |
| --- | --- | --- |
| `0x01` | `open_pane` | `request_id:u64, target:PaneTarget, size:TerminalSize, launch:Launch` solamente si `target=default` |
| `0x02` | `pane_input` | `pane_id:u64, bytes:tail` |
| `0x03` | `pane_resize` | `pane_id:u64, size:TerminalSize` |
| `0x04` | `frame_ack` | `pane_id:u64, frame_id:u64` |
| `0x05` | `request_snapshot` | `pane_id:u64, known_frame_id:u64` |
| `0x06` | `detach_pane` | `pane_id:u64` |
| `0x07` | `runtime_stop` | `empty` |
| `0x08` | `request_tab_snapshot` | `request_id:u64, location:TabLocation` |
| `0x09` | `create_pane` | `request_id:u64, location:TabLocation, size:TerminalSize, launch:Launch` |
| `0x0a` | `close_pane` | `request_id:u64, pane_id:u64` |
| `0x0b` | `query_history` | `request_id:u64, query:B16, scope:HistoryScope, scope_value:HistoryScopeValue(scope), failed_only:bool, author:HistoryAuthorFilter, match:HistoryMatch, distinct:bool, limit:u16, offset:u32, snapshot_id:u64, entry_id:u64` |
| `0x0c` | `request_workspace_snapshot` | `request_id:u64, workspace:WorkspaceLocation` |
| `0x0d` | `create_tab` | `request_id:u64, workspace:WorkspaceLocation, label:B16, size:TerminalSize, launch:Launch` |
| `0x0e` | `rename_tab` | `request_id:u64, location:TabLocation, label:B16` |
| `0x0f` | `close_tab` | `request_id:u64, location:TabLocation` |
| `0x10` | `move_tab` | `request_id:u64, location:TabLocation, direction:TabMoveDirection, relative_to:opt<u64>` |
| `0x11` | `request_graphics_snapshot` | `pane_id:u64` |
| `0x12` | `graphics_credit` | `pane_id:u64, bytes:u64` |
| `0x13` | `configure_graphics` | `shared:bool` |
| `0x14` | `request_runtime_state` | `client_identity:u64, interactive:bool` |
| `0x15` | `create_workspace` | `request_id:u64, size:TerminalSize, name:B16, create_cwd:bool, launch:Launch` |
| `0x16` | `rename_workspace` | `request_id:u64, workspace:WorkspaceLocation, name:B16` |
| `0x17` | `set_pane_viewport` | `pane_id:u64, offset:u32` |
| `0x18` | `copy_selection` | `pane_id:u64, start_x:u16, start_y:u32, end_x:u16, end_y:u32, linewise:bool` |
| `0x19` | `show_notification` | `request_id:u64, notification:NotificationBody` |
| `0x1a` | `update_client_layout` | `sidebar_visible:bool, sidebar_width:u16, workspace_list_collapsed:bool, active_tab:TabLocation, tab_count:u16, tabs[tab_count]:ClientTabLayout` |
| `0x1b` | `acknowledge_agent` | `pane_id:u64, pane_generation:u64` |
| `0x1c` | `query_agents` | `request_id:u64` |
| `0x1d` | `read_pane` | `request_id:u64, pane_id:u64, pane_generation:u64, rows:u16, source:PaneTextSource` |
| `0x1e` | `send_pane_text` | `request_id:u64, pane_id:u64, pane_generation:u64, mode:PaneTextMode, text:B32, sender:opt<u64>` |
| `0x1f` | `report_agent_session` | `request_id:u64, pane_id:u64, pane_generation:u64, session:B16` |
| `0x20` | `report_agent` | `request_id:u64, pane_id:u64, pane_generation:u64, provider:AgentProvider, state:AgentReportState, session:B16, session_file:B16, session_file_kind:AgentSessionFileKind, blocked_reason:AgentBlockedReason, event:B16` |
| `0x21` | `search_pane` | `request_id:u64, pane_id:u64, needle:B16` |
| `0x22` | `import_history` | `request_id:u64, source:B16, base_sequence:u64, entry_count:u16, entries[entry_count]:{ started_at_ms:i64, command:B16 }` |
| `0x23` | `delete_history` | `request_id:u64, id:u64` |
| `0x24` | `prune_history` | `request_id:u64, scope:HistoryScope, scope_value:HistoryScopeValue(scope), before_ms:i64, failed_only:bool, match:B16` |
| `0x25` | `read_history_output` | `request_id:u64, id:u64` |
| `0x26` | `history_stats` | `request_id:u64, scope:HistoryScope, scope_value:HistoryScopeValue(scope), since_ms:i64` |
| `0x27` | `request_pane_focus` | `request_id:u64, pane_id:u64, pane_generation:u64, direction:PaneDirection` |
| `0x28` | `complete_pane_focus` | `requester:ClientRoute, request_id:u64, pane_id:u64, pane_generation:u64, outcome:PaneFocusOutcome, focused_pane_id:u64` |
| `0x29` | `suggest_command` | `request_id:u64, pane_id:u64, text:B16` |
| `0x2a` | `report_agent_command` | `request_id:u64, pane_id:u64, pane_generation:u64, phase:AgentCommandPhase, provider:B16, tool_call_id:B16, command:B32, cwd:B16, session:B16, exit_code:opt<i32>` |
| `0x2b` | `report_agent_title` | `request_id:u64, pane_id:u64, pane_generation:u64, provider:AgentProvider, title:B16` |
| `0x2c` | `configure_terminal_colors` | `foreground:opt<raw[3]>, background:opt<raw[3]>, palette:opt<raw[48]>` |
| `0x33` | `query_clients` | `request_id:u64` |
| `0x34` | `detach_client` | `request_id:u64, client_id:u64, client_generation:u64` |
| `0x35` | `request_client_command` | `ClientCommand` |
| `0x36` | `complete_client_command` | `ClientCommand` |
| `0x3a` | `open_editor` | `request_id:u64, pane_id:u64, pane_generation:u64, editor:B16, path:B16, line:u32, column:u32` |
| `0x3b` | `find_paths` | `request_id:u64, root:B16, query:B16, kind:PathKindFilter, limit:u16, refresh:bool` |
| `0x3c` | `register_worktree` | `request_id:u64, source:u64, created_by:opt<u64>, origin:WorktreeOrigin, path:B16, branch:B16, base:B16, title:B16, brief:B16, dispatched_from:B16, coordinator:opt<CoordinatorReference>` |
| `0x3d` | `launch_worktree` | `request_id:u64, worktree:u64, label:B16, size:TerminalSize, launch:Launch` |
| `0x3e` | `forget_worktree` | `request_id:u64, worktree:u64` |
| `0x3f` | `interrupt_agent` | `request_id:u64, pane_id:u64, pane_generation:u64` |
| `0x40` | `report_agent_progress` | `request_id:u64, pane_id:u64, pane_generation:u64, provider:AgentProvider, cwd:B16, work_tree_path:B16, work_tree_branch:B16, final_message:B16, plan_op:AgentPlanOp, plan_index:u16, plan_status:AgentPlanStatus, plan_done:u16, plan_total:u16, plan_text:B16` |
| `0x41` | `launch_tab` | `request_id:u64, workspace:u64, label:B16, size:TerminalSize, launch:Launch` |
| `0x42` | `verify_pane_descent` | `request_id:u64, pane_id:u64, pane_generation:u64` |
| `0x43` | `report_limit` | `reach:LimitReach, hits:u32` |
| `0x44` | `query_limits` | `request_id:u64` |
| `0x45` | `configure_frame_interval` | `interval_ns:u64` |
| `0x46` | `execution_request` | `request_id:u64, action:ExecutionAction, execution_id:u64, workspace_id:u64, stdout_offset:u64, stderr_offset:u64, input_offset:u64, stdin_open:bool, cwd:B16, argument_count:u8, arguments[argument_count]:B16, bytes:B16` |
| `0x47` | `hold_tab` | `request_id:u64, location:TabLocation, held:bool` |

`open_pane` no transmite un bool de presencia para `launch`: lo determina
`target`. `launch_tab.workspace` es un ID plano, no `WorkspaceLocation`.
La paleta de `configure_terminal_colors` son 16 triples RGB consecutivos,
sin contador ni tag por color.

## Mensajes runtime → cliente

Los tags proceden de [ServerTag](../src/core/schema/messages/tags.zig).
Los nombres corresponden a las variantes de
[ServerMessage](../src/core/schema/messages/messages.zig).

| Tag | Mensaje | Body en orden de transmisión |
| --- | --- | --- |
| `0x81` | `pane_opened` | `request_id:u64, pane_id:u64, location:TabLocation, created:bool, pane_generation:u64` |
| `0x82` | `pane_frame` | `FrameBody` |
| `0x83` | `pane_exited` | `pane_id:u64, kind:ExitKind, value:u32` |
| `0x84` | `request_failed` | `request_id:u64, code:FailureCode, message:tail` |
| `0x85` | `runtime_stopping` | `empty` |
| `0x86` | `tab_snapshot` | `request_id:u64, location:TabLocation, pane_count:u16, panes[pane_count]:{ pane_id:u64, lifecycle:PaneLifecycle, pane_generation:u64 }` |
| `0x87` | `history_results` | `request_id:u64, entry_count:u16, snapshot_id:u64, has_more:bool, entries[entry_count]:HistoryEntry` |
| `0x88` | `workspace_snapshot` | `request_id:u64, workspace:WorkspaceLocation, name:B16, tab_count:u16, tabs[tab_count]:TabDescriptor` |
| `0x89` | `tab_created` | `request_id:u64, location:TabLocation, position:u16, label:B16, root_pane_id:u64, pane_generation:u64` |
| `0x8a` | `tab_renamed` | `request_id:u64, location:TabLocation, label:B16` |
| `0x8b` | `tab_closed` | `request_id:u64, location:TabLocation, workspace_closed:bool, previous_workspace:opt<u64>` |
| `0x8c` | `tab_moved` | `request_id:u64, location:TabLocation, position:u16` |
| `0x8d` | `graphics_snapshot` | `GraphicsHeader, phase:SnapshotPhase` |
| `0x8e` | `graphics_image` | `GraphicsHeader, image:ImageDescription` |
| `0x8f` | `graphics_image_chunk` | `GraphicsHeader, key:ImageKey, offset:u64, bytes:B32` |
| `0x90` | `graphics_placement` | `GraphicsHeader, placement:GraphicsPlacement` |
| `0x91` | `graphics_delete_image` | `GraphicsHeader, key:ImageKey` |
| `0x92` | `graphics_delete_placement` | `GraphicsHeader, key:ImageKey, virtual_id:u64, placement_id:u32` |
| `0x93` | `resync_required` | `workspace:WorkspaceLocation, workspace_closed:bool, previous_workspace:opt<u64>` |
| `0x94` | `graphics_shared_image` | `GraphicsHeader, image:ImageDescription, name:B32` |
| `0x95` | `proxy_status` | `active:bool, scope:ProxyScope, system_trusted:bool, port:opt<u16>, preferred_port:opt<u16>` |
| `0x96` | `agent_snapshot` | `revision:u64, entry_count:u16, entries[entry_count]:AgentSnapshotEntry` |
| `0x97` | `system_metrics` | `revision:u64, cpu_percent:u8, memory_used_decigib:u16, has_battery:bool, battery_percent:u8, cpu_count:u16, memory_total_decigib:u16` |
| `0x98` | `workspace_list` | `revision:u64, entry_count:u16, entries[entry_count]:WorkspaceListEntry, worktree_count:u16, worktrees[worktree_count]:WorktreeListEntry` |
| `0x99` | `pane_cwd` | `pane_id:u64, cwd:B16` |
| `0x9a` | `pane_clipboard` | `pane_id:u64, bytes:B32` |
| `0x9b` | `notification` | `NotificationBody` |
| `0x9c` | `notification_shown` | `request_id:u64, delivered_clients:u8` |
| `0x9d` | `pane_foreground` | `pane_id:u64, name:B16` |
| `0x9e` | `agent_sound` | `pane_id:u64, pane_generation:u64, sound:AgentSound` |
| `0x9f` | `client_layout_snapshot` | `restored:bool, sidebar_visible:bool, sidebar_width:u16, workspace_list_collapsed:bool, active_tab:opt<TabLocation>, tab_count:u16, tabs[tab_count]:ClientTabLayout` |
| `0xa0` | `pane_text` | `request_id:u64, pane_id:u64, truncated:bool, text:B32, exit_code:opt<i32>` |
| `0xa1` | `request_completed` | `request_id:u64` |
| `0xa2` | `pane_title` | `pane_id:u64, title:B16` |
| `0xa3` | `pane_matches` | `request_id:u64, pane_id:u64, truncated:bool, match_count:u16, matches[match_count]:{ x:u16, y:u32, len:u16 }` |
| `0xa4` | `history_pruned` | `request_id:u64, removed:u64` |
| `0xa5` | `history_output` | `request_id:u64, id:u64, truncated:bool, observed_bytes:u64, content:B32` |
| `0xa6` | `history_stats_result` | `request_id:u64, total:u64, unique:u64, top_count:u8, top[top_count]:{ count:u64, command:B16 }` |
| `0xa7` | `pane_focus_command` | `requester:ClientRoute, request_id:u64, pane_id:u64, pane_generation:u64, direction:PaneDirection` |
| `0xa8` | `pane_focus_result` | `request_id:u64, outcome:PaneFocusOutcome, focused_pane_id:u64` |
| `0xa9` | `command_suggestion` | `request_id:u64, status:SuggestionStatus, text:B16` |
| `0xaa` | `pane_progress` | `pane_id:u64, state:PaneProgressState, percent:u8` |
| `0xad` | `client_list` | `request_id:u64, count:u8, entries[count]:ClientDescriptor` |
| `0xae` | `client_command` | `ClientCommand` |
| `0xaf` | `client_command_result` | `ClientCommand` |
| `0xb2` | `editor_opened` | `request_id:u64, outcome:EditorOutcome, pane_id:u64, pane_generation:u64` |
| `0xb3` | `path_results` | `request_id:u64, root:B16, scanned:u32, complete:bool, truncated:bool, match_count:u16, matches[match_count]:PathMatch` |
| `0xb4` | `worktree_registered` | `request_id:u64, worktree:u64, created:bool` |
| `0xb5` | `limit_list` | `request_id:u64, runtime_evicted:u64, client_evicted:u64, refused_reports:u64, entry_count:u16, entries[entry_count]:LimitListEntry` |
| `0xb6` | `execution_reply` | `request_id:u64, execution_id:u64, workspace_id:u64, stdout_offset:u64, stderr_offset:u64, stdout_total:u64, stderr_total:u64, input_offset:u64, input_available:u64, state:ExecutionState, exit_code:i32, stdin_open:bool, failure:B16, stdout:B16, stderr:B16` |

Los huecos en los tags no son mensajes omitidos: no tienen variante en los
enums actuales. `execution_reply` transmite los campos en el orden de su
encoder, que no coincide con el orden de declaración de su struct.

## Estructuras compartidas

### Identidad, ubicación y lanzamiento

| Tipo | Campos en orden de transmisión |
| --- | --- |
| `TerminalSize` | `cols:u16, rows:u16, cell_width_px:u16, cell_height_px:u16` |
| `PaneTarget` | `kind:u8`; `0=default` sin más bytes; `1=pane` seguido de `pane_id:u64`; `2=workspace` seguido de `workspace_id:u64` |
| `WorkspaceLocation` | `kind:u8, id:u64`; `0=workspace`, `1=worktree` |
| `TabLocation` | `workspace:WorkspaceLocation, tab_id:u64` |
| `HistoryScopeValue(scope)` | `global`: vacío; `cwd` o `workspace`: `path:B16`; `pane`: `pane_id:u64`. No repite el discriminante `scope` |
| `ClientRoute` | `id:u64, generation:u64` |
| `CoordinatorReference` | `session_id:raw[16], pane_id:u64, pane_generation:u64` |
| `Launch` | `cwd:B16, cwd_source:u64, argument_count:u16, arguments[argument_count]:B16, environment_mode:EnvironmentMode, environment_count:u16, environment[environment_count]:{ name:B16, value:B32 }` |

`TerminalSize` ocupa 8 bytes; `WorkspaceLocation`, 9; `TabLocation`, 17;
`ClientRoute`, 16; `CoordinatorReference`, 32. Un `session_id` binario no es
una cadena UUID con guiones.

`Launch.cwd_source=0` significa ausencia: **no** es `opt<u64>`.
`Launch` necesita entre 1 y 64 argumentos, incluido el programa en el primero.
En `HistoryScope.workspace`, el valor es un **path**, no un workspace ID.

Fuentes: [codec.zig](../src/core/schema/codec.zig),
[launch.zig](../src/core/schema/messages/launch.zig),
[history.zig](../src/core/schema/messages/history.zig),
[CoordinatorReference.zig](../src/core/CoordinatorReference.zig).

### Tabs, workspaces y worktrees

| Tipo | Campos en orden de transmisión |
| --- | --- |
| `TabDescriptor` | `tab_id:u64, position:u16, pane_count:u16, label:B16, foreground_count:u16, foregrounds[foreground_count]:{ pane_id:u64, name:B16 }` |
| `WorkspaceListEntry` | `workspace:u64, name:B16, path:B16, tab_count:u16, branch:B16, dirty:bool` |
| `WorktreeListEntry` | `worktree:u64, source:u64, workspace:opt<u64>, created_by:opt<u64>, origin:WorktreeOrigin, state:WorktreeState, path:B16, branch:B16, base:B16, title:B16, brief:B16, dispatched_from:B16, coordinator:opt<CoordinatorReference>, diff_added:u32, diff_removed:u32, diff_files:u32, commits_ahead:u32, command_label:B16, command_state:CommandState, command_exit:i32` |

`source` es el workspace de origen; `created_by`, un pane ID; `workspace`,
cuando está presente, es el workspace asociado. `command_exit` no transmite
un bool de presencia: su interpretación depende de `command_state`.

Fuentes: [workspace.zig](../src/core/schema/messages/workspace.zig),
[worktree.zig](../src/core/schema/messages/worktree.zig).

### Historial

```text
HistoryEntry:
id:u64
pane_id:u64
started_at_ms:i64
duration_ns:i64
exit_code:opt<i32>
status:HistoryStatus
author:HistoryAuthor
origin:HistoryOrigin
provider:B16
command:B32
cwd:B16
workspace_path:B16
command_truncated:bool
```

`import_history.entries[].command` usa `B16`; `HistoryEntry.command` usa
`B32`. No son intercambiables. Fuente:
[history.zig](../src/core/schema/messages/history.zig).

### Agentes

```text
AgentSnapshotEntry:
pane_id:u64
pane_generation:u64
location:TabLocation
pane_index:u16
process_id:u32
session_id:raw[16]
workspace_label:B16
tab_label:B16
session_title:B16
title_source:AgentTitleSource
title_state:AgentTitleState
cwd_label:B16
provider:AgentProvider
provider_name:B16
display_name:B16
icon:B16
attachments:AgentAttachmentMarkers
status:AgentStatus
blocked_reason:AgentBlockedReason
last_event:B16
status_age_s:u32
source:AgentSource
authority:AgentAuthority
confidence:u8
sequence:u64
observed_at_ms:i64
expires_at_ms:i64
work_tree:u64
final_message:B16
plan_done:u16
plan_total:u16
plan_step:B16
```

`confidence` está entre 0 y 100. `pane_index` empieza en 1.
`work_tree=0` indica que no hay worktree asociado. `session_id` es binario,
mientras que los campos `session` de los reportes son referencias de texto
del proveedor. Fuente: [agent.zig](../src/core/schema/messages/agent.zig).

### Layout y control del cliente

| Tipo | Campos en orden de transmisión |
| --- | --- |
| `ClientDescriptor` | `id:u64, generation:u64, identity:u64, attachments:u16, last_input_pane:u64, last_input_sequence:u64` |
| `ClientCommand` | `request_id:u64, route:ClientRoute, action:ClientAction, status:ClientCommandStatus, target_id:u64, value:i64, text:B16` |
| `ClientTabLayout` | `location:TabLocation, focused_pane:u64, fullscreen:bool, workspace_active:bool, node_count:u16, nodes[node_count]:ClientLayoutNode` |
| `ClientLayoutNode` | `kind:u8`; `0=pane` seguido de `pane_id:u64`; `1=split` seguido de `axis:ClientLayoutAxis, ratio:u16` |

`ClientDescriptor` ocupa 42 bytes. `ClientCommand.text` admite como máximo
4096 bytes UTF-8; el buffer interno y su capacidad no se transmiten.

Los nodos del layout forman un árbol binario en preorden. Un split va seguido
por sus dos subárboles, no por índices de hijos. `ratio` usa escala 10000 y
admite 1000–9000. `update_client_layout.active_tab` es obligatorio;
`client_layout_snapshot.active_tab` sí lleva presencia opcional.

Fuentes: [clients.zig](../src/core/schema/messages/clients.zig),
[client_commands.zig](../src/core/schema/messages/client_commands.zig),
[ClientCommand.zig](../src/core/schema/messages/ClientCommand.zig),
[layout.zig](../src/core/schema/messages/layout.zig).

### Notificaciones, paths y límites

| Tipo | Campos en orden de transmisión |
| --- | --- |
| `NotificationBody` | `level:NotificationLevel, duration_ms:u32, target:NotificationTarget, title:B16, message:B16, link:B16` |
| `NotificationTarget` | `kind:u8`; `0=none` sin más bytes; `1=pane`, `2=tab` o `3=workspace` seguidos de su `id:u64` |
| `PathMatch` | `path:B16, kind:PathKind, position_count:u8, positions[position_count]:u16` |
| `LimitReach` | `name:B16, noun:B16, value:u64, requested:opt<u64>, route:B16` |
| `LimitListEntry` | `reach:LimitReach, origin:LimitOrigin, hits:u64, last_ms:i64` |

Los paths de `PathMatch` son relativos al root de la respuesta. Las posiciones
son índices de bytes del path. Un `link` de notificación es vacío o una URL
HTTPS aceptada por el validador del runtime.

Fuentes: [notification_support.zig](../src/core/schema/messages/notification_support.zig),
[paths.zig](../src/core/schema/messages/paths.zig),
[PathMatch.zig](../src/core/schema/PathMatch.zig),
[limits.zig](../src/core/schema/messages/limits.zig).

### Gráficos

| Tipo | Campos en orden de transmisión |
| --- | --- |
| `GraphicsHeader` | `pane_id:u64, revision:u64` |
| `ImageKey` | `image_id:u32, generation:u64` |
| `ImageDescription` | `key:ImageKey, format:ImageFormat, width:u32, height:u32, byte_len:u64` |
| `GraphicsPlacement` | `key:ImageKey, virtual_id:u64, placement_id:u32, x:i32, y:i32, source_x:u32, source_y:u32, source_width:u32, source_height:u32, columns:u32, rows:u32, offset_x:u32, offset_y:u32, z_index:i32, location:PlacementLocation` |

`ImageFormat` usa los valores `rgb=24`, `rgba=32`, no `0/1`.
Con `location=placeholders` la colocación no tiene celda ancla (`x`, `y` y
los offsets valen cero): el cliente la dibuja donde la nombran las celdas de
placeholder Unicode de Kitty (U+10EEEE), con `columns` y `rows` como rejilla.
`graphics_image` anuncia la imagen; sus píxeles no están en ese mensaje.
`graphics_image_chunk` lleva los bytes; `graphics_shared_image` lleva un
nombre de memoria compartida con prefijo `B32`.

Fuentes: [graphics.zig](../src/core/schema/graphics.zig),
[mensajes gráficos](../src/core/schema/messages/graphics.zig).

## Pantalla del terminal: `FrameBody`

El body de `pane_frame` no es un array de structs `Cell` copiadas en memoria.
Contiene una cabecera, metadata de texto y spans con celdas comprimidas.

```text
FrameBody:
pane_id:u64
frame_id:u64
base_frame_id:u64
cols:u16
rows:u16
cursor.visible:bool
cursor.x:u16
cursor.y:u16
mouse.tracking:MouseTracking
mouse.sgr:bool
mouse.pixels:bool
input_modes.cursor_keys:bool
input_modes.keypad_keys:bool
input_modes.bracketed_paste:bool
input_modes.focus_events:bool
input_modes.alternate_scroll:bool
input_modes.alternate_screen:bool
input_modes.kitty_keyboard_flags:u8
input_modes.modify_other_keys_2:bool
pointer_shape:PointerShape
scroll.total_rows:u32
scroll.offset:u32
span_count:u16
cursor.shape:CursorShape
cursor.blink:bool
text_metadata:B32
spans[span_count]:FrameSpan

FrameSpan:
start:u32
count:u32
encoded_length:u32
cells:raw[encoded_length]
```

La parte fija, incluido el `u32` de longitud de metadata, ocupa 61 bytes de
body. Cada span tiene otros 12 bytes de cabecera. `start` es un índice lineal
en la cuadrícula (`y * cols + x`); `count` cuenta celdas, no bytes.

`base_frame_id=0` indica un snapshot: debe llevar metadata y cubrir toda la
cuadrícula. Un delta puede tener longitud de metadata cero. Los spans tienen
count positivo, van ordenados, no se solapan y no salen de la cuadrícula.
Se admiten como máximo 4096 spans. `kitty_keyboard_flags` ocupa un byte,
pero solo son válidos sus cinco bits bajos, valores 0–31.

Fuente: [frame_support.zig](../src/core/schema/frame_support.zig).

### Metadata de texto

Cuando `text_metadata` tiene longitud distinta de cero, sus bytes contienen:

```text
TextMetadata:
status:TextMetadataStatus
row_count:u16
link_count:u16
run_count:u16
uri_length:u32
row_flags:raw[row_count]
links[link_count]:{ offset:u32, len:u16 }
runs[run_count]:{ start:u32, len:u32, link_index:u16 }
uris:raw[uri_length]
```

`row_count` debe coincidir con `FrameBody.rows`. Cada byte de `row_flags`
usa bit 0=`wrap`, bit 1=`continuation`, bit 2=`wide_padding`,
bit 3=`hyperlinks`; los bits 4–7 deben ser cero.

Los links referencian slices consecutivos en `uris`; `len` es positivo y
está limitado a 4096 bytes. Los runs son intervalos ordenados, sin solapamiento,
contenidos en una sola fila física y con `link_index` válido. `omitted` exige
cero links, runs y bytes de URI. Límites: 256 links, 2048 runs y 64 KiB de URIs
en total.

Fuentes: [View.zig](../src/core/text_metadata/View.zig),
[RowFlags.zig](../src/core/text_metadata/RowFlags.zig),
[límites de metadata](../src/core/text_metadata/limits.zig).

### Codec de celdas

Cada span reinicia su estado de estilo. Para cada una de sus `count` celdas:

```text
cell_header:u8
style:CellStyle       only when cell_header bit 7 is set
text:raw[text_length]

CellStyle:
flags:u16
foreground:CellColor
background:CellColor
underline_color:CellColor

CellColor:
kind:u8
channels              depend on kind
```

El header empaqueta `text_length` en bits 0–4, `width` en bits 5–6 y
`style_changed` en bit 7. La primera celda de cada span debe incluir estilo;
las siguientes pueden reutilizar el anterior. `text_length` admite como
máximo 16 bytes. `width=0` exige texto vacío; `width=1` o `2` exige texto
no vacío; `width=3` es inválido.

`CellColor.kind` vale `default=0` (cero canales), `indexed=1` (un índice
`u8`) o `rgb=2` (tres bytes RGB). No se transmite el padding del color en
memoria.

`flags` usa bits 0–7 para `bold`, `italic`, `faint`, `blink`, `inverse`,
`invisible`, `strikethrough`, `overline`, respectivamente. Bits 8–10 contienen
`underline`: `none=0`, `single=1`, `double=2`, `curly=3`, `dotted=4`,
`dashed=5`. Bits 11–15 deben ser cero. Hay que consumir exactamente
`count` celdas y exactamente `encoded_length` bytes de cada span.

Fuentes: [cell_run.zig](../lib/cellcodec/cell_run.zig),
[CellReader.zig](../lib/cellcodec/CellReader.zig),
[Flags.zig](../lib/cellgrid/Flags.zig),
[Style.zig](../lib/cellgrid/Style.zig).

## Valores de enums

Los nombres de algunos tipos aquí son etiquetas descriptivas del wire:
`ClientAction` corresponde a `client_actions.Action`, `ExecutionAction` a
`ExecutionRequest.Action`, `EditorOutcome` a `EditorOpened.Outcome`, etc.
No implican que exista un archivo Zig con ese nombre.

### Navegación, procesos y UI

| Enum | Valores |
| --- | --- |
| `EnvironmentMode` | `inherit_runtime=0, replace=1` |
| `TabMoveDirection` | `previous=0, next=1` |
| `PaneDirection` | `left=0, right=1, up=2, down=3` |
| `PaneFocusOutcome` | `focused=0, no_neighbor=1, source_not_focused=2` |
| `ProxyScope` | `exact=0, wildcard=1` |
| `ClientLayoutAxis` | `horizontal=0, vertical=1` |
| `ExitKind` | `exited=0, signaled=1` |
| `PaneLifecycle` | `running=0, exited=1` |
| `PaneTextSource` | `screen=0, recent=1` |
| `PaneTextMode` | `raw=0, prompt=1, raw_enter=2` |
| `PaneProgressState` | `remove=0, set=1, error=2, indeterminate=3, pause=4` |
| `NotificationLevel` | `info=0, success=1, warning=2, failure=3` |
| `PathKind` | `file=0, directory=1` |
| `PathKindFilter` | `any=0, files=1, directories=2` |
| `WorktreeOrigin` | `telar=0, external=1` |
| `WorktreeState` | `active=0, integrated=1, gone=2` |
| `CommandState` | `none=0, running=1, exited=2` |
| `SuggestionStatus` | `ready=0, unavailable=1, timeout=2, failed=3` |
| `EditorOutcome` | `unavailable=0, opened=1, failed=2, missing=3` |
| `ClientCommandStatus` | `request=0, applied=1, admitted=2, failed=3` |
| `ExecutionAction` | `start=0, status=1, input=2, eof=3, cancel=4, forget=5, list=6` |
| `ExecutionState` | `starting=0, running=1, exited=2, failed=3` |
| `LimitOrigin` | `runtime=0, client=1` |

Fuentes: [types.zig](../src/core/schema/types.zig),
[pane.zig](../src/core/schema/messages/pane.zig),
[EditorOpened.zig](../src/core/schema/messages/EditorOpened.zig),
[client_actions.zig](../src/core/schema/messages/client_actions.zig),
[ExecutionRequest.zig](../src/core/schema/messages/ExecutionRequest.zig),
[ExecutionReply.zig](../src/core/schema/messages/ExecutionReply.zig),
[LimitOrigin.zig](../src/core/LimitOrigin.zig).

### Historial y agentes

| Enum | Valores |
| --- | --- |
| `HistoryScope` | `global=0, cwd=1, workspace=2, pane=3` |
| `HistoryMatch` | `fts=0, fuzzy=1` |
| `HistoryStatus` | `completed=0, interrupted=1, running=2` |
| `HistoryAuthor` | `human=0, agent=1` |
| `HistoryOrigin` | `pane=0, hook=1, plugin=2` |
| `HistoryAuthorFilter` | `all=0, human=1, agent=2` |
| `AgentProvider` | `unknown=0, claude=1, codex=2, pi=3, cursor=4, opencode=5`; índices personalizados `6..32` |
| `AgentAttachmentMarkers` | `none=0, ordered=1, stable_number=2, pasted_path=3` |
| `AgentStatus` | `unknown=0, working=1, blocked=2, ready=3, failed=4, done=5` |
| `AgentBlockedReason` | `none=0, permission=1, question=2, plan=3, other=4` |
| `AgentSound` | `ready=0, needs_input=1` |
| `AgentSource` | `screen=1, foreground_process=2, lifecycle_report=3` |
| `AgentReportState` | `working=0, blocked=1, ready=2, exited=3, settling=4, continuing=5, waiting=6, idle=7, released=8` |
| `AgentAuthority` | `candidate=0, active=1, obscured=2, resumed=3, exited=4, stale=5` |
| `AgentTitleSource` | `telar=0, generated=1, manual=2, terminal=3, agent=4` |
| `AgentSessionFileKind` | `claude_transcript=0, codex_state=1, cursor_meta=2` |
| `AgentTitleState` | `placeholder=0, pending=1, ready=2, failed=3` |
| `AgentCommandPhase` | `started=0, finished=1` |
| `AgentPlanOp` | `none=0, add=1, mark=2, set=3` |
| `AgentPlanStatus` | `pending=0, in_progress=1, completed=2, deleted=3` |

Fuentes: [types.zig](../src/core/schema/types.zig),
[history.zig](../src/core/schema/messages/history.zig),
[agent.zig](../src/core/schema/messages/agent.zig).

### Acciones del cliente

`ClientAction` ocupa un byte. Los valores son consecutivos, pero se enumeran
explícitamente para evitar depender del orden de un enum de C++.

| Valor | Acción | Valor | Acción |
| --- | --- | --- | --- |
| 0 | `workspace_select` | 17 | `workspace_list_collapse` |
| 1 | `tab_create` | 18 | `client_open_goto` |
| 2 | `tab_select` | 19 | `client_open_history` |
| 3 | `tab_next` | 20 | `client_copy_mode` |
| 4 | `tab_previous` | 21 | `notification_dismiss` |
| 5 | `pane_create` | 22 | `client_open_link` |
| 6 | `pane_split` | 23 | `client_clipboard_copy` |
| 7 | `pane_close` | 24 | `pane_copy` |
| 8 | `pane_focus` | 25 | `layout_get` |
| 9 | `pane_resize` | 26 | `layout_apply` |
| 10 | `pane_fullscreen` | 27 | `config_reload` |
| 11 | `pane_scroll` | 28 | `config_show` |
| 12 | `sidebar_get` | 29 | `plugin_list` |
| 13 | `sidebar_show` | 30 | `plugin_get` |
| 14 | `sidebar_hide` | 31 | `plugin_enable` |
| 15 | `sidebar_resize` | 32 | `plugin_disable` |
| 16 | `workspace_list_expand` | 33 | `plugin_run` |

Fuente: [client_actions.zig](../src/core/schema/messages/client_actions.zig).

### Errores

`FailureCode` ocupa **dos bytes**.

| Valor | Código | Valor | Código |
| --- | --- | --- | --- |
| 1 | `pane_not_found` | 9 | `agent_blocked` |
| 2 | `invalid_request` | 10 | `pane_exited` |
| 3 | `spawn_failed` | 11 | `worktree_not_found` |
| 4 | `permission_denied` | 12 | `pane_focused` |
| 5 | `resource_limit` | 13 | `prompt_rate_limited` |
| 6 | `internal` | 14 | `agent_not_working` |
| 7 | `workspace_not_found` | 15 | `interrupt_unsupported` |
| 8 | `tab_not_found` | 16 | `foreign_process` |

Fuente: [types.zig](../src/core/schema/types.zig).

### Pantalla y gráficos

| Enum | Valores |
| --- | --- |
| `SnapshotPhase` | `begin=0, end=1` |
| `ImageFormat` | `rgb=24, rgba=32` |
| `PlacementLocation` | `cell=0, placeholders=1` |
| `MouseTracking` | `none=0, x10=1, normal=2, button=3, any=4` |
| `CursorShape` | `default=0, block=1, bar=2, underline=3, hollow=4` |
| `TextMetadataStatus` | `complete=0, omitted=1, partial=2` |

`PointerShape`:

| Valor | Forma | Valor | Forma |
| --- | --- | --- | --- |
| 0 | `default` | 17 | `all_scroll` |
| 1 | `context_menu` | 18 | `col_resize` |
| 2 | `help` | 19 | `row_resize` |
| 3 | `pointer` | 20 | `n_resize` |
| 4 | `progress` | 21 | `e_resize` |
| 5 | `wait` | 22 | `s_resize` |
| 6 | `cell` | 23 | `w_resize` |
| 7 | `crosshair` | 24 | `ne_resize` |
| 8 | `text` | 25 | `nw_resize` |
| 9 | `vertical_text` | 26 | `se_resize` |
| 10 | `alias` | 27 | `sw_resize` |
| 11 | `copy` | 28 | `ew_resize` |
| 12 | `move` | 29 | `ns_resize` |
| 13 | `no_drop` | 30 | `nesw_resize` |
| 14 | `not_allowed` | 31 | `nwse_resize` |
| 15 | `grab` | 32 | `zoom_in` |
| 16 | `grabbing` | 33 | `zoom_out` |

Fuentes: [graphics.zig](../src/core/schema/graphics.zig),
[frame_support.zig](../src/core/schema/frame_support.zig),
[Cursor.zig](../src/core/schema/Cursor.zig),
[CursorAppearance.zig](../src/core/schema/CursorAppearance.zig),
[límites de metadata](../src/core/text_metadata/limits.zig).

## Límites y sentinelas que debe respetar el codec

La tabla reúne límites de campos y colecciones. No sustituye las validaciones
semánticas de cada mensaje: un valor puede caber en su tipo y ser inválido.

| Campo o colección | Límite |
| --- | --- |
| Payload de transporte | 4 MiB, incluido el tag de aplicación |
| `pane_input.bytes`, `send_pane_text.text` | 64 KiB |
| Cwd y paths generales del esquema | 4096 bytes |
| `Launch.arguments` | 1–64 argumentos; cada uno cabe en `B16`; suma de sus bytes ≤128 KiB |
| `Launch.environment` | ≤256 entradas; suma de nombres y valores ≤512 KiB |
| Labels de tabs | 128 bytes |
| `create_workspace.name`, `rename_workspace.name` | 128 bytes: usan el validador de tab labels |
| Nombre en snapshots/lista de workspaces | 256 bytes |
| Tabs por workspace / panes por tab | 64 / 64 |
| `workspace_list.entries`, `workspace_list.worktrees` | 64 / 64 |
| Branch y base de worktree | 200 bytes |
| Título / brief / command label de worktree | 96 / 512 / 48 bytes |
| `query_history.query`, `prune_history.match` | 1024 bytes |
| `query_history.limit` / resultados | 1–1000 / ≤1000 entradas |
| `HistoryEntry.command` | 64 KiB |
| `import_history` | ≤64 entradas; source ≤256 bytes; command ≤65535 bytes |
| `history_output.content` / top de estadísticas | 64 KiB / ≤10 entradas |
| Proveedor / tool call ID de historial | 64 / 256 bytes |
| `agent_snapshot.entries` | 64 |
| Workspace label / cwd label de agente | 48 / 48 bytes |
| Tab label / session title / last event de agente | 128 / 96 / 96 bytes |
| Provider name / display name / icon de agente | 32 / 32 / 8 bytes |
| Referencia de sesión / path de session file | 64 / 1024 bytes |
| Final message / plan text o step de agente | 2048 / 96 bytes |
| Nombre de foreground / título de pane | 48 / 256 bytes |
| `search_pane.needle` / `pane_matches.matches` | 128 bytes / ≤256 matches |
| Filas solicitadas por `read_pane` / `pane_text.text` | 1–2000 / ≤256 KiB |
| `pane_clipboard.bytes` | 1 MiB |
| Notificación: title / message / link | 96 / 512 / 1024 bytes |
| Notificación: duración | 500–60000 ms |
| Texto de `suggest_command` / `command_suggestion` | 512 / 1024 bytes |
| `find_paths.query`, `PathMatch.positions` | 64 bytes / ≤64 posiciones |
| `find_paths.limit`, `path_results.matches` | 1–50 / ≤50 resultados |
| `PathMatch.path` | 1024 bytes |
| Tabs de layout / nodos por tab / nodos totales | ≤256 / ≤127 / ≤511 |
| Mensaje de layout | ≤16 KiB |
| `ClientCommand.text`, `client_list.entries` | 4096 bytes / ≤32 entradas |
| `LimitReach.name`, `noun`, `route` | 64 / 32 / 32 bytes |
| `limit_list.entries` | ≤256 entradas |
| `graphics_image_chunk.bytes` | 1–1048576 bytes |
| Nombre de shared image | ≤31 bytes |
| `execution_request.arguments` / suma de bytes de argumentos | ≤64 / ≤32768 bytes |
| `execution_request.bytes`, `execution_reply.stdout`, `stderr` | ≤4096 bytes cada uno |
| `execution_reply.failure` | ≤128 bytes |
| `request_failed.message` | ≤1024 bytes UTF-8 |
| `configure_frame_interval.interval_ns` | 4166666–33333333 ns, divisiones enteras de 1 segundo por 240 y 30 |

Fuentes: [types.zig](../src/core/schema/types.zig),
[history.zig](../src/core/schema/messages/history.zig),
[pane.zig](../src/core/schema/messages/pane.zig),
[workspace.zig](../src/core/schema/messages/workspace.zig),
[ClientCommand.zig](../src/core/schema/messages/ClientCommand.zig),
[ClientList.zig](../src/core/ClientList.zig),
[Limit.zig](../src/core/Limit.zig),
[LimitReach.zig](../src/core/LimitReach.zig),
[LimitReaches.zig](../src/core/LimitReaches.zig),
[graphics.zig](../src/core/graphics.zig),
[ShmName.zig](../src/core/ShmName.zig),
[execution.zig](../src/core/schema/messages/execution.zig),
[ExecutionReply.zig](../src/core/schema/messages/ExecutionReply.zig).

Excepciones que conviene representar explícitamente:

- `request_failed.request_id=0` puede comunicar un error de conexión sin
  petición correlacionada; `tab_closed.request_id=0` también está permitido.
- `Launch.cwd_source=0` significa ausencia; no lleva byte de presencia.
- `pane_progress.percent=255` significa ausencia; los porcentajes presentes
  están entre 0 y 100. Tampoco lleva byte de presencia.
- `AgentSnapshotEntry.work_tree=0` significa ausencia.
- `request_runtime_state.client_identity` debe ser distinto de cero.
- `system_metrics.revision` debe ser distinto de cero; CPU y batería son
  porcentajes 0–100. Sin batería, `battery_percent` debe ser cero. La memoria
  está en décimas de GiB; cero en CPU count o memoria total significa que el
  runtime no pudo leer ese dato.
- `TerminalSize.cols` y `rows` deben ser positivos; su producto no puede
  superar `frame_support.max_cell_count`. El tamaño de celda en píxeles puede
  ser cero cuando se desconoce.
- `execution_request.execution_id` solo puede ser cero para `action=list`.
  Todos sus campos siguen presentes para todas las acciones; el tag de acción
  no reduce el body a una variante más corta.
- `send_pane_text.text` puede ser vacío solo con `mode=raw_enter`.
- Una generación no es una propiedad que el cliente deba deducir del pane ID:
  conserva la que publica el runtime para evitar actuar sobre una instancia
  sustituida.

Fuentes de estas excepciones: [runtime.zig](../src/core/schema/messages/runtime.zig),
[tab.zig](../src/core/schema/messages/tab.zig),
[launch.zig](../src/core/schema/messages/launch.zig),
[pane.zig](../src/core/schema/messages/pane.zig),
[agent.zig](../src/core/schema/messages/agent.zig),
[SystemMetrics.zig](../src/core/schema/messages/SystemMetrics.zig),
[TerminalSize.zig](../src/core/schema/TerminalSize.zig),
[execution.zig](../src/core/schema/messages/execution.zig).

## Cómo trasladarlo al cliente C++

Los codecs fijos actuales cubren `RequestRuntimeState` y `SystemMetrics`.
Para completar el catálogo, el esquema necesitará también enteros con signo,
structs anidadas, `B16`, `B32`, `tail`, opcionales con bool de presencia,
listas con contador y uniones discriminadas. `pane_frame` necesita además el
codec con estado de estilo por span descrito arriba.

No uses `sizeof(Message)` ni `memcpy` de la struct para calcular o producir
el wire. Los tamaños constantes solo sirven para mensajes realmente fijos;
para los demás, calcula el tamaño codificado a partir del valor. Valida
longitudes y contadores antes de reservar memoria o avanzar el lector, y
comprueba que el body se consume completo.

No todos los mensajes son peticiones/respuestas: la recepción debe despachar
por tag y correlacionar por `request_id` únicamente cuando el mensaje lo
contiene. Frames y publicaciones de estado pueden llegar entre respuestas.

### Fuentes por familia de mensajes

| Familia | Encoder/decoder de referencia |
| --- | --- |
| Panes, texto, selección, progreso, frames | [pane.zig](../src/core/schema/messages/pane.zig) |
| Tabs | [tab.zig](../src/core/schema/messages/tab.zig) |
| Workspaces | [workspace.zig](../src/core/schema/messages/workspace.zig) |
| Worktrees | [worktree.zig](../src/core/schema/messages/worktree.zig) |
| Lanzamientos | [launch.zig](../src/core/schema/messages/launch.zig) |
| Agentes | [agent.zig](../src/core/schema/messages/agent.zig) |
| Historial | [history.zig](../src/core/schema/messages/history.zig) |
| Layout | [layout.zig](../src/core/schema/messages/layout.zig) |
| Runtime, estado, colores y resultados genéricos | [runtime.zig](../src/core/schema/messages/runtime.zig) |
| Clientes | [clients.zig](../src/core/schema/messages/clients.zig) |
| Comandos de cliente | [client_commands.zig](../src/core/schema/messages/client_commands.zig) |
| Ejecuciones | [execution.zig](../src/core/schema/messages/execution.zig) |
| Editor | [editor.zig](../src/core/schema/messages/editor.zig) |
| Paths | [paths.zig](../src/core/schema/messages/paths.zig) |
| Foco | [focus.zig](../src/core/schema/messages/focus.zig) |
| Notificaciones | [notification_support.zig](../src/core/schema/messages/notification_support.zig) |
| Límites | [limits.zig](../src/core/schema/messages/limits.zig) |
| Sugerencias | [suggestion.zig](../src/core/schema/messages/suggestion.zig) |
| Gráficos | [graphics.zig](../src/core/schema/messages/graphics.zig) |

Este catálogo debe revisarse cuando cambie `handshake.schema_id`. Los tags y
las declaraciones de tipos no bastan para actualizarlo: los codecs son la
fuente del orden, los prefijos y las condiciones de cada campo.
