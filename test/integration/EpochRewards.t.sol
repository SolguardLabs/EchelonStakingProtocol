// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonTestBase } from "../helpers/EchelonTestBase.sol";

import { EchelonStakingVault } from "../../src/staking/EchelonStakingVault.sol";
import { EpochRewardController } from "../../src/rewards/EpochRewardController.sol";
import { StakePositionToken } from "../../src/positions/StakePositionToken.sol";
import { PenaltyReserve } from "../../src/treasury/PenaltyReserve.sol";
import { EpochConfig, StakePosition } from "../../src/types/EchelonTypes.sol";
import {
    EpochAlreadyConfigured,
    EpochAlreadyStarted,
    InvalidEpochDuration,
    InvalidRewardBudget,
    InvalidRewardRate,
    EpochSyncLimitExceeded,
    RewardLiquidityInsufficient
} from "../../src/errors/EchelonErrors.sol";

/// @notice Public integration coverage for epoch emissions and position rewards.
contract EpochRewardsTest is EchelonTestBase {
    uint64 internal constant SAMPLE_WINDOW = 1 days;

    function test_rewardsAreDistributedProRataAcrossPositions() public {
        uint256 alicePosition = _stakeAs(ALICE, 100 ether, FLEX_TIER);
        uint256 bobPosition = _stakeAs(BOB, 300 ether, FLEX_TIER);

        _warpIntoEpoch(0, SAMPLE_WINDOW);

        uint256 aliceReward = _claimAs(ALICE, alicePosition);
        uint256 bobReward = _claimAs(BOB, bobPosition);
        uint256 emitted = uint256(REWARD_RATE) * SAMPLE_WINDOW;

        assertEq(aliceReward, emitted / 4, "alice receives one quarter");
        assertEq(bobReward, emitted * 3 / 4, "bob receives three quarters");
        assertEq(aliceReward + bobReward, emitted, "all emitted rewards are allocated");
        assertEq(rewardController.totalRewardsPaid(), emitted);
    }

    function test_tierWeightsApplyFromTheBeginningOfAnEpoch() public {
        uint256 alicePosition = _stakeAs(ALICE, 400 ether, FLEX_TIER);
        uint256 bobPosition = _stakeAs(BOB, 400 ether, GOLD_TIER);
        StakePosition memory aliceStake = _position(alicePosition);
        StakePosition memory bobStake = _position(bobPosition);

        _warpIntoEpoch(0, SAMPLE_WINDOW);

        uint256 aliceReward = _claimAs(ALICE, alicePosition);
        uint256 bobReward = _claimAs(BOB, bobPosition);
        uint256 emitted = uint256(REWARD_RATE) * SAMPLE_WINDOW;
        uint256 totalWeight = aliceStake.rewardWeight + bobStake.rewardWeight;
        uint256 expectedAlice = emitted * aliceStake.rewardWeight / totalWeight;
        uint256 expectedBob = emitted * bobStake.rewardWeight / totalWeight;

        assertApproxEqAbs(aliceReward, expectedAlice, 1, "flex reward follows its weight");
        assertApproxEqAbs(bobReward, expectedBob, 1, "gold reward follows its weight");
        assertApproxEqAbs(aliceReward + bobReward, emitted, 1, "emission remains conserved");
        assertGt(bobReward, aliceReward, "larger tier weight earns more");
    }

    function test_lateStakeOnlySharesRewardsAfterJoining() public {
        uint256 alicePosition = _stakeAs(ALICE, 200 ether, FLEX_TIER);

        _warpIntoEpoch(0, 12 hours);
        uint256 bobPosition = _stakeAs(BOB, 200 ether, FLEX_TIER);
        _warpIntoEpoch(0, SAMPLE_WINDOW);

        uint256 aliceReward = _claimAs(ALICE, alicePosition);
        uint256 bobReward = _claimAs(BOB, bobPosition);
        uint256 firstHalfEmission = uint256(REWARD_RATE) * 12 hours;
        uint256 secondHalfEmission = uint256(REWARD_RATE) * 12 hours;

        assertEq(
            aliceReward,
            firstHalfEmission + secondHalfEmission / 2,
            "incumbent earns alone before the join"
        );
        assertEq(bobReward, secondHalfEmission / 2, "late stake starts at its checkpoint");
        assertEq(aliceReward + bobReward, firstHalfEmission + secondHalfEmission);
    }

    function test_secondClaimAtSameTimestampPaysZero() public {
        uint256 positionId = _stakeAs(ALICE, 500 ether, SILVER_TIER);
        _warpIntoEpoch(0, 6 hours);

        uint256 firstReward = _claimAs(ALICE, positionId);
        uint256 secondReward = _claimAs(ALICE, positionId);

        assertApproxEqAbs(firstReward, uint256(REWARD_RATE) * 6 hours, 1);
        assertEq(secondReward, 0, "checkpoint prevents duplicate payout");
        assertEq(rewardToken.balanceOf(ALICE), firstReward);

        _warpIntoEpoch(0, 9 hours);
        uint256 laterReward = _claimAs(ALICE, positionId);

        assertApproxEqAbs(laterReward, uint256(REWARD_RATE) * 3 hours, 1);
        assertEq(rewardToken.balanceOf(ALICE), firstReward + laterReward);
    }

    function test_claimAcrossEpochsUsesEachEpochRate() public {
        uint128 firstRate = 1 ether;
        uint128 secondRate = 3 ether;
        _deployVariableRateSystem(firstRate, secondRate);
        uint256 positionId = _stakeAs(ALICE, 500 ether, BRONZE_TIER);

        vm.warp(uint256(genesis) + EPOCH_DURATION + SAMPLE_WINDOW);
        uint256 reward = _claimAs(ALICE, positionId);
        uint256 expected = uint256(firstRate) * EPOCH_DURATION + uint256(secondRate) * SAMPLE_WINDOW;

        EpochConfig memory firstEpoch = rewardController.epoch(0);
        EpochConfig memory secondEpoch = rewardController.epoch(1);
        assertEq(reward, expected, "claim includes both epoch schedules");
        assertEq(firstEpoch.emittedRewards, uint256(firstRate) * EPOCH_DURATION);
        assertEq(secondEpoch.emittedRewards, uint256(secondRate) * SAMPLE_WINDOW);
        assertEq(rewardController.totalRewardsPaid(), expected);
    }

    function test_emissionWithoutStakersIsRecordedAsSkipped() public {
        _warpIntoEpoch(0, SAMPLE_WINDOW);
        uint256 positionId = _stakeAs(ALICE, 300 ether, FLEX_TIER);
        uint256 firstWindowEmission = uint256(REWARD_RATE) * SAMPLE_WINDOW;

        assertEq(rewardController.totalRewardsEmitted(), firstWindowEmission);
        assertEq(rewardController.skippedRewards(), firstWindowEmission);
        assertEq(vault.pendingRewards(positionId), 0, "new position starts clean");

        _warpIntoEpoch(0, SAMPLE_WINDOW * 2);
        uint256 reward = _claimAs(ALICE, positionId);

        assertEq(reward, firstWindowEmission, "position earns only after joining");
        assertEq(rewardController.skippedRewards(), firstWindowEmission);
        assertEq(rewardController.totalRewardsEmitted(), firstWindowEmission * 2);
    }

    function test_epochConfigurationStoresBoundariesAndSchedule() public view {
        EpochConfig memory firstEpoch = rewardController.epoch(0);
        EpochConfig memory secondEpoch = rewardController.epoch(1);

        assertEq(firstEpoch.startTime, genesis);
        assertEq(firstEpoch.endTime, uint256(genesis) + EPOCH_DURATION);
        assertEq(firstEpoch.rewardBudget, EPOCH_BUDGET);
        assertEq(firstEpoch.rewardRate, REWARD_RATE);
        assertTrue(firstEpoch.enabled);
        assertFalse(firstEpoch.finalized);

        assertEq(secondEpoch.startTime, uint256(genesis) + EPOCH_DURATION);
        assertEq(secondEpoch.endTime, uint256(genesis) + EPOCH_DURATION * 2);
        assertEq(rewardController.highestConfiguredEpoch(), 2);
        assertEq(rewardController.totalRewardsConfigured(), TOTAL_REWARD_FUNDING);
    }

    function test_epochConfigurationRejectsDuplicatesAndAllowsFutureGaps() public {
        vm.prank(REWARD_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(EpochAlreadyConfigured.selector, uint32(0)));
        rewardController.configureEpoch(0, EPOCH_BUDGET, REWARD_RATE);

        rewardToken.mint(REWARD_MANAGER, EPOCH_BUDGET);
        vm.startPrank(REWARD_MANAGER);
        rewardToken.approve(address(rewardController), EPOCH_BUDGET);
        rewardController.fundRewards(EPOCH_BUDGET);
        rewardController.configureEpoch(4, EPOCH_BUDGET, REWARD_RATE);
        vm.stopPrank();

        EpochConfig memory futureEpoch = rewardController.epoch(4);
        assertEq(futureEpoch.startTime, uint256(genesis) + EPOCH_DURATION * 4);
        assertEq(rewardController.highestConfiguredEpoch(), 4);

        vm.warp(uint256(genesis) + uint256(EPOCH_DURATION) * 3);
        vm.prank(REWARD_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(EpochAlreadyStarted.selector, uint32(3)));
        rewardController.configureEpoch(3, EPOCH_BUDGET, REWARD_RATE);
    }

    function test_epochConfigurationValidatesBudgetRateAndLiquidity() public {
        vm.startPrank(REWARD_MANAGER);

        vm.expectRevert(abi.encodeWithSelector(InvalidRewardBudget.selector, uint256(0)));
        rewardController.configureEpoch(3, 0, REWARD_RATE);

        uint128 excessiveRate = REWARD_RATE + 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidRewardRate.selector, uint256(excessiveRate)));
        rewardController.configureEpoch(3, EPOCH_BUDGET, excessiveRate);

        vm.expectRevert(
            abi.encodeWithSelector(
                RewardLiquidityInsufficient.selector,
                TOTAL_REWARD_FUNDING + EPOCH_BUDGET,
                TOTAL_REWARD_FUNDING
            )
        );
        rewardController.configureEpoch(3, EPOCH_BUDGET, REWARD_RATE);

        vm.stopPrank();
    }

    function test_epochCannotBeConfiguredAfterItsStart() public {
        uint64 isolatedGenesis = uint64(block.timestamp + 2 days);
        EpochRewardController isolated = new EpochRewardController(
            address(rewardToken), address(accessManager), isolatedGenesis, EPOCH_DURATION
        );
        vm.warp(isolatedGenesis);

        vm.prank(REWARD_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(EpochAlreadyStarted.selector, uint32(0)));
        isolated.configureEpoch(0, EPOCH_BUDGET, REWARD_RATE);
    }

    function test_epochDurationMustStayWithinProtocolBounds() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidEpochDuration.selector, uint256(1 hours - 1)));
        new EpochRewardController(
            address(rewardToken), address(accessManager), genesis, uint64(1 hours - 1)
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidEpochDuration.selector, uint256(30 days + 1)));
        new EpochRewardController(
            address(rewardToken), address(accessManager), genesis, uint64(30 days + 1)
        );
    }

    function test_syncTraversalIsBounded() public {
        vm.warp(uint256(genesis) + uint256(EPOCH_DURATION) * 65);

        vm.expectRevert(abi.encodeWithSelector(EpochSyncLimitExceeded.selector, uint32(65)));
        rewardController.sync();
    }

    function test_syncNextEpochAllowsBoundedCatchUpAfterLongInactivity() public {
        uint256 target = uint256(genesis) + uint256(EPOCH_DURATION) * 65;
        vm.warp(target);

        vm.expectRevert(abi.encodeWithSelector(EpochSyncLimitExceeded.selector, uint32(65)));
        rewardController.sync();

        for (uint256 i; i < 65; ++i) {
            (, uint256 reachedTimestamp) = rewardController.syncNextEpoch();
            assertLe(reachedTimestamp, target, "keeper step cannot overshoot");
        }

        assertEq(rewardController.lastUpdateTime(), target, "controller catches up exactly");
        rewardController.sync();
    }

    function _claimAs(address owner, uint256 positionId) internal returns (uint256 reward) {
        vm.prank(owner);
        reward = vault.claim(positionId, owner);
    }

    function _deployVariableRateSystem(uint128 firstRate, uint128 secondRate) internal {
        genesis = uint64(block.timestamp + 1 days);
        positionToken = new StakePositionToken(
            "Echelon Variable Position", "eVAR", address(accessManager), "ipfs://echelon/variable/"
        );
        penaltyReserve = new PenaltyReserve(address(stakingToken), address(accessManager), TREASURY);
        rewardController = new EpochRewardController(
            address(rewardToken), address(accessManager), genesis, EPOCH_DURATION
        );
        vault = new EchelonStakingVault(
            address(stakingToken),
            address(rewardToken),
            address(accessManager),
            address(tierRegistry),
            address(rewardController),
            address(positionToken),
            address(penaltyReserve)
        );

        positionToken.setStakingVault(address(vault));
        rewardController.setStakingVault(address(vault));
        penaltyReserve.setStakingVault(address(vault));

        uint128 firstBudget = uint128(uint256(firstRate) * EPOCH_DURATION);
        uint128 secondBudget = uint128(uint256(secondRate) * EPOCH_DURATION);
        uint256 totalFunding = uint256(firstBudget) + secondBudget;
        rewardToken.mint(REWARD_MANAGER, totalFunding);

        vm.startPrank(REWARD_MANAGER);
        rewardToken.approve(address(rewardController), totalFunding);
        rewardController.fundRewards(totalFunding);
        rewardController.configureEpoch(0, firstBudget, firstRate);
        rewardController.configureEpoch(1, secondBudget, secondRate);
        vm.stopPrank();

        vm.prank(ALICE);
        stakingToken.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        stakingToken.approve(address(vault), type(uint256).max);
    }
}
