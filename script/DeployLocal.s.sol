// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ProtocolRegistry} from "../src/ProtocolRegistry.sol";
import {SmartInvestmentAccount} from "../src/SmartInvestmentAccount.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {AdapterType, PositionClass} from "../src/Types.sol";

import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockERC4626} from "../test/mocks/MockERC4626.sol";
import {MockAavePool} from "../test/mocks/MockAavePool.sol";
import {MockSwapRouter} from "../test/mocks/MockSwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice LOCAL-ONLY deploy for the anvil demo. Deploys mock protocols + the real contracts,
///         wires the registry, and seeds the router with liquidity. Not for any real network.
contract DeployLocal is Script {
    function run() external {
        vm.startBroadcast();

        // --- mock protocol universe ---
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 18);
        MockERC20 usds = new MockERC20("USDS", "USDS", 18);
        MockERC20 wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);
        MockAavePool aave = new MockAavePool();
        MockERC4626 vault = new MockERC4626(IERC20(address(usds)));
        MockSwapRouter router = new MockSwapRouter();

        // --- the real contracts ---
        ProtocolRegistry registry = new ProtocolRegistry(msg.sender); // deployer = admin
        SmartInvestmentAccount impl = new SmartInvestmentAccount();
        AccountFactory factory = new AccountFactory(address(impl), address(registry));

        // --- wire the registry ---
        registry.addProtocol(AdapterType.AAVE, address(aave), address(usdc), "lending");
        registry.addProtocol(AdapterType.ERC4626, address(vault), address(usds), "savings");
        registry.addAsset(address(usdc), PositionClass.STABLECOIN);
        registry.addAsset(address(usds), PositionClass.STABLECOIN);
        registry.addAsset(address(wsteth), PositionClass.HELD_ASSET);
        registry.setRoute(address(router), true);

        // --- seed the router with liquidity + BIDIRECTIONAL rates (so the planner can rebalance) ---
        usdc.mint(address(router), 1_000_000e18);
        usds.mint(address(router), 1_000_000e18);
        wsteth.mint(address(router), 1_000_000e18);
        router.setRate(address(usdc), address(usds), 1e18); // 1 USDC = 1 USDS
        router.setRate(address(usds), address(usdc), 1e18); // 1 USDS = 1 USDC
        router.setRate(address(usdc), address(wsteth), 4e14); // 1 USDC = 0.0004 wstETH
        router.setRate(address(wsteth), address(usdc), 2500e18); // 1 wstETH = 2500 USDC

        vm.stopBroadcast();

        console.log("REGISTRY", address(registry));
        console.log("IMPL", address(impl));
        console.log("FACTORY", address(factory));
        console.log("USDC", address(usdc));
        console.log("USDS", address(usds));
        console.log("WSTETH", address(wsteth));
        console.log("AAVE", address(aave));
        console.log("VAULT", address(vault));
        console.log("ROUTER", address(router));
    }
}
