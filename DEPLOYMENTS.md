# Deployments

## Ethereum Sepolia (chainId 11155111)

Deployed via `script/DeploySepolia.s.sol` — real Circle USDC as the stablecoin; mock Aave +
ERC-4626 vault (both over USDC, no swaps). Mocks don't accrue yield: this proves real on-chain
money movement (deposit / earn / withdraw), not real earnings. Swap the mock venues for real
Aave/vaults later.

| Contract | Address |
|---|---|
| AccountFactory | `0xEfeeD7E0FB70316E9ceaeDcB1dBB10907370567C` |
| ProtocolRegistry | `0xe7F24D9963d992b2d3b838c615d41E94Ca8F8bd1` |
| SmartInvestmentAccount (impl) | `0xd06F148d8fe1F8eb3F145AA30BE6dAd7347627Ab` |
| Mock Aave pool (USDC) | `0x5c631226d0467ff2C15065b7173383278A639bb8` |
| Mock ERC-4626 vault (USDC) | `0xc6fA7dc154218b6d7bB81fc19530D16D16778b9E` |
| USDC (Circle, real) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

Registry admin = deployer. Frontend uses `AccountFactory.predict(owner, 0x0)` for the piggy
address, then `executePlan` / `withdraw`. Users get test USDC from Circle's Sepolia faucet;
the piggy's owner (embedded wallet) needs a little Sepolia ETH for gas until 7702 + paymaster.
