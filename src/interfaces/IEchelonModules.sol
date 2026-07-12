// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    TierConfig,
    EpochConfig,
    StakePosition,
    PositionPreview,
    ReserveCreditKind
} from "../types/EchelonTypes.sol";

interface ILockTierRegistry {
    function tierCount() external view returns (uint32);
    function tier(uint32 tierId) external view returns (TierConfig memory);
    function requireActiveTier(uint32 tierId) external view returns (TierConfig memory);

    function calculateWeight(uint256 principal, uint32 tierId) external view returns (uint256);
    function previewExitPenalty(
        uint256 principal,
        uint64 commitmentStartedAt,
        uint64 unlockAt,
        uint16 commitmentPenaltyBps
    ) external view returns (uint256);
}

interface IEpochRewardController {
    function stakingVault() external view returns (address);
    function genesis() external view returns (uint64);
    function epochDuration() external view returns (uint64);
    function currentEpoch() external view returns (uint32);
    function epochAt(uint256 timestamp) external view returns (uint32);
    function epoch(uint32 epochId) external view returns (EpochConfig memory);

    function globalRewardIndex() external view returns (uint256);
    function totalRewardWeight() external view returns (uint256);
    function epochStartIndex(uint32 epochId) external view returns (uint256);
    function rewardLiquidity() external view returns (uint256);
    function totalRewardsFunded() external view returns (uint256);
    function totalRewardsPaid() external view returns (uint256);
    function previewGlobalRewardIndex(uint256 timestamp) external view returns (uint256);

    function sync() external returns (uint256 index, uint32 epochId);
    function onWeightChange(uint256 oldWeight, uint256 newWeight)
        external
        returns (uint256 index, uint32 epochId);
    function payReward(address recipient, uint256 amount) external;
}

interface IStakePositionToken {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool);

    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
}

interface IPenaltyReserve {
    function totalPenalties() external view returns (uint256);
    function totalSlashed() external view returns (uint256);
    function notifyCredit(uint256 amount, ReserveCreditKind kind) external;
}

interface IStakingSlashTarget {
    function position(uint256 positionId) external view returns (StakePosition memory);
    function previewPosition(uint256 positionId) external view returns (PositionPreview memory);
    function applySlash(uint256 positionId, uint16 slashBps, bytes32 evidenceHash)
        external
        returns (uint256 slashedAmount);
}

interface ISlashingManagerView {
    function pendingSlashCount(uint256 positionId) external view returns (uint256);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}
