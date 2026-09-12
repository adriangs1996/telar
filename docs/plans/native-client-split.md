# Cliente nativo: auditoría y secuencia

Continuación de [client-presentation-split](client-presentation-split.md), que
dejó `telar-client` como cliente semántico y `telar-frontend` como adaptador
TUI. Este documento fija lo que falta para que un segundo adaptador, la GUI
nativa, comparta toda la funcionalidad y sólo cambie dónde y cómo se pinta.
La decisión está en [ADR 0014](../adr/0014-native-chrome-is-a-second-presentation-adapter.md);
los términos nuevos en `CONTEXT.md` son presentation adapter, client chrome y
Telar view.

Todo lo que sigue se verificó sobre el árbol en `96d645d5` con `grep` de
imports resueltos. Las tablas nombran ficheros reales; el destino es la capa
donde debe vivir cada pieza cuando existan dos adaptadores.

Destinos:

- **compartido**: `telar-client`, igual para TUI, GUI y headless.
- **puerto**: contrato en `telar-client` que cada adaptador implementa.
- **TUI**: se queda en el adaptador terminal.
- **dividir**: parte compartida y parte del adaptador, indicada en la tabla.

## Campos de `src/frontend/client/Client.zig`

| Campo | Tipo hoy | Destino |
| --- | --- | --- |
| `io`, `gpa` | std | compartido |
| `runtime_transport` | `telar-client.RuntimeTransportState` | compartido |
| `writer`, `output`, `fast_output` en `Params` | `std.Io.Writer`, `resources/Output.zig`, `resources/FastWrite.zig` | puerto de salida del host; TUI lo implementa con el tty |
| `select`, `select_storage`, `ClientEvent` | `std.Io.Select` | driver; lo sustituye el loop genérico con `Host` comptime. Eventos del host: `input`, `input_timeout`, `resized`, `draw`, `media_tick`, `host_written`, `compression_done`, `sidebar_animation_tick`, `capability_timeout`. Compartidos: `server`, `sent`, `config_reload`, `plugin_result`, `bar_tick`, `bar_command`, `notification_tick`, `telemetry_tick`, `telemetry_written`, `sound_played`, `notified`, `link_opened`, `clipboard_image`, `binding_timeout` |
| `options` | `Options.zig` | dividir. Compartido: `arguments`, `cwd`, `endpoint`, `prefix`, `bindings`, `sidebar_visible`, `pane_gaps`, `bars`, `input_*_timeout_ns`, `lua_generation`, `config_path`, `config_mtime_ns`, `plugin_registry`, `trust_store`, `trust_path`, `profile`, `editor`. Adaptador: `theme`, `icon_theme`, `sidebar_rendering`, `sound`, `host_shared_memory`, `theme_locked`, `sidebar_renderer_locked` |
| `client_identity` | `telar-core.ClientIdentity` | compartido; su derivación (`terminalIdentity` en `run.zig`) es del host |
| `telemetry` | `resources/TelemetryState.zig` | compartido; `resources/telemetry.zig` importa `FormatRequest`, que trae `presentation`, ver clase D |
| `client_layouts`, `startup` | `resources/ClientLayoutsState.zig`, `controllers/session/State.zig` | compartido |
| `host_negotiation` | `resources/HostNegotiationState.zig` | dividir: el resultado (`HostCapabilities`, ya en `telar-client`) es compartido; las sondas del terminal son TUI |
| `presenter`, `view` | `presentation/Presenter.zig`, `presentation/State.zig` | TUI |
| `model`, `navigation_history` | `telar-client` | compartido |
| `graphics_store` | `graphics/kitty_delivery.zig` | TUI. La recepción y retención ya viven en `telar-client/graphics`; esto es entrega Kitty |
| `host_input` | `controllers/input/State.zig` | dividir: `router`, `application_leases`, `input_timeout`, `binding_timeout`, `startup_input`, `presentation_revision` compartidos; `file`, `chunk`, `read_pending` son el productor de input TUI |
| `lua_generation`, `plugin_registry`, `trust_store`, `reload` | `config/`, `plugins/`, `resources/ConfigReloadState.zig` | compartido; `config` y `plugins` pasan a `telar-client` |
| `sidebar_rendering` | `graphics/capabilities.zig` | TUI |
| `sound_playback` | `sound/Playback.zig` | puerto de servicios del host |
| `notification_delivery`, `history_show_agent_commands`, `history_enter_runs`, `history_match_fts`, `list_submission_alternate` | bool y enum | compartido |
| `appearance_themes` | `AppearanceThemes.zig` | dividir: la selección de tema por Lua es compartida; la paleta es del adaptador |
| `clipboard_capture_resources`, `link_opening`, `link_pointer` | `telar-client` | compartido |
| `request_lifecycle`, `sidebar_animation_scheduler`, `notification_scheduler`, `bar_updates` | `telar-client` y `controllers/*/State.zig` | compartido |

