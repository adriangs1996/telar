## Native diagram rendering

The message keeps its original Mermaid source when copied.

```mermaid
flowchart TD
    A[Teclado, ratón, texto del sistema] --> B[Callback input]
    B --> C[Inbox: eventos propios ordenados]
    C --> D[Callback pump]
    D --> E[Runner.dispatch]
    E --> F[MyWidget.input modifica estado]
    F --> G[dirty = true]
    G --> H[El backend programa un dibujo]
    H --> I[callback render → Runner.prepare]
    I --> J[MyWidget.draw → Canvas]
    J --> K[Frame: quads, atlas, sprites y token]
    K --> L[Backend gráfico → GPU]
    L --> M[callback complete]
    M --> C
    D --> N[Runner.finish confirma geometría interactiva]
```

### One turn, two participants

```mermaid
sequenceDiagram
    participant U as User
    participant A as Agent
    U->>A: Explain the rendering flow
    A-->>U: Diagram and explanation
```

The diagrams are generated locally and survive reconnect through the retained message.
