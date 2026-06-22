# DTSC Whitepaper
## Decentralized T-Share Coin

**Version 1.0 — PulseChain Mainnet Design**  
**June 2026**

---

## Abstract

DTSC (Decentralized T-Share Coin) is a strictly decentralized stablecoin targeting a $1 USD peg, backed exclusively by long-duration HEX T-shares (≥2,000 days to maturity). There is no governance token — all value accrues directly to participants.

---

## 1. Goals

| Goal | Description |
|------|-------------|
| Decentralization | Immutable contracts, renounced ownership after deploy |
| Long-term collateral | Only T-shares with ≥2,000 days remaining |
| Peg stability | Redemption + Stability Pool + Buyback & Burn |
| Fair distribution | No governance token; 80% of penalties to Stability Pool |
| Security | Conservative on-chain valuation, recovery mode |

---

## 2. Tokenomics

**Single token:** `DTSC` — ERC-20 stablecoin (18 decimals)

| Mechanism | Description |
|-----------|-------------|
| Mint | Only via VaultManager against collateral |
| Burn | Repay, liquidation, redemption, buyback |
| Penalties | 80% → Stability Pool rewards, 20% → Burn |
| Governance | **None** |

---

## 3. Collateral — T-Shares

### 3.1 Eligibility

| Tier | Days to maturity | Min CCR | LTV |
|------|------------------|---------|-----|
| Long | 4,000 – 5,555 | 150% | ~66% |
| Medium-Long | 2,000 – 3,999 | 160% | ~62.5% |
| Not allowed | < 2,000 | — | — |

### 3.2 Collateral Modes

**Registered Mode** — An existing stake remains in the user's wallet. The protocol monitors the `stakeId` on-chain. If the user calls early `endStake`, a 20–40% penalty applies.

**Custodial Mode** — The user sends HEX to VaultManager, which calls `startStake`. The stake is owned by the contract (**full lock**).

### 3.3 Valuation (Effective Value)

```
EV = (Principal × HEX_Price) + EarnedRewards + LongBonus − TimeDiscount
```

| Component | Phase 1 | Future |
|-----------|---------|--------|
| HEX_Price | min(TWAP₂₄h, spot) from PulseX | + volatility haircut |
| EarnedRewards | Only already accrued rewards | Yield model |
| LongBonus | 0% / 5% / 10–15% | — |
| TimeDiscount | Linear 0–15% | — |
| Cap | 2× Principal | — |

**Example:**
- Principal: 100,000 HEX × $0.001 = $100
- Earned: $80 | Bonus (+12%): $21.6 | Discount (−5%): −$10
- **EV = $191.6** → Max borrow @150% CCR = **$127.7 DTSC**

---

## 4. Vault Operations

| Operation | Description |
|-----------|-------------|
| Open Vault | Register existing stake or open custodial new stake |
| Mint DTSC | Interest-free, after 60-day cooldown |
| Repay | Burn DTSC, reduce debt |
| Close | Only when debt = 0 |
| Liquidate | When CR < min CCR |
| Early Unstake Report | Monitoring + penalty + SP offset |

---

## 5. Peg Maintenance

### 5.1 Redemption (Primary)
Anyone who burns DTSC reduces debt of the lowest-CR vaults first. Dynamic fee 0–5%.

### 5.2 Stability Pool (Primary)
Users deposit DTSC. The pool absorbs bad debt from liquidations and early unstakes. Depositors earn 80% of penalties.

### 5.3 Buyback & Burn (Secondary)
20% of penalties are burned immediately. Additional permissionless buyback via PulseX Router V2.

---

## 6. Manipulation Defenses

| Measure | Strength |
|---------|----------|
| No early unstake (custodial) | ★★★★★ |
| 20–40% penalty | ★★★★ |
| 60-day cooldown | ★★★★ |
| Dynamic CCR / Recovery Mode | ★★★ |
| min(TWAP, spot) oracle | ★★★★ |
| EV cap 2× principal | ★★★★ |

---

## 7. Recovery Mode

Activated when system CR < 150%:
- New minting blocked
- Stricter CCR requirements
- Redemptions prioritized

---

## 8. Technical Architecture

```
HEX Stakes → TShareValuation → VaultManager → DTSC
                    ↑                ↓
              HexPriceOracle    StabilityPool
              (PulseX TWAP)     RedemptionHandler
                                  BuybackBurn
```

### PulseChain Addresses
| Contract | Address |
|----------|---------|
| HEX | `0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39` |
| WPLS | `0xA1077a294dDE1B09bB078844df40758a5D0f9a27` |
| PulseX Router V2 | `0x165C3410fC91EF562C50559f7d2289fEbed552d9` |
| PulseX Factory V2 | `0x29eA7545DEf87022BAdc76323F373EA1e707C523` |

---

## 9. Deployment & Immutability

1. Deploy via `DTSCDeployer`
2. Wire all modules
3. `dtsc.lockWiring()` — permanent minter freeze
4. Renounce one-time setters
5. 2–3 external audits before public launch

---

## 10. Risks

| Risk | Level | Mitigation |
|------|-------|------------|
| Early unstake (registered) | Medium | Penalty + SP offset + monitoring |
| HEX price crash | Medium | Overcollateralization + Recovery |
| Oracle manipulation | Medium | TWAP + conservative min |
| Smart contract bug | High | Audits + immutable design |
| Low adoption | Medium | SP incentives |

---

## 11. Roadmap

| Phase | Duration | Status |
|-------|----------|--------|
| Design | 1–2 months | ✅ Complete |
| Development | 3–5 months | ✅ Core contracts |
| Testing | Ongoing | ✅ Foundry suite |
| Frontend | 1 month | ✅ Web UI |
| Audits | 2–3 months | 🔲 Pending |
| Bootstrap | 1–2 months | 🔲 Pending |
| Launch | — | 🔲 Pending |

---

## 12. Conclusion

DTSC is designed to be **simple, secure, and sustainable** — a stablecoin that:
- Is backed by long-duration T-shares
- Has no governance token
- Protects the peg with a triple mechanism
- Distributes benefits fairly to participants

---

*© 2026 DTSC Protocol — MIT License*