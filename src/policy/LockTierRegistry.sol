// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEchelonAccessManager } from "../interfaces/IEchelonAccessManager.sol";
import { ILockTierRegistry } from "../interfaces/IEchelonModules.sol";
import { TierConfig, EchelonConstants } from "../types/EchelonTypes.sol";
import { RewardMath } from "../libraries/RewardMath.sol";
import {
    ZeroAddress,
    TooManyTiers,
    TierNotFound,
    TierDisabled,
    InvalidTierMultiplier,
    InvalidTierDuration,
    InvalidTierPenalty,
    InvalidTierMinimum
} from "../errors/EchelonErrors.sol";

/// @title LockTierRegistry
/// @notice Governance registry for immutable lock economics.
/// @dev Existing tier economics cannot be edited, so positions retain predictable terms.
contract LockTierRegistry is ILockTierRegistry {
    IEchelonAccessManager public immutable accessManager;

    uint32 public override tierCount;
    mapping(uint32 => TierConfig) private _tiers;
    mapping(uint32 => string) private _tierNames;

    event TierCreated(
        uint32 indexed tierId,
        string name,
        uint64 lockDuration,
        uint64 changeCooldown,
        uint32 multiplierBps,
        uint16 maxExitPenaltyBps,
        uint128 minimumStake
    );
    event TierAvailabilityChanged(uint32 indexed tierId, bool enabled);

    constructor(address accessManager_) {
        if (accessManager_ == address(0)) revert ZeroAddress();
        accessManager = IEchelonAccessManager(accessManager_);
    }

    modifier onlyGovernor() {
        accessManager.checkRole(EchelonConstants.GOVERNOR_ROLE, msg.sender);
        _;
    }

    function createTier(
        string calldata name,
        uint64 lockDuration,
        uint64 changeCooldown,
        uint32 multiplierBps,
        uint16 maxExitPenaltyBps,
        uint128 minimumStake
    ) external onlyGovernor returns (uint32 tierId) {
        _validateTier(lockDuration, changeCooldown, multiplierBps, maxExitPenaltyBps, minimumStake);

        tierId = tierCount;
        if (tierId >= EchelonConstants.MAX_TIERS) revert TooManyTiers();
        unchecked {
            tierCount = tierId + 1;
        }

        _tiers[tierId] = TierConfig({
            lockDuration: lockDuration,
            changeCooldown: changeCooldown,
            multiplierBps: multiplierBps,
            maxExitPenaltyBps: maxExitPenaltyBps,
            minimumStake: minimumStake,
            enabled: true,
            exists: true
        });
        _tierNames[tierId] = name;

        emit TierCreated(
            tierId,
            name,
            lockDuration,
            changeCooldown,
            multiplierBps,
            maxExitPenaltyBps,
            minimumStake
        );
    }

    function setTierEnabled(uint32 tierId, bool enabled) external onlyGovernor {
        TierConfig storage config = _tiers[tierId];
        if (!config.exists) revert TierNotFound(tierId);
        if (config.enabled == enabled) return;
        config.enabled = enabled;
        emit TierAvailabilityChanged(tierId, enabled);
    }

    function tier(uint32 tierId) public view override returns (TierConfig memory config) {
        config = _tiers[tierId];
        if (!config.exists) revert TierNotFound(tierId);
    }

    function tierName(uint32 tierId) external view returns (string memory) {
        if (!_tiers[tierId].exists) revert TierNotFound(tierId);
        return _tierNames[tierId];
    }

    function requireActiveTier(uint32 tierId)
        external
        view
        override
        returns (TierConfig memory config)
    {
        config = tier(tierId);
        if (!config.enabled) revert TierDisabled(tierId);
    }

    function calculateWeight(uint256 principal, uint32 tierId)
        external
        view
        override
        returns (uint256)
    {
        TierConfig memory config = tier(tierId);
        return RewardMath.weight(principal, config.multiplierBps);
    }

    function previewExitPenalty(
        uint256 principal,
        uint64 commitmentStartedAt,
        uint64 unlockAt,
        uint16 commitmentPenaltyBps
    ) external view override returns (uint256) {
        return RewardMath.linearExitPenalty(
            principal, block.timestamp, unlockAt, commitmentStartedAt, commitmentPenaltyBps
        );
    }

    function previewCommitment(
        uint32 currentTierId,
        uint32 newTierId,
        uint64 currentCommitmentStartedAt,
        uint64 currentUnlockAt,
        uint16 currentPenaltyBps
    )
        external
        view
        returns (
            uint64 commitmentStartedAt,
            uint64 unlockAt,
            uint16 commitmentPenaltyBps,
            uint64 availableAt
        )
    {
        TierConfig memory current = tier(currentTierId);
        TierConfig memory next = tier(newTierId);
        if (!next.enabled) revert TierDisabled(newTierId);

        uint64 cooldown = current.changeCooldown > next.changeCooldown
            ? current.changeCooldown
            : next.changeCooldown;
        availableAt = uint64(block.timestamp + cooldown);

        uint256 candidateUnlock = block.timestamp + next.lockDuration;
        unlockAt = currentUnlockAt;
        commitmentStartedAt = currentCommitmentStartedAt;

        if (block.timestamp >= currentUnlockAt) {
            commitmentStartedAt = uint64(block.timestamp);
            unlockAt = uint64(candidateUnlock);
            commitmentPenaltyBps = next.maxExitPenaltyBps;
        } else {
            if (candidateUnlock > currentUnlockAt) {
                commitmentStartedAt = uint64(block.timestamp);
                unlockAt = uint64(candidateUnlock);
            }
            commitmentPenaltyBps = currentPenaltyBps > next.maxExitPenaltyBps
                ? currentPenaltyBps
                : next.maxExitPenaltyBps;
        }
    }

    function allTiers() external view returns (TierConfig[] memory configs) {
        uint32 count = tierCount;
        configs = new TierConfig[](count);
        for (uint32 i; i < count; ++i) {
            configs[i] = _tiers[i];
        }
    }

    function _validateTier(
        uint64 lockDuration,
        uint64 changeCooldown,
        uint32 multiplierBps,
        uint16 maxExitPenaltyBps,
        uint128 minimumStake
    ) internal pure {
        if (multiplierBps < EchelonConstants.BPS || multiplierBps > 50_000) {
            revert InvalidTierMultiplier(multiplierBps);
        }
        if (lockDuration > 730 days) revert InvalidTierDuration(lockDuration);
        if (changeCooldown > 7 days) revert InvalidTierDuration(changeCooldown);
        if (maxExitPenaltyBps > EchelonConstants.MAX_EXIT_PENALTY_BPS) {
            revert InvalidTierPenalty(maxExitPenaltyBps);
        }
        if (minimumStake == 0) revert InvalidTierMinimum(minimumStake);
    }
}
