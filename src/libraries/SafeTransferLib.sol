// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ERC20ApproveFailed,
    ERC20TransferFailed,
    ERC20TransferFromFailed
} from "../errors/EchelonErrors.sol";

/// @notice ERC-20 operations supporting tokens that omit boolean return values.
library SafeTransferLib {
    function safeTransfer(address token, address to, uint256 amount) internal {
        bool success;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(pointer, 0x04), to)
            mstore(add(pointer, 0x24), amount)
            success := and(
                or(eq(mload(0x00), 1), iszero(returndatasize())),
                call(gas(), token, 0, pointer, 0x44, 0x00, 0x20)
            )
        }
        if (!success) revert ERC20TransferFailed();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        bool success;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(pointer, 0x04), from)
            mstore(add(pointer, 0x24), to)
            mstore(add(pointer, 0x44), amount)
            success := and(
                or(eq(mload(0x00), 1), iszero(returndatasize())),
                call(gas(), token, 0, pointer, 0x64, 0x00, 0x20)
            )
        }
        if (!success) revert ERC20TransferFromFailed();
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        bool success;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(pointer, 0x04), spender)
            mstore(add(pointer, 0x24), amount)
            success := and(
                or(eq(mload(0x00), 1), iszero(returndatasize())),
                call(gas(), token, 0, pointer, 0x44, 0x00, 0x20)
            )
        }
        if (!success) revert ERC20ApproveFailed();
    }
}
