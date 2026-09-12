# Modelo de ejecución del frontend

Propuesta para discutir, no una descripción de `exper.zig` ni una decisión de
migración. El runtime se representa por sus límites de entrada, autoridad y
entrega; este documento no propone rehacer su ejecución interna.

[Ver el diagrama SVG](frontend-execution-model.svg).

## El modelo que estamos describiendo

El cliente recibe mensajes de productores independientes. Un único consumidor
los clasifica y delega su aplicación sobre el modelo del cliente. Una petición
al runtime se admite en una outbox local; no ejecuta una escritura IPC dentro
del handler. Un consumidor de esa outbox envía los mensajes por IPC.

En paralelo, otro productor recibe IPC, valida y traduce los mensajes del
runtime, y publica `ClientMessage` en la inbox del cliente. El runtime puede
publicar cambios sin que exista una petición previa del cliente. No hay un
turno global de petición y respuesta.

La misma separación existe en la entrega del runtime a cada cliente: la
aplicación decide qué publicar y el transporte escribe los bytes preparados.
No se prestan referencias al modelo vivo al escritor.

Aquí, «backend» significa el proceso runtime de telar. El `Runtime` de Native
SDK es el host de una aplicación gráfica, no el equivalente al proceso que
mantiene vivos los PTYs de telar. «Outbox» designa almacenamiento local de
transporte, no una outbox transaccional persistente.

## Estudio de Native SDK

Se revisó el código de [vercel-labs/native][native] en el commit
`31663e16b054f212f0377878eb901330bbc94b53`. Las referencias siguientes fijan esa
revisión; no dependen de que `main` conserve el mismo comportamiento.

El estudio cubre el contrato de aplicación, la entrada de mensajes, los efectos,
los canales para productores externos, los límites de drenaje, la propiedad de
payloads, los temporizadores y las pruebas de cierre, saturación y wakeups. Es
una inspección de fuentes y tests, no una ejecución de la suite de Native ni
una medición de rendimiento.

### 1. Una transición serializada y una vista derivada

`UiApp(Model, Msg)` admite dos interfaces Zig:

```zig
update(model: *Model, msg: Msg) void
update_fx(model: *Model, msg: Msg, fx: *Effects) void
```

Son alternativas de configuración, no dos pasos consecutivos. `applyMsg` llama
a la que se haya configurado. `dispatch` sincroniza estado de widgets, aplica
el mensaje y reconstruye las vistas instaladas.

La correspondencia con telar es la propiedad exclusiva del modelo durante la
transición. No exige poner todos los casos de uso en un `switch` gigante ni
hacer inmutables las estructuras Zig. En telar, el dispatcher debe seguir
delegando a controllers y handlers; no sustituye sus límites de autoridad.

Fuentes: [contrato de aplicación][app-model], [opciones Zig][options],
[`dispatch` y `applyMsg`][dispatch].

### 2. Efectos separados de sus resultados

En Zig, `update_fx` solicita operaciones mediante `Effects(Msg)`. Los workers
de subprocessos, HTTP y archivos publican completions; no reciben el modelo.
El hilo del bucle convierte sus resultados a `Msg` y aplica la transición.

En TypeScript la separación es más declarativa: `update` devuelve el nuevo
modelo y un `Cmd`. `TsCoreHost.dispatchDepth` confirma el modelo y después
`finishCycle` interpreta comandos y reconcilia subscriptions.

No son dos implementaciones idénticas de un reducer puro. La interfaz Zig
permite llamar a la fachada de efectos durante `update_fx`. Tampoco todos los
efectos de Native son workers: algunas operaciones de plataforma, como el
clipboard, se ejecutan en el hilo del bucle. Por tanto, Native no demuestra la
afirmación de que toda operación solicitada a una fachada sea no bloqueante.

Fuentes: [contrato de Effects][effects], [Cmd y resultados][typescript],
[commit, comandos y subscriptions][ts-cycle].

### 3. El equivalente más directo del productor IPC es un channel

`Effects.openChannel` entrega un `ChannelHandle`. Un socket, watcher o worker
externo puede llamar `handle.post(bytes)` desde otro hilo. El canal copia los
bytes aceptados a su almacenamiento acotado y despierta el host. El productor
no llama a `update`.

`post` distingue `accepted`, `dropped_full`, `dropped_oversized` y `closed`.
Los rechazos por capacidad y tamaño tienen contadores. Un handle lleva
generación; cerrar y reutilizar un slot no autoriza al productor antiguo a
publicar en la nueva ocupación.

Esa interfaz es una referencia para el contrato de nuestros productores. Su
política de descartar una publicación que no cabe no es apropiada para todos
los mensajes de telar: no se pueden perder silenciosamente comandos, entrada
o deltas necesarios para interpretar los siguientes.

Fuentes: [`ChannelHandle` y `post`][channel],
[tests de orden, saturación y generaciones][channel-tests].

### 4. Publicar datos y despertar el bucle son operaciones distintas

Los workers de Effects tienen una cola MPSC acotada, con exclusión mutua. Los
canales externos tienen staging por canal. Los wakes de un canal se fusionan:
una ráfaga aceptada no exige una notificación del host por cada mensaje.

