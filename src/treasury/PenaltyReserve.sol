// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IEchelonAccessManager } from "../interfaces/IEchelonAccessManager.sol";
import { IPenaltyReserve } from "../interfaces/IEchelonModules.sol";
import { ReserveCreditKind, EchelonConstants } from "../types/EchelonTypes.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import {
    ZeroAddress,
    ZeroAmount,
    VaultAlreadyConfigured,
    VaultNotConfigured,
    InvalidReserveSource,
    ReserveWithdrawalExceedsBalance,
    TokenNotRecoverable
} from "../errors/EchelonErrors.sol";

/// @title PenaltyReserve
/// @notice Isolated reserve for early-exit penalties and governance slashes.
contract PenaltyReserve is IPenaltyReserve {
    using SafeTransferLib for address;

    IERC20 public immutable stakingToken;
    IEchelonAccessManager public immutable accessManager;

    address public stakingVault;
    address public treasury;

    uint256 public accountedBalance;
    uint256 public totalWithdrawn;
    uint256 public override totalPenalties;
    uint256 public override totalSlashed;
    uint256 public totalRoundingSurplus;

    event StakingVaultConfigured(address indexed stakingVault);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ReserveCredited(ReserveCreditKind indexed kind, uint256 amount, uint256 accountedBalance);
    event ReserveWithdrawn(address indexed treasury, uint256 amount);
    event ForeignTokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    constructor(address stakingToken_, address accessManager_, address treasury_) {
        if (stakingToken_ == address(0) || accessManager_ == address(0) || treasury_ == address(0))
        {
            revert ZeroAddress();
        }
        stakingToken = IERC20(stakingToken_);
        accessManager = IEchelonAccessManager(accessManager_);
        treasury = treasury_;
    }

    modifier onlyGovernor() {
        accessManager.checkRole(EchelonConstants.GOVERNOR_ROLE, msg.sender);
        _;
    }

    modifier onlyVault() {
        if (stakingVault == address(0)) revert VaultNotConfigured();
        if (msg.sender != stakingVault) revert InvalidReserveSource(msg.sender);
        _;
    }

    function setStakingVault(address stakingVault_) external onlyGovernor {
        if (stakingVault_ == address(0)) revert ZeroAddress();
        if (stakingVault != address(0)) revert VaultAlreadyConfigured();
        stakingVault = stakingVault_;
        emit StakingVaultConfigured(stakingVault_);
    }

    function setTreasury(address newTreasury) external onlyGovernor {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function notifyCredit(uint256 amount, ReserveCreditKind kind) external override onlyVault {
        if (amount == 0) return;
        uint256 balance = stakingToken.balanceOf(address(this));
        uint256 expected = accountedBalance + amount;
        if (balance < expected) revert ReserveWithdrawalExceedsBalance(expected, balance);

        accountedBalance = expected;
        if (kind == ReserveCreditKind.EarlyExit) {
            totalPenalties += amount;
        } else if (kind == ReserveCreditKind.GovernanceSlash) {
            totalSlashed += amount;
        } else {
            totalRoundingSurplus += amount;
        }
        emit ReserveCredited(kind, amount, expected);
    }

    function withdraw(uint256 amount) external onlyGovernor {
        if (amount == 0) revert ZeroAmount();
        if (amount > accountedBalance) {
            revert ReserveWithdrawalExceedsBalance(amount, accountedBalance);
        }
        accountedBalance -= amount;
        totalWithdrawn += amount;
        address(stakingToken).safeTransfer(treasury, amount);
        emit ReserveWithdrawn(treasury, amount);
    }

    function recoverForeignToken(address token, address recipient, uint256 amount)
        external
        onlyGovernor
    {
        if (token == address(stakingToken)) revert TokenNotRecoverable(token);
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        token.safeTransfer(recipient, amount);
        emit ForeignTokenRecovered(token, recipient, amount);
    }

    function unaccountedBalance() external view returns (uint256) {
        uint256 balance = stakingToken.balanceOf(address(this));
        return balance > accountedBalance ? balance - accountedBalance : 0;
    }
}
