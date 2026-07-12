// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "../src/interfaces/IERC20.sol";
import { EchelonAccessManager } from "../src/access/EchelonAccessManager.sol";
import { LockTierRegistry } from "../src/policy/LockTierRegistry.sol";
import { StakePositionToken } from "../src/positions/StakePositionToken.sol";
import { PenaltyReserve } from "../src/treasury/PenaltyReserve.sol";
import { EpochRewardController } from "../src/rewards/EpochRewardController.sol";
import { EchelonStakingVault } from "../src/staking/EchelonStakingVault.sol";
import { SlashingManager } from "../src/security/SlashingManager.sol";
import { EchelonLens } from "../src/views/EchelonLens.sol";
import { EchelonMonitor } from "../src/monitoring/EchelonMonitor.sol";

/// @notice Deploys, wires, and minimally bootstraps every Echelon protocol module.
/// @dev Existing staking and reward token addresses are read from the environment.
contract DeployEchelon is Script {
    bytes32 internal constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 internal constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    struct Config {
        address stakingToken;
        address rewardToken;
        address treasury;
        address rewardManager;
        address slasher;
        address guardian;
        uint64 adminTransferDelay;
        uint64 genesis;
        uint64 epochDuration;
        uint64 slashDelay;
        uint128 minimumStake;
        uint256 initialRewardFunding;
        uint128 firstEpochBudget;
        uint128 firstEpochRate;
        string baseUri;
    }

    struct Deployment {
        EchelonAccessManager accessManager;
        LockTierRegistry tierRegistry;
        StakePositionToken positionToken;
        PenaltyReserve penaltyReserve;
        EpochRewardController rewardController;
        EchelonStakingVault vault;
        SlashingManager slashingManager;
        EchelonLens lens;
        EchelonMonitor monitor;
    }

    function run() external returns (Deployment memory deployed) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        Config memory config = _readConfig(deployer);

        vm.startBroadcast(privateKey);

        deployed.accessManager = new EchelonAccessManager(deployer, config.adminTransferDelay);
        deployed.tierRegistry = new LockTierRegistry(address(deployed.accessManager));
        deployed.positionToken = new StakePositionToken(
            "Echelon Stake Position", "ePOS", address(deployed.accessManager), config.baseUri
        );
        deployed.penaltyReserve = new PenaltyReserve(
            config.stakingToken, address(deployed.accessManager), config.treasury
        );
        deployed.rewardController = new EpochRewardController(
            config.rewardToken,
            address(deployed.accessManager),
            config.genesis,
            config.epochDuration
        );
        deployed.vault = new EchelonStakingVault(
            config.stakingToken,
            config.rewardToken,
            address(deployed.accessManager),
            address(deployed.tierRegistry),
            address(deployed.rewardController),
            address(deployed.positionToken),
            address(deployed.penaltyReserve)
        );
        deployed.slashingManager = new SlashingManager(
            address(deployed.accessManager), address(deployed.vault), config.slashDelay
        );
        deployed.lens = new EchelonLens(
            address(deployed.vault),
            address(deployed.rewardController),
            address(deployed.tierRegistry),
            address(deployed.positionToken),
            address(deployed.penaltyReserve)
        );
        deployed.monitor = new EchelonMonitor(
            address(deployed.vault),
            address(deployed.rewardController),
            address(deployed.tierRegistry),
            address(deployed.positionToken),
            address(deployed.penaltyReserve),
            address(deployed.slashingManager)
        );

        _wireModules(deployed);
        _configureInitialTiers(deployed.tierRegistry, config.minimumStake);
        _grantOperationalRoles(deployed.accessManager, config);
        _bootstrapRewards(deployed.rewardController, config);

        vm.stopBroadcast();

        _logDeployment(deployed, config);
    }

    function _readConfig(address deployer) internal view returns (Config memory config) {
        config.stakingToken = vm.envAddress("STAKING_TOKEN");
        config.rewardToken = vm.envAddress("REWARD_TOKEN");
        config.treasury = vm.envOr("TREASURY", deployer);
        config.rewardManager = vm.envOr("REWARD_MANAGER", deployer);
        config.slasher = vm.envOr("SLASHER", deployer);
        config.guardian = vm.envOr("GUARDIAN", deployer);
        config.adminTransferDelay =
            _uint64(vm.envOr("ADMIN_TRANSFER_DELAY", uint256(2 days)), "ADMIN_TRANSFER_DELAY");
        config.genesis = _uint64(vm.envOr("GENESIS", block.timestamp + 1 hours), "GENESIS");
        config.epochDuration =
            _uint64(vm.envOr("EPOCH_DURATION", uint256(7 days)), "EPOCH_DURATION");
        config.slashDelay = _uint64(vm.envOr("SLASH_DELAY", uint256(2 days)), "SLASH_DELAY");
        config.minimumStake = _uint128(vm.envOr("MINIMUM_STAKE", uint256(1 ether)), "MINIMUM_STAKE");
        config.initialRewardFunding = vm.envOr("INITIAL_REWARD_FUNDING", uint256(0));
        config.firstEpochBudget =
            _uint128(vm.envOr("FIRST_EPOCH_BUDGET", uint256(0)), "FIRST_EPOCH_BUDGET");

        uint256 defaultRate = config.firstEpochBudget == 0
            ? 0
            : uint256(config.firstEpochBudget) / config.epochDuration;
        config.firstEpochRate =
            _uint128(vm.envOr("FIRST_EPOCH_RATE", defaultRate), "FIRST_EPOCH_RATE");
        config.baseUri = vm.envOr("BASE_URI", string(""));

        require(config.stakingToken != config.rewardToken, "tokens must be different");
        require(config.treasury != address(0), "treasury is zero");
        require(config.rewardManager != address(0), "reward manager is zero");
        require(config.slasher != address(0), "slasher is zero");
        require(config.guardian != address(0), "guardian is zero");
        require(config.minimumStake != 0, "minimum stake is zero");

        if (config.firstEpochBudget != 0) {
            require(config.genesis > block.timestamp, "genesis must be in the future");
            require(config.firstEpochRate != 0, "first epoch rate is zero");
            require(
                uint256(config.firstEpochRate) * config.epochDuration <= config.firstEpochBudget,
                "first epoch rate exceeds budget"
            );
        } else {
            require(config.firstEpochRate == 0, "budget required for first epoch rate");
        }
    }

    function _wireModules(Deployment memory deployed) internal {
        deployed.positionToken.setStakingVault(address(deployed.vault));
        deployed.rewardController.setStakingVault(address(deployed.vault));
        deployed.penaltyReserve.setStakingVault(address(deployed.vault));
        deployed.vault.setSlashingManager(address(deployed.slashingManager));
    }

    function _configureInitialTiers(LockTierRegistry registry, uint128 minimumStake) internal {
        registry.createTier("Flexible", 0, 1 hours, 10_000, 0, minimumStake);
        registry.createTier("Bronze 30D", 30 days, 1 days, 12_500, 1000, minimumStake);
        registry.createTier("Silver 90D", 90 days, 1 days, 17_500, 2500, minimumStake);
        registry.createTier("Gold 365D", 365 days, 1 days, 25_000, 4000, minimumStake);
    }

    function _grantOperationalRoles(EchelonAccessManager manager, Config memory config) internal {
        manager.grantRole(REWARD_MANAGER_ROLE, config.rewardManager);
        manager.grantRole(SLASHER_ROLE, config.slasher);
        manager.grantRole(GUARDIAN_ROLE, config.guardian);
    }

    function _bootstrapRewards(EpochRewardController controller, Config memory config) internal {
        if (config.initialRewardFunding != 0) {
            bool approved = IERC20(config.rewardToken)
                .approve(address(controller), config.initialRewardFunding);
            require(approved, "reward approval failed");
            controller.fundRewards(config.initialRewardFunding);
        }

        if (config.firstEpochBudget != 0) {
            controller.configureEpoch(0, config.firstEpochBudget, config.firstEpochRate);
        }
    }

    function _logDeployment(Deployment memory deployed, Config memory config) internal pure {
        console2.log("Echelon deployment");
        console2.log("AccessManager:    ", address(deployed.accessManager));
        console2.log("TierRegistry:     ", address(deployed.tierRegistry));
        console2.log("PositionToken:    ", address(deployed.positionToken));
        console2.log("PenaltyReserve:   ", address(deployed.penaltyReserve));
        console2.log("RewardController: ", address(deployed.rewardController));
        console2.log("StakingVault:     ", address(deployed.vault));
        console2.log("SlashingManager:  ", address(deployed.slashingManager));
        console2.log("Lens:             ", address(deployed.lens));
        console2.log("Monitor:          ", address(deployed.monitor));
        console2.log("Genesis:          ", uint256(config.genesis));
    }

    function _uint64(uint256 value, string memory name) internal pure returns (uint64) {
        require(value <= type(uint64).max, string.concat(name, " exceeds uint64"));
        return uint64(value);
    }

    function _uint128(uint256 value, string memory name) internal pure returns (uint128) {
        require(value <= type(uint128).max, string.concat(name, " exceeds uint128"));
        return uint128(value);
    }
}