`flow.zig` traduce el wake de plataforma a `.effects_wake`.
`UiApp.drainEffects` toma una `DrainBoundary`, aplica solo las completions que
pertenecen a esa pasada y reconstruye las vistas después del lote. Los
resultados nacidos durante la pasada quedan para la siguiente. Esto preserva
la causalidad de su journal; no constituye por sí solo un presupuesto temporal.

Importa distinguir dos fusiones: Native fusiona wakes, pero no por eso borra
los mensajes aceptados del canal. Reducir notificaciones y descartar estados
obsoletos son políticas diferentes.

No hay una única cola global por la que Native obligue a pasar todo evento:
la entrada de UI puede llamar a `dispatch` desde el propio bucle, y los
resultados externos llegan por el drenaje de efectos. La inbox unificada del
experimento es una elección de telar, no una reproducción literal de Native.

Fuentes: [cola de completions][completion-queue],
[wake de plataforma][wake], [`drainEffects`][dispatch],
[`DrainBoundary`][drain-boundary], [tests de coalescing y carreras][wake-tests].

### 5. Las fuentes tienen lifecycle y memoria propios

Los payloads drenados de Effects pueden apuntar a scratch reutilizado en la
siguiente extracción. `update` debe copiar lo que retiene. En los canales,
`post` copia los bytes aceptados y la generación controla si el handle sigue
vigente. Estos son contratos concretos de memoria, no consecuencias automáticas
de usar mensajes.

Los temporizadores Zig de Effects usan servicios de plataforma, sin un worker
por temporizador. Las subscriptions TypeScript describen temporizadores activos
en función del modelo y se reconcilian después del commit. Un stream abierto
por un comando tiene un lifecycle explícito diferente al de una subscription.

Para telar, una recepción IPC necesita un buffer cuya vida llegue hasta el
consumo del mensaje, o una copia acotada. Un slice al buffer que el receptor
reescribe en la próxima lectura rompería el aislamiento aunque el modelo solo
tenga un escritor.

Fuentes: [payload lifetime][effects], [handles][channel],
[temporizadores Zig][timers], [subscriptions][typescript].

## Traducción a telar

| Native SDK | Propuesta para telar | Diferencia que se conserva |
| --- | --- | --- |
| `UiApp.dispatch` / `applyMsg` | `ClientLoop` clasifica y delega la transición | Los handlers conservan los límites de aplicación de telar |
| `Msg` | `ClientMessage` local | No es automáticamente el schema IPC |
| `Effects` / `Cmd` | Fachada de efectos con admisión en outbox | Admitir no significa enviar ni ejecutar |
| Worker o `ChannelHandle.post` | Productor de input, temporizador o recepción IPC | Sin acceso al modelo; payload con vida explícita |
| Completion staging + wake | Inbox acotada y despertar del consumidor | La estructura física y la equidad aún no se fijan |
| Drenaje por pasada | Lote de mensajes con límite de trabajo | Requiere presupuesto temporal además del límite de elementos |
| Vista derivada | Composición y diff bajo el dueño del modelo | La escritura al terminal se ejecuta aparte |
| Host de aplicación Native | Cliente conectado a runtime independiente | La supervivencia de PTYs y agentes es una propiedad de telar |

La outbox cliente → runtime pertenece al **cliente**, aunque contenga comandos
que solo el runtime puede ejecutar. La entrega runtime → cliente pertenece a
la sesión de ese cliente en el runtime. No hay una cola de memoria que cruce
el límite de proceso.

En el SVG, `Runtime ingress` es un punto de entrada conceptual al runtime
existente, no una propuesta de convertir su ejecución interna en otro
`ClientLoop`. `Client delivery` conserva el significado del glosario de telar:
respuestas pendientes más proyecciones actuales, no una cola de todos los
frames históricos. Cada escritor consume únicamente frames preparados para
su conexión.

## Un recorrido sin RPC síncrono

1. `InputProducer` recibe input y publica un mensaje local.
2. `ClientLoop` lo clasifica; el handler aplica el cambio local necesario y
   admite una petición en la outbox, o recibe un rechazo explícito de admisión.
3. El consumidor TX envía los frames admitidos en orden. Puede esperar al
   socket sin ocupar `ClientLoop`; el receptor RX sigue siendo independiente.
4. El runtime recibe el comando y lo despacha a su aplicación. Una escritura
   completada en el cliente no prueba que este paso haya terminado.
5. El runtime publica una respuesta o cambio cuando corresponda. También puede
   publicar por output de PTYs o cambios de agentes, sin una petición anterior.
6. La entrega por cliente prepara el siguiente frame; TX lo escribe por IPC.
7. `IpcReceiver` del cliente valida y traduce el frame, publica un mensaje y
   devuelve el control. `ClientLoop` aplica la proyección recibida en su turno.
8. Si cambió lo visible, el cliente solicita presentación. El vencimiento
   regresa por la misma inbox; la composición lee el modelo desde `ClientLoop`
   y entrega bytes estables al escritor del terminal.

