// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal Aave V3 Pool surface the account uses.
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
