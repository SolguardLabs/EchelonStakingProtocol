// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { EchelonTestBase } from "../helpers/EchelonTestBase.sol";
import { EchelonStakingVault } from "../../src/staking/EchelonStakingVault.sol";
import { EpochRewardController } from "../../src/rewards/EpochRewardController.sol";
import { StakePositionToken } from "../../src/positions/StakePositionToken.sol";
import { LockTierRegistry } from "../../src/policy/LockTierRegistry.sol";
import { PenaltyReserve } from "../../src/treasury/PenaltyReserve.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { StakePosition, PositionStatus, TierConfig } from "../../src/types/EchelonTypes.sol";

contract EchelonInvariantHandler is Test {
    EchelonStakingVault internal immutable vault;
    EpochRewardController internal immutable rewardController;
    StakePositionToken internal immutable positionToken;
    LockTierRegistry internal immutable tierRegistry;

    address[] internal actors;

    constructor(
        EchelonStakingVault vault_,
        EpochRewardController rewardController_,
        StakePositionToken positionToken_,
        LockTierRegistry tierRegistry_,
        address[] memory actors_
    ) {
        vault = vault_;
        rewardController = rewardController_;
        positionToken = positionToken_;
        tierRegistry = tierRegistry_;
        actors = actors_;
    }

    function openPosition(uint256 actorSeed, uint256 amountSeed, uint256 tierSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint32 tierId = uint32(tierSeed % tierRegistry.tierCount());
        TierConfig memory config = tierRegistry.tier(tierId);
        uint256 amount = bound(amountSeed, config.minimumStake, 10_000 ether);

        vm.prank(actor);
        try vault.stake(amount, tierId, actor) { } catch { }
    }

    function increasePosition(uint256 idSeed, uint256 amountSeed) external {
        uint256 upper = vault.nextPositionId();
        if (upper <= 1) return;
        uint256 positionId = bound(idSeed, 1, upper - 1);
        StakePosition memory stakePosition = vault.position(positionId);
        if (stakePosition.status != PositionStatus.Active) return;

        address owner = positionToken.ownerOf(positionId);
        uint256 amount = bound(amountSeed, 1 ether, 1000 ether);
        vm.prank(owner);
        try vault.increasePosition(positionId, amount) { } catch { }
    }

    function claimPosition(uint256 idSeed) external {
        uint256 upper = vault.nextPositionId();
        if (upper <= 1) return;
        uint256 positionId = bound(idSeed, 1, upper - 1);
        StakePosition memory stakePosition = vault.position(positionId);
        if (stakePosition.status != PositionStatus.Active) return;

        address owner = positionToken.ownerOf(positionId);
        vm.prank(owner);
        try vault.claim(positionId, owner) { } catch { }
    }

    function withdrawPosition(uint256 idSeed, uint256 amountSeed, bool closeFully) external {
        uint256 upper = vault.nextPositionId();
        if (upper <= 1) return;
        uint256 positionId = bound(idSeed, 1, upper - 1);
        StakePosition memory stakePosition = vault.position(positionId);
        if (stakePosition.status != PositionStatus.Active || stakePosition.principal == 0) return;

        TierConfig memory config = tierRegistry.tier(stakePosition.tierId);
        uint256 amount;
        if (closeFully || stakePosition.principal <= config.minimumStake) {
            amount = stakePosition.principal;
        } else {
            uint256 maximumPartial = stakePosition.principal - config.minimumStake;
            amount = bound(amountSeed, 1, maximumPartial);
        }

        address owner = positionToken.ownerOf(positionId);
        vm.prank(owner);
        try vault.unstake(positionId, amount, owner, type(uint256).max) { } catch { }
    }

    function moveTier(uint256 idSeed, uint256 tierSeed) external {
        uint256 upper = vault.nextPositionId();
        if (upper <= 1) return;
        uint256 positionId = bound(idSeed, 1, upper - 1);
        StakePosition memory stakePosition = vault.position(positionId);
        if (stakePosition.status != PositionStatus.Active || stakePosition.principal == 0) return;

        uint32 newTier = uint32(tierSeed % tierRegistry.tierCount());
        if (newTier == stakePosition.tierId) return;
        address owner = positionToken.ownerOf(positionId);
        vm.prank(owner);
        try vault.changeTier(positionId, newTier) { } catch { }
    }

    function transferPosition(uint256 idSeed, uint256 actorSeed) external {
        uint256 upper = vault.nextPositionId();
        if (upper <= 1) return;
        uint256 positionId = bound(idSeed, 1, upper - 1);
        if (vault.position(positionId).status != PositionStatus.Active) return;

        address owner = positionToken.ownerOf(positionId);
        address recipient = actors[actorSeed % actors.length];
        if (recipient == owner) return;
        vm.prank(owner);
        try positionToken.transferFrom(owner, recipient, positionId) { } catch { }
    }

    function advanceTime(uint256 secondsSeed) external {
        uint256 elapsed = bound(secondsSeed, 1 minutes, 2 days);
        vm.warp(block.timestamp + elapsed);
        try rewardController.sync() { } catch { }
    }
}

contract ProtocolInvariantsTest is EchelonTestBase {
    EchelonInvariantHandler internal handler;

    function setUp() public override {
        super.setUp();
        _warpToGenesis();

        _stakeAs(ALICE, 1000 ether, FLEX_TIER);
        _stakeAs(BOB, 2000 ether, BRONZE_TIER);
        _stakeAs(CAROL, 3000 ether, SILVER_TIER);

        address[] memory actors = new address[](3);
        actors[0] = ALICE;
        actors[1] = BOB;
        actors[2] = CAROL;
        handler = new EchelonInvariantHandler(
            vault, rewardController, positionToken, tierRegistry, actors
        );
        targetContract(address(handler));
    }

    function invariant_PrincipalIsFullyBacked() external view {
        assertGe(stakingToken.balanceOf(address(vault)), vault.totalPrincipal());
        assertTrue(vault.principalSolvent());
    }

    function invariant_TrackedPrincipalMatchesActivePositions() external view {
        uint256 upper = vault.nextPositionId();
        uint256 observed;
        for (uint256 id = 1; id < upper; ++id) {
            StakePosition memory stakePosition = vault.position(id);
            if (stakePosition.status == PositionStatus.Active) {
                observed += stakePosition.principal;
            }
        }
        assertEq(observed, vault.totalPrincipal());
    }

    function invariant_TrackedWeightMatchesActivePositions() external view {
        uint256 upper = vault.nextPositionId();
        uint256 observed;
        for (uint256 id = 1; id < upper; ++id) {
            StakePosition memory stakePosition = vault.position(id);
            if (stakePosition.status == PositionStatus.Active) {
                observed += stakePosition.rewardWeight;
            }
        }
        assertEq(observed, rewardController.totalRewardWeight());
    }

    function invariant_PositionSupplyMatchesActiveRecords() external view {
        uint256 upper = vault.nextPositionId();
        uint256 active;
        for (uint256 id = 1; id < upper; ++id) {
            if (vault.position(id).status == PositionStatus.Active) ++active;
        }
        assertEq(active, positionToken.totalSupply());
    }

    function invariant_ReserveCreditsRemainBacked() external view {
        assertGe(stakingToken.balanceOf(address(penaltyReserve)), penaltyReserve.accountedBalance());
        assertEq(
            penaltyReserve.accountedBalance() + penaltyReserve.totalWithdrawn(),
            penaltyReserve.totalPenalties() + penaltyReserve.totalSlashed()
                + penaltyReserve.totalRoundingSurplus()
        );
    }
}
