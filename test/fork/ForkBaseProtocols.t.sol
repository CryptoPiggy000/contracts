// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ProtocolRegistry} from "../../src/ProtocolRegistry.sol";
import {SmartInvestmentAccount} from "../../src/SmartInvestmentAccount.sol";
import {AccountFactory} from "../../src/AccountFactory.sol";
import {AdapterType, PositionClass, Action, ActionKind} from "../../src/Types.sol";

/// @dev Uniswap **SwapRouter02** surface (Base). NOTE: unlike the Ethereum SwapRouter (0xE592…),
///      SwapRouter02's `exactInputSingle` has NO `deadline` field — building the wrong struct here
///      would silently mis-encode the opaque routeData, which is exactly the kind of chain-specific
///      integration bug these fork tests exist to catch.
interface IUniV3Router02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

/// @title ForkBaseProtocols
/// @notice Runs OUR contracts against REAL **Base** protocols — the launch chain. Proves the adapters
///         speak the real ABIs (Aave V3, a MetaMorpho ERC-4626 vault, Uniswap V3), and exercises the
///         full product shape end-to-end: an "earn" (savings deposit + buy a held asset) followed by a
///         "close" (withdraw + SELL the held asset back to USDC — the sell-back path).
/// @dev    Needs a Base RPC:
///           BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/fork/ForkBaseProtocols*" -vvv
///         Without the env var these tests SKIP, so the default `forge test` suite stays green.
///         Addresses verified on Base mainnet; re-verify against your fork block before trusting a pass.
contract ForkBaseProtocols is Test {
    // --- real Base mainnet addresses (verified on-chain) ---
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // native USDC, 6 decimals
    address constant WETH = 0x4200000000000000000000000000000000000006; // canonical WETH (held asset)
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant MOONWELL_USDC = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca; // MetaMorpho ERC-4626, asset = USDC
    address constant UNIV3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02
    uint24 constant FEE_USDC_WETH = 500; // 0.05% — the deep Base USDC/WETH pool

    ProtocolRegistry registry;
    AccountFactory factory;
    SmartInvestmentAccount account;
    address owner = makeAddr("owner");
    bytes32 aaveId;
    bytes32 vaultId;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // no RPC -> tests skip (see onFork)
        vm.createSelectFork(rpc); // latest block; add a 2nd arg to pin for caching/determinism

        registry = new ProtocolRegistry(address(this));
        SmartInvestmentAccount impl = new SmartInvestmentAccount();
        factory = new AccountFactory(address(impl), address(registry));

        registry.addProtocol(AdapterType.AAVE, AAVE_V3_POOL, USDC, "lending");
        registry.addProtocol(AdapterType.ERC4626, MOONWELL_USDC, USDC, "savings");
        registry.addAsset(USDC, PositionClass.STABLECOIN);
        registry.addAsset(WETH, PositionClass.HELD_ASSET); // sell-back target must be an approved asset
        registry.setRoute(UNIV3_ROUTER, true);

        aaveId = registry.positionId(AdapterType.AAVE, AAVE_V3_POOL, USDC);
        vaultId = registry.positionId(AdapterType.ERC4626, MOONWELL_USDC, USDC);

        vm.prank(owner);
        account = SmartInvestmentAccount(factory.createAccount(bytes32(uint256(1))));
    }

    modifier onFork() {
        if (address(factory) == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// Real Base Aave V3: supply USDC, exact partial withdraw, then full exit with max.
    function test_base_aave_supply_withdraw() public onFork {
        deal(USDC, address(account), 10_000e6);

        _run(_dep(aaveId, 4_000e6));
        assertEq(IERC20(USDC).balanceOf(address(account)), 6_000e6, "4k USDC supplied to real Base Aave");

        _run(_wd(aaveId, 1_500e6)); // exact partial withdraw
        assertEq(IERC20(USDC).balanceOf(address(account)), 7_500e6, "1.5k USDC withdrawn to idle");

        vm.prank(owner);
        account.exit(aaveId, type(uint256).max);
        assertGe(IERC20(USDC).balanceOf(address(account)), 9_999e6, "remaining position withdrawn to idle");
    }

    /// Real Base MetaMorpho (Moonwell Flagship USDC) — ERC-4626, same adapter as any vault, zero new code.
    function test_base_metamorpho_deposit_redeem() public onFork {
        deal(USDC, address(account), 10_000e6);

        _run(_dep(vaultId, 4_000e6));
        assertGt(IERC4626(MOONWELL_USDC).balanceOf(address(account)), 0, "received real MetaMorpho shares");
        assertEq(IERC20(USDC).balanceOf(address(account)), 6_000e6, "4k USDC deposited to the Base vault");

        vm.prank(owner);
        account.exit(vaultId, type(uint256).max);
        assertEq(IERC4626(MOONWELL_USDC).balanceOf(address(account)), 0, "all vault shares redeemed");
        assertGe(IERC20(USDC).balanceOf(address(account)), 9_995e6, "USDC back to idle (>= principal - rounding)");
    }

    /// Real Base Uniswap V3: buy the held asset — USDC -> WETH through the opaque-routeData swap adapter.
    function test_base_swap_usdc_to_weth() public onFork {
        deal(USDC, address(account), 1_000e6);

        _run(_swap(USDC, WETH, 1_000e6, 0.1 ether)); // conservative floor; account enforces via balance-delta
        assertGt(IERC20(WETH).balanceOf(address(account)), 0.1 ether, "bought WETH on real Base Uniswap");
        assertEq(IERC20(USDC).balanceOf(address(account)), 0, "USDC spent");
    }

    /// THE product flow on real Base: earn (savings + buy held) then close (withdraw + SELL held back to USDC).
    /// Exercises the hardened _withdraw (balance-delta) and the new sell-back path against live protocols.
    function test_base_earn_then_sellback() public onFork {
        deal(USDC, address(account), 10_000e6);

        // EARN: 5k USDC -> Aave savings, 5k USDC -> WETH (the Bold-ish mix), in one atomic plan.
        Action[] memory earn = new Action[](2);
        earn[0] = _dep(aaveId, 5_000e6);
        earn[1] = _swap(USDC, WETH, 5_000e6, 0.5 ether);
        vm.prank(owner);
        account.executePlan(earn);

        uint256 weth = IERC20(WETH).balanceOf(address(account));
        assertGt(weth, 0.5 ether, "held WETH bought");
        assertEq(IERC20(USDC).balanceOf(address(account)), 0, "all idle USDC deployed");

        // CLOSE: withdraw all Aave + SELL all WETH back to USDC (the sell-back), atomic.
        Action[] memory close = new Action[](2);
        close[0] = _wd(aaveId, type(uint256).max);
        close[1] = _swap(WETH, USDC, weth, 4_500e6); // ~5k back minus two 0.05% fees + slippage
        vm.prank(owner);
        account.executePlan(close);

        assertEq(IERC20(WETH).balanceOf(address(account)), 0, "all WETH sold back to USDC");
        assertGe(IERC20(USDC).balanceOf(address(account)), 9_500e6, "dollars back in USDC after full round-trip");
    }

    // --- helpers ---
    function _run(Action memory a) internal {
        Action[] memory plan = new Action[](1);
        plan[0] = a;
        vm.prank(owner);
        account.executePlan(plan);
    }

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

    /// Build a SWAP action whose routeData is a real SwapRouter02 exactInputSingle call.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (Action memory a)
    {
        IUniV3Router02.ExactInputSingleParams memory p = IUniV3Router02.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: FEE_USDC_WETH,
            recipient: address(account),
            amountIn: amountIn,
            amountOutMinimum: 0, // the account enforces the floor via a post-swap balance delta
            sqrtPriceLimitX96: 0
        });
        a.kind = ActionKind.SWAP;
        a.assetIn = tokenIn;
        a.assetOut = tokenOut;
        a.router = UNIV3_ROUTER;
        a.amount = amountIn;
        a.minOut = minOut;
        a.routeData = abi.encodeWithSelector(IUniV3Router02.exactInputSingle.selector, p);
    }
}
