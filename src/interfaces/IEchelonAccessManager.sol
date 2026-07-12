// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEchelonAccessManager {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function checkRole(bytes32 role, address account) external view;

    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role) external;
}
