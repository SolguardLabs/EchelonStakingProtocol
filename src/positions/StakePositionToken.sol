// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEchelonAccessManager } from "../interfaces/IEchelonAccessManager.sol";
import { IStakePositionToken, IERC721Receiver } from "../interfaces/IEchelonModules.sol";
import { EchelonConstants } from "../types/EchelonTypes.sol";
import {
    ZeroAddress,
    VaultAlreadyConfigured,
    VaultNotConfigured,
    OnlyStakingVault,
    TokenAlreadyMinted,
    TokenDoesNotExist,
    InvalidTokenOwner,
    InvalidTokenReceiver,
    ApprovalToCurrentOwner,
    ApproveCallerNotOwnerNorOperator,
    TransferCallerNotOwnerNorApproved,
    TransferFromIncorrectOwner,
    ReceiverRejectedTokens,
    BaseUriFrozen
} from "../errors/EchelonErrors.sol";

/// @title StakePositionToken
/// @notice ERC-721 receipt representing control over a staking position.
contract StakePositionToken is IStakePositionToken {
    string public name;
    string public symbol;

    IEchelonAccessManager public immutable accessManager;
    address public stakingVault;

    string private _baseTokenURI;
    bool public baseUriIsFrozen;
    uint256 private _totalSupply;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event StakingVaultConfigured(address indexed stakingVault);
    event BaseUriUpdated(string previousBaseUri, string newBaseUri);
    event BaseUriPermanentlyFrozen(string baseUri);

    constructor(
        string memory name_,
        string memory symbol_,
        address accessManager_,
        string memory initialBaseUri
    ) {
        if (accessManager_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        accessManager = IEchelonAccessManager(accessManager_);
        _baseTokenURI = initialBaseUri;
    }

    modifier onlyGovernor() {
        accessManager.checkRole(EchelonConstants.GOVERNOR_ROLE, msg.sender);
        _;
    }

    modifier onlyVault() {
        if (stakingVault == address(0)) revert VaultNotConfigured();
        if (msg.sender != stakingVault) revert OnlyStakingVault(msg.sender);
        _;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x80ac58cd // ERC-721
            || interfaceId == 0x5b5e139f; // ERC-721 metadata
    }

    function setStakingVault(address stakingVault_) external onlyGovernor {
        if (stakingVault_ == address(0)) revert ZeroAddress();
        if (stakingVault != address(0)) revert VaultAlreadyConfigured();
        stakingVault = stakingVault_;
        emit StakingVaultConfigured(stakingVault_);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert InvalidTokenOwner(owner);
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view override returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist(tokenId);
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        ownerOf(tokenId);
        string memory base = _baseTokenURI;
        if (bytes(base).length == 0) return "";
        return string.concat(base, _toString(tokenId));
    }

    function baseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    function setBaseURI(string calldata newBaseUri) external onlyGovernor {
        if (baseUriIsFrozen) revert BaseUriFrozen();
        string memory previous = _baseTokenURI;
        _baseTokenURI = newBaseUri;
        emit BaseUriUpdated(previous, newBaseUri);
    }

    function freezeBaseURI() external onlyGovernor {
        if (baseUriIsFrozen) revert BaseUriFrozen();
        baseUriIsFrozen = true;
        emit BaseUriPermanentlyFrozen(_baseTokenURI);
    }

    function approve(address approved, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (approved == owner) revert ApprovalToCurrentOwner();
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) {
            revert ApproveCallerNotOwnerNorOperator();
        }
        _approve(approved, tokenId, owner);
    }

    function getApproved(uint256 tokenId) public view override returns (address) {
        ownerOf(tokenId);
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        if (operator == msg.sender) revert ApprovalToCurrentOwner();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function isApprovedOrOwner(address spender, uint256 tokenId)
        public
        view
        override
        returns (bool)
    {
        address owner = ownerOf(tokenId);
        return spender == owner || _tokenApprovals[tokenId] == spender
            || _operatorApprovals[owner][spender];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (!isApprovedOrOwner(msg.sender, tokenId)) {
            revert TransferCallerNotOwnerNorApproved();
        }
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (!_checkOnERC721Received(msg.sender, from, to, tokenId, data)) {
            revert ReceiverRejectedTokens();
        }
    }

    function mint(address to, uint256 tokenId) external override onlyVault {
        if (to == address(0)) revert InvalidTokenReceiver(to);
        if (_owners[tokenId] != address(0)) revert TokenAlreadyMinted(tokenId);

        unchecked {
            _balances[to] += 1;
            _totalSupply += 1;
        }
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function safeMint(address to, uint256 tokenId, bytes calldata data) external onlyVault {
        if (to == address(0)) revert InvalidTokenReceiver(to);
        if (_owners[tokenId] != address(0)) revert TokenAlreadyMinted(tokenId);

        unchecked {
            _balances[to] += 1;
            _totalSupply += 1;
        }
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);

        if (!_checkOnERC721Received(msg.sender, address(0), to, tokenId, data)) {
            revert ReceiverRejectedTokens();
        }
    }

    function burn(uint256 tokenId) external override onlyVault {
        address owner = ownerOf(tokenId);
        _approve(address(0), tokenId, owner);

        unchecked {
            _balances[owner] -= 1;
            _totalSupply -= 1;
        }
        delete _owners[tokenId];
        emit Transfer(owner, address(0), tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        address owner = ownerOf(tokenId);
        if (owner != from) revert TransferFromIncorrectOwner(from, owner);
        if (to == address(0)) revert InvalidTokenReceiver(to);

        _approve(address(0), tokenId, owner);
        unchecked {
            _balances[from] -= 1;
            _balances[to] += 1;
        }
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _approve(address approved, uint256 tokenId, address owner) internal {
        _tokenApprovals[tokenId] = approved;
        emit Approval(owner, approved, tokenId);
    }

    function _checkOnERC721Received(
        address operator,
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal returns (bool) {
        if (to.code.length == 0) return true;
        try IERC721Receiver(to).onERC721Received(operator, from, tokenId, data) returns (
            bytes4 retval
        ) {
            return retval == IERC721Receiver.onERC721Received.selector;
        } catch {
            return false;
        }
    }

    function _toString(uint256 value) internal pure returns (string memory str) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            unchecked {
                ++digits;
            }
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            unchecked {
                digits -= 1;
            }
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}
