// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonStakingVault } from "../staking/EchelonStakingVault.sol";
import { EpochRewardController } from "../rewards/EpochRewardController.sol";
import { LockTierRegistry } from "../policy/LockTierRegistry.sol";
import { StakePositionToken } from "../positions/StakePositionToken.sol";
import { PenaltyReserve } from "../treasury/PenaltyReserve.sol";
import { SlashingManager } from "../security/SlashingManager.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import {
    StakePosition,
    EpochConfig,
    PositionStatus,
    EchelonConstants
} from "../types/EchelonTypes.sol";
import { FullMath } from "../libraries/FullMath.sol";
import {
    ZeroAddress,
    BatchTooLarge,
    PositionIdsNotStrictlyIncreasing
} from "../errors/EchelonErrors.sol";

/// @title EchelonMonitor
/// @notice Operational health checks designed for keepers and alerting systems.
contract EchelonMonitor {
    uint256 public constant MAX_POSITION_AUDIT = 500;

    EchelonStakingVault public immutable vault;
    EpochRewardController public immutable rewardController;
    LockTierRegistry public immutable tierRegistry;
    StakePositionToken public immutable positionToken;
    PenaltyReserve public immutable penaltyReserve;
    SlashingManager public immutable slashingManager;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    struct WiringReport {
        bool controllerLinked;
        bool positionTokenLinked;
        bool reserveLinked;
        bool slashingLinked;
        bool stakingTokenLinked;
        bool rewardTokenLinked;
        bool fullyLinked;
    }

    struct BalanceReport {
        uint256 principalAssets;
        uint256 principalLiabilities;
        uint256 principalSurplus;
        uint256 rewardLiquidity;
        uint256 reserveAssets;
        uint256 reserveAccounted;
        uint256 reserveSurplus;
        bool principalSolvent;
        bool reserveSolvent;
    }

    struct PositionAudit {
        uint256 firstPositionId;
        uint256 lastPositionId;
        uint256 positionsInspected;
        uint256 activePositions;
        uint256 principalObserved;
        uint256 rewardWeightObserved;
        uint256 slashedObserved;
        bool coversAllPositions;
        bool principalMatches;
        bool rewardWeightMatches;
    }

    struct KeeperReport {
        uint32 currentEpoch;
        uint256 currentTimestamp;
        uint256 lastIndexUpdate;
        uint256 secondsSinceUpdate;
        uint256 globalRewardIndex;
        uint256 totalRewardWeight;
        bool epochConfigured;
        bool previousEpochNeedsFinalization;
        bool depositsPaused;
        bool exitsPaused;
        bool tierChangesPaused;
        bool payoutsPaused;
    }

    struct EpochHealth {
        uint32 epochId;
        uint64 startTime;
        uint64 endTime;
        uint256 rewardBudget;
        uint256 emittedRewards;
        uint256 unvestedBudget;
        uint256 rewardRate;
        bool enabled;
        bool finalized;
        bool started;
        bool ended;
    }

    constructor(
        address vault_,
        address rewardController_,
        address tierRegistry_,
        address positionToken_,
        address penaltyReserve_,
        address slashingManager_
    ) {
        if (
            vault_ == address(0) || rewardController_ == address(0) || tierRegistry_ == address(0)
                || positionToken_ == address(0) || penaltyReserve_ == address(0)
                || slashingManager_ == address(0)
        ) {
            revert ZeroAddress();
        }

        vault = EchelonStakingVault(vault_);
        rewardController = EpochRewardController(rewardController_);
        tierRegistry = LockTierRegistry(tierRegistry_);
        positionToken = StakePositionToken(positionToken_);
        penaltyReserve = PenaltyReserve(penaltyReserve_);
        slashingManager = SlashingManager(slashingManager_);
        stakingToken = EchelonStakingVault(vault_).stakingToken();
        rewardToken = EpochRewardController(rewardController_).rewardToken();
    }

    function wiringReport() public view returns (WiringReport memory report) {
        report.controllerLinked = rewardController.stakingVault() == address(vault)
            && address(vault.rewardController()) == address(rewardController);
        report.positionTokenLinked = positionToken.stakingVault() == address(vault)
            && address(vault.positionToken()) == address(positionToken);
        report.reserveLinked = penaltyReserve.stakingVault() == address(vault)
            && address(vault.penaltyReserve()) == address(penaltyReserve);
        report.slashingLinked = vault.slashingManager() == address(slashingManager)
            && address(slashingManager.stakingVault()) == address(vault);
        report.stakingTokenLinked = address(vault.stakingToken()) == address(stakingToken)
            && address(penaltyReserve.stakingToken()) == address(stakingToken);
        report.rewardTokenLinked = vault.rewardToken() == address(rewardToken)
            && address(rewardController.rewardToken()) == address(rewardToken);
        report.fullyLinked = report.controllerLinked && report.positionTokenLinked
            && report.reserveLinked && report.slashingLinked && report.stakingTokenLinked
            && report.rewardTokenLinked;
    }

    function balanceReport() public view returns (BalanceReport memory report) {
        report.principalAssets = stakingToken.balanceOf(address(vault));
        report.principalLiabilities = vault.totalPrincipal();
        report.principalSurplus =
            FullMath.saturatingSub(report.principalAssets, report.principalLiabilities);
        report.rewardLiquidity = rewardToken.balanceOf(address(rewardController));
        report.reserveAssets = stakingToken.balanceOf(address(penaltyReserve));
        report.reserveAccounted = penaltyReserve.accountedBalance();
        report.reserveSurplus =
            FullMath.saturatingSub(report.reserveAssets, report.reserveAccounted);
        report.principalSolvent = report.principalAssets >= report.principalLiabilities;
        report.reserveSolvent = report.reserveAssets >= report.reserveAccounted;
    }

    function auditPositionRange(uint256 firstPositionId, uint256 lastPositionId)
        external
        view
        returns (PositionAudit memory report)
    {
        uint256 nextId = vault.nextPositionId();
        uint256 first = firstPositionId == 0 ? 1 : firstPositionId;
        uint256 last = lastPositionId >= nextId ? nextId - 1 : lastPositionId;
        if (last < first) return report;

        uint256 count = last - first + 1;
        if (count > MAX_POSITION_AUDIT) revert BatchTooLarge(count, MAX_POSITION_AUDIT);

        report.firstPositionId = first;
        report.lastPositionId = last;
        report.positionsInspected = count;
        for (uint256 id = first; id <= last; ++id) {
            StakePosition memory stakePosition = vault.position(id);
            if (stakePosition.status == PositionStatus.Active) {
                ++report.activePositions;
                report.principalObserved += stakePosition.principal;
                report.rewardWeightObserved += stakePosition.rewardWeight;
                report.slashedObserved += stakePosition.totalSlashed;
            }
        }

        report.coversAllPositions = first == 1 && last + 1 == nextId;
        if (report.coversAllPositions) {
            report.principalMatches = report.principalObserved == vault.totalPrincipal();
            report.rewardWeightMatches =
                report.rewardWeightObserved == rewardController.totalRewardWeight();
        }
    }

    function auditSelectedPositions(uint256[] calldata positionIds)
        external
        view
        returns (PositionAudit memory report)
    {
        uint256 length = positionIds.length;
        if (length > MAX_POSITION_AUDIT) revert BatchTooLarge(length, MAX_POSITION_AUDIT);

        uint256 previous;
        report.positionsInspected = length;
        if (length != 0) {
            report.firstPositionId = positionIds[0];
            report.lastPositionId = positionIds[length - 1];
        }

        for (uint256 i; i < length; ++i) {
            uint256 id = positionIds[i];
            if (i != 0 && id <= previous) revert PositionIdsNotStrictlyIncreasing();
            previous = id;

            StakePosition memory stakePosition = vault.position(id);
            if (stakePosition.status == PositionStatus.Active) {
                ++report.activePositions;
                report.principalObserved += stakePosition.principal;
                report.rewardWeightObserved += stakePosition.rewardWeight;
                report.slashedObserved += stakePosition.totalSlashed;
            }
        }
    }

    function keeperReport() external view returns (KeeperReport memory report) {
        uint32 epochId = rewardController.currentEpoch();
        bool configured = rewardController.isEpochConfigured(epochId);
        bool previousNeedsFinalization;
        if (epochId != 0 && rewardController.isEpochConfigured(epochId - 1)) {
            EpochConfig memory previous = rewardController.epoch(epochId - 1);
            previousNeedsFinalization = block.timestamp >= previous.endTime && !previous.finalized;
        }

        uint256 lastUpdate = rewardController.lastUpdateTime();
        report = KeeperReport({
            currentEpoch: epochId,
            currentTimestamp: block.timestamp,
            lastIndexUpdate: lastUpdate,
            secondsSinceUpdate: FullMath.saturatingSub(block.timestamp, lastUpdate),
            globalRewardIndex: rewardController.globalRewardIndex(),
            totalRewardWeight: rewardController.totalRewardWeight(),
            epochConfigured: configured,
            previousEpochNeedsFinalization: previousNeedsFinalization,
            depositsPaused: vault.depositsArePaused(),
            exitsPaused: vault.exitsArePaused(),
            tierChangesPaused: vault.tierChangesArePaused(),
            payoutsPaused: rewardController.payoutsPaused()
        });
    }

    function epochHealth(uint32 epochId) external view returns (EpochHealth memory report) {
        EpochConfig memory config = rewardController.epoch(epochId);
        report = EpochHealth({
            epochId: epochId,
            startTime: config.startTime,
            endTime: config.endTime,
            rewardBudget: config.rewardBudget,
            emittedRewards: config.emittedRewards,
            unvestedBudget: uint256(config.rewardBudget) - config.emittedRewards,
            rewardRate: config.rewardRate,
            enabled: config.enabled,
            finalized: config.finalized,
            started: block.timestamp >= config.startTime,
            ended: block.timestamp >= config.endTime
        });
    }

    function roleCoverage(address account)
        external
        view
        returns (bool governor, bool rewardManager, bool slasher, bool guardian, bool keeper)
    {
        governor = vault.accessManager().hasRole(EchelonConstants.GOVERNOR_ROLE, account);
        rewardManager = vault.accessManager().hasRole(EchelonConstants.REWARD_MANAGER_ROLE, account);
        slasher = vault.accessManager().hasRole(EchelonConstants.SLASHER_ROLE, account);
        guardian = vault.accessManager().hasRole(EchelonConstants.GUARDIAN_ROLE, account);
        keeper = vault.accessManager().hasRole(EchelonConstants.KEEPER_ROLE, account);
    }
}
