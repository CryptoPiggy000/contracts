// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ProtocolRegistry} from "../src/ProtocolRegistry.sol";
import {SmartInvestmentAccount} from "../src/SmartInvestmentAccount.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {AdapterType, PositionClass, ActionKind, Action} from "../src/Types.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

/// @title GuardedRolloutTest
/// @notice The temporary launch guards (whitelist + deposit cap). Proves they gate money going IN,
///         never money coming OUT, and that each guard can be fully LIFTED. See docs/GUARDED_ROLLOUT.md.
contract GuardedRolloutTest is Test {
    ProtocolRegistry registry;
    SmartInvestmentAccount impl;
    AccountFactory factory;

    MockERC20 usdc;
    MockERC20 wsteth;
    MockAavePool aave;
    MockSwapRouter router;

    address admin = makeAddr("admin");
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    SmartInvestmentAccount acct; // owned by `user`, registered (created after setFactory)
    bytes32 aaveId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);
        aave = new MockAavePool();
        router = new MockSwapRouter();

        registry = new ProtocolRegistry(admin);
        impl = new SmartInvestmentAccount();
        factory = new AccountFactory(address(impl), address(registry));

        vm.startPrank(admin);
        aaveId = registry.addProtocol(AdapterType.AAVE, address(aave), address(usdc), "lending");
        registry.addAsset(address(usdc), PositionClass.STABLECOIN);
        registry.addAsset(address(wsteth), PositionClass.HELD_ASSET);
        registry.setRoute(address(router), true);
        // Wire the guards: bind the factory (so accounts register) + set the cap's unit. Both guards
        // stay OFF until explicitly enabled — the deploy is what turns them on for the rollout.
        registry.setFactory(address(factory));
        registry.setBaseAsset(address(usdc));
        vm.stopPrank();

        vm.prank(user);
        acct = SmartInvestmentAccount(factory.createAccount(bytes32("s1"))); // registers via the factory
        usdc.mint(address(acct), 1000e18);

        // router liquidity + both-way rates so buys and sell-backs work
        usdc.mint(address(router), 1_000_000e18);
        wsteth.mint(address(router), 1_000_000e18);
        router.setRate(address(usdc), address(wsteth), 4e14); // 1 USDC = 0.0004 wstETH
        router.setRate(address(wsteth), address(usdc), 2500e18); // 1 wstETH = 2500 USDC
    }

    // ============================================================ whitelist (WHO)

    function test_whitelist_offByDefault_anyoneCanOpen() public {
        assertTrue(registry.canOpen(stranger));
        vm.prank(stranger);
        factory.createAccount(bytes32("x")); // no revert
    }

    function test_whitelist_on_blocksStranger() public {
        vm.prank(admin);
        registry.setWhitelistEnabled(true);

        assertFalse(registry.canOpen(stranger));
        vm.prank(stranger);
        vm.expectRevert(AccountFactory.NotAllowed.selector);
        factory.createAccount(bytes32("x"));
    }

    function test_whitelist_on_allowsWhitelisted() public {
        vm.startPrank(admin);
        registry.setWhitelistEnabled(true);
        registry.setAllowed(stranger, true);
        vm.stopPrank();

        vm.prank(stranger);
        factory.createAccount(bytes32("x")); // allowed -> no revert
    }

    function test_whitelist_batch() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address[] memory list = new address[](2);
        list[0] = a;
        list[1] = b;

        vm.startPrank(admin);
        registry.setWhitelistEnabled(true);
        registry.setAllowedBatch(list, true);
        vm.stopPrank();

        assertTrue(registry.canOpen(a));
        assertTrue(registry.canOpen(b));
        assertFalse(registry.canOpen(stranger));
    }

    /// The LIFT: disabling the whitelist reopens account creation to everyone.
    function test_whitelist_lift_reopensToAll() public {
        vm.prank(admin);
        registry.setWhitelistEnabled(true);
        assertFalse(registry.canOpen(stranger));

        vm.prank(admin);
        registry.setWhitelistEnabled(false); // LIFT
        assertTrue(registry.canOpen(stranger));

        vm.prank(stranger);
        factory.createAccount(bytes32("x")); // open again
    }

    function test_whitelist_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setWhitelistEnabled(true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setAllowed(stranger, true);
    }

    // ============================================================ deposit cap (HOW MUCH)

    function _enableCap(uint256 cap) internal {
        vm.startPrank(admin);
        registry.setDepositCap(cap);
        registry.setDepositCapEnabled(true);
        vm.stopPrank();
    }

    function _dep(uint256 amt) internal view returns (Action memory a) {
        a.kind = ActionKind.DEPOSIT;
        a.positionId = aaveId;
        a.amount = amt;
    }

    function _wd(uint256 amt) internal view returns (Action memory a) {
        a.kind = ActionKind.WITHDRAW;
        a.positionId = aaveId;
        a.amount = amt;
    }

    function _buy(uint256 amt) internal view returns (Action memory a) {
        a.kind = ActionKind.SWAP;
        a.assetIn = address(usdc);
        a.assetOut = address(wsteth);
        a.router = address(router);
        a.amount = amt;
        a.minOut = 0;
        a.routeData = abi.encodeWithSelector(MockSwapRouter.swap.selector, usdc, wsteth, amt, 0, address(acct));
    }

    function _sell(uint256 amt) internal view returns (Action memory a) {
        a.kind = ActionKind.SWAP;
        a.assetIn = address(wsteth);
        a.assetOut = address(usdc);
        a.router = address(router);
        a.amount = amt;
        a.minOut = 0;
        a.routeData = abi.encodeWithSelector(MockSwapRouter.swap.selector, wsteth, usdc, amt, 0, address(acct));
    }

    function _run(Action memory a) internal {
        Action[] memory plan = new Action[](1);
        plan[0] = a;
        vm.prank(user);
        acct.executePlan(plan);
    }

    function test_cap_allowsUpToLimit_thenBlocks() public {
        _enableCap(100e18);

        _run(_dep(100e18)); // exactly the cap
        assertEq(registry.netDeployed(), 100e18);

        vm.prank(user);
        Action[] memory plan = new Action[](1);
        plan[0] = _dep(1e18); // one wei over
        vm.expectRevert(ProtocolRegistry.DepositCapExceeded.selector);
        acct.executePlan(plan);
    }

    /// Withdrawing frees cap room again — net tracking, so churn doesn't permanently fill the cap.
    function test_cap_withdrawFreesRoom() public {
        _enableCap(100e18);
        _run(_dep(100e18));

        _run(_wd(40e18)); // net 100 -> 60
        assertEq(registry.netDeployed(), 60e18);

        _run(_dep(40e18)); // fits again
        assertEq(registry.netDeployed(), 100e18);
    }

    /// THE invariant: the cap NEVER blocks money coming out — even enabled and full, withdraw works.
    function test_cap_neverBlocksWithdraw() public {
        _enableCap(100e18);
        _run(_dep(100e18));

        uint256 before = usdc.balanceOf(address(acct));
        _run(_wd(100e18)); // at the cap, still withdraws
        assertEq(usdc.balanceOf(address(acct)), before + 100e18, "withdraw succeeded at the cap");
        assertEq(registry.netDeployed(), 0);
    }

    /// A base-asset BUY (spending USDC) counts toward the cap.
    function test_cap_buySwapCounts_andBlocks() public {
        _enableCap(100e18);

        _run(_buy(100e18)); // spends 100 USDC on wstETH -> net 100
        assertEq(registry.netDeployed(), 100e18);

        vm.prank(user);
        Action[] memory plan = new Action[](1);
        plan[0] = _dep(1e18);
        vm.expectRevert(ProtocolRegistry.DepositCapExceeded.selector);
        acct.executePlan(plan);
    }

    /// A sell-back (wstETH -> USDC) is never blocked by the cap and credits principal back.
    function test_cap_sellBackNeverBlocked() public {
        _enableCap(100e18);
        _run(_buy(100e18)); // net 100 (at the cap)

        uint256 wbal = wsteth.balanceOf(address(acct));
        _run(_sell(wbal)); // closing out — must not revert even though we're at the cap
        assertEq(wsteth.balanceOf(address(acct)), 0, "sold all wstETH back");
        assertEq(registry.netDeployed(), 0, "cap credited back on the sell-back");
    }

    /// The LIFT: disabling the cap removes the limit (large deposit sails through).
    function test_cap_lift_removesLimit() public {
        _enableCap(100e18);

        vm.prank(user);
        Action[] memory plan = new Action[](1);
        plan[0] = _dep(500e18);
        vm.expectRevert(ProtocolRegistry.DepositCapExceeded.selector);
        acct.executePlan(plan);

        vm.prank(admin);
        registry.setDepositCapEnabled(false); // LIFT

        _run(_dep(500e18)); // now fine
    }

    function test_cap_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setDepositCap(1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setDepositCapEnabled(true);
    }

    // ============================================================ access control on the flow hooks

    /// An outside caller can't move the cap counter — the hooks no-op for non-accounts.
    function test_onDeploy_ignoresNonAccount() public {
        _enableCap(100e18);
        vm.prank(stranger);
        registry.onDeploy(address(usdc), 1_000_000e18); // no revert, no effect
        assertEq(registry.netDeployed(), 0);
    }

    function test_registerAccount_onlyFactory() public {
        vm.prank(stranger);
        vm.expectRevert(ProtocolRegistry.NotFactory.selector);
        registry.registerAccount(stranger);
    }

    function test_setFactory_setOnce() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolRegistry.FactoryAlreadySet.selector);
        registry.setFactory(makeAddr("other")); // already set in setUp
    }

    function test_setBaseAsset_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setBaseAsset(address(usdc));
    }
}
