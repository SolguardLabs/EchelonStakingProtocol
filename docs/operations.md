# Operaciones

## Flujo de publicación

```mermaid
flowchart LR
    C["Commit candidato"] --> P["Pull request"]
    P --> CI["CI + invariantes"]
    CI --> M["Merge main"]
    M --> B["Branch production"]
    B --> T["Tag anotado"]
    T --> R["Release"]
    R --> V["Verificación de refs"]
```

`main`, `production` y el tag pelado deben apuntar al mismo commit. La release se publica solo cuando
los tres eventos han finalizado correctamente.

## Checklist de despliegue

1. Fijar chain ID, RPC, tokens y roles.
2. Confirmar que staking token y reward token son distintos.
3. Simular el script sin broadcast.
4. Revisar tamaños y bytecode.
5. Desplegar y guardar direcciones.
6. Verificar wiring de controller, NFT, reserve y slashing manager.
7. Configurar tiers iniciales.
8. Financiar y programar el primer epoch.
9. Asignar roles operativos.
10. Transferir administración al gobierno final.

```mermaid
sequenceDiagram
    participant D as Deployer
    participant C as Contracts
    participant M as Monitor
    participant G as Governance
    D->>C: deploy + wire
    D->>C: tiers + funding + epoch
    D->>M: wiringReport + balanceReport
    M-->>D: all checks true
    D->>G: schedule admin transfer
    G->>C: accept after delay
```

## Monitorización

| Frecuencia | Señal |
| --- | --- |
| cada bloque | pausas, pagos y eventos de slashing |
| 5 minutos | reward liquidity, principal backing y reserve backing |
| por hora | index staleness, runway y cobertura |
| por epoch | budget, emission, skipped, paid y finalization |
| diaria | concentración de peso y roles |

## Runbook de contención

```mermaid
flowchart TB
    A["Señal crítica"] --> B["Pausar superficie"]
    B --> C["Fijar bloque y capturar estado"]
    C --> D["Conciliar principal/rewards/reserve"]
    D --> E{"Fondos respaldados"}
    E -->|sí| F["Corregir y ensayar"]
    E -->|no| G["Plan de recapitalización"]
    F --> H["Aprobación de gobierno"]
    G --> H
    H --> I["Nueva publicación"]
```

No se reanudan operaciones hasta obtener dos snapshots consistentes consecutivos y una aprobación
explícita del gobierno.

## Evidencia

Conservar commit, tag, chain ID, direcciones, bytecode hashes, transacciones de despliegue, roles,
configuración de tiers, epochs, reportes del monitor y evaluaciones de stress. Los secretos nunca se
incluyen en logs ni artefactos.

## Reversión

Los contratos son modulares y no dependen de un proxy. Una sustitución requiere desplegar un sistema
nuevo y un procedimiento de migración aprobado. Los tags publicados son inmutables.
