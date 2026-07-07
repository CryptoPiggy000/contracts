// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal Aave-V3-shaped pool: pulls the asset on supply, returns it on withdraw.
///      Tracks balances internally (real Aave mints aTokens; not needed to test the adapter).
contract MockAavePool {
    using SafeERC20 for IERC20;

    mapping(address user => mapping(address asset => uint256)) public supplied;

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
