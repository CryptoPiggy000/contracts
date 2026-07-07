// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SmartInvestmentAccount} from "./SmartInvestmentAccount.sol";

/// @title AccountFactory
/// @notice Deploys a per-user account clone (EIP-1167) and initializes it in the SAME transaction,
///         so there is no window to front-run `initialize` and hijack ownership.
/// @dev The CREATE2 salt namespaces addresses per owner, so accounts are counterfactual/derivable.
contract AccountFactory {
    error ZeroAddress();

    address public immutable implementation;
    address public immutable registry;

    event AccountCreated(address indexed owner, address indexed account, bytes32 salt);

    constructor(address implementation_, address registry_) {
        if (implementation_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        implementation = implementation_;
        registry = registry_;
    }

    function createAccount(bytes32 userSalt) external returns (address account) {
        bytes32 salt = keccak256(abi.encode(msg.sender, userSalt));
        account = Clones.cloneDeterministic(implementation, salt);
        SmartInvestmentAccount(account).initialize(msg.sender, registry);
        emit AccountCreated(msg.sender, account, userSalt);
    }

    function predict(address owner_, bytes32 userSalt) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(owner_, userSalt));
        return Clones.predictDeterministicAddress(implementation, salt, address(this));
    }
}
