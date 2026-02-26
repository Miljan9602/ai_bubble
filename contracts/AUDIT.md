# AI.Bubble — Smart Contract Audit Scope

## Overview

AI.Bubble is a satirical Web3 game where players mint soulbound NFTs representing fake AI companies, farm ERC-20 tokens ($BUBBLE), upgrade GPU tiers, and compete in a US vs China faction war for native-currency prizes. The game runs 8–10 weeks on any EVM chain (currently deployed on Sei).

**Solidity version**: 0.8.28
**Dependencies**: OpenZeppelin Contracts v5
**Compiler settings**: Optimizer 200 runs, EVM target `london`

---

## Contracts in Scope (6 contracts)

### 1. BubbleNFT.sol — Soulbound ERC-721 with Dynamic Pricing

**Purpose**: Mint soulbound (non-transferable) NFTs for 10 fictional AI companies. Each company has an independent bonding curve with time-based price decay.

**Key mechanics**:
- 10 companies × 7,500 max supply = 75,000 total NFTs
- **Token ID encoding**: `companyId * 10000 + localIndex` (no mapping needed, saves ~20K gas)
- **Soulbound**: `_update()` override blocks all transfers (only minting allowed)
- **Faction lock**: First mint locks a wallet to USA (companies 0–4) or China (companies 5–9). Subsequent mints must match faction.
- **Dynamic pricing**: Linear bonding curve with time-based decay:
  ```
  bondingPrice   = BASE_PRICE + (supply × PRICE_INCREMENT)
  elapsed        = block.timestamp − lastMintTimestamp[companyId]
  decay          = elapsed × DECAY_RATE
  effectivePrice = max(MIN_PRICE, bondingPrice − decay)
  ```
- **Slippage protection**: Caller passes `maxPrice`; reverts if actual price exceeds it
- **Excess refund**: Overpayment refunded via low-level `call`

**Constants**:
| Name | Value | Description |
|------|-------|-------------|
| `BASE_PRICE` | 0.01 ether | Starting price at 0 supply |
| `MAX_PRICE` | 0.20 ether | Theoretical max at full supply |
| `PRICE_INCREMENT` | 25,336,700,000,000 wei | Per-unit bonding slope |
| `MIN_PRICE` | 0.005 ether | Decay floor |
| `DECAY_RATE` | 2,777,777,777,778 wei/sec | ≈ 0.01 ether/hour decay |
| `MAX_SUPPLY_PER_COMPANY` | 7,500 | Per-company cap |
| `NUM_COMPANIES` | 10 | Total companies |

**External calls**: `GameController.registerMint()` (registers NFT in BubbleFarm for yield tracking), refund `call` to `msg.sender`.

---

### 2. BubbleToken.sol — ERC-20 with Efficiency Credits

**Purpose**: The in-game currency ($BUBBLE). Minted as yield from farming, burned for GPU upgrades and maintenance. Has an efficiency credits system that rewards DEX buyers.

**Key mechanics**:
- **Authorized minters/burners**: `authorized` mapping — BubbleFarm, GPUUpgrade, and GameController are authorized
- **Efficiency credits**: When tokens are transferred FROM the DEX pair address, the buyer earns 50% bonus credits (e.g., buy 10,000 BUBBLE → earn 5,000 credits)
- **Credit consumption**: GPUUpgrade uses credits to reduce upgrade costs (up to 1.5× value)
- **Min transfer for credits**: 1,000 BUBBLE minimum to prevent dust farming
- **Credit cap**: 5,000,000 BUBBLE per player

**Access control**: `Ownable` — owner can set DEX pair, authorize/deauthorize contracts.

---

### 3. BubbleFarm.sol — Per-NFT Yield Farming

**Purpose**: Each minted NFT automatically earns $BUBBLE per second. Yield rate depends on the NFT's GPU tier.

**Key mechanics**:
- **Base yield**: 10,000 BUBBLE/day per NFT (at tier 0)
- **Tier multipliers**: [1×, 1.5×, 2×, 3×, 5×, 8×] — tier 5 earns 80,000/day
- **Lazy accounting**: O(1) per claim — stores `lastClaimTime` per tokenId, computes yield on claim
- **Batch claims**: `claimMultiple()` for up to 50 NFTs in one transaction
- **Registration**: NFTs registered via `registerNFT()` (called by GameController on mint)
- **Start/stop**: Owner (GameController) can activate/deactivate farming

**External calls**: Reads GPU tier from `GPUUpgrade.getEffectiveTier()`, mints BUBBLE via `BubbleToken.mint()`.

---

