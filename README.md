# DTSC — Decentralized T-Share Coin

A strictly decentralized stablecoin protocol for **PulseChain**, pegged to **$1**, backed exclusively by **HEX T-shares** (minimum 2,000 days to maturity).

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  HEX Stake  │────▶│  VaultManager    │────▶│      DTSC       │
│  (T-share)  │     │  (CDP / Mint)    │     │   ($1 stable)   │
└─────────────┘     └────────┬─────────┘     └────────┬────────┘
                             │                          │
                    ┌────────▼────────┐        ┌────────▼────────┐
                    │ TShareValuation │        │ Stability Pool  │
                    │  + HexOracle    │        │  (80% penalties)│
                    └─────────────────┘        └────────┬────────┘
                                                          │
                    ┌─────────────────┐        ┌────────▼────────┐
                    │ RedemptionHandler│◀──────│  Buyback & Burn │
                    │  (primary peg)  │        │  (20% penalties)│
                    └─────────────────┘        └─────────────────┘
```

## Contracts

| Contract | Role |
|----------|------|
| `DTSC.sol` | Stablecoin token (the protocol's only token) |
| `TShareValuation.sol` | On-chain Effective Value (EV) |
| `HexPriceOracle.sol` | TWAP + spot from PulseX (conservative min) |
| `VaultManager.sol` | Vaults, mint/repay, liquidation |
| `StabilityPool.sol` | Primary peg defense mechanism |
| `RedemptionHandler.sol` | Primary redemption mechanism |
| `RecoveryModule.sol` | System-wide recovery mode |
| `PenaltyRouter.sol` | 80/20 penalty split |
| `BuybackBurn.sol` | Secondary peg support |
| `DTSCDeployer.sol` | One-shot deploy + wiring lock |

## Valuation Formula (EV)

```
EV = (Principal × HEX_Price) + EarnedRewards + LongBonus − TimeDiscount
```

- **EarnedRewards**: conservative only already accrued rewards (Phase 1)
- **LongBonus**: 0% / 5% / 10–15% (tier-based)
- **TimeDiscount**: linear 0–15%
- **Hard cap**: 2× Principal Value

## Collateral Tiers

| Tier | Days | Min CCR | LTV |
|------|------|---------|-----|
| Long | 4,000–5,555 | 150% | ~66% |
| Medium-Long | 2,000–3,999 | 160% | ~62.5% |
| Not allowed | < 2,000 | — | — |

## Two Collateral Modes

### 1. Registered (existing stakes)
The user registers a `stakeId` owned by their wallet. The protocol **monitors** on-chain for `endStake`  if triggered, a 20–40% penalty applies.

> Note: HEX stakes cannot be transferred between addresses. Full custody is only available via custodial mode.

### 2. Custodial (new stakes)
The user sends HEX to `VaultManager`, which calls `startStake` — the stake is owned by the contract (**full lock**).

## PulseChain Addresses (mainnet)

| Asset | Address |
|-------|---------|
| HEX | `0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39` |

## Development

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Setup
```bash
cd dtsc-protocol
forge install foundry-rs/forge-std
forge build
forge test
```

### Frontend
```powershell
cd frontend
.\serve.ps1
# Open http://localhost:5173 — connect wallet, paste deployed addresses
```

### Deploy (PulseChain)
```bash
export PRIVATE_KEY=0x...
export PULSECHAIN_RPC_URL=https://rpc.pulsechain.com
forge script script/Deploy.s.sol --rpc-url $PULSECHAIN_RPC_URL --broadcast
```

After deploy: addresses are automatically locked via `dtsc.lockWiring()`.

## Documentation

- [Whitepaper](docs/WHITEPAPER.md)
- [Security & Audit Checklist](docs/SECURITY.md)
- [Audit Package](docs/AUDIT_PACKAGE.md)
- [Internal Findings](docs/AUDIT_FINDINGS.md)

## Roadmap

| Phase | Activity |
|-------|----------|
| Design | Whitepaper + design (current) |
| Development | Smart contracts + tests |
| Audits | 2–3 audits + bug bounty |
| Bootstrap | Long-tier incentives + Stability Pool |
| Launch | Mainnet + renounce ownership |

## Risks

| Risk | Mitigation |
|------|------------|
| Early unstake (registered) | Monitoring + 20–40% penalty + cooldown |
| HEX price crash | Overcollateralization + SP + Recovery |
| Oracle manipulation | TWAP + min(TWAP, spot) + haircut cap |

## License

MIT
