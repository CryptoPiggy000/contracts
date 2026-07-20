// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ProtocolRegistry} from "../src/ProtocolRegistry.sol";
import {SmartInvestmentAccount} from "../src/SmartInvestmentAccount.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {AdapterType, PositionClass, ActionKind, Action} from "../src/Types.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MaliciousRouter} from "./mocks/MaliciousRouter.sol";

contract SmartInvestmentAccountTest is Test {
    ProtocolRegistry registry;
    SmartInvestmentAccount impl;
    AccountFactory factory;

    MockERC20 usdc;
    MockERC20 usds;
    MockERC20 wsteth;
    MockAavePool aave;
    MockERC4626 vault;
    MockSwapRouter router;

    address admin = makeAddr("admin");
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    SmartInvestmentAccount acct;
    bytes32 aaveId;
    bytes32 vaultId;

    uint256 constant START = 1000e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        usds = new MockERC20("USDS", "USDS", 18);
        wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);

        aave = new MockAavePool();
        vault = new MockERC4626(IERC20(address(usds)));
        router = new MockSwapRouter();

        registry = new ProtocolRegistry(admin);
        vm.startPrank(admin);
        aaveId = registry.addProtocol(AdapterType.AAVE, address(aave), address(usdc), "lending");
        vaultId = registry.addProtocol(AdapterType.ERC4626, address(vault), address(usds), "savings");
        registry.addAsset(address(usdc), PositionClass.STABLECOIN);
        registry.addAsset(address(usds), PositionClass.STABLECOIN);
        registry.addAsset(address(wsteth), PositionClass.HELD_ASSET);
        registry.setRoute(address(router), true);
        vm.stopPrank();

        impl = new SmartInvestmentAccount();
        factory = new AccountFactory(address(impl), address(registry));

        vm.prank(user);
        acct = SmartInvestmentAccount(factory.createAccount(bytes32("s1")));

        usdc.mint(address(acct), START);

        // router liquidity + rates: 1 usdc = 1 usds; 1 usdc = 0.0004 wstETH
        usds.mint(address(router), 1_000_000e18);
        wsteth.mint(address(router), 1_000_000e18);
        router.setRate(address(usdc), address(usds), 1e18);
        router.setRate(address(usdc), address(wsteth), 4e14);
    }

    // ------------------------------------------------------------------ helpers
    function _dep(bytes32 id, uint256 amt) internal pure returns (Action memory a) {
        a.kind = ActionKind.DEPOSIT;
        a.positionId = id;
        a.amount = amt;
    }

    function _wd(bytes32 id, uint256 amt) internal pure returns (Action memory a) {
        a.kind = ActionKind.WITHDRAW;
        a.positionId = id;
        a.amount = amt;
    }

    function _swap(address i, address o, address rtr, uint256 amt, uint256 minOut)
        internal
        view
        returns (Action memory a)
    {
        a.kind = ActionKind.SWAP;
        a.assetIn = i;
        a.assetOut = o;
        a.router = rtr;
        a.amount = amt;
        a.minOut = minOut;
        a.routeData = abi.encodeWithSelector(MockSwapRouter.swap.selector, i, o, amt, minOut, address(acct));
    }

    function _run(Action memory a) internal {
        Action[] memory plan = new Action[](1);
        plan[0] = a;
        vm.prank(user);
        acct.executePlan(plan);
    }

    // ------------------------------------------------------------------ factory / init
    function test_factory_create() public view {
        assertEq(acct.owner(), user);
        assertEq(address(acct.registry()), address(registry));
        assertEq(factory.predict(user, bytes32("s1")), address(acct));
    }

    function test_clone_cannotReinit() public {
        vm.expectRevert(SmartInvestmentAccount.AlreadyInitialized.selector);
        acct.initialize(stranger, address(registry));
    }

    function test_impl_isLocked() public {
        vm.expectRevert(SmartInvestmentAccount.AlreadyInitialized.selector);
        impl.initialize(user, address(registry));
    }

    // ------------------------------------------------------------------ deposits
    function test_deposit_aave() public {
        _run(_dep(aaveId, 400e18));
        assertEq(usdc.balanceOf(address(acct)), START - 400e18);
        assertEq(aave.supplied(address(acct), address(usdc)), 400e18);
        assertEq(usdc.allowance(address(acct), address(aave)), 0); // approval reset
    }

    function test_deposit_vault_viaSwap() public {
        _run(_swap(address(usdc), address(usds), address(router), 300e18, 299e18));
        assertEq(usds.balanceOf(address(acct)), 300e18);
        _run(_dep(vaultId, 300e18));
        assertEq(usds.balanceOf(address(acct)), 0);
        assertGt(vault.balanceOf(address(acct)), 0);
    }

    // ------------------------------------------------------------------ swaps
    function test_swap_toHeld() public {
        _run(_swap(address(usdc), address(wsteth), address(router), 250e18, 0.09e18));
        assertEq(wsteth.balanceOf(address(acct)), 250e18 * 4e14 / 1e18); // 0.1 wstETH
        assertEq(usdc.balanceOf(address(acct)), START - 250e18);
    }

    function test_swap_insufficientOutput_reverts() public {
        Action[] memory plan = new Action[](1);
        plan[0] = _swap(address(usdc), address(wsteth), address(router), 250e18, 1e18); // want 1, get 0.1
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.InsufficientOutput.selector);
        acct.executePlan(plan);
    }

    function test_swap_unapprovedRoute_reverts() public {
        MockSwapRouter bad = new MockSwapRouter();
        Action[] memory plan = new Action[](1);
        plan[0] = _swap(address(usdc), address(wsteth), address(bad), 10e18, 1); // minOut>0 so the route check is what reverts
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.RouteNotApproved.selector);
        acct.executePlan(plan);
    }

    function test_swap_unapprovedAssetOut_reverts() public {
        vm.prank(admin);
        registry.disableAsset(address(wsteth));
        Action[] memory plan = new Action[](1);
        plan[0] = _swap(address(usdc), address(wsteth), address(router), 10e18, 1); // minOut>0 so the asset check is what reverts
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.AssetNotApproved.selector);
        acct.executePlan(plan);
    }

    /// REGRESSION (security review): the spend side (assetIn) must ALSO be an approved asset — otherwise a
    /// swap could relay-spend any token the account holds through an approved router.
    function test_swap_unapprovedAssetIn_reverts() public {
        vm.prank(admin);
        registry.disableAsset(address(usdc)); // the token being spent is no longer approved
        Action[] memory plan = new Action[](1);
        plan[0] = _swap(address(usdc), address(wsteth), address(router), 10e18, 1);
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.AssetNotApproved.selector);
        acct.executePlan(plan);
    }

    /// REGRESSION (security review): a swap with a zero output floor is rejected — a real swap always has a
    /// minimum, and 0 disables the balance-delta slippage/theft guard entirely.
    function test_swap_zeroMinOut_reverts() public {
        Action[] memory plan = new Action[](1);
        plan[0] = _swap(address(usdc), address(wsteth), address(router), 10e18, 0);
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.ZeroMinOut.selector);
        acct.executePlan(plan);
    }

    // ------------------------------------------------------------------ withdraw / exit
    function test_withdraw_partial() public {
        _run(_dep(aaveId, 400e18));
        _run(_wd(aaveId, 150e18));
        assertEq(aave.supplied(address(acct), address(usdc)), 250e18);
        assertEq(usdc.balanceOf(address(acct)), START - 250e18);
    }

    function test_exit_aave_max() public {
        _run(_dep(aaveId, 400e18));
        vm.prank(user);
        acct.exit(aaveId, type(uint256).max);
        assertEq(aave.supplied(address(acct), address(usdc)), 0);
        assertEq(usdc.balanceOf(address(acct)), START);
    }

    function test_exit_vault_max() public {
        _run(_swap(address(usdc), address(usds), address(router), 300e18, 1)); // minOut>0 (mock 1:1 over-delivers)
        _run(_dep(vaultId, 300e18));
        vm.prank(user);
        acct.exit(vaultId, type(uint256).max);
        assertEq(vault.balanceOf(address(acct)), 0);
        assertApproxEqAbs(usds.balanceOf(address(acct)), 300e18, 1); // 4626 rounding
    }

    function test_disabled_blocksDeposit_allowsExit() public {
        _run(_dep(aaveId, 400e18));
        vm.prank(admin);
        registry.disableProtocol(aaveId);

        Action[] memory plan = new Action[](1);
        plan[0] = _dep(aaveId, 100e18);
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.PositionNotActive.selector);
        acct.executePlan(plan);

        // exit still works (status-independent)
        vm.prank(user);
        acct.exit(aaveId, type(uint256).max);
        assertEq(aave.supplied(address(acct), address(usdc)), 0);
    }

    function test_withdraw_toOwner() public {
        vm.prank(user);
        acct.withdraw(address(usdc), 100e18);
        assertEq(usdc.balanceOf(user), 100e18);
        assertEq(usdc.balanceOf(address(acct)), START - 100e18);
    }

    // ------------------------------------------------------------------ access control
    function test_executePlan_onlyOwner() public {
        Action[] memory plan = new Action[](1);
        plan[0] = _dep(aaveId, 1e18);
        vm.prank(stranger);
        vm.expectRevert(SmartInvestmentAccount.NotOwner.selector);
        acct.executePlan(plan);
    }

    function test_exit_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SmartInvestmentAccount.NotOwner.selector);
        acct.exit(aaveId, 1);
    }

    function test_withdraw_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SmartInvestmentAccount.NotOwner.selector);
        acct.withdraw(address(usdc), 1);
    }

    // ------------------------------------------------------------------ rebalance (one atomic plan)
    function test_rebalance_multiAction() public {
        _run(_dep(aaveId, 500e18));

        Action[] memory plan = new Action[](3);
        plan[0] = _wd(aaveId, 200e18); // pull from Aave
        plan[1] = _swap(address(usdc), address(usds), address(router), 200e18, 199e18); // convert
        plan[2] = _dep(vaultId, 200e18); // into the vault

        vm.prank(user);
        acct.executePlan(plan);

        assertEq(aave.supplied(address(acct), address(usdc)), 300e18);
        assertGt(vault.balanceOf(address(acct)), 0);
    }

    // ------------------------------------------------------------------ custody: even an APPROVED
    // malicious router cannot drain — the balance-delta check reverts the whole plan.
    function test_custody_maliciousRouter_cannotDrain() public {
        MaliciousRouter evil = new MaliciousRouter();
        vm.prank(admin);
        registry.setRoute(address(evil), true); // admin even approves it

        uint256 before = usdc.balanceOf(address(acct));
        Action[] memory plan = new Action[](1);
        plan[0] = Action({
            kind: ActionKind.SWAP,
            positionId: bytes32(0),
            assetIn: address(usdc),
            assetOut: address(wsteth),
            router: address(evil),
            amount: 500e18,
            minOut: 1,
            routeData: abi.encodeWithSelector(
                MaliciousRouter.swap.selector, address(usdc), address(wsteth), 500e18, uint256(1), address(acct)
            )
        });

        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.InsufficientOutput.selector);
        acct.executePlan(plan);

        // reverted -> funds intact, no dangling approval
        assertEq(usdc.balanceOf(address(acct)), before);
        assertEq(usdc.allowance(address(acct), address(evil)), 0);
    }

    // ------------------------------------------------------------------ more sad paths

    // a router whose call REVERTS (vs under-delivers) surfaces as SwapFailed; the whole plan rolls back
    function test_swap_routerReverts_swapFailed() public {
        RevertingRouter down = new RevertingRouter();
        vm.prank(admin);
        registry.setRoute(address(down), true);

        Action[] memory plan = new Action[](1);
        plan[0] = Action({
            kind: ActionKind.SWAP,
            positionId: bytes32(0),
            assetIn: address(usdc),
            assetOut: address(wsteth),
            router: address(down),
            amount: 10e18,
            minOut: 1, // >0 so the router-revert (SwapFailed) is what surfaces, not ZeroMinOut
            routeData: abi.encodeWithSelector(
                RevertingRouter.swap.selector, address(usdc), address(wsteth), uint256(10e18), uint256(0), address(acct)
            )
        });
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.SwapFailed.selector);
        acct.executePlan(plan);

        assertEq(usdc.balanceOf(address(acct)), START); // nothing moved
        assertEq(usdc.allowance(address(acct), address(down)), 0); // no dangling approval
    }

    // exit of a position that was never registered -> UnknownPosition (status-independent path)
    function test_exit_unknownPosition_reverts() public {
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.UnknownPosition.selector);
        acct.exit(bytes32("ghost"), 1);
    }

    // a WITHDRAW action against an unregistered position -> UnknownPosition
    function test_withdrawAction_unknownPosition_reverts() public {
        Action[] memory plan = new Action[](1);
        plan[0] = _wd(bytes32("ghost"), 1);
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.UnknownPosition.selector);
        acct.executePlan(plan);
    }

    // a malicious APPROVED vault that re-enters executePlan mid-deposit is rejected: onlyOwner fires on the
    // callback (the vault is not the owner) before nonReentrant is even reached, and the whole plan reverts.
    function test_reentrancy_maliciousVault_blocked() public {
        ReentrantVault evil = new ReentrantVault(address(acct), aaveId);
        vm.prank(admin);
        bytes32 evilId = registry.addProtocol(AdapterType.ERC4626, address(evil), address(usdc), "savings");

        Action[] memory plan = new Action[](1);
        plan[0] = _dep(evilId, 100e18);
        vm.prank(user);
        vm.expectRevert(SmartInvestmentAccount.NotOwner.selector);
        acct.executePlan(plan);

        assertEq(usdc.balanceOf(address(acct)), START); // the reentrant attempt moved nothing
    }

    // ------------------------------------------------------------------ fuzz: deposit then full exit
    function testFuzz_depositExit_aave(uint256 amount) public {
        amount = bound(amount, 1, START);
        _run(_dep(aaveId, amount));
        assertEq(aave.supplied(address(acct), address(usdc)), amount);
        vm.prank(user);
        acct.exit(aaveId, type(uint256).max);
        assertEq(usdc.balanceOf(address(acct)), START);
    }
}

/// A router whose swap reverts outright — the account should surface SwapFailed (the call returned ok=false).
contract RevertingRouter {
    function swap(address, address, uint256, uint256, address) external pure {
        revert("router down");
    }
}

/// A malicious ERC-4626 that re-enters executePlan during deposit. The reentrant caller is the vault, not the
/// owner, so onlyOwner rejects it (nonReentrant sits behind that as defense-in-depth) and the plan reverts.
contract ReentrantVault {
    address private immutable acct;
    bytes32 private immutable id;

    constructor(address acct_, bytes32 id_) {
        acct = acct_;
        id = id_;
    }

    function deposit(uint256, address) external returns (uint256) {
        Action[] memory p = new Action[](1);
        p[0].kind = ActionKind.WITHDRAW;
        p[0].positionId = id;
        p[0].amount = 1;
        SmartInvestmentAccount(acct).executePlan(p); // re-enter -> reverts
        return 0;
    }
}
