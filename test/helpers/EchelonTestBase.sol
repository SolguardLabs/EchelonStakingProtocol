// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { EchelonAccessManager } from "../../src/access/EchelonAccessManager.sol";
import { EchelonStakingVault } from "../../src/staking/EchelonStakingVault.sol";
import { EpochRewardController } from "../../src/rewards/EpochRewardController.sol";
import { LockTierRegistry } from "../../src/policy/LockTierRegistry.sol";
import { StakePositionToken } from "../../src/positions/StakePositionToken.sol";
import { PenaltyReserve } from "../../src/treasury/PenaltyReserve.sol";
import { SlashingManager } from "../../src/security/SlashingManager.sol";
import { EchelonLens } from "../../src/views/EchelonLens.sol";
import { EchelonMonitor } from "../../src/monitoring/EchelonMonitor.sol";
import { StakePosition } from "../../src/types/EchelonTypes.sol";

import { MockERC20 } from "./MockERC20.sol";

/// @notice Fully wired protocol fixture shared by unit, integration, and invariant tests.
abstract contract EchelonTestBase is Test {
    bytes32 internal constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 internal constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 internal constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint64 internal constant ADMIN_TRANSFER_DELAY = 2 days;
    uint64 internal constant EPOCH_DURATION = 7 days;
    uint64 internal constant SLASH_DELAY = 1 days;

    uint32 internal constant FLEX_TIER = 0;
    uint32 internal constant BRONZE_TIER = 1;
    uint32 internal constant SILVER_TIER = 2;
    uint32 internal constant GOLD_TIER = 3;

    uint128 internal constant MINIMUM_STAKE = 100 ether;
    uint128 internal constant REWARD_RATE = 1 ether;
    uint128 internal constant EPOCH_BUDGET = 604_800 ether;
    uint256 internal constant TOTAL_REWARD_FUNDING = uint256(EPOCH_BUDGET) * 3;
    uint256 internal constant USER_STAKING_BALANCE = 1_000_000 ether;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant GUARDIAN = address(0x600D);
    address internal constant REWARD_MANAGER = address(0xBEEF);
    address internal constant SLASHER = address(0x51A5);
    address internal constant KEEPER = address(0x4B33);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant OUTSIDER = address(0xBAD);

    MockERC20 internal stakingToken;
    MockERC20 internal rewardToken;

    EchelonAccessManager internal accessManager;
    LockTierRegistry internal tierRegistry;
    StakePositionToken internal positionToken;
    PenaltyReserve internal penaltyReserve;
    EpochRewardController internal rewardController;
    EchelonStakingVault internal vault;
    SlashingManager internal slashingManager;
    EchelonLens internal lens;
    EchelonMonitor internal monitor;

    uint64 internal genesis;

    function setUp() public virtual {
        vm.label(ALICE, "Alice");
        vm.label(BOB, "Bob");
        vm.label(CAROL, "Carol");
        vm.label(GUARDIAN, "Guardian");
        vm.label(REWARD_MANAGER, "Reward manager");
        vm.label(SLASHER, "Slasher");
        vm.label(KEEPER, "Keeper");
        vm.label(TREASURY, "Treasury");
        vm.label(OUTSIDER, "Outsider");

        stakingToken = new MockERC20("Echelon Stake", "eSTK", 18);
        rewardToken = new MockERC20("Echelon Reward", "eRWD", 18);
        accessManager = new EchelonAccessManager(address(this), ADMIN_TRANSFER_DELAY);
        tierRegistry = new LockTierRegistry(address(accessManager));
        positionToken = new StakePositionToken(
            "Echelon Stake Position", "ePOS", address(accessManager), "ipfs://echelon/"
        );
        penaltyReserve = new PenaltyReserve(address(stakingToken), address(accessManager), TREASURY);

        genesis = uint64(block.timestamp + 1 days);
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
        slashingManager = new SlashingManager(address(accessManager), address(vault), SLASH_DELAY);
        lens = new EchelonLens(
            address(vault),
            address(rewardController),
            address(tierRegistry),
            address(positionToken),
            address(penaltyReserve)
        );
        monitor = new EchelonMonitor(
            address(vault),
            address(rewardController),
            address(tierRegistry),
            address(positionToken),
            address(penaltyReserve),
            address(slashingManager)
        );

        positionToken.setStakingVault(address(vault));
        rewardController.setStakingVault(address(vault));
        penaltyReserve.setStakingVault(address(vault));
        vault.setSlashingManager(address(slashingManager));

        accessManager.grantRole(GUARDIAN_ROLE, GUARDIAN);
        accessManager.grantRole(REWARD_MANAGER_ROLE, REWARD_MANAGER);
        accessManager.grantRole(SLASHER_ROLE, SLASHER);
        accessManager.grantRole(KEEPER_ROLE, KEEPER);

        _configureTiers();
        _fundAndConfigureEpochs();
        _seedUser(ALICE);
        _seedUser(BOB);
        _seedUser(CAROL);
    }

    function _configureTiers() internal {
        tierRegistry.createTier("Flexible", 0, 1 hours, 10_000, 0, MINIMUM_STAKE);
        tierRegistry.createTier("Bronze 30D", 30 days, 1 days, 12_500, 1000, MINIMUM_STAKE);
        tierRegistry.createTier("Silver 90D", 90 days, 1 days, 17_500, 2500, MINIMUM_STAKE);
        tierRegistry.createTier("Gold 365D", 365 days, 1 days, 25_000, 4000, MINIMUM_STAKE);
    }

    function _fundAndConfigureEpochs() internal {
        rewardToken.mint(REWARD_MANAGER, TOTAL_REWARD_FUNDING);

        vm.startPrank(REWARD_MANAGER);
        rewardToken.approve(address(rewardController), TOTAL_REWARD_FUNDING);
        rewardController.fundRewards(TOTAL_REWARD_FUNDING);
        rewardController.configureEpoch(0, EPOCH_BUDGET, REWARD_RATE);
        rewardController.configureEpoch(1, EPOCH_BUDGET, REWARD_RATE);
        rewardController.configureEpoch(2, EPOCH_BUDGET, REWARD_RATE);
        vm.stopPrank();
    }

    function _seedUser(address user) internal {
        stakingToken.mint(user, USER_STAKING_BALANCE);
        vm.prank(user);
        stakingToken.approve(address(vault), type(uint256).max);
    }

    function _stakeAs(address user, uint256 amount, uint32 tierId)
        internal
        returns (uint256 positionId)
    {
        vm.prank(user);
        positionId = vault.stake(amount, tierId, user);
    }

    function _stakeFor(address funder, address recipient, uint256 amount, uint32 tierId)
        internal
        returns (uint256 positionId)
    {
        vm.prank(funder);
        positionId = vault.stake(amount, tierId, recipient);
    }

    function _position(uint256 positionId) internal view returns (StakePosition memory) {
        return vault.position(positionId);
    }

    function _warpToGenesis() internal {
        vm.warp(genesis);
    }

    function _warpIntoEpoch(uint32 epochId, uint64 elapsed) internal {
        require(elapsed < EPOCH_DURATION, "elapsed outside epoch");
        vm.warp(uint256(genesis) + uint256(epochId) * EPOCH_DURATION + elapsed);
    }
}
