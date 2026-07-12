// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared constants used by the Echelon staking modules.
library EchelonConstants {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAY = 1e27;

    uint8 internal constant MAX_TIERS = 16;
    uint16 internal constant MAX_EXIT_PENALTY_BPS = 5000;
    uint16 internal constant MAX_SLASH_BPS = 8000;

    uint64 internal constant MIN_EPOCH_DURATION = 1 hours;
    uint64 internal constant MAX_EPOCH_DURATION = 30 days;
    uint32 internal constant MAX_EPOCHS_PER_SYNC = 64;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 internal constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 internal constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
}

enum PositionStatus {
    None,
    Active,
    Closed
}

enum ReserveCreditKind {
    EarlyExit,
    GovernanceSlash,
    RoundingSurplus
}

enum SlashRequestStatus {
    None,
    Queued,
    Executed,
    Cancelled
}

/// @notice Economic parameters attached to a lock tier.
/// @dev Multipliers are expressed in basis points, where 10_000 is 1x.
struct TierConfig {
    uint64 lockDuration;
    uint64 changeCooldown;
    uint32 multiplierBps;
    uint16 maxExitPenaltyBps;
    uint128 minimumStake;
    bool enabled;
    bool exists;
}

/// @notice Per-epoch emission parameters and realized accounting.
struct EpochConfig {
    uint64 startTime;
    uint64 endTime;
    uint128 rewardBudget;
    uint128 emittedRewards;
    uint128 rewardRate;
    bool enabled;
    bool finalized;
}

/// @notice Reward checkpoint owned by a staking position.
struct RewardLedger {
    uint32 epoch;
    uint64 lastCheckpoint;
    uint256 indexPaid;
    uint256 carriedReward;
    uint256 storedReward;
}

/// @notice Principal, commitment, and reward state for one position NFT.
struct StakePosition {
    uint256 principal;
    uint256 rewardWeight;
    uint256 totalSlashed;
    uint64 createdAt;
    uint64 commitmentStartedAt;
    uint64 unlockAt;
    uint64 lastTierChange;
    uint32 tierId;
    uint16 commitmentPenaltyBps;
    PositionStatus status;
    RewardLedger rewards;
}

/// @notice Delayed governance action used by the slashing module.
struct SlashRequest {
    uint256 positionId;
    uint16 slashBps;
    uint64 queuedAt;
    uint64 executableAt;
    bytes32 evidenceHash;
    SlashRequestStatus status;
    address proposer;
}

/// @notice Read model returned by vault preview methods.
struct PositionPreview {
    uint256 positionId;
    address owner;
    uint256 principal;
    uint256 rewardWeight;
    uint256 pendingReward;
    uint256 earlyExitPenalty;
    uint256 withdrawablePrincipal;
    uint64 unlockAt;
    uint32 tierId;
    bool matured;
}

/// @notice Aggregate accounting exposed for monitoring and invariants.
struct ProtocolSnapshot {
    uint256 totalPrincipal;
    uint256 totalRewardWeight;
    uint256 rewardIndex;
    uint256 rewardLiquidity;
    uint256 totalRewardsFunded;
    uint256 totalRewardsPaid;
    uint256 totalPenalties;
    uint256 totalSlashed;
    uint32 currentEpoch;
    bool depositsPaused;
    bool exitsPaused;
}
