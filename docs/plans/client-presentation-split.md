# Separar el cliente semántico de la presentación

Plan aprobado para implementación en `refactor/client-presentation-split`.
Parte del checkout principal de Telar, no de `experiment/native-client`.
No incorpora Native SDK ni el fork de Ghostty.

## Seguimiento

- [x] 0. Referencia funcional y medición local registradas en
  [client-split-baseline](../performance/client-split-baseline/README.md).
- [x] 1. Valores y estado de panes. Validación y limitaciones en
  [client-split-step1](../performance/client-split-step1/README.md).
- [x] 2. Modelo y geometría de presentación. Validación y límites en
  `../performance/client-split-step2/README.md`.
- [x] 3. Aplicación, entrada y recursos comunes. Validación y límites en
  `../performance/client-split-step3/README.md`.
- [ ] 4. Gráficos y efectos del host.
- [ ] 5. Presentación intercambiable.
- [ ] 6. Dependencias y equivalencia.

## Resultado buscado

Un solo cliente semántico, con una implementación de presentación e integración
con el host que pueda sustituirse. La TUI actual será la primera implementación.
La segunda, durante este refactor, será un adaptador de prueba sin terminal ni
GPU. El renderer nativo vendrá después.

Compartimos el tipo de modelo y sus transiciones, no una instancia entre clientes.
Cada conexión conserva su navegación, foco, selección y sincronización. Con los
mismos eventos semánticos, geometría y resultados de efectos, dos instancias deben
producir los mismos cambios semánticos y peticiones al runtime.

No basta con abstraer `draw()`: la entrada, la geometría física y los servicios
del host también necesitan límites explícitos. Tampoco basta con mover archivos
mientras los handlers siguen conociendo `Screen`, `View` o `kitty.Store`.

## Evidencia en el código actual

| Archivo | Separación existente o acoplamiento que hay que resolver |
| --- | --- |
| `src/frontend/client/model/root.zig` | Ya concentra estado y transiciones, pero también contiene capacidades del terminal, geometría del host y detalles de presentación. |
| `src/frontend/client/application/` | Muchos handlers ya usan modelo y puertos de efectos acotados. Reutilizarlos, no sustituirlos por un reducer monolítico. |
| `src/frontend/client/client.zig` | Construye conjuntamente modelo, `Screen`, vista, lector TTY, transporte, workers y almacén Kitty. |
| `src/frontend/client/presentation/presentation_projection.zig` | Ya presta una proyección de lectura y separa recursos mutables de presentación. Su contrato todavía conoce tipos de widgets y capacidades del terminal. |
| `src/frontend/workspace/multiplexer.zig` | Conviven estado de panes, aplicación de daño, modelo de workspace y compositor de celdas. |
| `src/frontend/input/keybind.zig` | El tipo `Key` viene de `screen.Event`; el router también consume bytes mediante `term.parse`. |
| `src/frontend/input/host.zig` | Codifica entrada semántica para los modos del hijo, pero importa el tipo de tecla desde el renderer de terminal. |
| `src/frontend/graphics/kitty.zig` | Mezcla recepción y retención de gráficos del runtime con IDs externos, transmisión y confirmaciones del terminal anfitrión. |
| `src/frontend/client/presentation/presentation_lifecycle.zig` | Ya diferencia preparar salida, escribirla y confirmar la presentación. Hay que conservar esa distinción. |

La dirección continúa el [ADR de presentación por versiones][presentation-adr].
No reemplaza los [controllers y handlers existentes][handlers-adr].

## Dependencias objetivo

```text
telar-core
    ↑
telar-client                  src/client/root.zig
    ↑
telar-frontend                src/frontend/root.zig, TUI existente

Más adelante:
telar-client ← telar-native
```

`telar-client` no importa `telar-frontend`, un renderer ni APIs de ventana o TTY.
Puede depender de recursos comunes del cliente, como transporte y configuración;
no se pretende convertir todo el cliente en una función pura.

