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
    error NotFactory();
    error FactoryAlreadySet();
    error DepositCapExceeded();

    mapping(bytes32 positionId => ProtocolPosition) private _positions;
    bytes32[] private _positionIds; // append-only; enables off-chain enumeration (the indexer)
    mapping(address token => Asset) private _assets;
    mapping(address router => bool approved) public routeApproved;

    // --- Guarded rollout: temporary launch controls that limit blast radius WITHOUT touching custody.
    //     Both default OFF (so nothing changes until a deploy enables them) and are meant to be LIFTED
    //     once confidence is earned. Full operator + lift runbook: docs/GUARDED_ROLLOUT.md. ---
    address public factory; // the sole contract allowed to register accounts (set once, post-deploy)
    address public baseAsset; // the unit the cap counts (e.g. USDC); ONLY base-asset flows count/are capped
    bool public whitelistEnabled; // gate WHO may open an account
    bool public depositCapEnabled; // gate HOW MUCH base-asset principal may be deployed in total
    uint256 public depositCap; // max net base-asset principal across all accounts (enforced when enabled)
    uint256 public netDeployed; // current net base-asset principal deployed (deposits+buys − withdraws+sells)
    mapping(address user => bool) public isAllowed; // whitelist membership (used when whitelistEnabled)
    mapping(address account => bool) public isAccount; // factory-registered accounts (may report flows)

    event ProtocolAdded(
        bytes32 indexed positionId, AdapterType adapterType, address target, address asset, bytes32 category
    );
    event ProtocolDisabled(bytes32 indexed positionId);
    event AssetAdded(address indexed token, PositionClass class);
    event AssetDisabled(address indexed token);
    event RouteSet(address indexed router, bool approved);
    // Guarded-rollout events — every guard change and every capped flow is logged, so the rollout and
    // the eventual lift are fully auditable off-chain.
    event FactorySet(address indexed factory);
    event BaseAssetSet(address indexed asset);
    event WhitelistEnabledSet(bool enabled);
    event AllowedSet(address indexed user, bool allowed);
    event DepositCapEnabledSet(bool enabled);
    event DepositCapSet(uint256 cap);
    event AccountRegistered(address indexed account);
    event Deployed(address indexed account, uint256 amount, uint256 netDeployed);
    event Returned(address indexed account, uint256 amount, uint256 netDeployed);

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

    // ----------------------------------------------------------------- guarded rollout (admin)
    // See docs/GUARDED_ROLLOUT.md for the enable-at-deploy → operate → LIFT runbook. All controls are
    // owner-only (the two-step Ownable2Step owner — a multisig at launch) and default to OFF/unset.

    /// @notice Bind the one factory allowed to register accounts. Set once, right after deploy.
    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @notice The unit the deposit cap is denominated in (e.g. USDC). Only flows in this asset count
    ///         toward `netDeployed`/the cap; unset (address(0)) means nothing is capped.
    function setBaseAsset(address asset) external onlyOwner {
        baseAsset = asset;
        emit BaseAssetSet(asset);
    }

    /// @notice Turn the WHO gate on/off. On → only whitelisted addresses may open an account.
    ///         Setting false is the LIFT for the whitelist (anyone may open).
    function setWhitelistEnabled(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistEnabledSet(enabled);
    }

    function setAllowed(address user, bool allowed) public onlyOwner {
        isAllowed[user] = allowed;
        emit AllowedSet(user, allowed);
    }

    /// @notice Add/remove many addresses at once (rollout cohort management).
    function setAllowedBatch(address[] calldata users, bool allowed) external onlyOwner {
        for (uint256 i; i < users.length; ++i) {
            setAllowed(users[i], allowed);
        }
    }

    /// @notice Turn the HOW-MUCH gate on/off. Setting false is the LIFT for the cap (unlimited deploy).
    function setDepositCapEnabled(bool enabled) external onlyOwner {
        depositCapEnabled = enabled;
        emit DepositCapEnabledSet(enabled);
    }

    /// @notice Raise (or lower) the global net base-asset principal ceiling. Raise it as confidence grows.
    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    /// @notice Whether `user` may open an account. True when the whitelist is off or the user is allowed.
    function canOpen(address user) external view returns (bool) {
        return !whitelistEnabled || isAllowed[user];
    }

    // ----------------------------------------------------------------- guarded rollout (system)

    /// @notice The factory marks each account it creates as a legitimate flow reporter. Only the bound
    ///         factory can call this, so no outside contract can spoof an account to game the cap.
    function registerAccount(address account) external {
        if (msg.sender != factory) revert NotFactory();
        isAccount[account] = true;
        emit AccountRegistered(account);
    }

    /// @notice An account reports base-asset principal LEAVING idle into a strategy (a deposit, or a buy
    ///         swap spending the base asset). This is the ONLY guard that can revert — it blocks money
    ///         going IN when the cap would be breached. No-ops for non-accounts and non-base flows, so
    ///         un-wired setups (and any outside caller) are unaffected.
    function onDeploy(address asset, uint256 amount) external {
        if (!isAccount[msg.sender] || asset != baseAsset || amount == 0) return;
        if (depositCapEnabled && netDeployed + amount > depositCap) revert DepositCapExceeded();
        netDeployed += amount;
        emit Deployed(msg.sender, amount, netDeployed);
    }

    /// @notice An account reports base-asset principal RETURNING to idle (a withdraw, or a sell-back swap
    ///         producing the base asset). NEVER reverts on the cap — money coming OUT is never blocked,
    ///         which preserves the withdraw-anytime guarantee. (Accounts also wrap this call defensively.)
    function onReturn(address asset, uint256 amount) external {
        if (!isAccount[msg.sender] || asset != baseAsset || amount == 0) return;
        netDeployed = amount >= netDeployed ? 0 : netDeployed - amount;
        emit Returned(msg.sender, amount, netDeployed);
    }
}
