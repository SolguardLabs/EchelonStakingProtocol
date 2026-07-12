// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonTestBase } from "../helpers/EchelonTestBase.sol";
import {
    StakePosition,
    SlashRequest,
    SlashRequestStatus,
    ProtocolSnapshot
} from "../../src/types/EchelonTypes.sol";
import {
    Unauthorized,
    InvalidSlashBps,
    SlashRequestNotFound,
    SlashRequestNotQueued,
    SlashRequestNotReady,
    SlashDelayOutOfRange,
    EvidenceHashRequired,
    PositionNotActive,
    PositionHasPendingSlash
} from "../../src/errors/EchelonErrors.sol";

/// @notice End-to-end coverage for delayed governance slashing and its accounting effects.
contract SlashingIntegrationTest is EchelonTestBase {
    uint16 internal constant DEFAULT_SLASH_BPS = 2500;
    bytes32 internal constant EVIDENCE = keccak256("echelon:evidence:validator-42");

    function test_queueSlashPersistsEvidenceDelayAndProposer() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, GOLD_TIER);
        uint64 queuedAt = uint64(block.timestamp);

        vm.prank(SLASHER);
        uint256 requestId = slashingManager.queueSlash(positionId, DEFAULT_SLASH_BPS, EVIDENCE);

        SlashRequest memory request = slashingManager.request(requestId);
        assertEq(requestId, 1, "first request id");
        assertEq(slashingManager.nextRequestId(), 2, "request nonce");
        assertEq(request.positionId, positionId, "position id");
        assertEq(request.slashBps, DEFAULT_SLASH_BPS, "slash bps");
        assertEq(request.queuedAt, queuedAt, "queued timestamp");
        assertEq(request.executableAt, queuedAt + SLASH_DELAY, "execution timestamp");
        assertEq(request.evidenceHash, EVIDENCE, "evidence hash");
        assertEq(uint256(request.status), uint256(SlashRequestStatus.Queued), "status");
        assertEq(request.proposer, SLASHER, "proposer");
    }

    function test_queueSlashEnforcesRoleAndInputValidation() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, GOLD_TIER);

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, SLASHER_ROLE, OUTSIDER));
        slashingManager.queueSlash(positionId, DEFAULT_SLASH_BPS, EVIDENCE);

        vm.startPrank(SLASHER);

        vm.expectRevert(abi.encodeWithSelector(InvalidSlashBps.selector, 0));
        slashingManager.queueSlash(positionId, 0, EVIDENCE);

        vm.expectRevert(abi.encodeWithSelector(InvalidSlashBps.selector, 8001));
        slashingManager.queueSlash(positionId, 8001, EVIDENCE);

        vm.expectRevert(EvidenceHashRequired.selector);
        slashingManager.queueSlash(positionId, DEFAULT_SLASH_BPS, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(PositionNotActive.selector, 999));
        slashingManager.queueSlash(999, DEFAULT_SLASH_BPS, EVIDENCE);

        vm.stopPrank();
    }

    function test_executeSlashHonorsDelayAndIsPermissionlessOnceReady() public {
        uint256 principal = 1000 ether;
        uint16 slashBps = 1500;
        uint256 positionId = _stakeAs(ALICE, principal, SILVER_TIER);
        uint256 requestId = _queueSlash(positionId, slashBps, EVIDENCE);
        SlashRequest memory request = slashingManager.request(requestId);

        vm.warp(request.executableAt - 1);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(SlashRequestNotReady.selector, request.executableAt));
        slashingManager.executeSlash(requestId);

        assertEq(
            uint256(slashingManager.request(requestId).status),
            uint256(SlashRequestStatus.Queued),
            "early execution must not mutate status"
        );

        vm.warp(request.executableAt);
        vm.prank(OUTSIDER);
        uint256 slashedAmount = slashingManager.executeSlash(requestId);

        assertEq(slashedAmount, principal * slashBps / 10_000, "slashed amount");
        assertEq(
            uint256(slashingManager.request(requestId).status),
            uint256(SlashRequestStatus.Executed),
            "executed status"
        );

        vm.expectRevert(abi.encodeWithSelector(SlashRequestNotQueued.selector, requestId));
        slashingManager.executeSlash(requestId);
    }

    function test_governorAndGuardianCanCancelButOutsiderCannot() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, GOLD_TIER);
        uint256 requestId = _queueSlash(positionId, DEFAULT_SLASH_BPS, EVIDENCE);

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GOVERNOR_ROLE, OUTSIDER));
        slashingManager.cancelSlash(requestId);

        vm.prank(GUARDIAN);
        slashingManager.cancelSlash(requestId);
        assertEq(
            uint256(slashingManager.request(requestId).status),
            uint256(SlashRequestStatus.Cancelled),
            "guardian cancellation"
        );

        vm.warp(block.timestamp + SLASH_DELAY);
        vm.expectRevert(abi.encodeWithSelector(SlashRequestNotQueued.selector, requestId));
        slashingManager.executeSlash(requestId);

        uint256 secondRequest =
            _queueSlash(positionId, DEFAULT_SLASH_BPS, keccak256("second evidence"));
        slashingManager.cancelSlash(secondRequest);
        assertEq(
            uint256(slashingManager.request(secondRequest).status),
            uint256(SlashRequestStatus.Cancelled),
            "governor cancellation"
        );
    }

    function test_governorControlsSlashDelayWithinBounds() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GOVERNOR_ROLE, OUTSIDER));
        slashingManager.setSlashDelay(2 days);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, GOVERNOR_ROLE, GUARDIAN));
        slashingManager.setSlashDelay(2 days);

        slashingManager.setSlashDelay(2 days);
        assertEq(slashingManager.slashDelay(), 2 days, "updated delay");

        uint64 minimumDelay = slashingManager.MIN_SLASH_DELAY();
        uint64 maximumDelay = slashingManager.MAX_SLASH_DELAY();

        vm.expectRevert(abi.encodeWithSelector(SlashDelayOutOfRange.selector, minimumDelay - 1));
        slashingManager.setSlashDelay(minimumDelay - 1);

        vm.expectRevert(abi.encodeWithSelector(SlashDelayOutOfRange.selector, maximumDelay + 1));
        slashingManager.setSlashDelay(maximumDelay + 1);
    }

    function test_partialSlashReconcilesPrincipalWeightAndReserve() public {
        uint256 principal = 1000 ether;
        uint16 slashBps = 2500;
        uint256 positionId = _stakeAs(ALICE, principal, GOLD_TIER);
        StakePosition memory beforePosition = _position(positionId);
        uint256 expectedSlashed = principal * slashBps / 10_000;
        uint256 expectedPrincipal = principal - expectedSlashed;
        uint256 expectedWeight = expectedPrincipal * 25_000 / 10_000;

        uint256 requestId = _queueSlash(positionId, slashBps, EVIDENCE);
        SlashRequest memory request = slashingManager.request(requestId);
        vm.warp(request.executableAt);

        vm.prank(KEEPER);
        uint256 actualSlashed = slashingManager.executeSlash(requestId);

        StakePosition memory afterPosition = _position(positionId);
        ProtocolSnapshot memory snapshot = vault.protocolSnapshot();

        assertEq(actualSlashed, expectedSlashed, "return value");
        assertEq(afterPosition.principal, expectedPrincipal, "position principal");
        assertEq(afterPosition.rewardWeight, expectedWeight, "position weight");
        assertEq(
            afterPosition.totalSlashed,
            beforePosition.totalSlashed + expectedSlashed,
            "position slash history"
        );
        assertEq(vault.totalPrincipal(), expectedPrincipal, "vault principal liability");
        assertEq(vault.totalPrincipalSlashed(), expectedSlashed, "vault slash aggregate");
        assertEq(rewardController.totalRewardWeight(), expectedWeight, "global weight");

        assertEq(
            stakingToken.balanceOf(address(vault)), expectedPrincipal, "vault principal assets"
        );
        assertEq(
            stakingToken.balanceOf(address(penaltyReserve)), expectedSlashed, "reserve token assets"
        );
        assertEq(penaltyReserve.accountedBalance(), expectedSlashed, "accounted reserve");
        assertEq(penaltyReserve.totalSlashed(), expectedSlashed, "reserve slash aggregate");
        assertEq(penaltyReserve.totalPenalties(), 0, "exit penalties stay separate");
        assertEq(snapshot.totalPrincipal, expectedPrincipal, "snapshot principal");
        assertEq(snapshot.totalRewardWeight, expectedWeight, "snapshot weight");
        assertEq(snapshot.totalSlashed, expectedSlashed, "snapshot slashed");
        assertTrue(vault.principalSolvent(), "principal remains solvent");
    }

    function test_pendingSlashBlocksPrincipalExitUntilCancelled() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, GOLD_TIER);
        uint256 requestId = _queueSlash(positionId, DEFAULT_SLASH_BPS, EVIDENCE);

        assertEq(slashingManager.pendingSlashCount(positionId), 1, "queued request");

        vm.expectRevert(abi.encodeWithSelector(PositionHasPendingSlash.selector, positionId, 1));
        vm.prank(ALICE);
        vault.unstake(positionId, 100 ether, ALICE, type(uint256).max);

        vm.prank(GUARDIAN);
        slashingManager.cancelSlash(requestId);

        assertEq(slashingManager.pendingSlashCount(positionId), 0, "cancel clears pending count");
        vm.prank(ALICE);
        vault.unstake(positionId, 100 ether, ALICE, type(uint256).max);
        assertEq(_position(positionId).principal, 900 ether, "exit allowed after resolution");
    }

    function test_pendingSlashCountClearsAfterExecution() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, GOLD_TIER);
        uint256 requestId = _queueSlash(positionId, DEFAULT_SLASH_BPS, EVIDENCE);
        SlashRequest memory request = slashingManager.request(requestId);

        vm.warp(request.executableAt);
        slashingManager.executeSlash(requestId);

        assertEq(slashingManager.pendingSlashCount(positionId), 0, "execution clears pending count");
        vm.prank(ALICE);
        vault.unstake(positionId, 100 ether, ALICE, type(uint256).max);
        assertEq(_position(positionId).principal, 650 ether, "exit allowed after execution");
    }

    function test_slashPreservesAccruedRewardsAndChangesFutureShare() public {
        uint256 principal = 1000 ether;
        uint256 alicePosition = _stakeAs(ALICE, principal, GOLD_TIER);
        uint256 bobPosition = _stakeAs(BOB, principal, GOLD_TIER);

        _warpIntoEpoch(0, 1 days);
        uint256 firstDayShare = uint256(REWARD_RATE) * 1 days / 2;
        assertEq(vault.pendingRewards(alicePosition), firstDayShare, "alice day one");
        assertEq(vault.pendingRewards(bobPosition), firstDayShare, "bob day one");

        uint256 requestId = _queueSlash(alicePosition, 5000, EVIDENCE);
        SlashRequest memory request = slashingManager.request(requestId);
        vm.warp(request.executableAt);

        uint256 aliceAccruedBeforeSlash = vault.pendingRewards(alicePosition);
        uint256 bobAccruedBeforeSlash = vault.pendingRewards(bobPosition);
        uint256 expectedTwoDayShare = uint256(REWARD_RATE) * 2 days / 2;
        assertEq(aliceAccruedBeforeSlash, expectedTwoDayShare, "alice pre-slash rewards");
        assertEq(bobAccruedBeforeSlash, expectedTwoDayShare, "bob pre-slash rewards");

        vm.prank(OUTSIDER);
        slashingManager.executeSlash(requestId);

        StakePosition memory aliceAfterSlash = _position(alicePosition);
        assertEq(aliceAfterSlash.principal, 500 ether, "alice remaining principal");
        assertEq(aliceAfterSlash.rewardWeight, 1250 ether, "alice remaining weight");
        assertEq(_position(bobPosition).rewardWeight, 2500 ether, "bob weight");
        assertEq(rewardController.totalRewardWeight(), 3750 ether, "post-slash total weight");
        assertEq(
            vault.pendingRewards(alicePosition),
            aliceAccruedBeforeSlash,
            "slash cannot erase accrued rewards"
        );

        _assertPostSlashRewardDistribution(
            alicePosition, bobPosition, aliceAccruedBeforeSlash, bobAccruedBeforeSlash
        );
    }

    function test_unknownRequestCannotBeReadOrExecuted() public {
        vm.expectRevert(abi.encodeWithSelector(SlashRequestNotFound.selector, 777));
        slashingManager.request(777);

        vm.expectRevert(abi.encodeWithSelector(SlashRequestNotFound.selector, 777));
        slashingManager.executeSlash(777);
    }

    function _assertPostSlashRewardDistribution(
        uint256 alicePosition,
        uint256 bobPosition,
        uint256 aliceAccruedBeforeSlash,
        uint256 bobAccruedBeforeSlash
    ) internal {
        vm.warp(block.timestamp + 1 days);
        uint256 nextDayEmission = uint256(REWARD_RATE) * 1 days;
        uint256 expectedAliceReward = aliceAccruedBeforeSlash + nextDayEmission / 3;
        uint256 expectedBobReward = bobAccruedBeforeSlash + nextDayEmission * 2 / 3;

        assertEq(
            vault.pendingRewards(alicePosition), expectedAliceReward, "alice lower future share"
        );
        assertEq(vault.pendingRewards(bobPosition), expectedBobReward, "bob higher future share");

        uint256 liquidityBeforeClaims = rewardController.rewardLiquidity();
        vm.prank(ALICE);
        uint256 aliceClaimed = vault.claim(alicePosition, ALICE);
        vm.prank(BOB);
        uint256 bobClaimed = vault.claim(bobPosition, BOB);

        assertEq(aliceClaimed, expectedAliceReward, "alice claim");
        assertEq(bobClaimed, expectedBobReward, "bob claim");
        assertEq(rewardToken.balanceOf(ALICE), expectedAliceReward, "alice reward balance");
        assertEq(rewardToken.balanceOf(BOB), expectedBobReward, "bob reward balance");
        assertEq(vault.pendingRewards(alicePosition), 0, "alice ledger consumed");
        assertEq(vault.pendingRewards(bobPosition), 0, "bob ledger consumed");
        assertEq(
            rewardController.rewardLiquidity(),
            liquidityBeforeClaims - expectedAliceReward - expectedBobReward,
            "reward liquidity reconciled"
        );
        assertEq(
            rewardController.totalRewardsPaid(),
            expectedAliceReward + expectedBobReward,
            "paid rewards aggregate"
        );
    }

    function _queueSlash(uint256 positionId, uint16 slashBps, bytes32 evidenceHash)
        internal
        returns (uint256 requestId)
    {
        vm.prank(SLASHER);
        requestId = slashingManager.queueSlash(positionId, slashBps, evidenceHash);
    }
}
