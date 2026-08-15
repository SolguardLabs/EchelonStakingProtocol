// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FullMath } from "./FullMath.sol";

/// @title RiskMath
/// @notice Saturating arithmetic and basis-point helpers for operational risk views.
library RiskMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_RATIO_BPS = 1_000_000;

    function saturatingSub(uint256 left, uint256 right) internal pure returns (uint256) {
        return left > right ? left - right : 0;
    }

    function ratioBps(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (numerator == 0 || denominator == 0) return 0;
        uint256 ratio = FullMath.mulDiv(numerator, BPS, denominator);
        return ratio > MAX_RATIO_BPS ? MAX_RATIO_BPS : ratio;
    }

    function applyHaircut(uint256 amount, uint16 haircutBps) internal pure returns (uint256) {
        if (haircutBps >= BPS) return 0;
        return FullMath.mulDiv(amount, BPS - haircutBps, BPS);
    }

    function headroom(uint256 liquidity, uint256 obligations, uint256 targetCoverageBps)
        internal
        pure
        returns (uint256)
    {
        if (targetCoverageBps == 0) return 0;
        uint256 maximumObligations = FullMath.mulDiv(liquidity, BPS, targetCoverageBps);
        return saturatingSub(maximumObligations, obligations);
    }
}
