// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ProtocolRegistry} from "../src/ProtocolRegistry.sol";
import {SmartInvestmentAccount} from "../src/SmartInvestmentAccount.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {AdapterType, PositionClass} from "../src/Types.sol";

/// @title DeployBase
/// @notice REAL-FUNDS Base mainnet deploy. Deploys the three contracts, registers the fork-PROVEN Base
///         approved set, and turns the guarded rollout ON (whitelist + deposit cap) — the enable-at-deploy
///         sequence from docs/GUARDED_ROLLOUT.md §4. Admin starts as the deployer (a single key is fine
///         during the guarded phase); hand ownership to a multisig BEFORE lifting the guards (§5).
///
/// @dev Simulate first (no txs, no funds — just validates against live Base state):
///        PRIVATE_KEY=0x<any> forge script script/DeployBase.s.sol --rpc-url base
///      Broadcast the real deploy (needs a FUNDED Base key):
///        PRIVATE_KEY=0x<funded> DEPOSIT_CAP=10000000000 \
///          forge script script/DeployBase.s.sol --rpc-url base --broadcast --verify
///
///      Env:
///        PRIVATE_KEY  deployer / initial single-key admin (required).
///        DEPOSIT_CAP  cap in base-asset units (USDC, 6 dec). Default 10_000e6 = $10k.
///        ALLOWLIST    comma-separated addresses to whitelist at launch (deployer is always allowed).
contract DeployBase is Script {
    // --- verified Base mainnet addresses (proven in test/fork/ForkBaseProtocols.t.sol) ---
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // native USDC, 6 dec (base asset)
    address constant WETH = 0x4200000000000000000000000000000000000006; // canonical WETH (held asset)
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant MOONWELL_USDC = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca; // MetaMorpho ERC-4626, asset=USDC
    address constant UNIV3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // Uniswap SwapRouter02

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 cap = vm.envOr("DEPOSIT_CAP", uint256(10_000e6)); // $10k default
        address[] memory extra = vm.envOr("ALLOWLIST", ",", new address[](0));

        vm.startBroadcast(pk);

        // --- contracts (deployer = admin; single key for the rollout, multisig before the lift) ---
        ProtocolRegistry registry = new ProtocolRegistry(deployer);
        SmartInvestmentAccount impl = new SmartInvestmentAccount();
        AccountFactory factory = new AccountFactory(address(impl), address(registry));

        // --- approved set: only the fork-PROVEN Base venues/assets go live at launch. Expand post-deploy,
        //     each addition gated on its own fork test: cbBTC/SOL/cbXRP held assets + more USDC vaults
        //     (Morpho/Seamless/Steakhouse) via addAsset / addProtocol from the admin. ---
        registry.addProtocol(AdapterType.AAVE, AAVE_V3_POOL, USDC, "lending");
        registry.addProtocol(AdapterType.ERC4626, MOONWELL_USDC, USDC, "savings");
        registry.addAsset(USDC, PositionClass.STABLECOIN);
        registry.addAsset(WETH, PositionClass.HELD_ASSET);
        registry.setRoute(UNIV3_ROUTER, true);

        // --- guarded rollout ON (docs/GUARDED_ROLLOUT.md §4) ---
        registry.setFactory(address(factory)); // set-once: accounts register through the factory
        registry.setBaseAsset(USDC); // the cap counts USDC principal
        registry.setWhitelistEnabled(true); // WHO gate on
        registry.setAllowed(deployer, true); // the deployer can always open (for smoke-testing)
        for (uint256 i; i < extra.length; ++i) {
            registry.setAllowed(extra[i], true);
        }
        registry.setDepositCap(cap); // HOW MUCH ceiling
        registry.setDepositCapEnabled(true);

        vm.stopBroadcast();

        console.log("== CryptoPiggy on Base -- guarded rollout ON ==");
        console.log("REGISTRY  ", address(registry));
        console.log("IMPL      ", address(impl));
        console.log("FACTORY   ", address(factory));
        console.log("admin     ", deployer);
        console.log("depositCap", cap);
        console.log("extra allowlisted", extra.length);
    }
}
