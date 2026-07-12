# Echelon Staking Protocol

![banner](./assets/banner.png)

Echelon es un protocolo modular de *staking* para activos ERC-20. Cada depósito se representa
mediante una posición ERC-721 y combina tres elementos económicos: un nivel de bloqueo, un peso
de recompensa y una penalización decreciente por salida anticipada. Las emisiones se programan por
*epochs*, lo que permite variar presupuesto y tasa sin sustituir el contrato de custodia.

El repositorio contiene los contratos, pruebas con Foundry, un script de despliegue y utilidades de
integración continua.

## Arquitectura

```text
                              +----------------------+
                              | EchelonAccessManager |
                              +----------+-----------+
                                         |
           +-----------------------------+-----------------------------+
           |                             |                             |
+----------v-----------+      +----------v-----------+      +----------v----------+
| LockTierRegistry     |      | EpochRewardController|      | SlashingManager     |
| niveles y compromisos|      | epochs e índice global|      | cola y ejecución   |
+----------+-----------+      +----------+-----------+      +----------+----------+
           |                             |                             |
           +-----------------------------+-----------------------------+
                                         |
                              +----------v-----------+
                              | EchelonStakingVault  |
                              | principal y rewards  |
                              +----+-------------+---+
                                   |             |
                         +---------v--+      +---v------------+
                         | PositionNFT |      | PenaltyReserve |
                         +-------------+      +----------------+
                                         |
                              +----------v-----------+
                              | Lens y Monitor       |
                              | lectura y alertas    |
                              +----------------------+
```

- `EchelonStakingVault` custodia el principal y gestiona `stake`, aumentos, cambios de nivel,
  reclamaciones, salidas y *slashes*.
- `EpochRewardController` mantiene un índice acumulativo por unidad de peso y limita las emisiones
  al presupuesto configurado en cada *epoch*.
- `LockTierRegistry` publica niveles inmutables con duración, multiplicador, periodo de espera,
  penalización máxima y depósito mínimo.
- `StakePositionToken` representa la propiedad y delegación de cada posición mediante ERC-721.
- `SlashingManager` separa la propuesta de un *slash* de su ejecución mediante una cola con retardo
  y evidencia identificada por hash.
- `PenaltyReserve` contabiliza por separado penalizaciones de salida y principal recortado.
- `EchelonLens` agrega lecturas para interfaces, indexadores y monitorización operativa.
- `EchelonMonitor` comprueba enlaces entre módulos, solvencia, conciliación de posiciones y salud
  de los *epochs* para *keepers* y sistemas de alertas.

## Requisitos

- [Foundry](https://book.getfoundry.sh/getting-started/installation) actualizado.
- Solidity `0.8.24` (Foundry instala el compilador cuando es necesario).
- Dos tokens ERC-20 distintos: uno para el principal y otro para recompensas.

## Inicio rápido

```bash
forge build
forge test
```

La suite completa con los parámetros de CI se ejecuta con:

```bash
bash scripts/ci.sh
```

Para ejecutar un archivo o caso concreto se pueden pasar argumentos directamente a Forge:

```bash
bash scripts/tests.sh --match-path test/integration/Slashing.t.sol
bash scripts/tests.sh --match-test test_partialSlashReconcilesPrincipalWeightAndReserve
```

## Flujo del protocolo

1. Un usuario aprueba el token de principal y llama a `stake(amount, tierId, recipient)`.
2. El vault crea una posición, calcula su peso y acuña el NFT al destinatario.
3. Las emisiones activas incrementan el índice global según el peso total del sistema.
4. El propietario o un operador autorizado puede reclamar recompensas, aumentar la posición,
   cambiar de nivel o retirar principal.
5. Una salida anterior a `unlockAt` aplica la penalización lineal vigente y la envía a la reserva.
6. Un actor con rol `SLASHER_ROLE` puede encolar una medida con evidencia; cualquier cuenta puede
   ejecutarla una vez transcurrido el retardo, salvo que gobierno o guardián la cancelen.

Los cambios de peso sincronizan primero el controlador de recompensas. De este modo, el total de
peso, el principal custodiado y las reservas se mantienen observables en cada transición.

## Roles operativos

| Rol | Responsabilidad |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Administra el rol de gobierno y la transferencia diferida del administrador. |
| `GOVERNOR_ROLE` | Configura módulos, niveles y parámetros estructurales. |
| `REWARD_MANAGER_ROLE` | Financia recompensas y programa *epochs*. |
| `SLASHER_ROLE` | Encola solicitudes de *slashing* respaldadas por evidencia. |
| `GUARDIAN_ROLE` | Pausa operaciones sensibles y cancela solicitudes en emergencia. |
| `KEEPER_ROLE` | Identidad reservada para automatización y mantenimiento operativo. |

En producción, estos roles deberían asignarse a cuentas o contratos distintos, idealmente con
multifirma y *timelock*. El desplegador no debe conservar privilegios innecesarios.

## Despliegue

El script despliega y enlaza todos los módulos. Requiere direcciones de tokens ya desplegados:

```bash
export PRIVATE_KEY=<clave-del-desplegador>
export STAKING_TOKEN=<erc20-principal>
export REWARD_TOKEN=<erc20-recompensas>
export TREASURY=<tesoreria>
export GENESIS=<timestamp-futuro>

forge script script/DeployEchelon.s.sol:DeployEchelon \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify
```

Variables opcionales:

| Variable | Valor predeterminado | Uso |
| --- | ---: | --- |
| `ADMIN_TRANSFER_DELAY` | `172800` | Retardo, en segundos, para transferir el administrador. |
| `EPOCH_DURATION` | `604800` | Duración de cada *epoch*. |
| `SLASH_DELAY` | `172800` | Retardo entre propuesta y ejecución de un *slash*. |
| `BASE_URI` | cadena vacía | URI base de metadatos de las posiciones. |
| `MINIMUM_STAKE` | `1e18` | Principal mínimo de los niveles iniciales. |
| `REWARD_MANAGER` | desplegador | Cuenta operadora de recompensas. |
| `SLASHER` | desplegador | Cuenta autorizada a encolar medidas. |
| `GUARDIAN` | desplegador | Cuenta de respuesta a incidentes. |
| `INITIAL_REWARD_FUNDING` | `0` | Recompensas que el script transfiere al controlador. |
| `FIRST_EPOCH_BUDGET` | `0` | Si es mayor que cero, programa el *epoch* 0. |
| `FIRST_EPOCH_RATE` | `budget / duration` | Tasa por segundo del *epoch* inicial. |

Cuando `INITIAL_REWARD_FUNDING` es mayor que cero, el desplegador debe disponer del token de
recompensas. `GENESIS` debe seguir en el futuro al configurar el primer *epoch*.

## Verificación y calidad

```bash
forge fmt --check
forge build --sizes
FOUNDRY_PROFILE=ci forge test -vvv
```

Las pruebas cubren el ciclo de vida de posiciones, cambios de peso, contabilidad por *epoch*,
permisos, pausas, salidas, reservas y *slashing*. Antes de cualquier despliegue real también se
recomiendan pruebas sobre un *fork*, revisión independiente y monitorización de solvencia.

## Seguridad

Consulta [SECURITY.md](SECURITY.md) para el proceso de divulgación responsable, alcance y tiempos
de respuesta. Este software no constituye asesoramiento financiero y no se ofrece ninguna garantía
sobre su idoneidad para custodiar activos reales sin una revisión independiente.

## Licencia

Los contratos declaran licencia MIT mediante SPDX.
