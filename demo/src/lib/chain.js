// viem clients, deployed addresses, ABIs, and low-level helpers for the local anvil demo.
import {
  createPublicClient, createWalletClient, http, parseAbi,
  encodeFunctionData, parseUnits, formatUnits,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const RPC = 'http://127.0.0.1:8545';

// Deterministic fresh-anvil addresses from `forge script DeployLocal` (see demo/README.md).
export const A = {
  registry: '0x0165878A594ca255338adfa4d48449f69242Eb8F',
  factory:  '0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6',
  usdc:     '0x5FbDB2315678afecb367f032d93F642f64180aa3',
  usds:     '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
  wsteth:   '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0',
  aave:     '0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9',
  vault:    '0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9',
  router:   '0x5FC8d32690cc91D4c39d9d3abcBD16989F875707',
};

// anvil well-known dev keys — LOCAL ONLY, never use anywhere real.
const KEY0 = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'; // you (owner)
const KEY1 = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'; // "platform" (not owner)
export const SALT = '0x0000000000000000000000000000000000000000000000000000000000000001';
export const Z = '0x0000000000000000000000000000000000000000';
export const ZB = '0x0000000000000000000000000000000000000000000000000000000000000000';

// demo prices (wstETH derived from the router rate 1 USDC = 0.0004 wstETH => 1 wstETH = 2500 USDC)
export const PRICE = { USDC: 1, USDS: 1, wstETH: 2500 };
export const ETH_USD = 3000; // illustrative, for the gas-fee estimate only

const anvil = { id: 31337, name: 'Anvil', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
export const you = privateKeyToAccount(KEY0);
export const platform = privateKeyToAccount(KEY1);
export const pub = createPublicClient({ chain: anvil, transport: http(RPC) });
export const wYou = createWalletClient({ account: you, chain: anvil, transport: http(RPC) });
export const wPlat = createWalletClient({ account: platform, chain: anvil, transport: http(RPC) });

export const factoryAbi = parseAbi([
  'function createAccount(bytes32) returns (address)',
  'function predict(address,bytes32) view returns (address)',
]);
export const registryAbi = parseAbi(['function positionId(uint8,address,address) view returns (bytes32)']);
export const erc20Abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function mint(address,uint256)',
  'function transfer(address,uint256) returns (bool)',
]);
export const aaveAbi = parseAbi(['function supplied(address,address) view returns (uint256)']);
export const vaultAbi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function convertToAssets(uint256) view returns (uint256)',
]);
export const routerAbi = parseAbi(['function swap(address,address,uint256,uint256,address)']);
export const acctAbi = parseAbi([
  'struct Action {uint8 kind; bytes32 positionId; address assetIn; address assetOut; address router; uint256 amount; uint256 minOut; bytes routeData;}',
  'function executePlan(Action[] plan)',
  'function exit(bytes32,uint256)',
  'function withdraw(address,uint256)',
  'function owner() view returns (address)',
  'error NotOwner()', 'error AlreadyInitialized()', 'error ZeroAddress()', 'error PositionNotActive()',
  'error UnknownPosition()', 'error BadAdapter()', 'error RouteNotApproved()', 'error AssetNotApproved()',
  'error SwapFailed()', 'error InsufficientOutput()',
]);

export { formatUnits, encodeFunctionData };
export const U = (v) => parseUnits(String(v), 18);
export const num = (x) => Number(formatUnits(x, 18));
export const f = (x) => { const n = num(x); return n === 0 ? '0' : n.toLocaleString(undefined, { maximumFractionDigits: 4 }); };
export const money = (n) => '$' + n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);
