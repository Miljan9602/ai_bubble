# AI.Bubble Smart Contracts

Solidity smart contracts for AI.Bubble — a satirical Web3 game where players mint soulbound NFTs, farm $BUBBLE tokens, upgrade GPU tiers, and compete in faction wars for native-currency prizes.

**See [AUDIT.md](./AUDIT.md) for full audit scope, contract descriptions, interaction diagrams, and areas of interest.**

## Quick Start

```bash
# Install dependencies
forge install

# Build
forge build

# Run all tests (80 tests)
forge test -vvv

# Gas report
forge test --gas-report
```

## Contracts

| Contract | Description |
|----------|-------------|
| `BubbleNFT.sol` | Soulbound ERC-721 with linear bonding curve + time-based price decay |
| `BubbleToken.sol` | ERC-20 game currency with efficiency credits for DEX buyers |
| `BubbleFarm.sol` | Per-NFT lazy yield farming (tier-aware, O(1) per claim) |
| `GPUUpgrade.sol` | 5-tier upgrade system with weekly maintenance + lazy downgrade |
| `FactionWar.sol` | Merkle-proof prize distribution with 7-day linear vesting |
| `GameController.sol` | Central coordinator with role-based access control |

## Stack

- Solidity 0.8.28
- OpenZeppelin Contracts v5
- Foundry (Forge, Cast)
- Optimizer: 200 runs, EVM target: `london`
