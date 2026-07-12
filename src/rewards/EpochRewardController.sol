// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IEchelonAccessManager } from "../interfaces/IEchelonAccessManager.sol";
import { IEpochRewardController } from "../interfaces/IEchelonModules.sol";
import { EpochConfig, EchelonConstants } from "../types/EchelonTypes.sol";
import { EpochMath } from "../libraries/EpochMath.sol";
import { RewardMath } from "../libraries/RewardMath.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidEpochDuration,
    EpochAlreadyConfigured,
    EpochNotConfigured,
    EpochAlreadyStarted,
    EpochNotEnded,
    EpochAlreadyFinalized,
    InvalidRewardBudget,
    InvalidRewardRate,
    EpochSyncLimitExceeded,
    RewardLiquidityInsufficient,
    VaultAlreadyConfigured,
    VaultNotConfigured,
    OnlyStakingVault,
    UnsupportedTokenBehavior,
    WeightAccountingMismatch,
    ContractPaused
} from "../errors/EchelonErrors.sol";

/// @title EpochRewardController
/// @notice Funds variable-rate reward epochs and maintains the global reward index.
contract EpochRewardController is IEpochRewardController {
    using SafeTransferLib for address;

    IERC20 public immutable rewardToken;
    IEchelonAccessManager public immutable accessManager;

    uint64 public immutable override genesis;
    uint64 public immutable override epochDuration;

    address public override stakingVault;
    bool public payoutsPaused;

    uint256 public override globalRewardIndex;
    uint256 public override totalRewardWeight;
    uint256 public lastUpdateTime;

    uint256 public override totalRewardsFunded;
    uint256 public totalRewardsConfigured;
    uint256 public totalRewardsEmitted;
    uint256 public override totalRewardsPaid;
    uint256 public skippedRewards;

    uint32 public highestConfiguredEpoch;
    bool public hasConfiguredEpoch;

    mapping(uint32 => EpochConfig) private _epochs;
    mapping(uint32 => bool) private _configured;
    mapping(uint32 => uint256) private _epochStartIndexes;
    mapping(uint32 => bool) private _epochIndexRecorded;

    event StakingVaultConfigured(address indexed stakingVault);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 totalFunded);
    event EpochConfigured(
        uint32 indexed epochId,
        uint64 startTime,
        uint64 endTime,
        uint256 rewardBudget,
        uint256 rewardRate
    );
    event EpochAvailabilityChanged(uint32 indexed epochId, bool enabled);
    event EpochFinalized(uint32 indexed epochId, uint256 emitted, uint256 unusedBudget);
    event GlobalIndexUpdated(
        uint32 indexed epochId,
        uint256 indexed timestamp,
        uint256 emitted,
        uint256 totalWeight,
        uint256 newIndex
    );
    event WeightChanged(uint256 previousWeight, uint256 newWeight, uint256 index);
    event RewardPaid(address indexed recipient, uint256 amount, uint256 cumulativePaid);
    event PayoutPauseChanged(bool paused);

    constructor(
        address rewardToken_,
        address accessManager_,
        uint64 genesis_,
        uint64 epochDuration_
    ) {
        if (rewardToken_ == address(0) || accessManager_ == address(0)) {
            revert ZeroAddress();
        }
        if (
            epochDuration_ < EchelonConstants.MIN_EPOCH_DURATION
                || epochDuration_ > EchelonConstants.MAX_EPOCH_DURATION
        ) {
            revert InvalidEpochDuration(epochDuration_);
        }

        rewardToken = IERC20(rewardToken_);
        accessManager = IEchelonAccessManager(accessManager_);
        genesis = genesis_;
        epochDuration = epochDuration_;
        lastUpdateTime = block.timestamp < genesis_ ? genesis_ : block.timestamp;
        _epochIndexRecorded[0] = true;
    }

    modifier onlyGovernor() {
        accessManager.checkRole(EchelonConstants.GOVERNOR_ROLE, msg.sender);
        _;
    }

    modifier onlyRewardManager() {
        if (
            !accessManager.hasRole(EchelonConstants.REWARD_MANAGER_ROLE, msg.sender)
                && !accessManager.hasRole(EchelonConstants.GOVERNOR_ROLE, msg.sender)
        ) {
            accessManager.checkRole(EchelonConstants.REWARD_MANAGER_ROLE, msg.sender);
        }
        _;
    }

    modifier onlyGuardian() {
        if (
            !accessManager.hasRole(EchelonConstants.GUARDIAN_ROLE, msg.sender)
                && !accessManager.hasRole(EchelonConstants.GOVERNOR_ROLE, msg.sender)
        ) {
            accessManager.checkRole(EchelonConstants.GUARDIAN_ROLE, msg.sender);
        }
        _;
    }

    modifier onlyVault() {
        if (stakingVault == address(0)) revert VaultNotConfigured();
        if (msg.sender != stakingVault) revert OnlyStakingVault(msg.sender);
        _;
    }

    function setStakingVault(address stakingVault_) external onlyGovernor {
        if (stakingVault_ == address(0)) revert ZeroAddress();
        if (stakingVault != address(0)) revert VaultAlreadyConfigured();
        stakingVault = stakingVault_;
        emit StakingVaultConfigured(stakingVault_);
    }

    function fundRewards(uint256 amount) external onlyRewardManager {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        address(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert UnsupportedTokenBehavior();
        totalRewardsFunded += received;
        emit RewardsFunded(msg.sender, received, totalRewardsFunded);
    }

    function configureEpoch(uint32 epochId, uint128 rewardBudget, uint128 rewardRate)
        external
        onlyRewardManager
    {
        if (_configured[epochId]) revert EpochAlreadyConfigured(epochId);
        if (rewardBudget == 0) revert InvalidRewardBudget(rewardBudget);
        if (rewardRate == 0) revert InvalidRewardRate(rewardRate);

        uint64 startTime = EpochMath.startOf(epochId, genesis, epochDuration);
        if (block.timestamp >= startTime) revert EpochAlreadyStarted(epochId);
        if (uint256(rewardRate) * epochDuration > rewardBudget) {
            revert InvalidRewardRate(rewardRate);
        }

        uint256 configuredAfter = totalRewardsConfigured + rewardBudget;
        if (configuredAfter > totalRewardsFunded) {
            revert RewardLiquidityInsufficient(configuredAfter, totalRewardsFunded);
        }

        uint64 endTime = EpochMath.endOf(epochId, genesis, epochDuration);
        _epochs[epochId] = EpochConfig({
            startTime: startTime,
            endTime: endTime,
            rewardBudget: rewardBudget,
            emittedRewards: 0,
            rewardRate: rewardRate,
            enabled: true,
            finalized: false
        });
        _configured[epochId] = true;
        if (!hasConfiguredEpoch || epochId > highestConfiguredEpoch) {
            highestConfiguredEpoch = epochId;
        }
        hasConfiguredEpoch = true;
        totalRewardsConfigured = configuredAfter;

        emit EpochConfigured(epochId, startTime, endTime, rewardBudget, rewardRate);
    }

    function setEpochEnabled(uint32 epochId, bool enabled) external onlyGuardian {
        if (!_configured[epochId]) revert EpochNotConfigured(epochId);
        if (block.timestamp >= _epochs[epochId].startTime) revert EpochAlreadyStarted(epochId);
        _epochs[epochId].enabled = enabled;
        emit EpochAvailabilityChanged(epochId, enabled);
    }

    function finalizeEpoch(uint32 epochId) external {
        if (!_configured[epochId]) revert EpochNotConfigured(epochId);
        EpochConfig storage config = _epochs[epochId];
        if (block.timestamp < config.endTime) revert EpochNotEnded(epochId);
        if (config.finalized) revert EpochAlreadyFinalized(epochId);

        _syncTo(block.timestamp);
        config.finalized = true;
        emit EpochFinalized(
            epochId, config.emittedRewards, uint256(config.rewardBudget) - config.emittedRewards
        );
    }

    function setPayoutsPaused(bool paused) external onlyGuardian {
        payoutsPaused = paused;
        emit PayoutPauseChanged(paused);
    }

    function epochAt(uint256 timestamp) public view override returns (uint32) {
        return EpochMath.epochAt(timestamp, genesis, epochDuration);
    }

    function currentEpoch() public view override returns (uint32) {
        if (block.timestamp < genesis) return 0;
        return EpochMath.epochAt(block.timestamp, genesis, epochDuration);
    }

    function epoch(uint32 epochId) external view override returns (EpochConfig memory) {
        if (!_configured[epochId]) revert EpochNotConfigured(epochId);
        return _epochs[epochId];
    }

    function isEpochConfigured(uint32 epochId) external view returns (bool) {
        return _configured[epochId];
    }

    function epochStartIndex(uint32 epochId) external view override returns (uint256) {
        if (!_epochIndexRecorded[epochId]) {
            if (epochId == currentEpoch()) return globalRewardIndex;
            revert EpochNotConfigured(epochId);
        }
        return _epochStartIndexes[epochId];
    }

    function rewardLiquidity() public view override returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    function sync() external override returns (uint256 index, uint32 epochId) {
        _syncTo(block.timestamp);
        return (globalRewardIndex, currentEpoch());
    }

    /// @notice Advances accounting by at most one epoch segment.
    /// @dev Keepers can call this repeatedly after an extended inactive period.
    function syncNextEpoch() external returns (uint256 index, uint256 reachedTimestamp) {
        uint256 cursor = lastUpdateTime;
        if (cursor < genesis) cursor = genesis;
        uint256 target = block.timestamp;

        if (target > cursor) {
            uint32 cursorEpoch = EpochMath.epochAt(cursor, genesis, epochDuration);
            uint256 boundary = EpochMath.endOf(cursorEpoch, genesis, epochDuration);
            if (target > boundary) target = boundary;
            _syncTo(target);
        }
        return (globalRewardIndex, lastUpdateTime);
    }

    function onWeightChange(uint256 oldWeight, uint256 newWeight)
        external
        override
        onlyVault
        returns (uint256 index, uint32 epochId)
    {
        _syncTo(block.timestamp);
        uint256 previousTotal = totalRewardWeight;
        if (oldWeight > previousTotal) {
            revert WeightAccountingMismatch(oldWeight, previousTotal);
        }
        totalRewardWeight = previousTotal - oldWeight + newWeight;
        emit WeightChanged(previousTotal, totalRewardWeight, globalRewardIndex);
        return (globalRewardIndex, currentEpoch());
    }

    function payReward(address recipient, uint256 amount) external override onlyVault {
        if (payoutsPaused) revert ContractPaused();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        _syncTo(block.timestamp);
        uint256 available = rewardLiquidity();
        if (amount > available) revert RewardLiquidityInsufficient(amount, available);

        totalRewardsPaid += amount;
        address(rewardToken).safeTransfer(recipient, amount);
        emit RewardPaid(recipient, amount, totalRewardsPaid);
    }

    function previewGlobalRewardIndex(uint256 timestamp) external view returns (uint256 index) {
        index = globalRewardIndex;
        if (timestamp <= lastUpdateTime || totalRewardWeight == 0) return index;

        uint256 cursor = lastUpdateTime;
        if (cursor < genesis) cursor = genesis;
        if (timestamp <= cursor) return index;

        uint32 traversed;
        while (cursor < timestamp) {
            if (++traversed > EchelonConstants.MAX_EPOCHS_PER_SYNC) {
                revert EpochSyncLimitExceeded(traversed);
            }
            uint32 epochId = EpochMath.epochAt(cursor, genesis, epochDuration);
            uint256 end = EpochMath.segmentEnd(timestamp, epochId, genesis, epochDuration);

            if (_configured[epochId] && _epochs[epochId].enabled) {
                EpochConfig memory config = _epochs[epochId];
                uint256 remaining = uint256(config.rewardBudget) - config.emittedRewards;
                uint256 emission =
                    RewardMath.emittedForSegment(config.rewardRate, end - cursor, remaining);
                index += RewardMath.indexDelta(emission, totalRewardWeight);
            }
            cursor = end;
        }
    }

    function _syncTo(uint256 timestamp) internal {
        if (timestamp <= lastUpdateTime) return;

        uint256 cursor = lastUpdateTime;
        if (cursor < genesis) cursor = genesis;
        if (timestamp <= cursor) return;

        uint32 traversed;
        while (cursor < timestamp) {
            if (++traversed > EchelonConstants.MAX_EPOCHS_PER_SYNC) {
                revert EpochSyncLimitExceeded(traversed);
            }

            uint32 epochId = EpochMath.epochAt(cursor, genesis, epochDuration);
            uint256 end = EpochMath.segmentEnd(timestamp, epochId, genesis, epochDuration);
            uint256 emission;

            if (_configured[epochId] && _epochs[epochId].enabled) {
                EpochConfig storage config = _epochs[epochId];
                uint256 remaining = uint256(config.rewardBudget) - config.emittedRewards;
                emission = RewardMath.emittedForSegment(config.rewardRate, end - cursor, remaining);

                if (emission != 0) {
                    config.emittedRewards += uint128(emission);
                    totalRewardsEmitted += emission;
                    if (totalRewardWeight == 0) {
                        skippedRewards += emission;
                    } else {
                        globalRewardIndex += RewardMath.indexDelta(emission, totalRewardWeight);
                    }
                }
            }

            emit GlobalIndexUpdated(epochId, end, emission, totalRewardWeight, globalRewardIndex);
            cursor = end;

            if (cursor == EpochMath.endOf(epochId, genesis, epochDuration)) {
                uint32 nextEpoch = epochId + 1;
                _epochStartIndexes[nextEpoch] = globalRewardIndex;
                _epochIndexRecorded[nextEpoch] = true;
            }
        }

        lastUpdateTime = timestamp;
    }
}
