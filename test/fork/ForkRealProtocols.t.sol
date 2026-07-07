// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ProtocolRegistry} from "../../src/ProtocolRegistry.sol";
import {SmartInvestmentAccount} from "../../src/SmartInvestmentAccount.sol";
import {AccountFactory} from "../../src/AccountFactory.sol";
import {AdapterType, PositionClass, Action, ActionKind} from "../../src/Types.sol";

/// @dev Minimal Uniswap V3 SwapRouter surface, so we can build the opaque `routeData` in Solidity.
interface IUniV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

/// @title ForkRealProtocols
/// @notice Runs OUR contracts against REAL mainnet protocols — the proof that the adapters speak the
///         real ABIs, not just our mocks. Covers the three POC adapter paths: Aave V3 (bespoke lending),
///         an ERC-4626 vault (Spark sDAI), and a swap through Uniswap V3.
/// @dev    Needs a mainnet RPC:
///           MAINNET_RPC_URL=https://... forge test --match-path "test/fork/*" -vvv
///         Without the env var these tests SKIP, so the default `forge test` suite stays green.
///         Addresses are mainnet as of writing — verify them against your fork block before trusting a pass.
contract ForkRealProtocols is Test {
    // --- real mainnet addresses (VERIFY before relying on a green run) ---
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 decimals
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // 18 decimals
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA; // Spark savings DAI (ERC-4626, asset = DAI)
    address constant MORPHO_STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB; // MetaMorpho vault (ERC-4626, asset = USDC)
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // Uniswap V3 SwapRouter

    ProtocolRegistry registry;
    AccountFactory factory;
    SmartInvestmentAccount account;
    address owner = makeAddr("owner");
    bytes32 aaveId;
    bytes32 vaultId;
    bytes32 morphoId;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // no RPC -> tests skip (see onFork)
        vm.createSelectFork(rpc); // latest block; add a 2nd arg (e.g. 21_000_000) to pin for caching/determinism

        registry = new ProtocolRegistry(address(this));
        SmartInvestmentAccount impl = new SmartInvestmentAccount();
        factory = new AccountFactory(address(impl), address(registry));

        // register the REAL protocols + assets + router
        registry.addProtocol(AdapterType.AAVE, AAVE_V3_POOL, USDC, "lending");
        registry.addProtocol(AdapterType.ERC4626, SDAI, DAI, "savings");
        registry.addProtocol(AdapterType.ERC4626, MORPHO_STEAKHOUSE_USDC, USDC, "savings"); // Morpho = same adapter
        registry.addAsset(USDC, PositionClass.STABLECOIN);
        registry.addAsset(DAI, PositionClass.STABLECOIN);
        registry.setRoute(UNIV3_ROUTER, true);

        aaveId = registry.positionId(AdapterType.AAVE, AAVE_V3_POOL, USDC);
        vaultId = registry.positionId(AdapterType.ERC4626, SDAI, DAI);
        morphoId = registry.positionId(AdapterType.ERC4626, MORPHO_STEAKHOUSE_USDC, USDC);

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

    /// Real Aave V3: supply USDC, take a partial exact-amount withdraw, then exit the rest with max.
    /// @dev Aave rebases via a liquidity index, so withdrawing the EXACT full aToken balance can round the
    ///      scaled burn up past your balance and revert — you withdraw a full position with type(uint).max
    ///      (as `exit` / the smart-withdraw haircut do). Partial exact withdraws are safe.
    function test_aave_supply_withdraw() public onFork {
        deal(USDC, address(account), 10_000e6);

        _run(_dep(aaveId, 4_000e6));
        assertEq(IERC20(USDC).balanceOf(address(account)), 6_000e6, "4k USDC supplied to real Aave");

        _run(_wd(aaveId, 1_500e6)); // exact partial withdraw
        assertEq(IERC20(USDC).balanceOf(address(account)), 7_500e6, "1.5k USDC withdrawn back to idle");

        vm.prank(owner); // withdraw the remainder as "all"
        account.exit(aaveId, type(uint256).max);
        assertGe(IERC20(USDC).balanceOf(address(account)), 9_999e6, "remaining position withdrawn to idle");
    }

    /// Real ERC-4626 (Spark sDAI): deposit DAI for shares, then exit() redeems all.
    function test_erc4626_deposit_redeem() public onFork {
        deal(DAI, address(account), 10_000e18);

        _run(_dep(vaultId, 4_000e18));
        assertGt(IERC4626(SDAI).balanceOf(address(account)), 0, "received real vault shares");
        assertEq(IERC20(DAI).balanceOf(address(account)), 6_000e18, "4k DAI deposited to sDAI");

        vm.prank(owner);
        account.exit(vaultId, type(uint256).max);
        assertEq(IERC4626(SDAI).balanceOf(address(account)), 0, "all shares redeemed");
        assertGe(IERC20(DAI).balanceOf(address(account)), 9_999e18, "DAI back to idle (>= principal)");
    }

    /// Real Morpho — a MetaMorpho vault ("Steakhouse USDC") is ERC-4626, so it uses the SAME adapter as sDAI
    /// with ZERO new contract code. Registering the vault address is all it takes to support Morpho.
    function test_morpho_metamorpho_deposit_redeem() public onFork {
        deal(USDC, address(account), 10_000e6);

        _run(_dep(morphoId, 4_000e6));
        assertGt(IERC4626(MORPHO_STEAKHOUSE_USDC).balanceOf(address(account)), 0, "received MetaMorpho shares");
        assertEq(IERC20(USDC).balanceOf(address(account)), 6_000e6, "4k USDC deposited to Morpho vault");

        vm.prank(owner);
        account.exit(morphoId, type(uint256).max);
        assertEq(IERC4626(MORPHO_STEAKHOUSE_USDC).balanceOf(address(account)), 0, "all Morpho shares redeemed");
        assertGe(IERC20(USDC).balanceOf(address(account)), 9_999e6, "USDC back to idle (>= principal)");
    }

    /// Real Uniswap V3: swap USDC -> DAI through the account's opaque-routeData swap adapter, bounded by minOut.
    function test_univ3_swap() public onFork {
        deal(USDC, address(account), 1_000e6);

        IUniV3Router.ExactInputSingleParams memory p = IUniV3Router.ExactInputSingleParams({
            tokenIn: USDC,
            tokenOut: DAI,
            fee: 100, // 0.01% stable pool; bump to 500 if that pool is thin at your fork block
            recipient: address(account),
            deadline: block.timestamp + 1,
            amountIn: 1_000e6,
            amountOutMinimum: 0, // the account enforces the floor itself via a post-swap balance delta
            sqrtPriceLimitX96: 0
        });

        Action memory swap;
        swap.kind = ActionKind.SWAP;
        swap.assetIn = USDC;
        swap.assetOut = DAI;
        swap.router = UNIV3_ROUTER;
        swap.amount = 1_000e6;
        swap.minOut = 990e18; // expect ~1000 DAI; adapter reverts if the REAL delta is under this
        swap.routeData = abi.encodeWithSelector(IUniV3Router.exactInputSingle.selector, p);

        _run(swap);
        assertGe(IERC20(DAI).balanceOf(address(account)), 990e18, "swapped ~1000 USDC -> DAI on Uniswap V3");
        assertEq(IERC20(USDC).balanceOf(address(account)), 0, "USDC spent");
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
}