`telar-core` sigue compartiendo valores y operaciones entre runtime y cliente.
No recibe el modelo del cliente solo para facilitar el movimiento de archivos.
El nombre `telar-frontend` se conserva para la implementación TUI durante esta
extracción. No creamos todavía un paquete nativo vacío.

Dentro del cliente distinguimos:

- Modelo semántico y handlers de aplicación.
- Recursos operativos comunes: conexión, peticiones pendientes, buffers IPC,
  configuración y trabajo externo con sus presupuestos actuales.
- Contratos de entrada, geometría, efectos del host y presentación.

Cada capacidad mantiene un `root.zig` público. El ensamblaje conecta los puertos;
un handler no recibe el agregado que también posee el renderer.

## Reglas del contrato

### Entrada

```text
TTY bytes → terminal parser ─┐
                            ├→ semantic input → routing → handlers
Future OS events ───────────┘
```

Las teclas, el texto confirmado y los límites de paste son valores del cliente,
no tipos propiedad de `Screen`. Los eventos físicos de puntero se resuelven
contra la geometría publicada por la presentación antes de dirigirlos al destino.

El cliente común conserva bindings, modos de entrada, captura del gesto,
press/repeat/release, foco y codificación hacia el hijo según los modos publicados
por el runtime. Los escapes recibidos del host y sus respuestas a consultas
pertenecen exclusivamente al adaptador TUI. No confundimos esos escapes con los
que ambos clientes seguirán codificando para entregar entrada al PTY.

### Geometría

El árbol de splits, proporciones, orden y foco pertenecen al cliente común.
La presentación resuelve métricas físicas, bordes y espacio ocupado por widgets.
Devuelve una geometría acotada y versionada con los tamaños de pane necesarios
para los handlers. Ningún handler pregunta por `client.view.workbench()`.

La geometría usada para hit testing, navegación direccional y resize corresponde
a la misma revisión. Un gesto conserva su destinatario aunque cambie el foco.
La política de autoridad de geometría sigue perteneciendo al flujo existente;
un espectador no redimensiona el PTY por cambiar su ventana.

Las celdas del contenido de un pane siguen siendo celdas. No convertimos toda
la sidebar o los diálogos a una rejilla común obligatoria. La configuración y
los layouts persistidos mantienen su comportamiento TUI actual.

### Presentación

El cliente publica una proyección de lectura con revisiones, contenido de panes
y estado semántico de controles. No contiene `Screen`, escritores, widgets TUI,
texturas ni comandos GPU. La presentación tiene autoridad sobre sus cachés y
recursos, no sobre el modelo.

La proyección se presta solo durante la llamada síncrona. Si el adaptador
continúa trabajo después, retiene almacenamiento propio y acotado. No presta
punteros al modelo a un escritor o worker. La finalización identifica el trabajo
mediante IDs y revisiones; una finalización antigua no retira daño nuevo.

Se distinguen aplicar un frame recibido, preparar su presentación y completar
su entrega. Un intento ocupado, fallido o cancelado no confirma entrega. En la
TUI la finalización sigue ligada a la escritura completada, no a componer el
buffer. Esto no afirma que los píxeles hayan aparecido en el monitor.

Reutilizamos el commit y la política de acknowledgements existentes, eliminando
su dependencia del compositor TUI. El adaptador de prueba podrá demorar y fallar
la entrega para probar este contrato sin inventar una GPU.

La extracción no añade una cola de frames. Conserva la escritura en vuelo y la
presentación pendiente plegada del cliente actual. Nunca descarta bytes de un
diff parcialmente escrito ni deltas IPC necesarios para aplicar otro delta.
El pacing concreto queda fuera del modelo; la TUI mantiene su política actual.

### Gráficos y servicios del host

La recepción de gráficos, identidad, generaciones, validación y almacenamiento
retenido del cliente no deben duplicarse por renderer. Se separan de IDs Kitty
externos, transferencias al host, compresión de salida y placements físicos.
Los bytes siguen siendo recursos del cliente, no campos del modelo semántico.

