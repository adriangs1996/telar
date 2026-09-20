# Compatibilidad de Telar GUI con OSC y Kitty Graphics Protocol

Auditoría del 19 de septiembre de 2026. Telar GUI todavía no dibuja las imágenes
KGP de los procesos. El runtime tiene una implementación considerable, pero el
adaptador GUI declara las imágenes como no soportadas y conserva recursos sin
un consumidor GPU. En OSC, varias operaciones actualizan el VT pero no llegan
al sistema operativo o al renderizador.

Referencias de la comparación:

- Telar, HEAD `a81a49f22d946d17b766e94d252e4dc683fa9135`, más el árbol de trabajo
  observado durante la auditoría. Había cambios concurrentes ajenos a ella.
- Dependencia de Telar, Ghostty `a4edca2a90d6cf89900bb058e71cb6860cec78c5`, fijada
  en [build.zig.zon](../build.zig.zon).
- Objetivo, Ghostty `main` en
  [`b32f20f3e8d25bb925ec545c54498e93518e7ced`](https://github.com/ghostty-org/ghostty/commit/b32f20f3e8d25bb925ec545c54498e93518e7ced),
  commit del 18 de septiembre. Esta referencia incluye funciones que no estaban
  en la revisión fijada por Telar. No equivale a prometer que estén en una
  versión estable publicada.

El inventario procede de seguir parser, estado, IPC, consumidor y renderizado,
y de comparar ambas revisiones de Ghostty. Una secuencia reconocida por el
parser no cuenta como una función implementada. Las diferencias de código
identificadas son verificables; la lista no sustituye una suite diferencial de
conformidad ni una comparación visual de ambas aplicaciones.

## OSC: carencias confirmadas

| ID | Operación | Qué falta | Evidencia de Telar |
| --- | --- | --- | --- |
| O1 | `OSC 0/2`, título | Llevar el título del panel enfocado al título de la ventana nativa y actualizarlo al cambiar de foco. El runtime y el modelo ya lo conservan, y está disponible para las barras configurables. Las ventanas nativas reciben el título al crearse. | [TitleState](../src/backend/pane/TitleState.zig), [Model.focusedPaneTitle](../src/client/model/Model.zig), [macOS](../src/gui/macos/window.m), [Wayland](../src/gui/linux/window.c). |
| O2 | `OSC 12/112` y `OSC 21;cursor=...` | Aplicar y restablecer el color del cursor por panel. El VT lo modifica, pero el esquema del cursor no transporta color y la GUI usa el del tema. También falta comunicar el cursor del tema al runtime para que las consultas describan el color configurado. | [Cursor](../src/core/schema/Cursor.zig), [TerminalColors](../src/core/schema/TerminalColors.zig), [TerminalRenderer](../src/gui/render/TerminalRenderer.zig), [Pane.setTerminalColors](../src/backend/pane/Pane.zig). |
| O3 | Escritura y borrado `OSC 52`; `OSC 1337;Copy=:` | Conectar las solicitudes del proceso con el portapapeles nativo, incluyendo vaciado y selección de destino cuando la plataforma lo permita. Copiar una selección de Telar ya funciona, pero es otra entrada: `clipboard_write` no está conectado en el handler del panel. | [Pane.create](../src/backend/pane/Pane.zig), [PaneClipboardHandler](../src/client/application/panes/PaneClipboardHandler.zig), [Services](../src/gui/host/Services.zig). |
| O4 | Lectura `OSC 52;...;?` | Resolver la consulta, aplicar una política de acceso y devolver la respuesta al PTY solicitante. El `TerminalStream` fijado descarta las lecturas deliberadamente; conectar el callback de escritura no lo resuelve. El pegado nativo existente parte de una acción del usuario, no de esta secuencia. | Handler de la dependencia en `src/terminal/stream_terminal.zig`, [TerminalClipboard](../src/gui/host/TerminalClipboard.zig). |
| O5 | Notificaciones `OSC 9` y `OSC 777;notify` | Conectar `desktop_notification` y entregar la notificación al escritorio, conservando el panel de origen. Además del callback ausente en el runtime, la función GUI `deliverNotification` está vacía. | [Pane.create](../src/backend/pane/Pane.zig), [host_ports](../src/gui/host_ports.zig). |
| O6 | CWD `OSC 7` y alias `OSC 1337;CurrentDir` | Unificar la observación del CWD con el estado del VT. El observador auxiliar solo reconoce los códigos `7` y `133`, por lo que no propaga el alias `CurrentDir`. También faltan el reset con valor vacío, tratar `kitty-shell-cwd://` como ruta sin percent-decoding y validar el host para no convertir una ruta remota en una ruta local. | [OscTracker.finish/cwdReport](../src/backend/history/OscTracker.zig), [CwdState](../src/backend/pane/CwdState.zig), [Pane.updateObservedCwd](../src/backend/pane/Pane.zig). |
| O7 | `OSC 5522`, Kitty Clipboard Protocol | Incorporar el handler que Ghostty añadió después de nuestra revisión: lectura, escritura por transacciones, representaciones MIME, alias, respuestas y autorización. El parser fijado conoce el comando, pero su stream lo deja sin implementar. Los puertos actuales de Telar para copiar texto no cubren esta función. | `src/terminal/stream.zig` de la dependencia fijada; [Services](../src/gui/host/Services.zig), [PaneClipboardHandler](../src/client/application/panes/PaneClipboardHandler.zig). |

Ghostty ejecuta las operaciones externas de OSC en
[su handler de aplicación](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/termio/stream_handler.zig).
Su biblioteca VT expone menos efectos que esa aplicación. Para CWD, la
[documentación de OSC 7](https://ghostty.org/docs/vt/osc/7) y `reportPwd` permiten
contrastar la semántica. En `CurrentDir`, la comparación se refiere a valores
que Ghostty acepta en `reportPwd`; no presupone soporte de cualquier ruta literal
de iTerm2.

## KGP: carencias confirmadas

| ID | Operación o comportamiento | Qué falta | Evidencia |
| --- | --- | --- | --- |
| G1 | Imágenes de procesos en la GUI | Crear y actualizar texturas desde los recursos KGP recibidos y componerlas en Metal y Vulkan. Incluye RGB, RGBA y el PNG ya decodificado por el runtime. | [graphics_delivery](../src/gui/graphics_delivery.zig) es un adaptador sin consumidor GPU; [GuiClient.start/resize](../src/gui/GuiClient.zig) asigna `images = .unsupported`. |
| G2 | Presentación de placements | Dibujar recortes de origen, tamaño natural o en celdas, offsets y transparencia. Respetar las tres capas respecto al fondo y al texto, además del orden entre imágenes. Recortar siempre al panel y mantener el chrome y los modales fuera del alcance de sus imágenes. | Telar ya transporta esos datos en [media.placementValue](../src/backend/media/media.zig), pero G1 impide consumirlos. Ghostty los compone en [renderer/image.zig](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/renderer/image.zig). |
| G3 | Ciclo de vida GPU | Vincular retención, reemplazo y destrucción de texturas a la finalización del frame GPU. Reconstruir lo visible tras scroll, resize, cambio de fuente, pestaña y reconexión; respetar generaciones y devolver créditos cuando termine el último consumidor. Hay infraestructura compartida reutilizable, pero falta su consumidor nativo. | [graphics_delivery.canRelease](../src/gui/graphics_delivery.zig), [GuiClient.noMedia](../src/gui/GuiClient.zig), [contrato de presentación](../src/client/presentation/README.md). |
| G4 | Unicode placeholders, `U=1` | Resolver las referencias codificadas en las celdas y sus diacríticos, convertirlas en fragmentos visibles de imagen y preservar su relación con texto, scroll y borrado. Actualmente `placementValue` devuelve `null` para `.virtual`; esos placements no llegan al cliente. | [media.placementValue](../src/backend/media/media.zig). Ghostty dispone de tratamiento de placeholders en [renderer/image.zig](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/renderer/image.zig). |
| G5 | Transporte general por archivo, `t=f` | Admitir comandos ordinarios de transmisión y display, PNG, compresión y lectura con offset/tamaño. El soporte actual es una excepción para consultas y un patrón concreto de frame completo RGB/RGBA, `a=T`, `C=1`, `q=2`, con envoltura sincronizada. El resto cae en un emulador con `.file = false`. | [image_loading_limits, parseSharedFrameControl, sharedFrameAt](../src/backend/media/media.zig), [Processor](../src/backend/media/Processor.zig). |
| G6 | Archivos temporales, `t=t` | Añadir la carga validada y la eliminación del temporal conforme al protocolo. Hoy está deshabilitada. Esto no requiere permitir rutas arbitrarias: deben conservarse las validaciones de propietario, tipo, límites y ciclo de vida. | [image_loading_limits](../src/backend/media/media.zig). Ghostty habilita archivos y temporales al crear su terminal en `src/termio/Termio.zig` y los valida en [graphics_image.zig](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/terminal/kitty/graphics_image.zig). |
| G7 | Placements relativos, `P/Q/H/V` | Incorporar relaciones padre/hijo y proyectar su posición y su eliminación en cascada. El código fijado por Telar acepta campos de parentesco pero crea un pin en el cursor para el placement no virtual; no resuelve al padre. El nuevo Ghostty sí lo hace. | Dependencia fijada, `src/terminal/kitty/graphics_exec.zig`; [implementación actual](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/terminal/kitty/graphics_exec.zig). |
| G8 | Animaciones, `a=f`, `a=a`, `a=c`, `d=f/F` | Añadir carga y edición de frames, composición, control de reproducción, tiempos, bucles y borrado. La dependencia fijada responde `ERROR: unimplemented action` para las tres acciones. La revisión actual las ejecuta. Telar necesita además avanzar la animación desde el runtime y publicar cambios de generación aunque no lleguen más bytes del proceso. | [graphics_exec actual](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/terminal/kitty/graphics_exec.zig), [reloj de Ghostty](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/renderer/generic.zig). |
| G9 | Scroll con márgenes | Incorporar la semántica añadida por Ghostty para imágenes dentro, fuera o cruzando una región de scroll: movimiento, recorte proporcional y eliminación. La dependencia fijada carece de `scrollMarginsBegin/end`. | [graphics_storage actual](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/terminal/kitty/graphics_storage.zig). |
| G10 | IDs automáticos y números `I=` | Incorporar la asignación que evita colisiones con imágenes explícitas y elige el menor ID libre para solicitudes por número. La revisión fijada incrementa `next_image_id` sin comprobar colisiones. | `loadAndAddImage` fijado frente a `nextImageId` en [graphics_storage actual](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/terminal/kitty/graphics_storage.zig). |
| G11 | Tolerancia y respuestas de comandos | Adoptar los cambios actuales: `f=0` como RGBA; `q>2` silencioso; `C!=1` permite movimiento; `U!=0` virtual; formato desconocido respondido con `EINVAL` e identidad, en lugar de perderse durante el parseo; rango de borrado invertido tratado como vacío. | Comparación de [graphics_command](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/terminal/kitty/graphics_command.zig) y sus pruebas con el archivo fijado. |
| G12 | Placements después de reset | Incorporar la corrección que limpia `cursor_pin.garbage` tras `Screen.reset`. Sin ella, los nuevos placements copian un pin inválido; Telar además los filtra al proyectarlos. | [Screen.reset actual](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/terminal/Screen.zig), [media.placementValue](../src/backend/media/media.zig). |

G7 a G12 son diferencias con el `main` consultado, no razones para reimplementar
Ghostty dentro de Telar. Conviene actualizar o incorporar los cambios pertinentes
de la dependencia y adaptar nuestra extracción de estado. Actualizarla por sí
sola no resuelve G1 a G6 ni el reloj de G8.

La memoria compartida entre runtime y GUI está desactivada en el bootstrap.
Activarla puede reducir copias, pero no es una carencia de protocolo por sí
misma: `t=s` del proceso al runtime ya existe y el transporte IPC por chunks
puede alimentar un renderizador nativo.

## Funciones relacionadas que requieren una decisión de paridad

| Área | Diferencia y alcance |
| --- | --- |
| `OSC 133`, experiencia de shell | El VT y el historial de Telar ya reciben marcas. Para igualar la experiencia de Ghostty falta exponer navegación entre prompts en el terminal y notificación configurable de finalización de comandos de shell. Son consumidores de marcas existentes, no una ausencia total del protocolo. Ghostty implementa `jump_to_prompt` y procesa `start_command/stop_command` en `src/Surface.zig`; Telar no transporta marcas de prompt en [RowFlags](../src/core/text_metadata/RowFlags.zig). |
| Formato de consultas de color | Ghostty permite respuestas de 8 bits, 16 bits o desactivadas. El handler VT que usa Telar responde en 16 bits. La modalidad habitual existe; falta la configuración equivalente si el objetivo también incluye estas opciones de Ghostty. |
| Anuncio de capacidades | El handler de Telar no conecta `device_attributes`. Al añadir portapapeles debe anunciar su soporte de forma coherente. Para KGP hay que comprobar explícitamente la relación entre consultas respondidas por el runtime y capacidad de cada cliente para mostrar el resultado. Es trabajo de negociación asociado, aunque DA no sea OSC. |

Las opciones de color están documentadas en
[la referencia de Ghostty](https://ghostty.org/docs/config/reference#osc-color-report-format).
La arquitectura de Telar exige que efectos del escritorio, foco y permisos
pertenezcan al cliente; estado de imágenes y reproducción pertenecen al runtime.

## Lo que ya existe y no debe duplicarse

| Área | Base reutilizable comprobada en código |
| --- | --- |
| OSC | Títulos retenidos y publicados; enlaces OSC 8 con interacción nativa; progreso OSC 9;4; formas de puntero OSC 22; paleta OSC 4/104 y foreground/background OSC 10/11/110/111; la parte equivalente de OSC 21; marcas de shell OSC 133 y CWD OSC 7 con las diferencias descritas. |
| KGP en runtime | RGB/RGBA/PNG; transmisión directa y chunks; zlib; memoria compartida; consultas; transmitir, mostrar y borrar imágenes y placements ordinarios; geometría y generaciones; cuotas, respuestas PTY, snapshots y créditos. |
| GUI | Texturas y quads para otros recursos de interfaz, servicios de portapapeles, retención de celdas y finalización de frames. Deben reutilizarse donde sus contratos encajen. No significan que las imágenes KGP ya se dibujen. |

Referencias locales: [documentación KGP](kitty-graphics.md),
[pruebas de enlaces](../src/gui/tests/links.zig),
[progreso nativo](../src/gui/widgets/PaneProgress.zig),
[pruebas del panel](../src/backend/pane/pane_namespace.zig),
[blit de colores](../src/backend/pane/blit.zig).

## Fuera de la lista de carencias frente a Ghostty

No incluir como funciones que Ghostty ya ofrece: OSC 1, los comandos ConEmu
distintos de `9;4`, OSC 66, OSC 99, OSC 3008 y el protocolo DnD OSC 72. En la
revisión consultada se parsean, pero el stream o el handler de aplicación los
deja sin ejecutar. Tampoco cuenta el protocolo de imágenes iTerm2 `OSC 1337;File`.
Los colores especiales OSC 5/105 y los colores dinámicos de puntero, Tektronix
y selección no tienen la implementación equivalente a foreground/background/cursor.

Esto se comprueba en el
[dispatch OSC](https://github.com/ghostty-org/ghostty/blob/b32f20f3e8d25bb925ec545c54498e93518e7ced/src/terminal/stream.zig)
y en el handler de aplicación. El soporte de parser, por sí solo, daría un
inventario engañoso.

## Verificación y orden de trabajo

Se ejecutó `zig build test-gui test-png --summary all`: 49 pasos correctos,
692 pruebas GUI y 40 pruebas PNG aprobadas. No se ejecutó una comparación
visual nueva contra Ghostty ni pruebas nativas en Linux para esta auditoría.
Los resultados cubren el árbol que compiló el comando; había ediciones
concurrentes. No se modificó código de aplicación.

Para cerrar la paridad falta una suite diferencial con la misma entrada PTY,
geometría y configuración en ambas aplicaciones. Debe verificar respuestas y
estado, además del resultado visual en macOS y Linux. Los casos esenciales son
placeholders y relaciones padre/hijo, capas, scroll con márgenes, reset,
animaciones sin nueva salida PTY, reemplazos durante un frame GPU, reconexión y
dos clientes con distintas capacidades. Las pruebas de transporte existentes
no demuestran por sí mismas que la GUI dibuje correctamente.

Mi orden propuesto es resolver G1 a G3 y O2 a O5 primero; actualizar después la
dependencia con pruebas de las diferencias G7 a G12 y O7; completar placeholders
y archivos; y cerrar CWD, título nativo y los consumidores de marcas de shell.
El criterio de cierre debe ser observable: la aplicación recibe la misma
respuesta útil y el usuario ve el mismo contenido, dentro del panel correcto.
