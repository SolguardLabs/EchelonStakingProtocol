// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEchelonAccessManager } from "../interfaces/IEchelonAccessManager.sol";
import { EchelonConstants } from "../types/EchelonTypes.sol";
import {
    ZeroAddress,
    Unauthorized,
    CannotRenounceDefaultAdmin,
    AdminTransferNotPending,
    AdminTransferNotReady,
    SameAdminCandidate
} from "../errors/EchelonErrors.sol";

/// @title EchelonAccessManager
/// @notice Central role registry shared by all protocol modules.
contract EchelonAccessManager is IEchelonAccessManager {
    struct RoleData {
        mapping(address => bool) members;
        bytes32 adminRole;
    }

    mapping(bytes32 => RoleData) private _roles;

    address public defaultAdmin;
    address public pendingDefaultAdmin;
    uint64 public pendingAdminReadyAt;
    uint64 public immutable adminTransferDelay;

    event RoleAdminChanged(
        bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole
    );
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event DefaultAdminTransferScheduled(
        address indexed currentAdmin, address indexed pendingAdmin, uint64 readyAt
    );
    event DefaultAdminTransferCancelled(address indexed cancelledAdmin);
    event DefaultAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    constructor(address initialAdmin, uint64 transferDelay) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        defaultAdmin = initialAdmin;
        adminTransferDelay = transferDelay;

        _roles[EchelonConstants.DEFAULT_ADMIN_ROLE].adminRole = EchelonConstants.DEFAULT_ADMIN_ROLE;
        _grantRole(EchelonConstants.DEFAULT_ADMIN_ROLE, initialAdmin);

        _setRoleAdmin(EchelonConstants.GOVERNOR_ROLE, EchelonConstants.DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(EchelonConstants.REWARD_MANAGER_ROLE, EchelonConstants.GOVERNOR_ROLE);
        _setRoleAdmin(EchelonConstants.SLASHER_ROLE, EchelonConstants.GOVERNOR_ROLE);
        _setRoleAdmin(EchelonConstants.GUARDIAN_ROLE, EchelonConstants.GOVERNOR_ROLE);
        _setRoleAdmin(EchelonConstants.KEEPER_ROLE, EchelonConstants.GOVERNOR_ROLE);

        _grantRole(EchelonConstants.GOVERNOR_ROLE, initialAdmin);
    }

    modifier onlyRole(bytes32 role) {
        checkRole(role, msg.sender);
        _;
    }

    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return _roles[role].members[account];
    }

    function getRoleAdmin(bytes32 role) public view override returns (bytes32) {
        return _roles[role].adminRole;
    }

    function checkRole(bytes32 role, address account) public view override {
        if (!hasRole(role, account)) revert Unauthorized(role, account);
    }

    function grantRole(bytes32 role, address account)
        external
        override
        onlyRole(getRoleAdmin(role))
    {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account)
        external
        override
        onlyRole(getRoleAdmin(role))
    {
        if (role == EchelonConstants.DEFAULT_ADMIN_ROLE && account == defaultAdmin) {
            revert CannotRenounceDefaultAdmin();
        }
        _revokeRole(role, account);
    }

    function renounceRole(bytes32 role) external override {
        if (role == EchelonConstants.DEFAULT_ADMIN_ROLE) {
            revert CannotRenounceDefaultAdmin();
        }
        _revokeRole(role, msg.sender);
    }

    function setRoleAdmin(bytes32 role, bytes32 adminRole)
        external
        onlyRole(EchelonConstants.DEFAULT_ADMIN_ROLE)
    {
        _setRoleAdmin(role, adminRole);
    }

    function scheduleDefaultAdminTransfer(address candidate)
        external
        onlyRole(EchelonConstants.DEFAULT_ADMIN_ROLE)
    {
        if (candidate == address(0)) revert ZeroAddress();
        if (candidate == defaultAdmin) revert SameAdminCandidate();

        pendingDefaultAdmin = candidate;
        pendingAdminReadyAt = uint64(block.timestamp + adminTransferDelay);
        emit DefaultAdminTransferScheduled(defaultAdmin, candidate, pendingAdminReadyAt);
    }

    function cancelDefaultAdminTransfer() external onlyRole(EchelonConstants.DEFAULT_ADMIN_ROLE) {
        address candidate = pendingDefaultAdmin;
        if (candidate == address(0)) revert AdminTransferNotPending();
        pendingDefaultAdmin = address(0);
        pendingAdminReadyAt = 0;
        emit DefaultAdminTransferCancelled(candidate);
    }

    function acceptDefaultAdminTransfer() external {
        if (msg.sender != pendingDefaultAdmin) revert AdminTransferNotPending();
        if (block.timestamp < pendingAdminReadyAt) {
            revert AdminTransferNotReady(pendingAdminReadyAt);
        }

        address previous = defaultAdmin;
        defaultAdmin = msg.sender;
        pendingDefaultAdmin = address(0);
        pendingAdminReadyAt = 0;

        _grantRole(EchelonConstants.DEFAULT_ADMIN_ROLE, msg.sender);
        _revokeRole(EchelonConstants.DEFAULT_ADMIN_ROLE, previous);
        emit DefaultAdminTransferred(previous, msg.sender);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role].members[account]) {
            _roles[role].members[account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (_roles[role].members[account]) {
            _roles[role].members[account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal {
        bytes32 previous = _roles[role].adminRole;
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previous, adminRole);
    }
}