Los créditos no se devuelven porque una función de dibujo haya terminado, sino
cuando la propiedad y liberación del almacenamiento lo permiten según el
protocolo. El renderer informa su consumo o liberación; el cliente aplica la
política común. Se preservan cuotas, cancelación, resync y liberación diferida.

Clipboard, notificaciones, apertura de enlaces, apariencia y título de ventana
usan puertos por capacidad. Reutilizamos los `Effects` ya existentes. No creamos
una interfaz gigante que exponga todo el host ni un bus de eventos genérico.

## Secuencia de implementación

### 0. Fijar la referencia

- Registrar el estado de trabajo actual, incluidos los cambios pendientes ajenos.
- Ejecutar los tests existentes y registrar cualquier fallo previo.
- Capturar una referencia de rendimiento con las herramientas del proyecto.
- Seleccionar recorridos de integración que preservaremos durante la migración.

Salida: referencia reproducible del estado real, no asumir que el checkout ya
está verde. No hacer stash, reset ni trasladar cambios al worktree experimental.

### 1. Extraer los valores y el estado de panes

- Crear el módulo `telar-client` y su target `test-client` en `build.zig`.
- Separar `Pane`, almacenamiento de celdas, daño, aplicación de frames y commits
  del compositor en `workspace/multiplexer.zig`.
- Separar `applyBuffer` del adaptador a `Screen` en `presentation/frame.zig`.
- Extraer los tipos de entrada semántica que hoy pertenecen a `screen.Event`.
- Mantener la TUI utilizando las implementaciones extraídas, sin copiarlas.

Salida: aplicar snapshots y patches, detectar una base inválida y conservar
modos del hijo sin importar ni construir `Screen`. Los tests del código movido
acompañan a su nuevo dueño.

### 2. Separar modelo y geometría de presentación

- Mover navegación, estado de workspaces/tabs, edición, selección, búsqueda,
  agentes y sus transiciones al módulo común.
- Separar el árbol de layout de sus métricas y cachés de composición.
- Sustituir accesos a `view.workbench()` por geometría de entrada explícita.
- Retirar probes, capacidades TTY y detalles visuales específicos del modelo.
- Separar valores de configuración comunes y ajustes TUI sin cambiar el formato
  Lua ni las opciones actuales del usuario.

Salida: construir el modelo completo sin terminal, fuentes ni servicios de
ventana. La TUI conserva splits, resize, navegación y configuración existentes.

### 3. Extraer aplicación, entrada y recursos comunes

- Mantener los handlers y sus puertos; eliminar dependencias del agregado TUI
  en los controllers y adaptadores que pasan a ser comunes.
- Separar el decoder de bytes del motor de bindings y routing semántico.
- Reutilizar la outbox, admisión, request lifecycle, recepción y recuperación.
- Separar la aplicación de su driver de eventos. La TUI sigue usando el driver
  actual; las pruebas pueden invocar los mismos entrypoints sin TTY.
- Adaptar configuración, plugins, timers y resultados de workers mediante sus
  capacidades y presupuestos existentes, no mediante acceso al renderer.

Salida: ejecutar flujos de sesión, input y gestión de panes con un transporte
sustituido y efectos capturados, sin inicializar la presentación terminal.

### 4. Extraer gráficos y efectos específicos del host

- Dividir `kitty.Store` en recepción/retención común y entrega específica TUI.
- Separar estado semántico de attachments de previews y placements físicos.
- Conectar clipboard, enlaces, notificaciones, sonido y apariencia mediante
  puertos estrechos. Las implementaciones actuales siguen atendiendo la TUI.
- Verificar fallo parcial de inicialización, teardown, generación retirada y
  desconexión con recursos o workers en vuelo.

Salida: ningún flujo común de gráficos o attachments necesita construir un
almacén de salida Kitty. No se pierde funcionalidad TUI para simplificar el corte.

### 5. Hacer intercambiable la presentación

