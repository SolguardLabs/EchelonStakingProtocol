# Arquitectura

## Diseño modular

Echelon divide las responsabilidades que mueven activos de las que definen política o exponen
lecturas. El vault coordina, pero no administra roles, no programa emisiones y no mantiene la
propiedad ERC-721.

```mermaid
flowchart TB
    subgraph Control
        AM["AccessManager"]
        TR["TierRegistry"]
        SM["SlashingManager"]
    end
    subgraph Accounting
        V["StakingVault"]
        RC["RewardController"]
        PR["PenaltyReserve"]
    end
    subgraph Ownership
        NFT["PositionToken"]
    end
    subgraph ReadModel
        L["Lens"]
        M["Monitor"]
        RE["RiskEngine"]
    end
    AM --> TR
    AM --> SM
    AM --> RC
    TR --> V
    SM --> V
    RC --> V
    V --> PR
    V --> NFT
    V --> L
    RC --> L
    V --> M
    RC --> M
    V --> RE
    RC --> RE
```

## Dependencias

| Módulo | Puede escribir en | Llamadas externas de activos |
| --- | --- | --- |
| Vault | posiciones, principal, peso | staking token, reward controller, reserve, NFT |
| RewardController | epochs, índice, pagos | reward token |
| TierRegistry | configuración de tiers | ninguna |
| PositionToken | ownership y aprobaciones | receptor ERC-721 |
| SlashingManager | cola y estado de solicitudes | vault al ejecutar |
| PenaltyReserve | créditos y retiros | staking token |
| Lens/Monitor/Risk | ninguna | solo lecturas |

```mermaid
graph LR
    Types --> Libraries
    Interfaces --> Modules
    Libraries --> Modules
    Modules --> Views
    Modules --> Monitoring
    Modules --> Risk
    Modules --> Deploy
    Views -. no escribe .-> Modules
    Monitoring -. no escribe .-> Modules
    Risk -. no escribe .-> Modules
```

## Flujo de escritura

```mermaid
sequenceDiagram
    autonumber
    participant Caller
    participant Vault
    participant Controller
    participant Token
    participant NFT
    Caller->>Vault: acción autorizada
    Vault->>Vault: validar estado y parámetros
    Vault->>Controller: sincronizar índice/peso
    Controller-->>Vault: index + epoch
    Vault->>Vault: acumular posición
    Vault->>Token: transfer exacto si aplica
    Vault->>NFT: mint/burn si aplica
    Vault-->>Caller: evento y retorno
```

Las mutaciones de principal siguen el orden sincronizar, acumular, actualizar y transferir. Los
contratos de lectura nunca se usan como fuente de autoridad.

## Propiedades de despliegue

- staking token y reward token deben ser distintos;
- controller, NFT, reserve y slashing manager se enlazan una sola vez;
- el deployer configura tiers y roles antes de transferir gobierno;
- lens, monitor y risk engine reciben direcciones inmutables;
- toda dirección desplegada se registra junto a chain ID, commit y bytecode hash.

## Extensión

Una nueva política de tier se implementa en el registry y se consume desde el vault. Una nueva
métrica se añade a Lens, Monitor o RiskEngine sin introducir escritura. Una nueva acción con activos
requiere pruebas de autorización, reentrada, conciliación, pausas y comportamiento de tokens.
