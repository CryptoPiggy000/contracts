// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Red-team fixture: an APPROVED router that pulls the input and delivers NOTHING.
///      The account's balance-delta >= minOut check must catch this and revert the whole plan.
contract MaliciousRouter {
    using SafeERC20 for IERC20;

    function swap(address assetIn, address, uint256 amountIn, uint256, address) external {
        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // ... and delivers nothing.
    }
}
