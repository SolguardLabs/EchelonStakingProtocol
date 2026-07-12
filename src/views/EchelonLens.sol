// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonStakingVault } from "../staking/EchelonStakingVault.sol";
import { EpochRewardController } from "../rewards/EpochRewardController.sol";
import { LockTierRegistry } from "../policy/LockTierRegistry.sol";
import { StakePositionToken } from "../positions/StakePositionToken.sol";
import { PenaltyReserve } from "../treasury/PenaltyReserve.sol";
import {
    StakePosition,
    PositionPreview,
    ProtocolSnapshot,
    TierConfig,
    EpochConfig,
    PositionStatus
} from "../types/EchelonTypes.sol";
import { RewardMath } from "../libraries/RewardMath.sol";
import { FullMath } from "../libraries/FullMath.sol";
import { ZeroAddress, BatchTooLarge, PositionNotFound } from "../errors/EchelonErrors.sol";

/// @title EchelonLens
/// @notice Read-only aggregation for dashboards, keepers, and integration clients.
contract EchelonLens {
    uint256 public constant MAX_PAGE_SIZE = 100;
    uint256 public constant MAX_OWNER_SCAN = 1000;

    EchelonStakingVault public immutable vault;
    EpochRewardController public immutable rewardController;
    LockTierRegistry public immutable tierRegistry;
    StakePositionToken public immutable positionToken;
    PenaltyReserve public immutable penaltyReserve;

    struct PositionView {
        StakePosition position;
        PositionPreview preview;
        TierConfig tier;
        string tierName;
    }

    struct EpochView {
        uint32 epochId;
        EpochConfig config;
        uint256 startIndex;
        uint256 elapsed;
        uint256 remainingTime;
        uint256 remainingBudget;
        bool current;
    }

    struct TierChangeQuote {
        uint32 currentTierId;
        uint32 requestedTierId;
        uint256 currentWeight;
        uint256 resultingWeight;
        uint64 availableAt;
        uint64 resultingUnlockAt;
        uint16 resultingPenaltyBps;
        bool availableNow;
    }

    struct ReserveView {
        uint256 tokenBalance;
        uint256 accountedBalance;
        uint256 unaccountedBalance;
        uint256 totalPenalties;
        uint256 totalSlashed;
        uint256 totalRoundingSurplus;
        uint256 totalWithdrawn;
        address treasury;
    }

    struct SolvencyView {
        uint256 principalLiability;
        uint256 principalAssets;
        uint256 rewardLiquidity;
        uint256 rewardsFunded;
        uint256 rewardsEmitted;
        uint256 rewardsPaid;
        uint256 skippedRewards;
        bool principalSolvent;
    }

    constructor(
        address vault_,
        address rewardController_,
        address tierRegistry_,
        address positionToken_,
        address penaltyReserve_
    ) {
        if (
            vault_ == address(0) || rewardController_ == address(0) || tierRegistry_ == address(0)
                || positionToken_ == address(0) || penaltyReserve_ == address(0)
        ) {
            revert ZeroAddress();
        }
        vault = EchelonStakingVault(vault_);
        rewardController = EpochRewardController(rewardController_);
        tierRegistry = LockTierRegistry(tierRegistry_);
        positionToken = StakePositionToken(positionToken_);
        penaltyReserve = PenaltyReserve(penaltyReserve_);
    }

    function getPosition(uint256 positionId) public view returns (PositionView memory item) {
        StakePosition memory stakePosition = vault.position(positionId);
        if (stakePosition.status == PositionStatus.None) revert PositionNotFound(positionId);

        item.position = stakePosition;
        item.preview = vault.previewPosition(positionId);
        item.tier = tierRegistry.tier(stakePosition.tierId);
        item.tierName = tierRegistry.tierName(stakePosition.tierId);
    }

    function getPositions(uint256[] calldata positionIds)
        external
        view
        returns (PositionView[] memory items)
    {
        uint256 length = positionIds.length;
        if (length > MAX_PAGE_SIZE) revert BatchTooLarge(length, MAX_PAGE_SIZE);
        items = new PositionView[](length);
        for (uint256 i; i < length; ++i) {
            items[i] = getPosition(positionIds[i]);
        }
    }

    function positionsOfOwner(address owner, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory positionIds, uint256 nextCursor)
    {
        if (owner == address(0)) revert ZeroAddress();
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert BatchTooLarge(limit, MAX_PAGE_SIZE);

        uint256 upper = vault.nextPositionId();
        uint256 id = cursor == 0 ? 1 : cursor;
        uint256 scanEnd = FullMath.min(upper, id + MAX_OWNER_SCAN);
        positionIds = new uint256[](limit);
        uint256 found;

        while (id < scanEnd && found < limit) {
            StakePosition memory stakePosition = vault.position(id);
            if (stakePosition.status == PositionStatus.Active && positionToken.ownerOf(id) == owner)
            {
                positionIds[found] = id;
                unchecked {
                    ++found;
                }
            }
            unchecked {
                ++id;
            }
        }

        assembly ("memory-safe") {
            mstore(positionIds, found)
        }
        nextCursor = id < upper ? id : 0;
    }

    function activePositions(uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory positionIds, uint256 nextCursor)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert BatchTooLarge(limit, MAX_PAGE_SIZE);
        uint256 upper = vault.nextPositionId();
        uint256 id = cursor == 0 ? 1 : cursor;
        positionIds = new uint256[](limit);
        uint256 found;

        while (id < upper && found < limit) {
            if (vault.position(id).status == PositionStatus.Active) {
                positionIds[found] = id;
                unchecked {
                    ++found;
                }
            }
            unchecked {
                ++id;
            }
        }

        assembly ("memory-safe") {
            mstore(positionIds, found)
        }
        nextCursor = id < upper ? id : 0;
    }

    function currentEpochView() external view returns (EpochView memory) {
        return getEpoch(rewardController.currentEpoch());
    }

    function getEpoch(uint32 epochId) public view returns (EpochView memory item) {
        EpochConfig memory config = rewardController.epoch(epochId);
        uint256 elapsed;
        uint256 remainingTime;

        if (block.timestamp <= config.startTime) {
            remainingTime = config.endTime - config.startTime;
        } else if (block.timestamp < config.endTime) {
            elapsed = block.timestamp - config.startTime;
            remainingTime = config.endTime - block.timestamp;
        } else {
            elapsed = config.endTime - config.startTime;
        }

        uint256 startIndex;
        if (epochId <= rewardController.currentEpoch()) {
            try rewardController.epochStartIndex(epochId) returns (uint256 recordedIndex) {
                startIndex = recordedIndex;
            } catch {
                startIndex = rewardController.globalRewardIndex();
            }
        }

        item = EpochView({
            epochId: epochId,
            config: config,
            startIndex: startIndex,
            elapsed: elapsed,
            remainingTime: remainingTime,
            remainingBudget: uint256(config.rewardBudget) - config.emittedRewards,
            current: epochId == rewardController.currentEpoch()
        });
    }

    function getEpochs(uint32 firstEpoch, uint32 count)
        external
        view
        returns (EpochView[] memory items)
    {
        if (count == 0 || count > MAX_PAGE_SIZE) revert BatchTooLarge(count, MAX_PAGE_SIZE);
        items = new EpochView[](count);
        for (uint32 i; i < count; ++i) {
            items[i] = getEpoch(firstEpoch + i);
        }
    }

    function getTiers() external view returns (TierConfig[] memory configs, string[] memory names) {
        uint32 count = tierRegistry.tierCount();
        configs = new TierConfig[](count);
        names = new string[](count);
        for (uint32 i; i < count; ++i) {
            configs[i] = tierRegistry.tier(i);
            names[i] = tierRegistry.tierName(i);
        }
    }

    function quoteTierChange(uint256 positionId, uint32 newTierId)
        external
        view
        returns (TierChangeQuote memory quote)
    {
        StakePosition memory stakePosition = vault.position(positionId);
        if (stakePosition.status == PositionStatus.None) revert PositionNotFound(positionId);

        TierConfig memory current = tierRegistry.tier(stakePosition.tierId);
        TierConfig memory requested = tierRegistry.requireActiveTier(newTierId);
        uint64 cooldown = current.changeCooldown > requested.changeCooldown
            ? current.changeCooldown
            : requested.changeCooldown;
        uint64 availableAt = stakePosition.lastTierChange + cooldown;

        uint64 resultingUnlockAt = stakePosition.unlockAt;
        uint16 resultingPenaltyBps = stakePosition.commitmentPenaltyBps;
        uint256 candidateUnlock = block.timestamp + requested.lockDuration;
        if (block.timestamp >= stakePosition.unlockAt) {
            resultingUnlockAt = uint64(candidateUnlock);
            resultingPenaltyBps = requested.maxExitPenaltyBps;
        } else {
            if (candidateUnlock > resultingUnlockAt) {
                resultingUnlockAt = uint64(candidateUnlock);
            }
            if (requested.maxExitPenaltyBps > resultingPenaltyBps) {
                resultingPenaltyBps = requested.maxExitPenaltyBps;
            }
        }

        quote = TierChangeQuote({
            currentTierId: stakePosition.tierId,
            requestedTierId: newTierId,
            currentWeight: stakePosition.rewardWeight,
            resultingWeight: RewardMath.weight(stakePosition.principal, requested.multiplierBps),
            availableAt: availableAt,
            resultingUnlockAt: resultingUnlockAt,
            resultingPenaltyBps: resultingPenaltyBps,
            availableNow: block.timestamp >= availableAt
        });
    }

    function reserveView() external view returns (ReserveView memory item) {
        uint256 balance = penaltyReserve.stakingToken().balanceOf(address(penaltyReserve));
        uint256 accounted = penaltyReserve.accountedBalance();
        item = ReserveView({
            tokenBalance: balance,
            accountedBalance: accounted,
            unaccountedBalance: balance > accounted ? balance - accounted : 0,
            totalPenalties: penaltyReserve.totalPenalties(),
            totalSlashed: penaltyReserve.totalSlashed(),
            totalRoundingSurplus: penaltyReserve.totalRoundingSurplus(),
            totalWithdrawn: penaltyReserve.totalWithdrawn(),
            treasury: penaltyReserve.treasury()
        });
    }

    function solvencyView() external view returns (SolvencyView memory item) {
        uint256 liabilities = vault.totalPrincipal();
        uint256 assets = vault.stakingToken().balanceOf(address(vault));
        item = SolvencyView({
            principalLiability: liabilities,
            principalAssets: assets,
            rewardLiquidity: rewardController.rewardLiquidity(),
            rewardsFunded: rewardController.totalRewardsFunded(),
            rewardsEmitted: rewardController.totalRewardsEmitted(),
            rewardsPaid: rewardController.totalRewardsPaid(),
            skippedRewards: rewardController.skippedRewards(),
            principalSolvent: assets >= liabilities
        });
    }

    function protocolSnapshot() external view returns (ProtocolSnapshot memory) {
        return vault.protocolSnapshot();
    }
}
