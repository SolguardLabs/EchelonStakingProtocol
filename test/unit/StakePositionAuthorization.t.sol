// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonTestBase } from "../helpers/EchelonTestBase.sol";
import { StakePosition } from "../../src/types/EchelonTypes.sol";
import {
    PositionNotAuthorized,
    TransferCallerNotOwnerNorApproved
} from "../../src/errors/EchelonErrors.sol";

contract StakePositionAuthorizationTest is EchelonTestBase {
    function test_ownerCanManagePosition() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, BRONZE_TIER);

        vm.prank(ALICE);
        vault.increasePosition(positionId, 100 ether);

        assertEq(_position(positionId).principal, 1100 ether);
    }

    function test_unapprovedAccountCannotManagePosition() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, BRONZE_TIER);

        vm.expectRevert(abi.encodeWithSelector(PositionNotAuthorized.selector, positionId, BOB));
        vm.prank(BOB);
        vault.increasePosition(positionId, 100 ether);

        assertEq(_position(positionId).principal, 1000 ether);
    }

    function test_tokenApprovalAuthorizesPositionManagement() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, BRONZE_TIER);

        vm.prank(ALICE);
        positionToken.approve(BOB, positionId);

        assertEq(positionToken.getApproved(positionId), BOB);
        assertTrue(positionToken.isApprovedOrOwner(BOB, positionId));

        vm.prank(BOB);
        vault.increasePosition(positionId, 250 ether);

        assertEq(_position(positionId).principal, 1250 ether);
        assertEq(stakingToken.balanceOf(BOB), USER_STAKING_BALANCE - 250 ether);
    }

    function test_operatorApprovalAuthorizesMultiplePositions() public {
        uint256 firstPosition = _stakeAs(ALICE, 1000 ether, BRONZE_TIER);
        uint256 secondPosition = _stakeAs(ALICE, 2000 ether, SILVER_TIER);

        vm.prank(ALICE);
        positionToken.setApprovalForAll(BOB, true);

        assertTrue(positionToken.isApprovedForAll(ALICE, BOB));
        assertTrue(positionToken.isApprovedOrOwner(BOB, firstPosition));
        assertTrue(positionToken.isApprovedOrOwner(BOB, secondPosition));

        vm.startPrank(BOB);
        vault.increasePosition(firstPosition, 100 ether);
        vault.increasePosition(secondPosition, 200 ether);
        vm.stopPrank();

        assertEq(_position(firstPosition).principal, 1100 ether);
        assertEq(_position(secondPosition).principal, 2200 ether);
    }

    function test_unapprovedAccountCannotTransferPositionReceipt() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, BRONZE_TIER);

        vm.expectRevert(TransferCallerNotOwnerNorApproved.selector);
        vm.prank(BOB);
        positionToken.transferFrom(ALICE, CAROL, positionId);

        assertEq(positionToken.ownerOf(positionId), ALICE);
    }

    function test_approvedTransferMovesManagementRightsAndClearsApproval() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, SILVER_TIER);

        vm.prank(ALICE);
        positionToken.approve(BOB, positionId);

        vm.prank(BOB);
        positionToken.transferFrom(ALICE, CAROL, positionId);

        assertEq(positionToken.ownerOf(positionId), CAROL);
        assertEq(positionToken.getApproved(positionId), address(0));
        assertFalse(positionToken.isApprovedOrOwner(ALICE, positionId));
        assertFalse(positionToken.isApprovedOrOwner(BOB, positionId));
        assertTrue(positionToken.isApprovedOrOwner(CAROL, positionId));

        vm.expectRevert(abi.encodeWithSelector(PositionNotAuthorized.selector, positionId, ALICE));
        vm.prank(ALICE);
        vault.increasePosition(positionId, 100 ether);

        vm.prank(CAROL);
        vault.increasePosition(positionId, 100 ether);

        StakePosition memory stakePosition = _position(positionId);
        assertEq(stakePosition.principal, 1100 ether);
    }

    function test_transferDoesNotMutatePositionEconomics() public {
        uint256 positionId = _stakeAs(ALICE, 1000 ether, GOLD_TIER);
        StakePosition memory beforeTransfer = _position(positionId);

        vm.prank(ALICE);
        positionToken.transferFrom(ALICE, BOB, positionId);

        StakePosition memory afterTransfer = _position(positionId);
        assertEq(afterTransfer.principal, beforeTransfer.principal);
        assertEq(afterTransfer.rewardWeight, beforeTransfer.rewardWeight);
        assertEq(afterTransfer.tierId, beforeTransfer.tierId);
        assertEq(afterTransfer.createdAt, beforeTransfer.createdAt);
        assertEq(afterTransfer.commitmentStartedAt, beforeTransfer.commitmentStartedAt);
        assertEq(afterTransfer.unlockAt, beforeTransfer.unlockAt);
        assertEq(afterTransfer.commitmentPenaltyBps, beforeTransfer.commitmentPenaltyBps);
    }
}
