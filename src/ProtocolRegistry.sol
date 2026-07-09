// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {AdapterType, PositionClass, Status, ProtocolPosition, Asset} from "./Types.sol";

/// @title ProtocolRegistry
/// @notice The admin-governed approved set. Every account reads it to validate each action.
/// @dev It answers three questions for `executePlan`:
///        1. protocol positions — yield venues you may deposit into;
///        2. assets            — held/stable tokens a swap may produce or you may hold;
///        3. routes            — swap routers a swap may go through.
///      Positions are DISABLED, never deleted, so a user can always `exit`. Admin ownership uses a
///      two-step transfer (safe hand-off to a multisig/timelock at scale).
contract ProtocolRegistry is Ownable2Step {
    error ZeroAddress();
    error BadAdapter();
    error BadClass();
    error UnknownPosition();

    mapping(bytes32 positionId => ProtocolPosition) private _positions;
    bytes32[] private _positionIds; // append-only; enables off-chain enumeration (the indexer)
    mapping(address token => Asset) private _assets;
    mapping(address router => bool approved) public routeApproved;

    event ProtocolAdded(
        bytes32 indexed positionId, AdapterType adapterType, address target, address asset, bytes32 category
    );
    event ProtocolDisabled(bytes32 indexed positionId);
    event AssetAdded(address indexed token, PositionClass class);
    event AssetDisabled(address indexed token);
    event RouteSet(address indexed router, bool approved);

    /// @param admin_ the governance owner (a key for the POC; a multisig/timelock at scale).
    constructor(address admin_) Ownable(admin_) {}

    // ----------------------------------------------------------------- protocol positions

    /// @notice Self-describing id: anyone can recompute it from the load-bearing tuple.
    function positionId(AdapterType adapterType, address target, address asset) public pure returns (bytes32) {
        return keccak256(abi.encode(adapterType, target, asset));
    }

    /// @notice Add a yield venue. Expansion — the gated direction.
    function addProtocol(AdapterType adapterType, address target, address asset, bytes32 category)
        external
        onlyOwner
        returns (bytes32 id)
    {
        if (adapterType != AdapterType.ERC4626 && adapterType != AdapterType.AAVE) revert BadAdapter();
        if (target == address(0) || asset == address(0)) revert ZeroAddress();
        id = positionId(adapterType, target, asset);
        if (_positions[id].target == address(0)) _positionIds.push(id); // first insert only
        _positions[id] = ProtocolPosition(adapterType, target, asset, category, Status.ACTIVE);
        emit ProtocolAdded(id, adapterType, target, asset, category);
    }

    /// @notice Restriction: blocks new deposits. The record is kept so exit/withdraw stay open.
    function disableProtocol(bytes32 id) external onlyOwner {
        if (_positions[id].target == address(0)) revert UnknownPosition();
        _positions[id].status = Status.DISABLED;
        emit ProtocolDisabled(id);
    }

    function getProtocol(bytes32 id) external view returns (ProtocolPosition memory) {
        return _positions[id];
    }

    /// @notice Total number of registered positions (active + disabled; never deleted).
    function positionCount() external view returns (uint256) {
        return _positionIds.length;
    }

    /// @notice All registered position ids, in insertion order — lets an off-chain indexer
    ///         discover every venue without needing to know ids up front.
    function allPositionIds() external view returns (bytes32[] memory) {
        return _positionIds;
    }

    // ----------------------------------------------------------------- approved assets

    function addAsset(address token, PositionClass class_) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (class_ != PositionClass.HELD_ASSET && class_ != PositionClass.STABLECOIN) revert BadClass();
        _assets[token] = Asset(class_, Status.ACTIVE);
        emit AssetAdded(token, class_);
    }

    function disableAsset(address token) external onlyOwner {
        _assets[token].status = Status.DISABLED;
        emit AssetDisabled(token);
    }

    function isAssetApproved(address token) external view returns (bool) {
        return _assets[token].status == Status.ACTIVE;
    }

    function getAsset(address token) external view returns (Asset memory) {
        return _assets[token];
    }

    // ----------------------------------------------------------------- approved routers

    function setRoute(address router, bool approved) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        routeApproved[router] = approved;
        emit RouteSet(router, approved);
    }
}
