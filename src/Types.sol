// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev How the account reaches a position (execution dispatch).
enum AdapterType {
    NONE,
    ERC4626, // Morpho vaults, Sky sUSDS, Spark savings, ...
    AAVE // Aave V3 Pool (+ forks like Spark)
}

/// @dev What a position is (risk taxonomy). Leverage is excluded -> no 4th class.
enum PositionClass {
    NONE,
    PROTOCOL, // contract risk
    HELD_ASSET, // asset / price risk
    STABLECOIN // denomination / peg risk
}

enum Status {
    NONE,
    ACTIVE,
    DISABLED
}

enum ActionKind {
    DEPOSIT, // idle -> a PROTOCOL position (dispatch by adapterType)
    WITHDRAW, // a PROTOCOL position -> idle
    SWAP // idle token -> idle token, via an approved router
}

/// @dev A yield venue in the registry. DISABLED, never deleted, so exit always resolves.
struct ProtocolPosition {
    AdapterType adapterType;
    address target; // the vault (ERC4626) or the Aave Pool
    address asset; // supplied token (== vault.asset() for ERC4626)
    bytes32 category; // lending | savings | ...
    Status status;
}

/// @dev An approved held / stablecoin token (a swap may produce it; you may hold it).
struct Asset {
    PositionClass class;
    Status status;
}

/// @dev One step of an execution plan. No field names an external destination.
struct Action {
    ActionKind kind;
    bytes32 positionId; // DEPOSIT / WITHDRAW
    address assetIn; // SWAP
    address assetOut; // SWAP
    address router; // SWAP (must be an approved route)
    uint256 amount; // amount in (asset units); WITHDRAW: type(uint).max = all
    uint256 minOut; // SWAP floor
    bytes routeData; // SWAP: opaque router/aggregator calldata
}
