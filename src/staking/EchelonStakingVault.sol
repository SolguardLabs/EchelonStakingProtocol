// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IEchelonAccessManager } from "../interfaces/IEchelonAccessManager.sol";
import {
    ILockTierRegistry,
    IEpochRewardController,
    IStakePositionToken,
    IPenaltyReserve,
    IStakingSlashTarget,
    ISlashingManagerView
} from "../interfaces/IEchelonModules.sol";
import {
    TierConfig,
    RewardLedger,
    StakePosition,
    PositionPreview,
    ProtocolSnapshot,
    PositionStatus,
    ReserveCreditKind,
    EchelonConstants
} from "../types/EchelonTypes.sol";
import { RewardMath } from "../libraries/RewardMath.sol";
import { FullMath } from "../libraries/FullMath.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import {
    ZeroAddress,
    ZeroAmount,
    Reentrancy,
    DepositsPaused,
    ExitsPaused,
    ContractPaused,
    PositionNotFound,
    PositionNotActive,
    PositionNotAuthorized,
    InvalidRecipient,
    InsufficientPositionBalance,
    PositionBelowMinimum,
    PenaltyExceedsLimit,
    TokenNotRecoverable,
    UnsupportedTokenBehavior,
    RewardTokenMatchesStakingToken,
    TierChangeOnCooldown,
    SameTier,
    InvalidSlashBps,
    SlashingManagerAlreadyConfigured,
    SlashingManagerNotConfigured,
    OnlySlashingManager,
    PositionHasPendingSlash,
    PositionHasPrincipal,
    PositionHasRewards
} from "../errors/EchelonErrors.sol";

