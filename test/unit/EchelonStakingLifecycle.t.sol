// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonTestBase } from "../helpers/EchelonTestBase.sol";
import { StakePosition, PositionPreview, PositionStatus } from "../../src/types/EchelonTypes.sol";
import {
    ZeroAmount,
    PositionBelowMinimum,
    PenaltyExceedsLimit,
    TokenDoesNotExist
} from "../../src/errors/EchelonErrors.sol";

contract EchelonStakingLifecycleTest is EchelonTestBase {
    function test_stakeCreatesWeightedPositionAndMintsReceipt() public {
        uint256 amount = 1000 ether;
        uint256 aliceBefore = stakingToken.balanceOf(ALICE);
        uint256 expectedWeight = tierRegistry.calculateWeight(amount, SILVER_TIER);
        uint256 expectedUnlock = block.timestamp + 90 days;

        uint256 positionId = _stakeFor(ALICE, BOB, amount, SILVER_TIER);
        StakePosition memory stakePosition = _position(positionId);

        assertEq(positionId, 1);
        assertEq(vault.nextPositionId(), 2);
        assertEq(positionToken.ownerOf(positionId), BOB);
        assertEq(positionToken.balanceOf(BOB), 1);
        assertEq(positionToken.totalSupply(), 1);
        assertEq(stakePosition.principal, amount);
        assertEq(stakePosition.rewardWeight, expectedWeight);
        assertEq(stakePosition.tierId, SILVER_TIER);
        assertEq(stakePosition.createdAt, block.timestamp);
        assertEq(stakePosition.commitmentStartedAt, block.timestamp);
        assertEq(stakePosition.unlockAt, expectedUnlock);
        assertEq(uint8(stakePosition.status), uint8(PositionStatus.Active));
        assertEq(vault.totalPrincipal(), amount);
        assertEq(rewardController.totalRewardWeight(), expectedWeight);
        assertEq(stakingToken.balanceOf(ALICE), aliceBefore - amount);
        assertEq(stakingToken.balanceOf(address(vault)), amount);
        assertTrue(vault.principalSolvent());
    }

    function test_stakeSupportsEveryConfiguredTier() public {
        uint256 amount = 500 ether;

        uint256 flexible = _stakeAs(ALICE, amount, FLEX_TIER);
        uint256 bronze = _stakeAs(ALICE, amount, BRONZE_TIER);
        uint256 silver = _stakeAs(BOB, amount, SILVER_TIER);
        uint256 gold = _stakeAs(CAROL, amount, GOLD_TIER);

        assertEq(_position(flexible).rewardWeight, 500 ether);
        assertEq(_position(bronze).rewardWeight, 625 ether);
        assertEq(_position(silver).rewardWeight, 875 ether);
        assertEq(_position(gold).rewardWeight, 1250 ether);
        assertEq(vault.totalPrincipal(), amount * 4);
        assertEq(rewardController.totalRewardWeight(), 3250 ether);
        assertEq(positionToken.totalSupply(), 4);
    }

    function test_stakeRejectsZeroAndBelowTierMinimum() public {
        vm.startPrank(ALICE);

        vm.expectRevert(ZeroAmount.selector);
        vault.stake(0, FLEX_TIER, ALICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                PositionBelowMinimum.selector, uint256(MINIMUM_STAKE) - 1, MINIMUM_STAKE
            )
        );
        vault.stake(uint256(MINIMUM_STAKE) - 1, GOLD_TIER, ALICE);

        vm.stopPrank();
    }

    function test_increasePositionAccruesExistingWeightThenUpdatesPrincipal() public {
        uint256 initialAmount = 1000 ether;
        uint256 increaseAmount = 400 ether;
        uint256 positionId = _stakeAs(ALICE, initialAmount, SILVER_TIER);

        _warpIntoEpoch(0, 1 days);
        uint256 balanceBefore = stakingToken.balanceOf(ALICE);

        vm.prank(ALICE);
        vault.increasePosition(positionId, increaseAmount);

        StakePosition memory stakePosition = _position(positionId);
        uint256 expectedWeight =
            tierRegistry.calculateWeight(initialAmount + increaseAmount, SILVER_TIER);

        assertEq(stakePosition.principal, initialAmount + increaseAmount);
        assertEq(stakePosition.rewardWeight, expectedWeight);
        uint256 expectedAccrual = 1 days * uint256(REWARD_RATE);
        assertApproxEqAbs(stakePosition.rewards.carriedReward, expectedAccrual, 1);
        assertEq(stakePosition.rewards.lastCheckpoint, block.timestamp);
        assertApproxEqAbs(vault.pendingRewards(positionId), expectedAccrual, 1);
        assertEq(vault.totalPrincipal(), initialAmount + increaseAmount);
        assertEq(rewardController.totalRewardWeight(), expectedWeight);
        assertEq(stakingToken.balanceOf(ALICE), balanceBefore - increaseAmount);
        assertEq(stakingToken.balanceOf(address(vault)), initialAmount + increaseAmount);
    }

    function test_increasePositionRenewsCurrentTierCommitment() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, GOLD_TIER);
        StakePosition memory beforeIncrease = _position(positionId);

        vm.warp(block.timestamp + 10 days);
        uint64 increasedAt = uint64(block.timestamp);
        vm.prank(ALICE);
        vault.increasePosition(positionId, 250 ether);

        StakePosition memory afterIncrease = _position(positionId);
        assertEq(afterIncrease.commitmentStartedAt, increasedAt);
        assertEq(afterIncrease.unlockAt, increasedAt + 365 days);
        assertGt(afterIncrease.unlockAt, beforeIncrease.unlockAt);
        assertEq(afterIncrease.commitmentPenaltyBps, beforeIncrease.commitmentPenaltyBps);
        assertEq(afterIncrease.lastTierChange, beforeIncrease.lastTierChange);
    }

    function test_earlyUnstakeRoutesLinearPenaltyToReserve() public {
        uint256 amount = 1000 ether;
        uint256 positionId = _stakeAs(ALICE, amount, SILVER_TIER);
        StakePosition memory beforeUnstake = _position(positionId);
        uint256 expectedPenalty = tierRegistry.previewExitPenalty(
            amount,
            beforeUnstake.commitmentStartedAt,
            beforeUnstake.unlockAt,
            beforeUnstake.commitmentPenaltyBps
        );
        uint256 aliceBefore = stakingToken.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 received, uint256 penalty) =
            vault.unstake(positionId, amount, ALICE, expectedPenalty);

        StakePosition memory afterUnstake = _position(positionId);
        assertEq(expectedPenalty, 250 ether);
        assertEq(penalty, expectedPenalty);
        assertEq(received, amount - expectedPenalty);
        assertEq(stakingToken.balanceOf(ALICE), aliceBefore + received);
        assertEq(stakingToken.balanceOf(address(penaltyReserve)), expectedPenalty);
        assertEq(penaltyReserve.accountedBalance(), expectedPenalty);
        assertEq(penaltyReserve.totalPenalties(), expectedPenalty);
        assertEq(vault.totalExitPenalties(), expectedPenalty);
        assertEq(vault.totalPrincipal(), 0);
        assertEq(afterUnstake.principal, 0);
        assertEq(afterUnstake.rewardWeight, 0);
        assertEq(uint8(afterUnstake.status), uint8(PositionStatus.Active));
        assertTrue(vault.principalSolvent());
    }

    function test_earlyUnstakeHonorsCallerPenaltyLimit() public {
        uint256 amount = 1000 ether;
        uint256 positionId = _stakeAs(ALICE, amount, GOLD_TIER);
        PositionPreview memory preview = vault.previewPosition(positionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PenaltyExceedsLimit.selector, preview.earlyExitPenalty, preview.earlyExitPenalty - 1
            )
        );
        vm.prank(ALICE);
        vault.unstake(positionId, amount, ALICE, preview.earlyExitPenalty - 1);

        assertEq(_position(positionId).principal, amount);
        assertEq(vault.totalPrincipal(), amount);
        assertEq(penaltyReserve.accountedBalance(), 0);
    }

    function test_matureUnstakeReturnsPrincipalWithoutPenalty() public {
        uint256 amount = 1000 ether;
        uint256 aliceBeforeStake = stakingToken.balanceOf(ALICE);
        uint256 positionId = _stakeAs(ALICE, amount, BRONZE_TIER);
        StakePosition memory stakePosition = _position(positionId);

        vm.warp(stakePosition.unlockAt);
        PositionPreview memory preview = vault.previewPosition(positionId);
        assertTrue(preview.matured);
        assertEq(preview.earlyExitPenalty, 0);

        vm.prank(ALICE);
        (uint256 received, uint256 penalty) = vault.unstake(positionId, amount, ALICE, 0);

        assertEq(received, amount);
        assertEq(penalty, 0);
        assertEq(stakingToken.balanceOf(ALICE), aliceBeforeStake);
        assertEq(stakingToken.balanceOf(address(penaltyReserve)), 0);
        assertEq(penaltyReserve.totalPenalties(), 0);
        assertEq(vault.totalPrincipal(), 0);
        assertEq(_position(positionId).principal, 0);
    }

    function test_partialUnstakeMustLeaveAtLeastTierMinimum() public {
        uint256 amount = 500 ether;
        uint256 positionId = _stakeAs(ALICE, amount, BRONZE_TIER);
        uint256 amountLeavingDust = amount - uint256(MINIMUM_STAKE) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                PositionBelowMinimum.selector, uint256(MINIMUM_STAKE) - 1, MINIMUM_STAKE
            )
        );
        vm.prank(ALICE);
        vault.unstake(positionId, amountLeavingDust, ALICE, type(uint256).max);

        assertEq(_position(positionId).principal, amount);
    }

    function test_zeroPrincipalPositionCanCloseAndBurnReceipt() public {
        uint256 amount = 500 ether;
        uint256 positionId = _stakeAs(ALICE, amount, FLEX_TIER);

        vm.prank(ALICE);
        vault.unstake(positionId, amount, ALICE, 0);

        vm.prank(ALICE);
        vault.closePosition(positionId);

        assertEq(uint8(_position(positionId).status), uint8(PositionStatus.Closed));
        assertEq(positionToken.totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(TokenDoesNotExist.selector, positionId));
        positionToken.ownerOf(positionId);
    }
}