- Extraer del `Presenter` el contrato de proyección, versiones y finalización.
- Mantener `View`, widgets, `Screen`, diff, output, pacing y KGP anfitrión en TUI.
- Conectar la TUI mediante ese contrato, conservando la confirmación tras write.
- Añadir un adaptador de prueba que captura proyecciones y controla completions.
- Unir las piezas en el entrypoint actual sin cambiar CLI ni protocolo IPC.

Salida: el mismo cliente funciona con TUI o con el adaptador de prueba. Cambia el
ensamblaje de entrada, host y presentación, no una segunda copia de los casos de uso.

### 6. Cerrar dependencias y verificar equivalencia

- Los tests comunes importan únicamente `telar-client` y sus dependencias
  permitidas, sin enlace a FreeType, AppKit ni construcción de recursos TTY.
- Eliminar accesos a archivos internos y aliases transitorios que oculten
  dependencias inversas. Revisar el grafo de módulos de `build.zig`.
- Actualizar documentación de paquetes, flujos y términos que efectivamente
  cambien. Registrar la decisión aceptada sin presentar este plan como un ADR.
- Ejecutar los gates funcionales y de rendimiento sobre la TUI resultante.

Salida: dependencia unidireccional comprobada por compilación y recorridos de
cliente comprobados sin renderer terminal. No basta con una interfaz vacía.

Las fases se integran por recorridos completos y revisables. En cada recorrido,
la TUI deja de usar la implementación anterior cuando adopta la extraída. No
mantenemos una copia antigua y otra nueva hasta el final.

## Pruebas de aceptación

- Mismos mensajes, acciones, geometría y resultados de efectos producen el mismo
  estado semántico y peticiones. No comparamos píxeles entre renderers.
- Las pruebas de entrada comparan eventos equivalentes después del decoder. La
  TUI conserva además pruebas de escapes partidos, paste y timeouts.
- Snapshot, patch, base inválida, pane retirado, resync y reconexión mantienen
  admisión y recuperación actuales.
- Entrega demorada, escritura parcial, fallo, cancelación y completion obsoleta
  no generan ACK anticipado ni borran daño de un frame posterior.
- Foco antes de input, captura del gesto y releases tras cambio de foco siguen
  funcionando. Geometrías distintas no se confunden con diferencias semánticas.
- Gráficos y attachments conservan cuotas, créditos, clipping, cancelación y
  liberación con referencias en vuelo.
- Búsqueda, rename, barras, Lua, plugins, enlaces, clipboard, sonido y
  notificaciones conservan sus recorridos y errores esperados.
- Cerrar o matar el cliente deja vivo el hijo del runtime; reconectar recupera
  su estado. Un cliente lento no bloquea otro cliente ni los PTYs.
- Sin trabajo visual pendiente no aparece polling o repaint periódico nuevo.

Reutilizar `test-frontend`, `test-schema`, `test-transport`, los tests de
isolation y las herramientas de `tools/`, además del nuevo `test-client`.
Las mediciones se comparan en el mismo host, target, modo, geometría y carga,
siguiendo [los gates existentes][performance]. Incluir p50/p95/p99, asignaciones,
bytes IPC, memoria retenida, profundidad de colas y trabajo descartado. Una
referencia ruidosa produce `no verdict`, no una afirmación de ausencia de regresión.

## Fuera de este refactor

- Metal, Vulkan, OpenGL, ventana nativa o `telar app`.
- Cambios en propiedad de PTYs, emulación VT o mensajes del runtime.
- Rediseñar la interfaz o añadir funciones exclusivas de GUI.
- Cambiar a la vez `std.Io.Select`, el pool de workers o el modelo de ejecución.
- Crear un framework de widgets multiplataforma o una display list universal.

El [plan del modelo de ejecución][execution] queda separado. Esta extracción
permite cambiar el driver más adelante sin convertir esa reescritura en un
requisito previo para reutilizar la semántica del cliente.

[presentation-adr]: ../adr/0007-drive-client-presentation-from-model-versions.md
[handlers-adr]: ../adr/0006-separate-request-controllers-from-command-handlers.md
[performance]: ../performance-gates.md
[execution]: frontend-execution-model.md
