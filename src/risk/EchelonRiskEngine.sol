// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonStakingVault } from "../staking/EchelonStakingVault.sol";
import { EpochRewardController } from "../rewards/EpochRewardController.sol";
import { EpochConfig, StakePosition } from "../types/EchelonTypes.sol";
import { FullMath } from "../libraries/FullMath.sol";
import { RiskMath } from "../libraries/RiskMath.sol";
import { ZeroAddress } from "../errors/EchelonErrors.sol";

error InvalidRiskPolicy();
error EmptyPositionSet();
error PositionSetTooLarge(uint256 supplied, uint256 maximum);
error PositionIdsNotOrdered(uint256 previous, uint256 current);

/// @title EchelonRiskEngine
/// @notice Read-only capital, runway, stress, epoch, and concentration analytics.
contract EchelonRiskEngine {
    using RiskMath for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_POSITION_SET = 128;
    uint256 public constant MAX_EPOCH_WINDOW = 32;

    EchelonStakingVault public immutable vault;
    EpochRewardController public immutable rewardController;

    enum RiskBand {
        Healthy,
        Watch,
        Constrained,
        Paused
    }

    struct RiskPolicy {
        uint32 minimumCoverageBps;
        uint32 maximumPayoutUtilizationBps;
        uint16 stressHaircutBps;
        uint64 minimumRunwaySeconds;
    }

    struct RewardCapitalSnapshot {
        uint256 rewardLiquidity;
        uint256 funded;
        uint256 configured;
        uint256 emitted;
        uint256 paid;
        uint256 skipped;
        uint256 unpaidEmitted;
        uint256 scheduledRemaining;
        uint256 totalObligations;
        uint256 unallocatedLiquidity;
        uint256 activeRewardRate;
        uint256 runwaySeconds;
        uint256 coverageBps;
        uint256 payoutUtilizationBps;
        uint32 currentEpoch;
        bool currentEpochEnabled;
        bool payoutsPaused;
    }

    struct StressReport {
        RewardCapitalSnapshot capital;
        uint256 stressedLiquidity;
        uint256 stressedCoverageBps;
        uint256 capacityAtTarget;
        RiskBand band;
    }

    struct PortfolioReport {
        uint256 positions;
        uint256 totalPrincipal;
        uint256 totalRewardWeight;
        uint256 largestRewardWeight;
        uint256 largestShareBps;
        uint256 concentrationHhi;
    }

    constructor(address vault_, address rewardController_) {
        if (vault_ == address(0) || rewardController_ == address(0)) revert ZeroAddress();
        vault = EchelonStakingVault(vault_);
        rewardController = EpochRewardController(rewardController_);
    }

    function capitalSnapshot() public view returns (RewardCapitalSnapshot memory report) {
        report.rewardLiquidity = rewardController.rewardLiquidity();
        report.funded = rewardController.totalRewardsFunded();
        report.configured = rewardController.totalRewardsConfigured();
        report.emitted = rewardController.totalRewardsEmitted();
        report.paid = rewardController.totalRewardsPaid();
        report.skipped = rewardController.skippedRewards();

        uint256 eligibleEmission = report.emitted.saturatingSub(report.skipped);
        report.unpaidEmitted = eligibleEmission.saturatingSub(report.paid);
        report.scheduledRemaining = report.configured.saturatingSub(report.emitted);
        report.totalObligations = report.unpaidEmitted + report.scheduledRemaining;
        report.unallocatedLiquidity = report.rewardLiquidity.saturatingSub(report.totalObligations);
        report.coverageBps = report.totalObligations == 0
            ? BPS
            : report.rewardLiquidity.ratioBps(report.totalObligations);
        report.payoutUtilizationBps = report.paid.ratioBps(report.funded);
        report.currentEpoch = rewardController.currentEpoch();
        report.payoutsPaused = rewardController.payoutsPaused();

        if (rewardController.isEpochConfigured(report.currentEpoch)) {
            EpochConfig memory config = rewardController.epoch(report.currentEpoch);
            report.currentEpochEnabled = config.enabled;
            if (
                config.enabled && block.timestamp >= config.startTime
                    && block.timestamp < config.endTime
            ) {
                report.activeRewardRate = config.rewardRate;
                report.runwaySeconds = report.activeRewardRate == 0
                    ? 0
                    : report.rewardLiquidity / report.activeRewardRate;
            }
        }
    }

    function assess(RiskPolicy calldata policy) external view returns (StressReport memory report) {
        _validatePolicy(policy);
        report.capital = capitalSnapshot();
        report.stressedLiquidity =
            report.capital.rewardLiquidity.applyHaircut(policy.stressHaircutBps);
        report.stressedCoverageBps = report.capital.totalObligations == 0
            ? BPS
            : report.stressedLiquidity.ratioBps(report.capital.totalObligations);
        report.capacityAtTarget = RiskMath.headroom(
            report.stressedLiquidity, report.capital.totalObligations, policy.minimumCoverageBps
        );

        if (report.capital.payoutsPaused) {
            report.band = RiskBand.Paused;
        } else if (
            report.stressedCoverageBps < policy.minimumCoverageBps
                || (report.capital.activeRewardRate != 0
                    && report.capital.runwaySeconds < policy.minimumRunwaySeconds)
        ) {
            report.band = RiskBand.Constrained;
        } else if (
            report.capital.payoutUtilizationBps > policy.maximumPayoutUtilizationBps
                || report.stressedLiquidity < report.capital.totalObligations
        ) {
            report.band = RiskBand.Watch;
        } else {
            report.band = RiskBand.Healthy;
        }
    }

    function epochWindow(uint32 firstEpoch, uint32 count)
        external
        view
        returns (
            uint256 totalBudget,
            uint256 totalEmitted,
            uint256 totalRemaining,
            uint256 weightedRateSeconds
        )
    {
        if (count == 0 || count > MAX_EPOCH_WINDOW) {
            revert InvalidRiskPolicy();
        }
        for (uint32 offset; offset < count; ++offset) {
            uint32 epochId = firstEpoch + offset;
            if (!rewardController.isEpochConfigured(epochId)) continue;
            EpochConfig memory config = rewardController.epoch(epochId);
            totalBudget += config.rewardBudget;
            totalEmitted += config.emittedRewards;
            totalRemaining += uint256(config.rewardBudget) - config.emittedRewards;
            if (config.enabled) {
                weightedRateSeconds += uint256(config.rewardRate)
                * (uint256(config.endTime) - config.startTime);
            }
        }
    }

    function positionPortfolio(uint256[] calldata positionIds)
        external
        view
        returns (PortfolioReport memory report)
    {
        uint256 length = positionIds.length;
        if (length == 0) revert EmptyPositionSet();
        if (length > MAX_POSITION_SET) revert PositionSetTooLarge(length, MAX_POSITION_SET);

        uint256[] memory weights = new uint256[](length);
        uint256 previous;
        for (uint256 i; i < length; ++i) {
            uint256 positionId = positionIds[i];
            if (i != 0 && positionId <= previous) {
                revert PositionIdsNotOrdered(previous, positionId);
            }
            StakePosition memory stakePosition = vault.position(positionId);
            report.totalPrincipal += stakePosition.principal;
            report.totalRewardWeight += stakePosition.rewardWeight;
            if (stakePosition.rewardWeight > report.largestRewardWeight) {
                report.largestRewardWeight = stakePosition.rewardWeight;
            }
            weights[i] = stakePosition.rewardWeight;
            previous = positionId;
        }

        report.positions = length;
        if (report.totalRewardWeight == 0) return report;
        report.largestShareBps =
            FullMath.mulDiv(report.largestRewardWeight, BPS, report.totalRewardWeight);
        for (uint256 i; i < length; ++i) {
            uint256 shareBps = FullMath.mulDiv(weights[i], BPS, report.totalRewardWeight);
            report.concentrationHhi += shareBps * shareBps;
        }
    }

    function _validatePolicy(RiskPolicy calldata policy) internal pure {
        if (
            policy.minimumCoverageBps < BPS || policy.minimumCoverageBps > 100_000
                || policy.maximumPayoutUtilizationBps > BPS || policy.stressHaircutBps >= BPS
                || policy.minimumRunwaySeconds == 0
        ) {
            revert InvalidRiskPolicy();
        }
    }
}