### 4. GPUUpgrade.sol — 5-Tier Upgrade System with Maintenance

**Purpose**: Players burn $BUBBLE to upgrade their NFTs through 5 GPU tiers, increasing yield multiplier. Each tier requires weekly maintenance or it degrades.

**Key mechanics**:
- **Tiers**: 0 (Stock CPU) → 1 (RTX 4070) → 2 (RTX 4090) → 3 (A100) → 4 (H100) → 5 (B200)
- **Lazy downgrade**: `getEffectiveTier()` computes the actual tier based on missed maintenance periods. Stored tier only updates when `payMaintenance()` or `enforceDowngrade()` is called.
- **Efficiency credit discount**: Credits from DEX purchases reduce upgrade burn cost (up to 1.5× effective value per credit)
- **Maintenance required before upgrade**: Cannot upgrade if current effective tier < stored tier (must pay maintenance first)
- **Public enforcement**: Anyone can call `enforceDowngrade()` to materialize a lazy downgrade

| Tier | Upgrade Cost | Weekly Maintenance |
|------|-------------|-------------------|
| 0 | Free | None |
| 1 | 50,000 BUBBLE | 2,500 BUBBLE |
| 2 | 150,000 BUBBLE | 10,000 BUBBLE |
| 3 | 400,000 BUBBLE | 30,000 BUBBLE |
| 4 | 1,000,000 BUBBLE | 75,000 BUBBLE |
| 5 | 2,500,000 BUBBLE | 200,000 BUBBLE |

**External calls**: Burns BUBBLE via `BubbleToken.burnFrom()`, consumes credits via `BubbleToken.consumeCredits()`.

---

### 5. FactionWar.sol — Merkle Prize Distribution with Vesting

**Purpose**: Weekly prize rounds funded with native currency. Operator finalizes each round with a merkle root. Winners claim prizes that vest linearly over 7 days.

**Key mechanics**:
- **Rounds**: Owner starts a round with native currency (`startRound{value: ...}()`), can add more funds via `addPrizePool()`
- **Finalization**: Owner sets a merkle root containing `(roundId, playerAddress, amount)` leaves
- **Double-hash leaf**: `keccak256(bytes.concat(keccak256(abi.encode(roundId, msg.sender, amount))))` — OpenZeppelin standard
- **Linear vesting**: 7-day linear vesting from claim time. Players call `withdrawVested()` to withdraw unlocked portion.
- **Single claim per round**: `require(c.totalAmount == 0, "Already claimed")`

**Known limitation**: The contract does not verify that total claimed amounts ≤ prize pool. The merkle root is trusted to contain valid allocations. An incorrect merkle root could allow over-claiming relative to the pool balance.

**External calls**: Native currency transfers via `call{value: ...}` to claimants.

---

### 6. GameController.sol — Coordinator with Access Control

**Purpose**: Central coordinator that manages game lifecycle, wires contracts, and provides role-based access for operations.

**Key mechanics**:
- **Roles**: `DEFAULT_ADMIN_ROLE` (deployer), `OPERATOR_ROLE` (game operations), `KEEPER_ROLE` (unused, reserved)
- **One-time setup**: `setContracts()` can only be called once (`_contractsSet` flag)
- **Two setup paths**: Either `initializeGame()` (auto-wires all contracts) or manual wiring via Deploy.s.sol — both set `_contractsSet`
- **Game lifecycle**: `startGame()` → `endGame()` — controls farming activation
- **Revenue withdrawal**: Admin can withdraw accumulated NFT mint revenue via `withdrawNFTRevenue()`
- **Emergency**: `emergencyPause()` stops farming immediately
- **Faction war proxy**: `startFactionRound()`, `finalizeFactionRound()` — forwards calls to FactionWar

**External calls**: Calls functions on all 5 other contracts. Receives native currency via `receive()`.

---

## Contract Interaction Diagram

```
                    ┌──────────────────────┐
                    │   GameController     │
                    │  (AccessControl)     │
                    │                      │
                    │ ADMIN: setContracts  │
                    │ OPERATOR: startGame  │
                    │ OPERATOR: endGame    │
                    └──┬────┬────┬────┬───┘
                       │    │    │    │
          ┌────────────┘    │    │    └────────────┐
          ▼                 ▼    ▼                  ▼
   ┌─────────────┐  ┌───────────┐  ┌────────────┐  ┌──────────┐
   │  BubbleNFT  │  │BubbleFarm │  │ GPUUpgrade │  │FactionWar│
   │  (ERC-721)  │  │  (Yield)  │  │  (Tiers)   │  │ (Prizes) │
   │             │  │           │  │            │  │          │
   │ mint()──────┼──▶registerNFT│  │ upgrade()  │  │ claim()  │
   │ soulbound   │  │ claim()   │  │ maintain() │  │ vest()   │
   └─────────────┘  └─────┬─────┘  └──────┬─────┘  └──────────┘
                          │               │
                          ▼               ▼
                    ┌─────────────────────────┐
                    │      BubbleToken        │
                    │       (ERC-20)          │
                    │                         │
                    │ mint() ← Farm           │
                    │ burnFrom() ← GPU        │
                    │ consumeCredits() ← GPU  │
                    │ efficiencyCredits ← DEX │
                    └─────────────────────────┘
```

