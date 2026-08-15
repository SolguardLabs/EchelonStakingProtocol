// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonTestBase } from "../helpers/EchelonTestBase.sol";
import {
    EchelonRiskEngine,
    InvalidRiskPolicy,
    EmptyPositionSet,
    PositionIdsNotOrdered
} from "../../src/risk/EchelonRiskEngine.sol";

contract EchelonRiskEngineTest is EchelonTestBase {
    EchelonRiskEngine internal riskEngine;

    function setUp() public override {
        super.setUp();
        riskEngine = new EchelonRiskEngine(address(vault), address(rewardController));
    }

    function test_capitalSnapshotSeparatesLiquidityAndScheduledObligations() public view {
        EchelonRiskEngine.RewardCapitalSnapshot memory report = riskEngine.capitalSnapshot();

        assertEq(report.rewardLiquidity, TOTAL_REWARD_FUNDING);
        assertEq(report.funded, TOTAL_REWARD_FUNDING);
        assertEq(report.configured, TOTAL_REWARD_FUNDING);
        assertEq(report.scheduledRemaining, TOTAL_REWARD_FUNDING);
        assertEq(report.totalObligations, TOTAL_REWARD_FUNDING);
        assertEq(report.coverageBps, 10_000);
        assertEq(report.unallocatedLiquidity, 0);
    }

    function test_snapshotTracksEmissionAndUnpaidRewards() public {
        _stakeAs(ALICE, 1000 ether, FLEX_TIER);
        _warpIntoEpoch(0, 1 days);
        rewardController.sync();

        EchelonRiskEngine.RewardCapitalSnapshot memory report = riskEngine.capitalSnapshot();
        assertEq(report.emitted, 86_400 ether);
        assertEq(report.unpaidEmitted, 86_400 ether);
        assertEq(report.scheduledRemaining, TOTAL_REWARD_FUNDING - 86_400 ether);
        assertEq(report.totalObligations, TOTAL_REWARD_FUNDING);
        assertEq(report.activeRewardRate, REWARD_RATE);
    }

    function test_snapshotCalculatesRunwayAtActiveRate() public {
        _stakeAs(ALICE, 100 ether, FLEX_TIER);
        _warpIntoEpoch(0, 1 hours);

        EchelonRiskEngine.RewardCapitalSnapshot memory report = riskEngine.capitalSnapshot();
        assertEq(report.activeRewardRate, REWARD_RATE);
        assertEq(report.runwaySeconds, TOTAL_REWARD_FUNDING / REWARD_RATE);
    }

    function test_assessReturnsHealthyForFullyBackedSchedule() public view {
        EchelonRiskEngine.StressReport memory report = riskEngine.assess(_policy(10_000, 9000, 0));
        assertEq(uint256(report.band), uint256(EchelonRiskEngine.RiskBand.Healthy));
        assertEq(report.stressedCoverageBps, 10_000);
    }

    function test_assessReturnsConstrainedAfterStressHaircut() public view {
        EchelonRiskEngine.StressReport memory report =
            riskEngine.assess(_policy(10_000, 9000, 2000));
        assertEq(uint256(report.band), uint256(EchelonRiskEngine.RiskBand.Constrained));
        assertEq(report.stressedCoverageBps, 8000);
        assertEq(report.capacityAtTarget, 0);
    }

    function test_assessReturnsPausedWhenPayoutsArePaused() public {
        vm.prank(GUARDIAN);
        rewardController.setPayoutsPaused(true);

        EchelonRiskEngine.StressReport memory report = riskEngine.assess(_policy(10_000, 9000, 0));
        assertEq(uint256(report.band), uint256(EchelonRiskEngine.RiskBand.Paused));
    }

    function test_assessRejectsInvalidPolicy() public {
        EchelonRiskEngine.RiskPolicy memory policy = _policy(9999, 9000, 0);
        vm.expectRevert(InvalidRiskPolicy.selector);
        riskEngine.assess(policy);
    }

    function test_epochWindowAggregatesConfiguredSchedules() public view {
        (uint256 budget, uint256 emitted, uint256 remaining, uint256 rateSeconds) =
            riskEngine.epochWindow(0, 3);

        assertEq(budget, TOTAL_REWARD_FUNDING);
        assertEq(emitted, 0);
        assertEq(remaining, TOTAL_REWARD_FUNDING);
        assertEq(rateSeconds, TOTAL_REWARD_FUNDING);
    }

    function test_positionPortfolioCalculatesWeightConcentration() public {
        uint256 first = _stakeAs(ALICE, 100 ether, FLEX_TIER);
        uint256 second = _stakeAs(BOB, 100 ether, FLEX_TIER);
        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;

        EchelonRiskEngine.PortfolioReport memory report = riskEngine.positionPortfolio(ids);
        assertEq(report.positions, 2);
        assertEq(report.totalPrincipal, 200 ether);
        assertEq(report.largestShareBps, 5000);
        assertEq(report.concentrationHhi, 50_000_000);
    }

    function test_positionPortfolioRejectsEmptyAndUnorderedSets() public {
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(EmptyPositionSet.selector);
        riskEngine.positionPortfolio(empty);

        uint256 first = _stakeAs(ALICE, 100 ether, FLEX_TIER);
        uint256 second = _stakeAs(BOB, 100 ether, FLEX_TIER);
        uint256[] memory unordered = new uint256[](2);
        unordered[0] = second;
        unordered[1] = first;
        vm.expectRevert(abi.encodeWithSelector(PositionIdsNotOrdered.selector, second, first));
        riskEngine.positionPortfolio(unordered);
    }

    function _policy(uint32 coverage, uint32 utilization, uint16 haircut)
        internal
        pure
        returns (EchelonRiskEngine.RiskPolicy memory)
    {
        return EchelonRiskEngine.RiskPolicy({
            minimumCoverageBps: coverage,
            maximumPayoutUtilizationBps: utilization,
            stressHaircutBps: haircut,
            minimumRunwaySeconds: 1 days
        });
    }
}
