// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EchelonConstants } from "../types/EchelonTypes.sol";
import { FullMath } from "./FullMath.sol";

/// @notice Arithmetic shared by position and emission accounting.
library RewardMath {
    using FullMath for uint256;

    function weight(uint256 principal, uint256 multiplierBps) internal pure returns (uint256) {
        return FullMath.mulDiv(principal, multiplierBps, EchelonConstants.BPS);
    }

    function accrued(uint256 rewardWeight, uint256 currentIndex, uint256 indexPaid)
        internal
        pure
        returns (uint256)
    {
        if (rewardWeight == 0 || currentIndex <= indexPaid) return 0;
        return FullMath.mulDiv(rewardWeight, currentIndex - indexPaid, EchelonConstants.RAY);
    }

    function indexDelta(uint256 rewardAmount, uint256 totalWeight) internal pure returns (uint256) {
        if (rewardAmount == 0 || totalWeight == 0) return 0;
        return FullMath.mulDiv(rewardAmount, EchelonConstants.RAY, totalWeight);
    }

    function emittedForSegment(uint256 rate, uint256 elapsed, uint256 remainingBudget)
        internal
        pure
        returns (uint256)
    {
        if (rate == 0 || elapsed == 0 || remainingBudget == 0) return 0;
        uint256 scheduled;
        if (elapsed > type(uint256).max / rate) {
            scheduled = type(uint256).max;
        } else {
            scheduled = rate * elapsed;
        }
        return FullMath.min(scheduled, remainingBudget);
    }

    function linearExitPenalty(
        uint256 principal,
        uint256 nowTime,
        uint256 unlockAt,
        uint256 commitmentStartedAt,
        uint256 maximumPenaltyBps
    ) internal pure returns (uint256) {
        if (principal == 0 || nowTime >= unlockAt || maximumPenaltyBps == 0) return 0;

        uint256 totalCommitment =
            unlockAt > commitmentStartedAt ? unlockAt - commitmentStartedAt : 1;
        uint256 remaining = unlockAt - nowTime;
        uint256 currentPenaltyBps = FullMath.mulDivUp(maximumPenaltyBps, remaining, totalCommitment);
        if (currentPenaltyBps > maximumPenaltyBps) {
            currentPenaltyBps = maximumPenaltyBps;
        }
        return FullMath.mulDivUp(principal, currentPenaltyBps, EchelonConstants.BPS);
    }

    function proportional(uint256 value, uint256 part, uint256 whole)
        internal
        pure
        returns (uint256)
    {
        if (value == 0 || part == 0 || whole == 0) return 0;
        return FullMath.mulDiv(value, part, whole);
    }
}