---

## Token Economics

- **Minting**: Players pay native currency (bonding curve + decay). Revenue held in BubbleNFT contract.
- **Yield**: BubbleFarm mints new BUBBLE continuously. Base: 10,000/day/NFT. Max (tier 5): 80,000/day/NFT.
- **Sinks**: GPU upgrades burn BUBBLE. Maintenance burns BUBBLE weekly. Both are permanent burns.
- **DEX incentive**: Buying BUBBLE from DEX earns 50% efficiency credits, making upgrades cheaper.
- **Prize pool**: Operator funds FactionWar rounds with native currency. Winners claim via merkle proof + vesting.

---

## Access Control Summary

| Contract | Access Model | Admin Can | Notes |
|----------|-------------|-----------|-------|
| BubbleNFT | Ownable | withdraw(), setGameController() | Owner = deployer |
| BubbleToken | Ownable + authorized mapping | setDexPair(), setAuthorized() | Owner = deployer |
| BubbleFarm | Ownable | setFarmingActive(), setStartTime() | Owner = GameController |
| GPUUpgrade | Ownable | (none exposed) | Owner = GameController |
| FactionWar | Ownable | startRound(), finalizeRound() | Owner = GameController |
| GameController | AccessControl | setContracts(), initializeGame() | ADMIN = deployer |

---

## Areas of Interest for Auditors

1. **BubbleNFT.mint()** — Refund logic, reentrancy via `call`, bonding curve math, price decay overflow
2. **GPUUpgrade.upgrade()** — Efficiency credit discount math (rounding, edge cases at boundary values)
3. **GPUUpgrade.getEffectiveTier()** — Lazy downgrade calculation (integer division, boundary at exactly 7 days)
4. **FactionWar.claimPrize()** — Merkle proof verification, prize pool solvency (no total-claims check)
5. **FactionWar.withdrawVested()** — Linear vesting math, potential for dust amounts
6. **BubbleToken._update()** — DEX pair detection for efficiency credits (first-buy/flash-loan scenarios)
7. **GameController.withdrawNFTRevenue()** — Two-step withdrawal (NFT → Controller → Admin), balance handling
8. **General** — Reentrancy guards, access control correctness, upgrade path one-time-set invariants

---

## Build & Test

```bash
# Install dependencies
forge install

# Build
forge build

# Run tests (80 tests)
forge test -vvv

# Gas report
forge test --gas-report

# Fuzz tests (extended)
forge test --fuzz-runs 10000 -vvv
```

---

## File Summary

```
src/
├── BubbleNFT.sol          173 lines   Soulbound ERC-721 + bonding curve + price decay
├── BubbleToken.sol         91 lines   ERC-20 + efficiency credits
├── BubbleFarm.sol         106 lines   Per-NFT lazy yield farming
├── GPUUpgrade.sol         154 lines   5-tier upgrade + maintenance + lazy downgrade
├── FactionWar.sol         126 lines   Merkle prize distribution + linear vesting
├── GameController.sol     139 lines   Coordinator + access control
└── interfaces/
    ├── IBubbleNFT.sol                 NFT interface
    ├── IBubbleToken.sol               Token interface
    ├── IBubbleFarm.sol                Farm interface
    ├── IGPUUpgrade.sol                GPU interface
    ├── IFactionWar.sol                War interface
    └── IGameController.sol            Controller interface

test/
├── BubbleNFT.t.sol                    40 tests — minting, pricing, factions, soulbound
├── BubbleToken.t.sol                  18 tests — auth, credits, minting, burning
├── FullDeployment.t.sol               16 tests — end-to-end deployment + wiring
└── Integration.t.sol                   6 tests — cross-contract flows

script/
├── Deploy.s.sol                       Full deployment (all 6 contracts)
└── Redeploy.s.sol                     Partial redeploy (keep BubbleToken)

Total: ~789 lines of Solidity (contracts), 80 tests
```
