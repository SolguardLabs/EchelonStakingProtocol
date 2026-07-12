// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EpochBeforeGenesis } from "../errors/EchelonErrors.sol";

library EpochMath {
    function epochAt(uint256 timestamp, uint64 genesis, uint64 duration)
        internal
        pure
        returns (uint32)
    {
        if (timestamp < genesis) revert EpochBeforeGenesis();
        uint256 epochId = (timestamp - genesis) / duration;
        if (epochId > type(uint32).max) return type(uint32).max;
        return uint32(epochId);
    }

    function startOf(uint32 epochId, uint64 genesis, uint64 duration)
        internal
        pure
        returns (uint64)
    {
        uint256 start = uint256(genesis) + uint256(epochId) * duration;
        return start > type(uint64).max ? type(uint64).max : uint64(start);
    }

    function endOf(uint32 epochId, uint64 genesis, uint64 duration) internal pure returns (uint64) {
        uint256 end = uint256(genesis) + (uint256(epochId) + 1) * duration;
        return end > type(uint64).max ? type(uint64).max : uint64(end);
    }

    function segmentEnd(uint256 target, uint32 epochId, uint64 genesis, uint64 duration)
        internal
        pure
        returns (uint256)
    {
        uint256 boundary = endOf(epochId, genesis, duration);
        return target < boundary ? target : boundary;
    }

    function hasStarted(uint32 epochId, uint64 genesis, uint64 duration, uint256 timestamp)
        internal
        pure
        returns (bool)
    {
        return timestamp >= startOf(epochId, genesis, duration);
    }

    function hasEnded(uint32 epochId, uint64 genesis, uint64 duration, uint256 timestamp)
        internal
        pure
        returns (bool)
    {
        return timestamp >= endOf(epochId, genesis, duration);
    }

    function elapsedInEpoch(uint32 epochId, uint64 genesis, uint64 duration, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        uint256 start = startOf(epochId, genesis, duration);
        if (timestamp <= start) return 0;
        uint256 end = endOf(epochId, genesis, duration);
        uint256 capped = timestamp < end ? timestamp : end;
        return capped - start;
    }
}
