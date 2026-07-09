// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal Aave-V3-shaped pool: pulls the asset on supply, returns it on withdraw.
///      Tracks balances internally (real Aave mints aTokens; not needed to test the adapter).
contract MockAavePool {
    using SafeERC20 for IERC20;

    uint256 private constant RAY = 1e27;
    uint256 private constant APR_BPS = 1500; // 15%/yr mock yield — gives the engine a real, positive rate
    uint256 private immutable deployedAt;

    mapping(address user => mapping(address asset => uint256)) public supplied;

    constructor() {
        deployedAt = block.timestamp;
    }

    /// @notice Aave-style RAY liquidity index, accruing linearly at APR_BPS since deploy. LOCAL MOCK
    ///         ONLY — a real pool's index is driven by borrower interest. Lets the indexer observe a
    ///         non-flat index (and thus a real APY) as chain time advances.
    function liquidityIndex(address) external view returns (uint256) {
        uint256 elapsed = block.timestamp - deployedAt;
        return RAY + (RAY * APR_BPS * elapsed) / (10_000 * 365 days);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        supplied[onBehalfOf][asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 bal = supplied[msg.sender][asset];
        if (amount > bal) amount = bal; // supports type(uint256).max = all
        supplied[msg.sender][asset] = bal - amount;
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }
}
