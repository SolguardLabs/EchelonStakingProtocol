// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEchelonAccessManager } from "../interfaces/IEchelonAccessManager.sol";
import { IStakingSlashTarget } from "../interfaces/IEchelonModules.sol";
import {
    SlashRequest,
    SlashRequestStatus,
    StakePosition,
    PositionStatus,
    EchelonConstants
} from "../types/EchelonTypes.sol";
import {
    ZeroAmount,
    ZeroAddress,
    InvalidSlashBps,
    SlashRequestNotFound,
    SlashRequestNotQueued,
    SlashRequestNotReady,
    SlashRequestAlreadyResolved,
    SlashDelayOutOfRange,
    EvidenceHashRequired,
    BatchTooLarge,
    PositionNotActive
} from "../errors/EchelonErrors.sol";

/// @title SlashingManager
/// @notice Delayed, evidence-addressed slashing for active staking positions.
contract SlashingManager {
    uint64 public constant MIN_SLASH_DELAY = 1 hours;
    uint64 public constant MAX_SLASH_DELAY = 14 days;
    uint256 public constant MAX_BATCH_SIZE = 20;

    IEchelonAccessManager public immutable accessManager;
    IStakingSlashTarget public immutable stakingVault;

    uint64 public slashDelay;
    uint256 public nextRequestId = 1;

    mapping(uint256 => SlashRequest) private _requests;
    mapping(uint256 => uint256) public pendingSlashCount;

    event SlashQueued(
        uint256 indexed requestId,
        uint256 indexed positionId,
        uint16 slashBps,
        bytes32 indexed evidenceHash,
        uint64 executableAt,
        address proposer
    );
    event SlashExecuted(
        uint256 indexed requestId,
        uint256 indexed positionId,
        uint256 slashedAmount,
        address executor
    );
    event SlashCancelled(uint256 indexed requestId, address indexed canceller);
    event SlashDelayUpdated(uint64 previousDelay, uint64 newDelay);

    constructor(address accessManager_, address stakingVault_, uint64 slashDelay_) {
        if (accessManager_ == address(0) || stakingVault_ == address(0)) {
            revert ZeroAddress();
        }
        _validateDelay(slashDelay_);
        accessManager = IEchelonAccessManager(accessManager_);
        stakingVault = IStakingSlashTarget(stakingVault_);
        slashDelay = slashDelay_;
    }

    modifier onlySlasher() {
        accessManager.checkRole(EchelonConstants.SLASHER_ROLE, msg.sender);
        _;
    }

    modifier onlyGovernorOrGuardian() {
        if (
            !accessManager.hasRole(EchelonConstants.GOVERNOR_ROLE, msg.sender)
                && !accessManager.hasRole(EchelonConstants.GUARDIAN_ROLE, msg.sender)
        ) {
            accessManager.checkRole(EchelonConstants.GOVERNOR_ROLE, msg.sender);
        }
        _;
    }

    function queueSlash(uint256 positionId, uint16 slashBps, bytes32 evidenceHash)
        external
        onlySlasher
        returns (uint256 requestId)
    {
        return _queueSlash(positionId, slashBps, evidenceHash, msg.sender);
    }

    function queueSlashBatch(
        uint256[] calldata positionIds,
        uint16[] calldata slashBps,
        bytes32[] calldata evidenceHashes
    ) external onlySlasher returns (uint256[] memory requestIds) {
        uint256 length = positionIds.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert BatchTooLarge(length, MAX_BATCH_SIZE);
        }
        if (slashBps.length != length || evidenceHashes.length != length) {
            revert BatchTooLarge(slashBps.length, length);
        }

        requestIds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            requestIds[i] = _queueSlash(positionIds[i], slashBps[i], evidenceHashes[i], msg.sender);
        }
    }

    function executeSlash(uint256 requestId) public returns (uint256 slashedAmount) {
        SlashRequest storage slashRequest = _requests[requestId];
        if (slashRequest.status == SlashRequestStatus.None) revert SlashRequestNotFound(requestId);
        if (slashRequest.status != SlashRequestStatus.Queued) {
            revert SlashRequestNotQueued(requestId);
        }
        if (block.timestamp < slashRequest.executableAt) {
            revert SlashRequestNotReady(slashRequest.executableAt);
        }

        slashRequest.status = SlashRequestStatus.Executed;
        --pendingSlashCount[slashRequest.positionId];
        slashedAmount = stakingVault.applySlash(
            slashRequest.positionId, slashRequest.slashBps, slashRequest.evidenceHash
        );
        emit SlashExecuted(requestId, slashRequest.positionId, slashedAmount, msg.sender);
    }

    function executeSlashBatch(uint256[] calldata requestIds)
        external
        returns (uint256[] memory slashedAmounts)
    {
        uint256 length = requestIds.length;
        if (length == 0 || length > MAX_BATCH_SIZE) {
            revert BatchTooLarge(length, MAX_BATCH_SIZE);
        }
        slashedAmounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            slashedAmounts[i] = executeSlash(requestIds[i]);
        }
    }

    function cancelSlash(uint256 requestId) external onlyGovernorOrGuardian {
        SlashRequest storage slashRequest = _requests[requestId];
        if (slashRequest.status == SlashRequestStatus.None) revert SlashRequestNotFound(requestId);
        if (slashRequest.status != SlashRequestStatus.Queued) {
            revert SlashRequestAlreadyResolved(requestId);
        }
        slashRequest.status = SlashRequestStatus.Cancelled;
        --pendingSlashCount[slashRequest.positionId];
        emit SlashCancelled(requestId, msg.sender);
    }

    function setSlashDelay(uint64 newDelay) external {
        accessManager.checkRole(EchelonConstants.GOVERNOR_ROLE, msg.sender);
        _validateDelay(newDelay);
        uint64 previous = slashDelay;
        slashDelay = newDelay;
        emit SlashDelayUpdated(previous, newDelay);
    }

    function request(uint256 requestId) external view returns (SlashRequest memory) {
        SlashRequest memory slashRequest = _requests[requestId];
        if (slashRequest.status == SlashRequestStatus.None) {
            revert SlashRequestNotFound(requestId);
        }
        return slashRequest;
    }

    function _queueSlash(
        uint256 positionId,
        uint16 slashBps,
        bytes32 evidenceHash,
        address proposer
    ) internal returns (uint256 requestId) {
        if (slashBps == 0 || slashBps > EchelonConstants.MAX_SLASH_BPS) {
            revert InvalidSlashBps(slashBps);
        }
        if (evidenceHash == bytes32(0)) revert EvidenceHashRequired();
        StakePosition memory stakePosition = stakingVault.position(positionId);
        if (stakePosition.status != PositionStatus.Active) {
            revert PositionNotActive(positionId);
        }
        if (stakePosition.principal == 0) revert ZeroAmount();

        requestId = nextRequestId++;
        uint64 executableAt = uint64(block.timestamp + slashDelay);
        _requests[requestId] = SlashRequest({
            positionId: positionId,
            slashBps: slashBps,
            queuedAt: uint64(block.timestamp),
            executableAt: executableAt,
            evidenceHash: evidenceHash,
            status: SlashRequestStatus.Queued,
            proposer: proposer
        });
        ++pendingSlashCount[positionId];
        emit SlashQueued(requestId, positionId, slashBps, evidenceHash, executableAt, proposer);
    }

    function _validateDelay(uint64 delay_) internal pure {
        if (delay_ < MIN_SLASH_DELAY || delay_ > MAX_SLASH_DELAY) {
            revert SlashDelayOutOfRange(delay_);
        }
    }
}