/// @title EchelonStakingVault
/// @notice Principal custody, position lifecycle, lock commitments, and reward attribution.
contract EchelonStakingVault is IStakingSlashTarget {
    using SafeTransferLib for address;

    IERC20 public immutable stakingToken;
    address public immutable rewardToken;
    IEchelonAccessManager public immutable accessManager;
    ILockTierRegistry public immutable tierRegistry;
    IEpochRewardController public immutable rewardController;
    IStakePositionToken public immutable positionToken;
    IPenaltyReserve public immutable penaltyReserve;

    address public slashingManager;

    uint256 public nextPositionId = 1;
    uint256 public totalPrincipal;
    uint256 public totalPrincipalSlashed;
    uint256 public totalExitPenalties;

    bool public depositsArePaused;
    bool public exitsArePaused;
    bool public tierChangesArePaused;

    uint256 private _reentrancyState = 1;
    mapping(uint256 => StakePosition) private _positions;

    event PositionOpened(
        uint256 indexed positionId,
        address indexed funder,
        address indexed owner,
        uint256 principal,
        uint32 tierId,
        uint256 rewardWeight,
        uint64 unlockAt
    );
    event PositionIncreased(
        uint256 indexed positionId,
        address indexed funder,
        uint256 amount,
        uint256 newPrincipal,
        uint256 newRewardWeight
    );
    event TierChanged(
        uint256 indexed positionId,
        uint32 indexed previousTierId,
        uint32 indexed newTierId,
        uint256 previousWeight,
        uint256 newWeight,
        uint64 unlockAt
    );
    event PositionWithdrawn(
        uint256 indexed positionId,
        address indexed recipient,
        uint256 principalRemoved,
        uint256 penalty,
        uint256 principalReceived,
        uint256 remainingPrincipal
    );
    event RewardClaimed(
        uint256 indexed positionId, address indexed owner, address indexed recipient, uint256 amount
    );
    event PositionSlashed(
        uint256 indexed positionId,
        uint256 amount,
        uint16 slashBps,
        bytes32 indexed evidenceHash,
        uint256 remainingPrincipal
    );
    event PositionClosed(uint256 indexed positionId, address indexed owner);
    event SlashingManagerConfigured(address indexed slashingManager);
    event DepositPauseChanged(bool paused);
    event ExitPauseChanged(bool paused);
    event TierChangePauseChanged(bool paused);
    event ForeignTokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    constructor(
        address stakingToken_,
        address rewardToken_,
        address accessManager_,
        address tierRegistry_,
        address rewardController_,
        address positionToken_,
        address penaltyReserve_
    ) {
        if (
            stakingToken_ == address(0) || rewardToken_ == address(0)
                || accessManager_ == address(0) || tierRegistry_ == address(0)
                || rewardController_ == address(0) || positionToken_ == address(0)
                || penaltyReserve_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (stakingToken_ == rewardToken_) revert RewardTokenMatchesStakingToken();

        stakingToken = IERC20(stakingToken_);
        rewardToken = rewardToken_;
        accessManager = IEchelonAccessManager(accessManager_);
        tierRegistry = ILockTierRegistry(tierRegistry_);
        rewardController = IEpochRewardController(rewardController_);
        positionToken = IStakePositionToken(positionToken_);
        penaltyReserve = IPenaltyReserve(penaltyReserve_);
    }

    modifier nonReentrant() {
        if (_reentrancyState != 1) revert Reentrancy();
        _reentrancyState = 2;
        _;
        _reentrancyState = 1;
    }

    modifier onlyGovernor() {
        accessManager.checkRole(EchelonConstants.GOVERNOR_ROLE, msg.sender);
        _;
    }

    modifier onlyGuardian() {
        if (
            !accessManager.hasRole(EchelonConstants.GUARDIAN_ROLE, msg.sender)
                && !accessManager.hasRole(EchelonConstants.GOVERNOR_ROLE, msg.sender)
        ) {
            accessManager.checkRole(EchelonConstants.GUARDIAN_ROLE, msg.sender);
        }
        _;
    }

    modifier onlySlashManager() {
        if (slashingManager == address(0)) revert SlashingManagerNotConfigured();
        if (msg.sender != slashingManager) revert OnlySlashingManager(msg.sender);
        _;
    }

    function setSlashingManager(address slashingManager_) external onlyGovernor {
        if (slashingManager_ == address(0)) revert ZeroAddress();
        if (slashingManager != address(0)) revert SlashingManagerAlreadyConfigured();
        slashingManager = slashingManager_;
        emit SlashingManagerConfigured(slashingManager_);
    }

    function setDepositsPaused(bool paused) external onlyGuardian {
        depositsArePaused = paused;
        emit DepositPauseChanged(paused);
    }

    function setExitsPaused(bool paused) external onlyGuardian {
        exitsArePaused = paused;
        emit ExitPauseChanged(paused);
    }

    function setTierChangesPaused(bool paused) external onlyGuardian {
        tierChangesArePaused = paused;
        emit TierChangePauseChanged(paused);
    }

    function stake(uint256 amount, uint32 tierId, address recipient)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        if (depositsArePaused) revert DepositsPaused();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();

        TierConfig memory config = tierRegistry.requireActiveTier(tierId);
        if (amount < config.minimumStake) {
            revert PositionBelowMinimum(amount, config.minimumStake);
        }

        _pullExactStakingTokens(msg.sender, amount);
        uint256 rewardWeight = RewardMath.weight(amount, config.multiplierBps);
        (uint256 index, uint32 epochId) = rewardController.onWeightChange(0, rewardWeight);

        positionId = nextPositionId++;
        uint64 nowTime = uint64(block.timestamp);
        uint64 unlockAt = uint64(block.timestamp + config.lockDuration);
        _positions[positionId] = StakePosition({
            principal: amount,
            rewardWeight: rewardWeight,
            totalSlashed: 0,
            createdAt: nowTime,
            commitmentStartedAt: nowTime,
            unlockAt: unlockAt,
            lastTierChange: nowTime,
            tierId: tierId,
            commitmentPenaltyBps: config.maxExitPenaltyBps,
            status: PositionStatus.Active,
            rewards: RewardLedger({
                epoch: epochId,
                lastCheckpoint: nowTime,
                indexPaid: index,
                carriedReward: 0,
                storedReward: 0
            })
        });

        totalPrincipal += amount;
        positionToken.mint(recipient, positionId);
        emit PositionOpened(
            positionId, msg.sender, recipient, amount, tierId, rewardWeight, unlockAt
        );
    }

    function increasePosition(uint256 positionId, uint256 amount) external nonReentrant {
        if (depositsArePaused) revert DepositsPaused();
        if (amount == 0) revert ZeroAmount();
        _requireAuthorized(positionId);

        StakePosition storage stakePosition = _activePosition(positionId);
        TierConfig memory config = tierRegistry.requireActiveTier(stakePosition.tierId);
        uint256 newPrincipal = stakePosition.principal + amount;
        uint256 newWeight = RewardMath.weight(newPrincipal, config.multiplierBps);

        _pullExactStakingTokens(msg.sender, amount);
        (uint256 index, uint32 epochId) =
            rewardController.onWeightChange(stakePosition.rewardWeight, newWeight);
        _accruePosition(stakePosition, index, epochId);

        stakePosition.principal = newPrincipal;
        stakePosition.rewardWeight = newWeight;
        _updateCommitment(stakePosition, config);
        totalPrincipal += amount;
        emit PositionIncreased(positionId, msg.sender, amount, newPrincipal, newWeight);
    }

    function changeTier(uint256 positionId, uint32 newTierId) external nonReentrant {
        if (tierChangesArePaused) revert ContractPaused();
        _requireAuthorized(positionId);

        StakePosition storage stakePosition = _activePosition(positionId);
        uint32 oldTierId = stakePosition.tierId;
        if (newTierId == oldTierId) revert SameTier(newTierId);

        TierConfig memory oldConfig = tierRegistry.tier(oldTierId);
        TierConfig memory newConfig = tierRegistry.requireActiveTier(newTierId);
        if (stakePosition.principal < newConfig.minimumStake) {
            revert PositionBelowMinimum(stakePosition.principal, newConfig.minimumStake);
        }

        uint64 cooldown = oldConfig.changeCooldown > newConfig.changeCooldown
            ? oldConfig.changeCooldown
            : newConfig.changeCooldown;
        uint64 availableAt = stakePosition.lastTierChange + cooldown;
        if (block.timestamp < availableAt) revert TierChangeOnCooldown(availableAt);

        uint256 oldWeight = stakePosition.rewardWeight;
        uint256 newWeight = RewardMath.weight(stakePosition.principal, newConfig.multiplierBps);
        (uint256 index, uint32 epochId) = rewardController.onWeightChange(oldWeight, newWeight);

        _rollRewardEpoch(stakePosition, index, epochId);
        _updateCommitment(stakePosition, newConfig);
        stakePosition.tierId = newTierId;
        stakePosition.rewardWeight = newWeight;
        stakePosition.lastTierChange = uint64(block.timestamp);

        emit TierChanged(
            positionId, oldTierId, newTierId, oldWeight, newWeight, stakePosition.unlockAt
        );
    }

    function claim(uint256 positionId, address recipient)
        external
        nonReentrant
        returns (uint256 reward)
    {
        _requireAuthorized(positionId);
        if (recipient == address(0)) revert InvalidRecipient();
        StakePosition storage stakePosition = _activePosition(positionId);

        (uint256 index, uint32 epochId) = rewardController.sync();
        _accruePosition(stakePosition, index, epochId);
        reward = _consumeRewards(stakePosition);

        if (reward != 0) rewardController.payReward(recipient, reward);
        emit RewardClaimed(positionId, positionToken.ownerOf(positionId), recipient, reward);
    }

    function unstake(uint256 positionId, uint256 amount, address recipient, uint256 maximumPenalty)
        external
        nonReentrant
        returns (uint256 received, uint256 penalty)
    {
        if (exitsArePaused) revert ExitsPaused();
        _requireAuthorized(positionId);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();

        StakePosition storage stakePosition = _activePosition(positionId);
        _requireNoPendingSlash(positionId);
        uint256 oldPrincipal = stakePosition.principal;
        if (amount > oldPrincipal) {
            revert InsufficientPositionBalance(amount, oldPrincipal);
        }

        uint256 remainingPrincipal = oldPrincipal - amount;
        TierConfig memory config = tierRegistry.tier(stakePosition.tierId);
        if (remainingPrincipal != 0 && remainingPrincipal < config.minimumStake) {
            revert PositionBelowMinimum(remainingPrincipal, config.minimumStake);
        }

        uint256 newWeight = RewardMath.weight(remainingPrincipal, config.multiplierBps);
        (uint256 index, uint32 epochId) =
            rewardController.onWeightChange(stakePosition.rewardWeight, newWeight);
        _accruePosition(stakePosition, index, epochId);

        penalty = tierRegistry.previewExitPenalty(
            amount,
            stakePosition.commitmentStartedAt,
            stakePosition.unlockAt,
            stakePosition.commitmentPenaltyBps
        );
        if (penalty > maximumPenalty) revert PenaltyExceedsLimit(penalty, maximumPenalty);

        stakePosition.principal = remainingPrincipal;
        stakePosition.rewardWeight = newWeight;
        totalPrincipal -= amount;

        if (penalty != 0) {
            totalExitPenalties += penalty;
            address(stakingToken).safeTransfer(address(penaltyReserve), penalty);
            penaltyReserve.notifyCredit(penalty, ReserveCreditKind.EarlyExit);
        }
        received = amount - penalty;
        if (received != 0) address(stakingToken).safeTransfer(recipient, received);

        emit PositionWithdrawn(positionId, recipient, amount, penalty, received, remainingPrincipal);
    }

    function closePosition(uint256 positionId) external nonReentrant {
        _requireAuthorized(positionId);
        StakePosition storage stakePosition = _activePosition(positionId);
        _requireNoPendingSlash(positionId);
        if (stakePosition.principal != 0) {
            revert PositionHasPrincipal(positionId, stakePosition.principal);
        }

        (uint256 index, uint32 epochId) = rewardController.sync();
        _accruePosition(stakePosition, index, epochId);
        uint256 rewards = _pendingStored(stakePosition);
        if (rewards != 0) revert PositionHasRewards(positionId, rewards);

        address owner = positionToken.ownerOf(positionId);
        stakePosition.status = PositionStatus.Closed;
        positionToken.burn(positionId);
        emit PositionClosed(positionId, owner);
    }

    function applySlash(uint256 positionId, uint16 slashBps, bytes32 evidenceHash)
        external
        override
        nonReentrant
        onlySlashManager
        returns (uint256 slashedAmount)
    {
        if (slashBps == 0 || slashBps > EchelonConstants.MAX_SLASH_BPS) {
            revert InvalidSlashBps(slashBps);
        }
        StakePosition storage stakePosition = _activePosition(positionId);
        if (stakePosition.principal == 0) revert ZeroAmount();

        slashedAmount = FullMath.mulDiv(stakePosition.principal, slashBps, EchelonConstants.BPS);
        if (slashedAmount == 0) slashedAmount = 1;

        uint256 remainingPrincipal = stakePosition.principal - slashedAmount;
        TierConfig memory config = tierRegistry.tier(stakePosition.tierId);
        uint256 newWeight = RewardMath.weight(remainingPrincipal, config.multiplierBps);
        (uint256 index, uint32 epochId) =
            rewardController.onWeightChange(stakePosition.rewardWeight, newWeight);
        _accruePosition(stakePosition, index, epochId);

        stakePosition.principal = remainingPrincipal;
        stakePosition.rewardWeight = newWeight;
        stakePosition.totalSlashed += slashedAmount;
        totalPrincipal -= slashedAmount;
        totalPrincipalSlashed += slashedAmount;

        address(stakingToken).safeTransfer(address(penaltyReserve), slashedAmount);
        penaltyReserve.notifyCredit(slashedAmount, ReserveCreditKind.GovernanceSlash);
        emit PositionSlashed(positionId, slashedAmount, slashBps, evidenceHash, remainingPrincipal);
    }

    function position(uint256 positionId) external view override returns (StakePosition memory) {
        return _positions[positionId];
    }

    function pendingRewards(uint256 positionId) public view returns (uint256) {
        StakePosition memory stakePosition = _positions[positionId];
        if (stakePosition.status == PositionStatus.None) revert PositionNotFound(positionId);
        if (stakePosition.status != PositionStatus.Active) return 0;

        uint256 previewIndex = rewardController.previewGlobalRewardIndex(block.timestamp);
        return _pendingAtIndex(stakePosition, previewIndex);
    }

    function previewPosition(uint256 positionId)
        external
        view
        override
        returns (PositionPreview memory preview)
    {
        StakePosition memory stakePosition = _positions[positionId];
        if (stakePosition.status == PositionStatus.None) revert PositionNotFound(positionId);

        address owner;
        if (stakePosition.status == PositionStatus.Active) {
            owner = positionToken.ownerOf(positionId);
        }
        uint256 penalty = tierRegistry.previewExitPenalty(
            stakePosition.principal,
            stakePosition.commitmentStartedAt,
            stakePosition.unlockAt,
            stakePosition.commitmentPenaltyBps
        );
        preview = PositionPreview({
            positionId: positionId,
            owner: owner,
            principal: stakePosition.principal,
            rewardWeight: stakePosition.rewardWeight,
            pendingReward: stakePosition.status == PositionStatus.Active
                ? pendingRewards(positionId)
                : 0,
            earlyExitPenalty: penalty,
            withdrawablePrincipal: stakePosition.principal - penalty,
            unlockAt: stakePosition.unlockAt,
            tierId: stakePosition.tierId,
            matured: block.timestamp >= stakePosition.unlockAt
        });
    }

    function protocolSnapshot() external view returns (ProtocolSnapshot memory snapshot) {
        snapshot = ProtocolSnapshot({
            totalPrincipal: totalPrincipal,
            totalRewardWeight: rewardController.totalRewardWeight(),
            rewardIndex: rewardController.previewGlobalRewardIndex(block.timestamp),
            rewardLiquidity: rewardController.rewardLiquidity(),
            totalRewardsFunded: rewardController.totalRewardsFunded(),
            totalRewardsPaid: rewardController.totalRewardsPaid(),
            totalPenalties: penaltyReserve.totalPenalties(),
            totalSlashed: penaltyReserve.totalSlashed(),
            currentEpoch: rewardController.currentEpoch(),
            depositsPaused: depositsArePaused,
            exitsPaused: exitsArePaused
        });
    }

    function principalSolvent() external view returns (bool) {
        return stakingToken.balanceOf(address(this)) >= totalPrincipal;
    }

    function recoverForeignToken(address token, address recipient, uint256 amount)
        external
        onlyGovernor
        nonReentrant
    {
        if (token == address(stakingToken) || token == rewardToken) {
            revert TokenNotRecoverable(token);
        }
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        token.safeTransfer(recipient, amount);
        emit ForeignTokenRecovered(token, recipient, amount);
    }

    function _activePosition(uint256 positionId)
        internal
        view
        returns (StakePosition storage stakePosition)
    {
        stakePosition = _positions[positionId];
        if (stakePosition.status == PositionStatus.None) revert PositionNotFound(positionId);
        if (stakePosition.status != PositionStatus.Active) {
            revert PositionNotActive(positionId);
        }
    }

    function _requireAuthorized(uint256 positionId) internal view {
        if (!positionToken.isApprovedOrOwner(msg.sender, positionId)) {
            revert PositionNotAuthorized(positionId, msg.sender);
        }
    }

    function _requireNoPendingSlash(uint256 positionId) internal view {
        if (slashingManager == address(0)) return;
        uint256 pendingRequests =
            ISlashingManagerView(slashingManager).pendingSlashCount(positionId);
        if (pendingRequests != 0) revert PositionHasPendingSlash(positionId, pendingRequests);
    }

    function _pullExactStakingTokens(address from, uint256 amount) internal {
        uint256 beforeBalance = stakingToken.balanceOf(address(this));
        address(stakingToken).safeTransferFrom(from, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert UnsupportedTokenBehavior();
    }

    function _accruePosition(
        StakePosition storage stakePosition,
        uint256 currentIndex,
        uint32 epochId
    ) internal {
        _rollRewardEpoch(stakePosition, currentIndex, epochId);
        uint256 newlyAccrued = RewardMath.accrued(
            stakePosition.rewardWeight, currentIndex, stakePosition.rewards.indexPaid
        );
        stakePosition.rewards.carriedReward += newlyAccrued;
        stakePosition.rewards.indexPaid = currentIndex;
        stakePosition.rewards.lastCheckpoint = uint64(block.timestamp);
    }

    function _rollRewardEpoch(
        StakePosition storage stakePosition,
        uint256 currentIndex,
        uint32 epochId
    ) internal {
        if (stakePosition.rewards.epoch == epochId) return;

        uint256 boundaryIndex = rewardController.epochStartIndex(epochId);
        uint256 priorEpochReward = RewardMath.accrued(
            stakePosition.rewardWeight, boundaryIndex, stakePosition.rewards.indexPaid
        );
        stakePosition.rewards.storedReward += stakePosition.rewards.carriedReward + priorEpochReward;
        stakePosition.rewards.carriedReward = 0;
        stakePosition.rewards.indexPaid =
            boundaryIndex > currentIndex ? currentIndex : boundaryIndex;
        stakePosition.rewards.epoch = epochId;
    }

    function _updateCommitment(StakePosition storage stakePosition, TierConfig memory newConfig)
        internal
    {
        uint64 nowTime = uint64(block.timestamp);
        uint64 candidateUnlock = uint64(block.timestamp + newConfig.lockDuration);

        if (block.timestamp >= stakePosition.unlockAt) {
            stakePosition.commitmentStartedAt = nowTime;
            stakePosition.unlockAt = candidateUnlock;
            stakePosition.commitmentPenaltyBps = newConfig.maxExitPenaltyBps;
            return;
        }

        if (candidateUnlock > stakePosition.unlockAt) {
            stakePosition.commitmentStartedAt = nowTime;
            stakePosition.unlockAt = candidateUnlock;
        }
        if (newConfig.maxExitPenaltyBps > stakePosition.commitmentPenaltyBps) {
            stakePosition.commitmentPenaltyBps = newConfig.maxExitPenaltyBps;
        }
    }

    function _consumeRewards(StakePosition storage stakePosition)
        internal
        returns (uint256 reward)
    {
        reward = _pendingStored(stakePosition);
        stakePosition.rewards.storedReward = 0;
        stakePosition.rewards.carriedReward = 0;
    }

    function _pendingStored(StakePosition storage stakePosition) internal view returns (uint256) {
        return stakePosition.rewards.storedReward + stakePosition.rewards.carriedReward;
    }

    function _pendingAtIndex(StakePosition memory stakePosition, uint256 index)
        internal
        pure
        returns (uint256)
    {
        return stakePosition.rewards.storedReward + stakePosition.rewards.carriedReward
            + RewardMath.accrued(stakePosition.rewardWeight, index, stakePosition.rewards.indexPaid);
    }
}