## Campos de `src/frontend/client/presentation/State.zig`

Todos son del adaptador TUI. Tres parecen semánticos y no lo son:
`sidebar_requested`, `sidebar_preferred_width` y `workspace_list_collapsed`
son espejos de `Model.sidebarVisible`, `Model.sidebarWidth` y
`Model.workspaceListCollapsed`. El handler `ToggleSidebarHandler` commitea en
el modelo y `sidebar_projection.apply` proyecta al espejo. Deben seguir siendo
espejos; la GUI tendrá los suyos.

El resto es físico: `scratch`, `regions`, `hits`, `hovered`,
`pointer_position`, `pointer_content`, `sidebar` (scroll en filas), `dirty`,
`interaction_revision`, `sidebar_rendering`, `toast_overlay_drawn`, los cinco
renderers `kitty_*`, `attachment_store`, `graphics_plan`, `cell_width_px`,
`cell_height_px`, `modal_overlay_area`. `theme` e `icon_theme` son la paleta
resuelta, también del adaptador.

## Controllers, resources y entrypoints por clase de acoplamiento

Lo que un fichero importa fuera de `src/frontend/client` decide su destino.

**A. Sin dependencias del paquete TUI.** Se mueven a `telar-client` tal cual,
conservando su cableado por `connection` y `entrypoints`:

- `controllers/tabs/*`, `controllers/workspaces/*`.
- `controllers/panes/`: `Completion`, `pane_attachments`, `pane_focus`,
  `pane_focus_commands`, `pane_focus_reports`, `pane_graphics`,
  `pane_metadata`, `pane_openings`, `pane_progress`, `pane_resources`,
  `pane_splits`, `pane_viewports`.
- `controllers/session/`: `State`, `client_detachments`, `client_layouts`,
  `request_failures`, `resync_requirements`.
- `controllers/agents/`: `agent_navigation`, `agent_snapshots`,
  `proxy_status`, `system_metrics`.
- `controllers/input/`: `action_routing`, `actions`, `attachment_prompts`,
  `copy_modes`, `history_palettes`, `pane_inputs`, `pane_mouse_inputs`,
  `pane_pastes`, `paste_routing`, `suggestions` y sus contextos.
- `controllers/configuration/`: `lua_actions`, `State`, `Synchronization`,
  `Due`, `DueInput`, `Failure`, `CommandExecution`, `CallbackRequest`,
  `BarUpdatesJob`, `EvaluationContext`, `AdoptionContext`, `DeliveryContext`.
- `controllers/notifications/`: `Scheduler`, `sidebar_animations`,
  `sidebar_toggles`.
- `controllers/host/`: `Completion`, `CompletionContext`.
- `entrypoints/`: `DecodedObservation`, `runtime_io`, `runtime_messages`.
- `resources/`: todos los que no aparecen en las clases B a D.

