// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ProtocolRegistry} from "../src/ProtocolRegistry.sol";
import {SmartInvestmentAccount} from "../src/SmartInvestmentAccount.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {AdapterType, PositionClass} from "../src/Types.sol";

import {MockAavePool} from "../test/mocks/MockAavePool.sol";
import {MockERC4626} from "../test/mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Sepolia deploy for the live app. Uses **real Circle USDC** (6-dec) as the stablecoin,
///         with a mock Aave pool and a mock ERC-4626 vault — BOTH over USDC, so there are no
///         swaps and no decimal juggling. The real contracts (registry/impl/factory) are the
///         same ones audited/tested; only the protocol venues are mocks. Mocks don't accrue
///         yield, so this proves real on-chain money movement (deposit/earn/withdraw), not
///         real earnings — swap the mock venues for real Aave/vaults later.
///
/// Run: `set -a; . .env; set +a` then
///   forge script script/DeploySepolia.s.sol:DeploySepolia --rpc-url <sepolia> --broadcast
/// (reads PRIVATE_KEY from env via vm.envUint — never on the command line).
contract DeploySepolia is Script {
    // Circle's official test USDC on Ethereum Sepolia (6 decimals).
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        // Mock venues, both denominated in USDC (no swap needed to enter/exit).
        MockAavePool aave = new MockAavePool();
        MockERC4626 vault = new MockERC4626(IERC20(USDC));

        // The real, non-custodial contracts.
        ProtocolRegistry registry = new ProtocolRegistry(deployer); // deployer = admin
        SmartInvestmentAccount impl = new SmartInvestmentAccount();
        AccountFactory factory = new AccountFactory(address(impl), address(registry));

        // Wire the registry: two USDC venues + USDC as an approved stablecoin.
        registry.addProtocol(AdapterType.AAVE, address(aave), USDC, "lending");
        registry.addProtocol(AdapterType.ERC4626, address(vault), USDC, "savings");
        registry.addAsset(USDC, PositionClass.STABLECOIN);

        vm.stopBroadcast();

        console.log("REGISTRY", address(registry));
        console.log("IMPL", address(impl));
        console.log("FACTORY", address(factory));
        console.log("AAVE", address(aave));
        console.log("VAULT", address(vault));
        console.log("USDC", USDC);
    }
}