`sent`, `failed` y `disconnected` son eventos de transporte, no confirmaciones
de negocio. Si una operación exige correlación, el protocolo debe usar un
request ID y una respuesta explícita. No se deduce entrega exactamente una vez
ni orden global entre productores o entre las dos direcciones IPC.

## Condiciones para que el aislamiento funcione

- **Admisión sin espera en los bucles dueños del estado.** Si la outbox está
  llena, el handler recibe un resultado explícito. Sustituir una escritura
  bloqueante por un `putOne` bloqueante sobre una cola llena solo mueve la
  espera. La política exacta por comando queda pendiente.
- **Aislamiento por conexión.** Una escritura lenta retiene únicamente el frame
  y la tarea de esa conexión. El runtime no espera a que ese cliente consuma;
  pliega estado visual o fuerza resincronización según el protocolo.
- **Presupuestos separados.** La inbox del dibujo es una frontera lógica de
  despacho. Media y observación mantienen sus propias colas y workers; al
  dispatcher llegan resultados acotados, no trabajo pesado por ejecutar.
- **Propiedad de bytes.** El mensaje retiene almacenamiento propio o una cesión
  explícita hasta su consumo. El escritor no accede al modelo vivo. Un buffer
  en vuelo no se modifica, recicla ni libera hasta completar o cancelar I/O.
- **Órdenes locales explícitos.** Un escritor por dirección y conexión mantiene
  el orden de frames admitidos. Respuestas y patches respetan sus dependencias;
  no se descarta un delta arbitrario conservando otro que dependa de él.
- **Cierre supervisado.** Fallos, EOF y cancelaciones se comunican al dueño.
  Durante teardown se revoca admisión, se cancelan y esperan las tareas que
  usan recursos, y solo después se liberan colas, buffers y conexiones.
- **Estado vivo sin espectador.** Desconectar el cliente no cancela PTYs ni
  agentes. Reconectar reconstruye las proyecciones desde snapshots. Esto no
  promete supervivencia al crash del propio runtime.
- **Presentación por demanda.** El diagrama propone dirty + deadline según los
  invariantes de telar, no un ticker periódico obligatorio. Se pliegan frames
  pendientes antes de codificar; no se descartan bytes arbitrarios de un diff
  ya preparado contra el estado de pantalla anterior.

## Qué ya existe y qué queda por decidir

El frontend actual ya tiene piezas de este modelo:

- [`connection/outbox.zig`](../../src/frontend/client/connection/outbox.zig)
  posee mensajes y copia payloads variables en almacenamiento acotado.
- [`connection/runtime_transport.zig`](../../src/frontend/client/connection/runtime_transport.zig)
  reserva buffers y separa lifecycle de envío y recepción.
- [`entrypoints/runtime_io.zig`](../../src/frontend/client/entrypoints/runtime_io.zig)
  programa recepción y envío concurrentes.
- [`presentation/presentation_lifecycle.zig`](../../src/frontend/client/presentation/presentation_lifecycle.zig)
  separa composición, escritura pendiente y confirmación de presentación.
- [Client event dispatch](../flows/client-event-dispatch.md) describe el
  despacho mediante select. Una cola consumida por una tarea permanente y
  operaciones rearmadas mediante select pueden implementar la separación del
  dibujo; no se decide aquí reemplazar una por la otra.
- El [ADR de client delivery](../adr/0003-separate-client-delivery-from-attachment-sync.md)
  ya separa política de entrega, sincronización de attachments y socket I/O.

Quedan abiertas las capacidades en bytes y elementos, la política de admisión
por tipo, el presupuesto de drenaje, la equidad entre fuentes, la supervisión
concreta y la forma del sink de efectos. No se fija un hilo del SO por productor
ni una nueva infraestructura genérica de efectos.

Antes de promover este dibujo a implementación hay que verificar: cliente que
no lee, cola llena en cada frontera, ráfaga concurrente con input, desconexión
con envío en vuelo, completions de una generación retirada, wake durante el
drenaje, recuperación por snapshot y cero repintados en reposo. Las mediciones
deberían incluir p50/p95/p99 de input y presentación, bytes retenidos, profundidad
de cola, rechazos, pérdidas y despertares. La inspección de Native no reemplaza
esas pruebas.

[native]: https://github.com/vercel-labs/native/tree/31663e16b054f212f0377878eb901330bbc94b53
[app-model]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/docs/src/app/docs/app-model/page.mdx
[options]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/ui_app.zig#L570-L596
[dispatch]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/ui_app.zig#L1745-L1880
[effects]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/effects.zig#L1-L70
[typescript]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/docs/src/app/docs/typescript/page.mdx#L222-L537
[ts-cycle]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/ts_core_host.zig#L910-L975
[channel]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/effects.zig#L1485-L1640
[channel-tests]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/effects_channel_tests.zig#L48-L240
[completion-queue]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/effects.zig#L15533-L15554
[wake]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/flow.zig#L473-L475
[drain-boundary]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/effects.zig#L11379-L11487
[wake-tests]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/effects_channel_tests.zig#L556-L671
[timers]: https://github.com/vercel-labs/native/blob/31663e16b054f212f0377878eb901330bbc94b53/src/runtime/effects.zig#L10120-L10194