**B. Dependen de código compartible que hoy vive en `telar-frontend`.**
Primero se mueve ese código a `telar-client`; después el fichero entra en la
clase A:

| Fichero | Importa |
| --- | --- |
| `controllers/configuration/bar_updates.zig` | `config/BarCallbackContext`, `config/BarMetrics`, `bars/command`, y `platform` (clase E) |
| `controllers/configuration/BarUpdatesCompletion.zig`, `CommandOutput.zig` | `bars/Output` |
| `controllers/configuration/plugin_actions.zig`, `PluginActionsCompletion.zig`, `PluginActionsJob.zig`, `StartContext.zig` | `plugins/plugins`, `plugins/WorkerResult`, `plugins/WorkerRequest` |
| `controllers/input/Config.zig`, `host_inputs.zig` | `config/model`, `config/default_bindings`, `input/GenericRouter` |
| `resources/Adoption.zig`, `Loaded.zig`, `Orphans.zig`, `Partial.zig`, `ScheduleArgs.zig`, `WaitArgs.zig`, `config_reload.zig` | `config/*`, `plugins/*` |

Código a mover: `src/frontend/config`, `src/frontend/plugins`,
`src/frontend/bars` y `src/frontend/transport/local.zig`. `bars`, `plugins` y `transport/local`
sólo dependen de `config`, std y `telar-core`. `config` arrastra valores del
adaptador y hay que dividirlo antes de moverlo:

| Fichero | Importa del adaptador | Qué hacer |
| --- | --- | --- |
| `config/Generation.zig`, `config/generation_support.zig` | `graphics/capabilities` (`SidebarRendering`) | el valor configurado es un enum sin dependencias; se declara en el config compartido y el adaptador lo resuelve |
| `config/Snapshot.zig` | `ui/Theme`, `ui/theme_support`, `graphics/capabilities`, `sound/Config` | separar el snapshot en parte compartida y parte del adaptador, como `Options.zig` |
| `config/theme.zig` | `ui/Theme`, `ui/theme_support`, `ui/Overrides` | la lectura Lua del tema es compartida; el tipo de paleta lo aporta el adaptador |
| `input/GenericRouter.zig` | `presentation/screen_support` como `term` | no se mueve: es la especialización TUI de `telar-client.GenericRouter` con el decodificador del terminal como `Decoder`. La GUI instancia el mismo genérico con su decodificador |

**C. Importan `graphics/kitty_delivery.zig`, la entrega Kitty al host.**
Destino: puerto de gráficos del host, que ADR 0012 ya describe como leases.
El controller pide y libera; el adaptador transmite:

`config_reloads`, `host_capabilities`, `host_resources`, `key_routing`,
`view_interactions`, `sidebar_projection`, `active_pane_resources`,
`pane_closures`, `pane_frames`, `pane_geometry`, `client_startup` (vía
`graphics/kitty.zig`), `entrypoints/events.zig`, `resources/Checks.zig`,
`resources/Snapshot.zig`, `resources/InputHandler.zig`, `Client.zig`.

**D. Importan `presentation/screen_support.zig` como `term`.** Son tipos de
evento y utilidades del decodificador del terminal. Destino: sustituir por los
tipos semánticos de `telar-client/input`; lo que quede de terminal pasa al
productor de input TUI:

`host_capabilities`, `copy_mode_pointer`, `link_openings`, `name_prompts`,
`pointer_routing`, `notifications`, `pane_clipboards`, `resources/Capture.zig`,
`resources/FormatRequest.zig`, `resources/StartupInputState.zig`,
`resources/telemetry.zig`.

**E. Importan `platform`.** Destino: host TUI. `host_resizes`, `Source`,
`session/Request`, `bar_updates`, `entrypoints/Resources.zig`, `run.zig`.

**F. Servicios del host.** Destino: un puerto por capacidad, como ya prevé el
plan anterior. `agent_sounds` (`sound/worker`), `notifications`
(`notifications/host`, `notifications/Payload`), `link_openings`
(`links/host`), `clipboard_images` (`attachments/capture`).

