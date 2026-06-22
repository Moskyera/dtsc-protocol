# DTSC — Decentralized T-Share Coin

Αυστηρά αποκεντρωμένο stablecoin πρωτόκολλο για **PulseChain**, με peg στο **$1**, backed αποκλειστικά από **HEX T-shares** (ελάχιστο 2.000 ημέρες μέχρι ωρίμανση).

## Αρχιτεκτονική

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

| Contract | Ρόλος |
|----------|-------|
| `DTSC.sol` | Stablecoin token (μόνο token του πρωτοκόλλου) |
| `TShareValuation.sol` | On-chain Effective Value (EV) |
| `HexPriceOracle.sol` | TWAP + spot από PulseX (conservative min) |
| `VaultManager.sol` | Vaults, mint/repay, liquidation |
| `StabilityPool.sol` | Κύριος μηχανισμός προστασίας peg |
| `RedemptionHandler.sol` | Κύριος redemption μηχανισμός |
| `RecoveryModule.sol` | System-wide recovery mode |
| `PenaltyRouter.sol` | 80/20 κατανομή ποινών |
| `BuybackBurn.sol` | Δευτερεύων peg support |
| `DTSCDeployer.sol` | One-shot deploy + wiring lock |

## Τύπος Αποτίμησης (EV)

```
EV = (Principal × HEX_Price) + EarnedRewards + LongBonus − TimeDiscount
```

- **EarnedRewards**: συντηρητικά — μόνο ήδη παραχθέντα (Phase 1)
- **LongBonus**: 0% / 5% / 10–15% (tier-based)
- **TimeDiscount**: γραμμικό 0–15%
- **Hard cap**: 2× Principal Value

## Collateral Tiers

| Tier | Ημέρες | Min CCR | LTV |
|------|--------|---------|-----|
| Long | 4.000–5.555 | 150% | ~66% |
| Medium-Long | 2.000–3.999 | 160% | ~62.5% |
| Μη επιτρεπτό | < 2.000 | — | — |

## Δύο Λειτουργίες Collateral

### 1. Registered (υπάρχοντα stakes)
Ο χρήστης δηλώνει `stakeId` που ανήκει στο wallet του. Το πρωτόκολλο **παρακολουθεί** on-chain αν γίνει `endStake` — σε αυτή την περίπτωση ενεργοποιείται πέναλτι 20–40%.

> Σημείωση: Τα HEX stakes δεν μεταφέρονται μεταξύ addresses. Η πλήρης κηδεσία γίνεται μόνο με custodial mode.

### 2. Custodial (νέα stakes)
Ο χρήστης στέλνει HEX στο `VaultManager`, που καλεί `startStake` — το stake ανήκει στο contract (**πλήρες lock**).

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
# Άνοιξε http://localhost:5173 — σύνδεσε wallet, επικόλλησε deployed addresses
```

### Deploy (PulseChain)
```bash
export PRIVATE_KEY=0x...
export PULSECHAIN_RPC_URL=https://rpc.pulsechain.com
forge script script/Deploy.s.sol --rpc-url $PULSECHAIN_RPC_URL --broadcast
```

Μετά το deploy: addresses αυτόματα locked via `dtsc.lockWiring()`.

## Documentation

- [Whitepaper](docs/WHITEPAPER.md)
- [Security & Audit Checklist](docs/SECURITY.md)

## Roadmap

| Φάση | Δραστηριότητα |
|------|---------------|
| Σχεδιασμός | Whitepaper + design (τώρα) |
| Development | Smart contracts + tests |
| Audits | 2–3 audits + bug bounty |
| Bootstrap | Incentives Long tier + Stability Pool |
| Launch | Mainnet + renounce ownership |

## Κίνδυνοι

| Κίνδυνος | Mitigation |
|----------|------------|
| Early unstake (registered) | Monitoring + 20–40% penalty + cooldown |
| HEX price crash | Overcollateralization + SP + Recovery |
| Oracle manipulation | TWAP + min(TWAP, spot) + haircut cap |

## License

MIT