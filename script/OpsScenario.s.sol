// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ProtocolRegistry} from "../src/ProtocolRegistry.sol";
import {SmartInvestmentAccount} from "../src/SmartInvestmentAccount.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {AdapterType, PositionClass, ActionKind, Action} from "../src/Types.sol";

import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockERC4626} from "../test/mocks/MockERC4626.sol";
import {MockAavePool} from "../test/mocks/MockAavePool.sol";
import {MockSwapRouter} from "../test/mocks/MockSwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Anvil-only scenario for the OPS INDEXER integration test. Deploys the mock universe + the real
///         contracts, wires the guarded-rollout plumbing (setFactory + setBaseAsset — so accounts register
///         and Deployed/Returned actually fire), then drives TWO users through deposits / a buy swap / a
///         withdrawal so AccountCreated + Deployed + Returned all appear on chain. Logs every address the
///         test needs. NOT for any real network. (State vars keep run()'s stack shallow.)
contract OpsScenario is Script {
    // anvil default keys 0/1/2
    uint256 constant ADMIN_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant USER1_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant USER2_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    address constant USER1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant USER2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    MockERC20 usdc;
    MockERC20 wsteth;
    MockAavePool aave;
    MockSwapRouter router;
    ProtocolRegistry registry;
    AccountFactory factory;
    bytes32 aaveId;

    function run() external {
        deployAndWire();
        address a1 = driveUser1();
        address a2 = driveUser2();

        console.log("REGISTRY", address(registry));
        console.log("FACTORY", address(factory));
        console.log("USDC", address(usdc));
        console.log("AAVE", address(aave));
        console.log("WSTETH", address(wsteth));
        console.log("ACCT1", a1);
        console.log("ACCT2", a2);
    }

    function deployAndWire() internal {
        vm.startBroadcast(ADMIN_PK);
        usdc = new MockERC20("USD Coin", "USDC", 18); // anvil mock USDC is 18dp
        MockERC20 usds = new MockERC20("USDS", "USDS", 18);
        wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);
        aave = new MockAavePool();
        MockERC4626 vault = new MockERC4626(IERC20(address(usds)));
        router = new MockSwapRouter();

        registry = new ProtocolRegistry(vm.addr(ADMIN_PK));
        factory = new AccountFactory(address(new SmartInvestmentAccount()), address(registry));

        registry.addProtocol(AdapterType.AAVE, address(aave), address(usdc), "lending");
        registry.addProtocol(AdapterType.ERC4626, address(vault), address(usds), "savings");
        registry.addAsset(address(usdc), PositionClass.STABLECOIN);
        registry.addAsset(address(usds), PositionClass.STABLECOIN);
        registry.addAsset(address(wsteth), PositionClass.HELD_ASSET);
        registry.setRoute(address(router), true);
        registry.setFactory(address(factory)); // so createAccount registers the account (flows count)
        registry.setBaseAsset(address(usdc)); // so Deployed/Returned fire on USDC principal

        usdc.mint(address(router), 1_000_000e18);
        wsteth.mint(address(router), 1_000_000e18);
        router.setRate(address(usdc), address(wsteth), 4e14); // 1 USDC = 0.0004 wstETH
        router.setRate(address(wsteth), address(usdc), 2500e18);

        aaveId = registry.positionId(AdapterType.AAVE, address(aave), address(usdc));
        usdc.mint(factory.predict(USER1, bytes32("s1")), 1000e18);
        usdc.mint(factory.predict(USER2, bytes32("s2")), 1000e18);
        vm.stopBroadcast();
    }

    // user1: open account, deposit 300 to Aave, buy 200 USDC → wstETH
    function driveUser1() internal returns (address) {
        vm.startBroadcast(USER1_PK);
        SmartInvestmentAccount a1 = SmartInvestmentAccount(factory.createAccount(bytes32("s1")));
        Action[] memory plan = new Action[](2);
        plan[0] = Action(ActionKind.DEPOSIT, aaveId, address(0), address(0), address(0), 300e18, 0, "");
        plan[1] = Action(
            ActionKind.SWAP,
            bytes32(0),
            address(usdc),
            address(wsteth),
            address(router),
            200e18,
            1,
            abi.encodeWithSelector(
                MockSwapRouter.swap.selector, address(usdc), address(wsteth), uint256(200e18), uint256(0), address(a1)
            )
        );
        a1.executePlan(plan);
        vm.stopBroadcast();
        return address(a1);
    }

    // user2: open account, deposit 500 to Aave, withdraw 200
    function driveUser2() internal returns (address) {
        vm.startBroadcast(USER2_PK);
        SmartInvestmentAccount a2 = SmartInvestmentAccount(factory.createAccount(bytes32("s2")));
        Action[] memory dep = new Action[](1);
        dep[0] = Action(ActionKind.DEPOSIT, aaveId, address(0), address(0), address(0), 500e18, 0, "");
        a2.executePlan(dep);
        Action[] memory wd = new Action[](1);
        wd[0] = Action(ActionKind.WITHDRAW, aaveId, address(0), address(0), address(0), 200e18, 0, "");
        a2.executePlan(wd);
        vm.stopBroadcast();
        return address(a2);
    }
}