## Lo que la proyección aún no da a una GUI

- `Projection.geometry` es `Region`: la rejilla de celdas del workbench que
  publica el adaptador. No es geometría del terminal host: la TUI la deriva de
  su tamaño y su chrome, y una ventana la derivará de sus píxeles y su fuente.
  El modelo reparte los panes dentro de ella. Ver el paso 6.
- El layout no distingue contenido. Un nodo será pane de terminal o Telar
  view. El thread view y el composer del plan de agent mode son las primeras
  Telar views.
- `status_mode` viene de `hints_support.Mode`, ligado a las hints de la barra
  TUI. Hay que comprobar si la GUI necesita el mismo valor o sólo el modo de
  input.

## Secuencia

Cada paso deja la TUI funcionando con `zig build test`,
`zig build check-client-boundaries` y los gates de rendimiento vigentes.

1. Auditoría y decisión. Este documento y ADR 0014. Hecho.
2. Mover a `telar-client` el código de la clase B: config, plugins, bars y
   transporte local, sin cambio de comportamiento. Hecho: ver
   [Paso 2](#paso-2-resultado).
3. Sustituir `term` en los ficheros de la clase D por tipos semánticos y
   conectar los servicios de la clase F mediante puertos. Hecho: ver
   [Paso 3](#paso-3-resultado).
4. Sacar `kitty_delivery` de los ficheros de la clase C detrás del puerto de
   gráficos del host. Hecho: ver [Paso 4](#paso-4-resultado).
5. Telar views en el modelo como superficie por hoja, con la proyección del
   thread view y su composer. Hecho: ver [Paso 5](#paso-5-resultado).
6. Rehacer `Projection` sin `Region` de host. Resuelto por análisis, sin
   cambio de código: ver [Paso 6](#paso-6-resultado).
7. Agregado compartido y puertos, con el driver en el adaptador. Sustituye al
   `Host` comptime con loop genérico: ver [Contrato del paso 7](#paso-7-contrato).
   Hecho: ver [Paso 7](#paso-7-resultado). `telar-frontend` conserva su nombre.
8. Primer hito de `telar-gui`: pintar sidebar y un pane de terminal en una
   ventana, sin input.
9. Migrar el loop real al modelo inbox/outbox de
   [frontend-execution-model](frontend-execution-model.md) con los tres hosts.

## Fuera de alcance

- Cambios en propiedad de PTYs, emulación VT o mensajes del runtime. El
  cliente nativo no emula VT; recibe celdas del runtime.
- Un framework de widgets común o una display list universal.
- Funciones exclusivas de la GUI.

## Paso 2, resultado

Todo lo de la clase B vive ahora en `telar-client` y `telar-frontend` no
declara ningún export de configuración, plugins, tema ni transporte:

- `config/` completo, incluido `bootstrap.lua`, en `src/client/config/`.
  `telar-client` importa `telar-lua` y `lua-api`; `build.zig` y
  `tools/check_client_boundaries.py` fijan ese conjunto exacto.
- `src/frontend/config/lua_api.zig` era la raíz del módulo `lua-api`, no un
  fichero de configuración. Está en `src/lua/lua_api.zig`.
- `plugins/` en `src/client/plugins/`; `bars/command.zig` y `bars/Output.zig`
  en `src/client/bars/`; `transport/` en `src/client/transport/`.
- Los valores que arrastraba `config` y eran del adaptador se dividieron:
  `SidebarRendering` y su resolución contra `Support` están en
  `src/client/config/sidebar_rendering.zig`; el tema, la paleta y las
  sobreescrituras en `src/client/appearance/`; la política de sonido en
  `src/client/config/SoundPolicy.zig`. Las sondas del terminal siguen en
  `src/frontend/graphics/capabilities.zig`.
- `input/GenericRouter.zig` del frontend no se movió: es la especialización
  TUI del genérico compartido con el decodificador del terminal.

## Paso 3, resultado

Ningún controller de `src/frontend/client/controllers` importa ya `sound`,
`notifications/host`, `links/host` ni `attachments/capture`, y sólo dos siguen
importando el decodificador del terminal, ambos por ser cableado TUI:

- Puertos nuevos en `telar-client`: `agents/SoundPort.zig`,
  `notifications/HostNotifier.zig`, `links/LinkOpener.zig`,
  `attachments/CapturePort.zig`, y `application/panes/Clipboard.zig` expuesto
  como `HostClipboard`. `Client` los lleva como campos y
  `resources/host_ports.zig` es la implementación terminal: OSC 9, OSC 52,
  workers de sonido, notificación del sistema, apertura de enlaces y captura
  de clipboard sobre `select`. Los controllers conservan la política (colas,
  coalescencia, canal de entrega) y llaman al puerto.
- `name_prompts.handleInput` recibe `Input`: tecla, inicio y fin de paste, o
  texto pegado. La decodificación de bytes reproducidos por el router vive en
  `key_routing.routePromptBytes`; `paste_routing` publica eventos. La regla
  "un salto de línea pegado es texto" pasó del decodificador al modelo:
  `NamePromptState` convierte CR, LF y CRLF pegados en un espacio. Antes CRLF
  producía dos espacios porque cada byte se convertía en Enter; ahora uno.
- `Mouse` de `telar-client` sustituye a `term.Event.Mouse` en
  `copy_mode_pointer`, `pointer_routing`, `link_openings` e `InputHandler`.
- Siguen en el adaptador, y así deben quedar: `host_capabilities.zig`
  (negociación de sondas del terminal; la parte compartida es
  `HostCapabilitiesHandler`), `key_routing.zig` (cableado de efectos con vista
  y Kitty), `resources/InputHandler.zig`, `resources/StartupInputState.zig` y
  `resources/Capture.zig`, que consumen respuestas del terminal.
  `resources/FormatRequest.zig` y `resources/telemetry.zig` importan `Pacer`
  para el snapshot de diagnóstico; se resolverán con el host en el paso 7.

## Paso 4, resultado

Los nueve controllers que sólo pedían `invalidatePlacements` llaman ahora a
`client.host_graphics.invalidatePlacements()`, un puerto `graphics/HostGraphics.zig`
de `telar-client` cuya implementación terminal vive en `resources/host_ports.zig`.
`client_startup` obtiene el soporte de memoria compartida de
`telar-client.supportsSharedMemory`, que ya existía; el alias de
`graphics/kitty.zig` sobraba.

Siguen importando `kitty_delivery` y quedan para el paso 7, porque son el
host TUI: `Client.zig` y `presentation/Resources.zig` (poseen el `Store`),
`entrypoints/events.zig` (completa compresiones), `resources/InputHandler.zig`
(respuestas Kitty del terminal) y `controllers/host/host_capabilities.zig`
(negociación de zlib).

## Paso 5, resultado

La rama `agent-mode` queda fuera por decisión de Adrián; las vistas se modelan
en `main` desde la dirección GUI. Corte: superficie por hoja, no hoja de vista
independiente.

- Wire y persistencia: `ClientLayoutNode.pane` es `ClientLayoutPane { id,
  surface }` y `PaneSurface` vive en `telar-core`. El esquema sube a la
  versión 44 con fingerprint `7a7380`; los goldens de `update_client_layout` y
  `client_layout_snapshot` cambian. El runtime guarda el nodo tal cual.
- Árbol: `Slot.surface`, `LayoutView.surface`, `WorkspaceLayout.surface` y
  `setSurface`, con test de revisión, wire y snapshot. `ClientLayoutBuilder`
  restaura la superficie; `restoreDisplayOrder` la pierde porque reconstruye el
  árbol sólo desde ids, igual que hoy pierde los ratios.
- Acción: `toggle_thread_view` sustituye a `toggle_agent_mode` en `prefix+a`,
  cableada a `TogglePaneSurfaceHandler` y `Model.togglePaneSurface`, que avanza
  la versión de panes. `Model.mode`, `PresentationMode`, la autoridad
  `agent_mode_active` y sus tests desaparecen.
- Proyección: `presentation/ThreadView.zig` con `capture(model, agents,
  pane_id)` y `Projection.threadView`. Lleva el agente del pane, si lo hay, y
  el borrador del composer, que `Pane` posee como slice acotado a 2048 bytes
  (`setComposer`, `composerSlice`). La lista de thread items queda fuera hasta
  que el runtime indexe transcripts; el pintado lo dice en pantalla.
- TUI: `workspace/thread_surface.zig` pinta cabecera, cuerpo y composer en la
  hoja; el compositor salta el copiado incremental de celdas para esas hojas,
  no coloca cursor en ellas, y se invalida cuando cambia la versión de agentes
  mientras haya alguna. `Presenter` pasa `agents` y su versión en
  `CompositionInput`.
- Descubierto de paso: `Client.init` construía el modelo de 2,2 MB en la pila
  y lo copiaba al heap. Ahora se construye en su sitio; un test del frontend
  desbordaba la pila con 64 KB más de modelo.

Pendiente, en este orden: edición del composer como modo de input y envío al
pane; indexado de transcripts en el runtime y `ThreadItem` en la proyección;
persistir el borrador en el runtime si debe sobrevivir al cliente.

## Paso 6, resultado

La auditoría del paso 1 leyó mal `Projection.geometry`. Verificado en código:

- `Region` es la rejilla de celdas del workbench para la pestaña activa, con
  revisión. La TUI la publica desde `Regions.workbench` en
  `presentation/State.zig`; una GUI la publicará desde su ventana y la métrica
  de su fuente. Ninguna otra pieza de la proyección describe el terminal host.
- El modelo reparte los panes dentro de esa rejilla (`WorkspaceLayout.snapshot`)
  y deriva columnas y filas por pane; `Geometry.capture` sólo copia identidad
  de coordenadas. Mover el reparto a "geometría por nodo" publicada por el
  adaptador duplicaría la aritmética del layout en TUI y GUI, así que no se
  hace.
- `Projection.host_size` son las métricas de la rejilla: columnas, filas y
  píxeles por celda. La GUI las tiene por su fuente; el runtime necesita los
  píxeles para el lease de geometría.

Se corrigen ADR 0014, el README de presentación, el flujo de presentación y
el comentario de `Region`. Quedan dos fugas reales, anotadas para cuando exista
la GUI: `sidebar_width` viaja en celdas por el wire y una GUI tendrá que mapear
su unidad, y `status_mode` viene de las hints de la barra TUI.

## Paso 7, contrato

Decidido el 2026-09-11. El cliente ya expresa sus efectos como puertos con
punteros a función (`Effects`, `Sink`, `Scheduler` y los puertos de los pasos
3 y 4); un `Host` comptime sería una segunda convención para lo mismo, y el
coste de una llamada indirecta no toca el invariante del path interactivo,
que es no asignar. Lo que debe quedarse en cada adaptador es el driver: quién
lee bytes, quién arma `select`, cómo llegan las completions.

- `telar-client/Client.zig` es el agregado compartido: modelo, transporte,
  ciclo de peticiones, configuración, plugins, telemetría semántica y todos los
  puertos. Los controllers viven en `telar-client/controllers/` y reciben
  `*Client`. La TUI compone ese agregado en `TerminalClient.zig` con `select`,
  `Screen`, `Presenter`, la vista, el decodificador y la entrega Kitty.
- Puertos por capacidad, cada uno de dos o tres funciones: presentación
  (pedir draw, pedir media), gráficos del host con la retención compartida
  separada de la entrega Kitty, temporizadores sobre `Scheduler`, y ejecutores
  de trabajo externo: comando de barra, worker de plugins, recarga de
  configuración y escritura de telemetría.
- El headless es el segundo driver; la GUI tendrá el suyo sobre el loop de
  ventana.
- Los usos de `view` desde controllers se clasifican uno a uno: lo semántico
  pasa al modelo, lo físico queda detrás de un puerto.

Orden: 7a gráficos, 7b `view`, 7c presentación y telemetría, 7d ejecutores y
temporizadores, 7e mover controllers y dividir el agregado.

## Paso 7, resultado

- 7a. `graphics/GraphicsRetention.zig` y `graphics/Credit.zig`: los controllers
  ven el store de gráficos por un puerto; cada adaptador instancia el
  `GenericResourceStore` con su estado de entrega. La entrega Kitty no se
  reescribió: separarla en tablas laterales tocaba 250 accesos del path de
  media sin gates de rendimiento que lo respalden, y el puerto cumple el
  objetivo, que es que el agregado compartido no conozca ese tipo.
- 7b. `presentation/HostChrome.zig`, `attachments/AttachmentCatalogPort.zig` y
  `attachments/AttachmentShelf.zig`. Los doce usos de `view` desde controllers
  eran todos físicos o de attachments; ninguno pasó al modelo.
- 7c. `presentation/HostPresentation.zig`: tamaño, pacing de input, cadencia
  y geometría entregada.
- 7d. `resources/HostTimers.zig` con `timers.Kind`, `bars/BarCommandRunner.zig`,
  `plugins/PluginWorkerRunner.zig`; los tipos de trabajo y completion viven en
  `telar-client`. La animación del sidebar usa el `Scheduler` compartido.
- 7e. `input/HostInputSource.zig`, `connection/TransportDriver.zig`,
  `resources/HostClock.zig`, `resources/ConfigReloadWatcher.zig`; la cola de
  sonido y `LocalTime` en `telar-client`; la adopción de configuración lleva
  `RouterConfig` y el adaptador compila su router. `src/client/AttachedClient.zig`
  es el agregado compartido y `src/frontend/client/TerminalClient.zig` lo
  embebe como `app`; `TerminalClient.of(client)` recupera el adaptador por
  `@fieldParentPtr`, así que los controllers y los puertos sólo reciben
  `*AttachedClient`. Se movieron 117 ficheros: `controllers/`, `entrypoints/`
  compartidos, `resources/` compartidos, `connection/request_lifecycle.zig`,
  `Options.zig` y `AppearanceThemes.zig`.

Se llama `AttachedClient` y no `Client` porque el entrypoint del paquete es
`client.zig` y el sistema de ficheros de macOS no distingue mayúsculas: el
primer intento sobrescribió el entrypoint y hubo que reconstruirlo desde git.

Quedan en el adaptador por diseño: `host_inputs`, `host_capabilities`,
`host_resizes`, `client_startup`, `events`, `runtime_io` sólo en su parte de
I/O (`TransportDriver`), telemetría de host e `InputHandler`. La GUI
implementa los mismos puertos que `resources/host_ports.zig` implementa para
la terminal; ese fichero es la lista completa del contrato.

## Paso 8, primer corte

`zig build gui` abre una ventana AppKit con `CAMetalLayer` y pinta "Telar".
Verificado en pantalla y con `test-gui`, `just check` y `zig build cross`.

- El contrato con el backend nativo es un buffer de quads en píxeles de
  dispositivo más una página alfa: `render/Quad.zig`, `macos/Frame.zig` y
  `macos/Viewport.zig` reflejan campo a campo las structs de
  `macos/window.m`. El backend no sabe nada de terminales ni de texto.
- `window.m` compila un pipeline Metal de quads instanciados con blending
  de alfa recta y sube la página alfa sólo cuando cambia su versión. Dibuja
  al mostrar la ventana, al redimensionar y al cambiar la escala de backing.
- `text/GlyphAtlas.zig` rasteriza glifos bajo demanda con FreeType, los
  empaqueta por estantes en una página de 1024 texels y convierte texto
  shaped por HarfBuzz en quads. Texel (0, 0) es blanco opaco para que un
  rectángulo sólido sea un quad más. Repite el shaping de
  `frontend/graphics/Rasterizer.zig`; compartir una cara entre adaptadores
  queda para cuando el GUI pinte la sidebar.
- Los binarios embebidos pasaron a `src/assets/` como módulo `assets`, para
  que el GUI embeba la fuente sin importar `telar-frontend`.

## Paso 8, segundo corte

`telar gui` es un subcomando del binario y comparte con `telar` la
preparación entera del cliente: `ClientLaunch` carga la generación Lua, el
registro de plugins y el almacén de confianza, y `frontendOptions` produce
el mismo `Options` para ambos adaptadores. `cli/client.zig` recibe el
adaptador como puntero a función; el TUI pasa `ClientRun` y el GUI
`telar-gui.run`. El runtime se conecta o arranca igual que con el TUI; el GUI
todavía no consume la conexión.

La ventana pinta con la paleta del tema resuelto y muestra ruta del config,
perfil, tema, iconos, prefijo y los recuentos de bindings, callbacks de barra
y plugins. `render/cell_colors.zig` traduce los colores de celda del cliente
a colores del shader; `default` cae al color que nombra el llamador, porque
la ventana es su propio host. Un solo `GlyphAtlas` sirve todos los tamaños,
con la caché por glifo y tamaño, para que un frame muestree una sola página.

Verificado en pantalla con `dev/config.lua`: el daemon del runtime arranca
con `cwd` en `/`, así que `--config` necesita una ruta absoluta.

## Paso 8, tercer corte: Linux

El mismo `telar gui` abre una ventana Wayland y pinta por Vulkan. El
contrato con el backend nativo no cambió: `native/telar_gui.h` es el único
punto que ambos backends implementan, y `linux/window.c` con
`linux/renderer.c` consumen el mismo buffer de quads y la misma página alfa
que `macos/window.m`.

- Ventana: `wl_compositor` y `xdg_wm_base`, un toplevel que pinta en cada
  `configure`. El código cliente de xdg-shell lo genera `wayland-scanner`
  durante el build a partir del protocolo instalado en el sistema.
- Renderer: instancia con la superficie Wayland, un dispositivo con una cola
  que dibuja y presenta, swapchain FIFO, un render pass, un pipeline con los
  quads en un storage buffer y el viewport como push constant, un frame en
  vuelo. La página alfa sube por staging sólo cuando cambia su versión.
- Shaders: GLSL en `src/gui/shaders`, compilados a SPIR-V con `glslc` y
  embebidos por `spirv.zig` como palabras `u32`, así que el build no
  necesita el compilador de shaders.
- Sin entrada todavía, igual que en macOS. La escala es 1 hasta que el
  backend lea `wl_output`.

Verificado con `tools/vm/vm.py gui-smoke`, que compila dentro de la máquina
QEMU de `tools/vm`, abre la ventana sobre sway con Vulkan por software y
captura la pantalla por QMP.

## Paso 8, empaquetado

Documentado en `docs/packaging.md`: `zig build bundle` y `zig build dmg` en
macOS, `zig build package-linux` en Linux, `telar gui --login-shell` como
camino único desde Finder y desde un menú de escritorio, y `telar cli
install` para el enlace en el `PATH`. Verificado abriendo el bundle con
`open` desde un entorno vacío: el proceso resultante lleva el `PATH` del
shell de login y `TELAR_LOGIN_SHELL=1`; y en la máquina Linux con
`vm.py gui-smoke`, que ahora lanza por `--login-shell` y comprueba la marca.

Siguiente corte: un pane de terminal desde celdas reales del runtime, con
`AttachedClient` y los puertos implementados sobre esta ventana.
