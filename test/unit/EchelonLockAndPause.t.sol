// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonTestBase } from "../helpers/EchelonTestBase.sol";
import { StakePosition } from "../../src/types/EchelonTypes.sol";
import {
    Unauthorized,
    DepositsPaused,
    ExitsPaused,
    ContractPaused,
    TierChangeOnCooldown,
    TierDisabled
} from "../../src/errors/EchelonErrors.sol";

contract EchelonLockAndPauseTest is EchelonTestBase {
    function test_activeCommitmentCannotBeShortenedBySelectingShorterTier() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, SILVER_TIER);
        StakePosition memory original = _position(positionId);

        vm.warp(original.lastTierChange + 1 days);
        vm.prank(ALICE);
        vault.changeTier(positionId, BRONZE_TIER);

        StakePosition memory changed = _position(positionId);
        assertEq(changed.tierId, BRONZE_TIER);
        assertEq(changed.unlockAt, original.unlockAt);
        assertEq(changed.commitmentStartedAt, original.commitmentStartedAt);
        assertEq(changed.commitmentPenaltyBps, original.commitmentPenaltyBps);
        assertEq(changed.rewardWeight, tierRegistry.calculateWeight(changed.principal, BRONZE_TIER));
    }

    function test_longerTierExtendsCommitmentFromChangeTimestamp() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, BRONZE_TIER);
        StakePosition memory original = _position(positionId);

        vm.warp(original.lastTierChange + 1 days);
        uint256 changedAt = block.timestamp;
        vm.prank(ALICE);
        vault.changeTier(positionId, GOLD_TIER);

        StakePosition memory changed = _position(positionId);
        assertEq(changed.tierId, GOLD_TIER);
        assertGt(changed.unlockAt, original.unlockAt);
        assertEq(changed.unlockAt, changedAt + 365 days);
        assertEq(changed.commitmentStartedAt, changedAt);
        assertEq(changed.commitmentPenaltyBps, 4000);
    }

    function test_consecutiveTierChangesPreserveMonotonicUnlock() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, SILVER_TIER);
        StakePosition memory initial = _position(positionId);

        vm.warp(initial.lastTierChange + 1 days);
        vm.prank(ALICE);
        vault.changeTier(positionId, BRONZE_TIER);
        uint64 afterShorterTier = _position(positionId).unlockAt;

        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        vault.changeTier(positionId, GOLD_TIER);
        uint64 afterLongerTier = _position(positionId).unlockAt;

        assertGe(afterShorterTier, initial.unlockAt);
        assertGe(afterLongerTier, afterShorterTier);
    }

    function test_maturePositionStartsFreshCommitmentWhenTierChanges() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, FLEX_TIER);
        StakePosition memory original = _position(positionId);

        vm.warp(original.lastTierChange + 1 days);
        uint256 changedAt = block.timestamp;
        vm.prank(ALICE);
        vault.changeTier(positionId, BRONZE_TIER);

        StakePosition memory changed = _position(positionId);
        assertEq(changed.commitmentStartedAt, changedAt);
        assertEq(changed.unlockAt, changedAt + 30 days);
        assertEq(changed.commitmentPenaltyBps, 1000);
    }

    function test_tierChangeEnforcesConfiguredCooldown() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, SILVER_TIER);
        StakePosition memory stakePosition = _position(positionId);
        uint64 availableAt = stakePosition.lastTierChange + 1 days;

        vm.expectRevert(abi.encodeWithSelector(TierChangeOnCooldown.selector, availableAt));
        vm.prank(ALICE);
        vault.changeTier(positionId, GOLD_TIER);

        assertEq(_position(positionId).tierId, SILVER_TIER);
    }

    function test_guardianCanPauseAndResumeEachVaultActionFamily() public {
        vm.prank(GUARDIAN);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsArePaused());

        vm.expectRevert(DepositsPaused.selector);
        vm.prank(ALICE);
        vault.stake(1000 ether, BRONZE_TIER, ALICE);

        vm.prank(GUARDIAN);
        vault.setDepositsPaused(false);
        uint256 positionId = _stakeAs(ALICE, 1000 ether, BRONZE_TIER);

        vm.prank(GUARDIAN);
        vault.setExitsPaused(true);
        assertTrue(vault.exitsArePaused());

        vm.expectRevert(ExitsPaused.selector);
        vm.prank(ALICE);
        vault.unstake(positionId, 100 ether, ALICE, type(uint256).max);

        vm.prank(GUARDIAN);
        vault.setExitsPaused(false);

        vm.prank(GUARDIAN);
        vault.setTierChangesPaused(true);
        assertTrue(vault.tierChangesArePaused());

        vm.warp(_position(positionId).lastTierChange + 1 days);
        vm.expectRevert(ContractPaused.selector);
        vm.prank(ALICE);
        vault.changeTier(positionId, SILVER_TIER);

        vm.prank(GUARDIAN);
        vault.setTierChangesPaused(false);
        vm.prank(ALICE);
        vault.changeTier(positionId, SILVER_TIER);

        assertFalse(vault.depositsArePaused());
        assertFalse(vault.exitsArePaused());
        assertFalse(vault.tierChangesArePaused());
        assertEq(_position(positionId).tierId, SILVER_TIER);
    }

    function test_governorIsAcceptedForGuardianPauseControls() public {
        vault.setDepositsPaused(true);
        vault.setExitsPaused(true);
        vault.setTierChangesPaused(true);
        rewardController.setPayoutsPaused(true);

        assertTrue(vault.depositsArePaused());
        assertTrue(vault.exitsArePaused());
        assertTrue(vault.tierChangesArePaused());
        assertTrue(rewardController.payoutsPaused());
    }

    function test_outsiderCannotUseGuardianControls() public {
        vm.startPrank(OUTSIDER);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GUARDIAN_ROLE, OUTSIDER));
        vault.setDepositsPaused(true);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GUARDIAN_ROLE, OUTSIDER));
        vault.setExitsPaused(true);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GUARDIAN_ROLE, OUTSIDER));
        vault.setTierChangesPaused(true);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GUARDIAN_ROLE, OUTSIDER));
        rewardController.setPayoutsPaused(true);

        vm.stopPrank();
    }

    function test_nonGovernorCannotMutateGovernanceConfiguration() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GOVERNOR_ROLE, GUARDIAN));
        vm.prank(GUARDIAN);
        tierRegistry.setTierEnabled(GOLD_TIER, false);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GOVERNOR_ROLE, OUTSIDER));
        vm.prank(OUTSIDER);
        accessManager.grantRole(GUARDIAN_ROLE, OUTSIDER);

        assertFalse(accessManager.hasRole(GUARDIAN_ROLE, OUTSIDER));
        assertTrue(tierRegistry.tier(GOLD_TIER).enabled);
    }

    function test_disabledCurrentTierRejectsTopUps() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, GOLD_TIER);
        tierRegistry.setTierEnabled(GOLD_TIER, false);

        vm.expectRevert(abi.encodeWithSelector(TierDisabled.selector, GOLD_TIER));
        vm.prank(ALICE);
        vault.increasePosition(positionId, 100 ether);
    }
}
