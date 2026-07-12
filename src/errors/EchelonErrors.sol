// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

error ZeroAddress();
error ZeroAmount();
error Unauthorized(bytes32 role, address account);
error InvalidRoleAdmin(bytes32 role);
error CannotRenounceDefaultAdmin();
error AdminTransferNotPending();
error AdminTransferNotReady(uint64 readyAt);
error SameAdminCandidate();

error Reentrancy();
error DepositsPaused();
error ExitsPaused();
error ContractPaused();
error PositionNotFound(uint256 positionId);
error PositionNotActive(uint256 positionId);
error PositionNotAuthorized(uint256 positionId, address caller);
error InvalidRecipient();
error InsufficientPositionBalance(uint256 requested, uint256 available);
error PositionBelowMinimum(uint256 remaining, uint256 minimum);
error PenaltyExceedsLimit(uint256 quoted, uint256 accepted);
error TokenNotRecoverable(address token);
error UnsupportedTokenBehavior();
error RewardTokenMatchesStakingToken();
error SlashingManagerAlreadyConfigured();
error SlashingManagerNotConfigured();
error OnlySlashingManager(address caller);
error PositionHasPendingSlash(uint256 positionId, uint256 requestCount);
error PositionHasPrincipal(uint256 positionId, uint256 principal);
error PositionHasRewards(uint256 positionId, uint256 rewards);

error TierNotFound(uint32 tierId);
error TierDisabled(uint32 tierId);
error TooManyTiers();
error InvalidTierMultiplier(uint256 multiplierBps);
error InvalidTierDuration(uint256 duration);
error InvalidTierPenalty(uint256 penaltyBps);
error InvalidTierMinimum(uint256 minimumStake);
error TierChangeOnCooldown(uint64 availableAt);
error SameTier(uint32 tierId);

error InvalidEpochDuration(uint256 duration);
error EpochBeforeGenesis();
error EpochAlreadyConfigured(uint32 epochId);
error EpochNotConfigured(uint32 epochId);
error EpochAlreadyStarted(uint32 epochId);
error EpochNotEnded(uint32 epochId);
error EpochAlreadyFinalized(uint32 epochId);
error InvalidRewardBudget(uint256 budget);
error InvalidRewardRate(uint256 rate);
error EpochBudgetExceeded(uint256 attempted, uint256 budget);
error EpochSyncLimitExceeded(uint32 traversed);
error RewardLiquidityInsufficient(uint256 requested, uint256 available);
error VaultAlreadyConfigured();
error VaultNotConfigured();
error OnlyStakingVault(address caller);
error WeightAccountingMismatch(uint256 removedWeight, uint256 trackedWeight);

error ERC20TransferFailed();
error ERC20TransferFromFailed();
error ERC20ApproveFailed();

error TokenAlreadyMinted(uint256 tokenId);
error TokenDoesNotExist(uint256 tokenId);
error InvalidTokenOwner(address owner);
error InvalidTokenReceiver(address receiver);
error ApprovalToCurrentOwner();
error ApproveCallerNotOwnerNorOperator();
error TransferCallerNotOwnerNorApproved();
error TransferFromIncorrectOwner(address expected, address actual);
error ReceiverRejectedTokens();
error BaseUriFrozen();

error ReserveSourceAlreadyConfigured();
error InvalidReserveSource(address source);
error ReserveWithdrawalExceedsBalance(uint256 requested, uint256 available);

error InvalidSlashBps(uint256 slashBps);
error SlashRequestNotFound(uint256 requestId);
error SlashRequestNotQueued(uint256 requestId);
error SlashRequestNotReady(uint64 executableAt);
error SlashRequestAlreadyResolved(uint256 requestId);
error SlashDelayOutOfRange(uint256 delay);
error EvidenceHashRequired();
error BatchTooLarge(uint256 length, uint256 maximum);
error PositionIdsNotStrictlyIncreasing();
