// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev A router that swaps at a fixed rate. It deliberately does NOT enforce minOut — the
///      account's balance-delta check is the authority. That lets us test the account's own guard.
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    mapping(address assetIn => mapping(address assetOut => uint256 rate1e18)) public rate;

    function setRate(address assetIn, address assetOut, uint256 rate1e18) external {
        rate[assetIn][assetOut] = rate1e18;
    }

    function swap(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256,
        /*minOut*/
        address to
    )
        external
    {
        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 r = rate[assetIn][assetOut];
        require(r != 0, "no rate");
        uint256 out = amountIn * r / 1e18;
        IERC20(assetOut).safeTransfer(to, out);
    }
}
