// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ProtocolRegistry} from "./ProtocolRegistry.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {AdapterType, Status, ActionKind, Action, ProtocolPosition} from "./Types.sol";

/// @title SmartInvestmentAccount
/// @notice Non-custodial per-user account, deployed as an EIP-1167 clone.
/// @dev The platform can never call this: `executePlan` is `onlyOwner` — the user submits their own
///      transaction. No `Action` kind names an external destination, so funds can only ever move
///      WITHIN this account (idle <-> deployed/held). The only door out is `withdraw`, which sends to
///      the owner's own wallet. `executePlan` dispatches by the position's `adapterType`.
contract SmartInvestmentAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error AlreadyInitialized();
    error ZeroAddress();
    error PositionNotActive();
    error UnknownPosition();
    error BadAdapter();
    error RouteNotApproved();
    error AssetNotApproved();
    error SwapFailed();
    error InsufficientOutput();
    error NothingReceived();

    address public owner;
    ProtocolRegistry public registry;
    bool private _initialized;

    event Deposited(bytes32 indexed positionId, uint256 amount);
    event Withdrawn(bytes32 indexed positionId, uint256 amount);
    event Swapped(address indexed assetIn, address indexed assetOut, uint256 amountIn, uint256 amountOut);
    event WithdrawnToOwner(address indexed token, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Locks the implementation so only clones (fresh storage) can be initialized.
    constructor() {
        _initialized = true;
    }

    /// @dev Set-once; the factory calls this atomically at deploy time (no front-run window).
    function initialize(address owner_, address registry_) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        _initialized = true;
        owner = owner_;
        registry = ProtocolRegistry(registry_);
    }

    // ---------------------------------------------- the platform proposes, the OWNER executes

    /// @notice Run an ordered plan atomically. Any failing action reverts the whole plan.
    function executePlan(Action[] calldata plan) external onlyOwner nonReentrant {
        uint256 n = plan.length;
        for (uint256 i; i < n; ++i) {
            Action calldata a = plan[i];
            if (a.kind == ActionKind.DEPOSIT) {
                _deposit(a.positionId, a.amount);
            } else if (a.kind == ActionKind.WITHDRAW) {
                _withdraw(a.positionId, a.amount);
            } else {
                _swap(a.assetIn, a.assetOut, a.router, a.amount, a.minOut, a.routeData);
            }
        }
    }

    // ---------------------------------------------- user sovereignty (always available)

    /// @notice Unwind a protocol position back to idle. Status-independent — a disabled protocol
    ///         never traps the user. `amount == type(uint256).max` exits the full position.
    function exit(bytes32 positionId, uint256 amount) external onlyOwner nonReentrant {
        _withdraw(positionId, amount);
    }

    /// @notice The only external door: funds leave only to the owner's own wallet.
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(owner, amount);
        emit WithdrawnToOwner(token, amount);
    }

    // ---------------------------------------------- internal adapters (dispatch by adapterType)

    function _deposit(bytes32 id, uint256 amount) internal {
        ProtocolPosition memory p = registry.getProtocol(id);
        if (p.status != Status.ACTIVE) revert PositionNotActive();

        registry.onDeploy(p.asset, amount); // guarded-rollout cap: reverts if this deposit breaches it

        IERC20(p.asset).forceApprove(p.target, amount);
        if (p.adapterType == AdapterType.ERC4626) {
            // A real vault mints shares for the deposit — zero means nothing was credited.
            uint256 shares = IERC4626(p.target).deposit(amount, address(this));
            if (shares == 0) revert NothingReceived();
        } else if (p.adapterType == AdapterType.AAVE) {
            IAavePool(p.target).supply(p.asset, amount, address(this), 0); // returns nothing
        } else {
            revert BadAdapter();
        }
        IERC20(p.asset).forceApprove(p.target, 0);
        emit Deposited(id, amount);
    }

    function _withdraw(bytes32 id, uint256 amount) internal {
        ProtocolPosition memory p = registry.getProtocol(id);
        if (p.target == address(0)) revert UnknownPosition(); // status-independent

        // Snapshot before: the balance-delta is the authoritative "received", not the protocol's own
        // return value (with real funds, never trust a target to report its own payout honestly).
        uint256 balBefore = IERC20(p.asset).balanceOf(address(this));
        if (p.adapterType == AdapterType.ERC4626) {
            IERC4626 v = IERC4626(p.target);
            if (amount == type(uint256).max) {
                uint256 assets = v.redeem(v.balanceOf(address(this)), address(this), address(this));
                if (assets == 0) revert NothingReceived();
            } else {
                uint256 burned = v.withdraw(amount, address(this), address(this));
                if (burned == 0) revert NothingReceived();
            }
        } else if (p.adapterType == AdapterType.AAVE) {
            uint256 got = IAavePool(p.target).withdraw(p.asset, amount, address(this)); // max = all
            if (got == 0) revert NothingReceived();
        } else {
            revert BadAdapter();
        }
        uint256 received = IERC20(p.asset).balanceOf(address(this)) - balBefore;
        if (received == 0) revert NothingReceived();
        // Tell the cap principal came back. Defensive try/catch: a misbehaving registry can NEVER block a
        // withdrawal — money coming out stays unstoppable (the withdraw-anytime guarantee).
        try registry.onReturn(p.asset, received) {} catch {}
        emit Withdrawn(id, received); // the ACTUAL amount out, not the requested/`max` sentinel
    }

    /// @dev The highest-risk path: an opaque call to an APPROVED router, bounded by
    ///      approve-exact (+ reset) and a post-swap balance-delta >= minOut. Even a malicious
    ///      approved router cannot do better than under-deliver, which reverts the whole plan.
    function _swap(
        address assetIn,
        address assetOut,
        address router,
        uint256 amount,
        uint256 minOut,
        bytes calldata routeData
    ) internal {
        ProtocolRegistry r = registry;
        if (!r.routeApproved(router)) revert RouteNotApproved();
        if (!r.isAssetApproved(assetOut)) revert AssetNotApproved();

        // guarded-rollout cap: a base-asset BUY (spending USDC) counts toward the cap and can be blocked;
        // a sell-back (assetIn is not the base asset) no-ops here, so closing a position is never blocked.
        r.onDeploy(assetIn, amount);

        uint256 balBefore = IERC20(assetOut).balanceOf(address(this));

        IERC20(assetIn).forceApprove(router, amount);
        (bool ok,) = router.call(routeData);
        if (!ok) revert SwapFailed();
        IERC20(assetIn).forceApprove(router, 0);

        uint256 out = IERC20(assetOut).balanceOf(address(this)) - balBefore;
        if (out < minOut) revert InsufficientOutput();
        // A sell-back to the base asset credits the cap back; defensively wrapped (never blocks a swap out).
        try r.onReturn(assetOut, out) {} catch {}
        emit Swapped(assetIn, assetOut, amount, out);
    }
}
