# Gobierno y seguridad

## Separación de funciones

```mermaid
flowchart TB
    DA["Default admin"] --> G["Governor"]
    G --> RM["Reward manager"]
    G --> SL["Slasher"]
    G --> GD["Guardian"]
    G --> KP["Keeper"]
    RM --> B["Budgets"]
    SL --> Q["Slash queue"]
    GD --> P["Pause controls"]
    KP --> S["Sync operations"]
```

El default admin controla la jerarquía y su propia transferencia diferida. Governor gestiona
configuración estructural. Los roles operativos no deben compartir firmantes salvo procedimiento de
emergencia documentado.

## Transferencia administrativa

```mermaid
stateDiagram-v2
    [*] --> Current
    Current --> Pending: schedule(candidate)
    Pending --> Current: cancel
    Pending --> Ready: delay elapsed
    Ready --> Transferred: candidate accepts
    Transferred --> [*]
```

La transferencia requiere propuesta del administrador actual, espera y aceptación del candidato.
No se permite renunciar al rol por la ruta ordinaria.

## Slashing diferido

```mermaid
sequenceDiagram
    participant S as Slasher
    participant M as Manager
    participant G as Guardian/Governor
    participant E as Executor
    participant V as Vault
    S->>M: queue(position, bps, evidence)
    alt contención
        G->>M: cancel(request)
    else delay cumplido
        E->>M: execute(request)
        M->>V: applySlash
        V-->>M: principal slashed
    end
```

La evidencia se representa por hash. La ejecución es permissionless una vez cumplido el retardo;
esto evita depender de disponibilidad continua del slasher.

## Pausas

| Pausa | Bloquea | No bloquea |
| --- | --- | --- |
| Deposits | stake e increase | claim y exits |
| Exits | unstake | claim y nuevos depósitos |
| Tier changes | changeTier | claim e increase |
| Payouts | transferencias de reward | sync y principal |

Las pausas separadas reducen el radio operativo de una contención.

## Tokens soportados

Se requieren ERC-20 con transferencias exactas. El vault y controller comparan balances antes y
después. No se admiten tokens con fee-on-transfer, rebasing, callbacks no estándar o comportamiento
que cambie saldos sin transferencia.

## Revisión de cambios

Todo cambio sensible debe incluir:

- mapa de roles y llamadas externas;
- transiciones antes/después;
- efecto sobre principal, peso, rewards y reservas;
- pruebas de pausa, reentrada y permisos;
- invariantes y escenario de recuperación;
- plan de migración sin mover tags existentes.
