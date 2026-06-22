# DTSC — Internal Security Review (Pre-Audit)

**Date:** June 2026  
**Status:** Pre-mainnet — **not immutable** until external audits + open issues closed  
**Collateral:** **pHEX T-shares only** on PulseChain — eHEX out of scope entirely

---

## Fixed in this review

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| C-01 | CRITICAL | `stakeKeyToVaultId` not cleared in `reportEarlyUnstake` | `_clearStakeKey()` |
| C-02 | CRITICAL | `notifyReward()` open to anyone | `penaltyRouter` only |
| C-03 | CRITICAL | `setRedemptionHandler` / `setStabilityPool` without access control | `onlyDeployer` + `finalizeSetup()` |
| H-01 | HIGH | Invalid `stakeIndex` after HEX list reorder | `_syncStakeIndex` + `effectiveValueSafe` |
| H-02 | HIGH | Redemption only on underwater vaults | `findLowestCrActiveVault()` |
| M-01 | MEDIUM | Principal truncation (hearts → hex division) | Price per hearts |
| M-02 | MEDIUM | `globalInfo()[4]` instead of `currentDay()` | Added to IHEX |

---

## Fixed (Security Hardening v2)

| ID | Fix |
|----|-----|
| C-04 | Redemption pays HEX from custodial vaults |
| C-05 | 7.5% HEX liquidation bonus on custodial |
| C-06 | Removed penalty mint — SP `offsetDebt` only |
| H-03 | `registeredVaultsEnabled = false` by default |
| H-04 | `closeVault` calls `endStake` + returns HEX |
| M-03 | Stability Pool Liquity P-factor + burn DTSC on offset |
| NEW | Oracle min liquidity + 2h staleness guard |
| NEW | `nonReentrant` on critical VaultManager paths |

---

## Fixed (Audit v3 — June 2026)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| H-07 | HIGH | `RedemptionHandler.redeem()` burned **all** DTSC even when `maxVaults` or CR implied a small fill — lost funds | Pull → process → burn only applied+fee → **refund** unused |
| M-06 | MEDIUM | `BuybackBurn.receivePenalty()` public — anyone could burn DTSC in the contract | `setPenaltyRouter()` + `penaltyRouter` only |
| H-05 | HIGH | USDC depeg / thin-pool pump | Aggregator guard ±5% vs cross-rate |
| H-06 | HIGH | TWAP 2-slot | 8-slot `TwapRingBuffer` |
| COLL-01 | POLICY | pHEX only | `VaultManager` rejects `hexContract != PHEX` on chain 369 |

---

## Fixed (Audit v4 — June 2026)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| H-08 | HIGH | Spot pump on mint path (`getPrice()` / fallback to live reserves) | `getCollateralPrice()` for borrow/mint; TWAP-only with `lastTwapPrice` cache when cumulative unchanged; `TShareValuation.calculateEffectiveValueForBorrow` |
| M-07 | MEDIUM | Residual bad debt without recovery policy | `RecoveryModule.recordBadDebt()` + threshold `BAD_DEBT_RECOVERY_THRESHOLD_DTSC`; `MIN_SP_COVERAGE_DTSC` gate on `mintDtsc` |
| M-04 | MEDIUM | Redemption O(n) scan on every redeem | CR cache (`cachedLowestCrVaultId`, `_recomputeCrCache`) — invalidation on state changes |

**New attack tests:** ATTACK36 (SP coverage gate), ATTACK37 (TWAP collateral ignores spot pump), ATTACK38 (CR cache), ATTACK39 (bad debt → recovery).

---

## Fixed (Bounty-hunter review — June 2026)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| H-NEW-01 | HIGH | `claimRewards()` zeroed claimable due to `_accrue()` before claim | `_syncDeposit()` + `rewardDebt += reward` on claim |
| H-NEW-02 | HIGH | Registered redemption burned DTSC without HEX | Redemption only on custodial vaults (`_scanLowestCr` + `applyRedemption`) |
| H-NEW-03 | MEDIUM | Permanent recovery from `totalBadDebtDtsc` latch | Recovery from live CR; `unbackedDebtBlocksMint()` gate on mint |
| M-NEW-04 | MEDIUM | CR cache stale after `refreshVault()` | `_recomputeCrCache()` in `refreshVault()` |

---

## Fixed (Professional audit alignment — June 2026)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| M-NEW-05 | MEDIUM | CR cache stale when vault becomes debt-free inside `redeem(maxVaults>1)` | `_recomputeCrCache()` always in `applyRedemption` + in `refreshVault` even if debt=0 |
| M-NEW-06 | MEDIUM | Debt reduced without HEX payout (100% EES edge) | Revert + debt restore if `heartsPaid == 0` |
| M-NEW-07 | LOW | `BuybackBurn.setPenaltyRouter()` race (first caller) | `onlyDeployer` one-shot + renounce |

**New tests:** `AuditProfessional.t.sol` (AUDIT01–05), `AdversarialRedemption.t.sol`, `RedemptionPolicyParamSweep.t.sol`.

---

## What professional audits cover (OpenZeppelin / Trail of Bits / Coinspect Liquity-Bold scope)

| Category | DTSC status | Notes |
|----------|-------------|-------|
| Access control / CEI | ✅ | `finalizeSetup`, minter ACL, deployer-only setters |
| Reentrancy | ✅ | VM + RedemptionHandler guards; SP optional hardening (L-01) |
| Oracle / TWAP | ⚠️ | Same-block ✅ (H-08); multi-block pump open |
| Economic / redemption | ✅ | Hybrid policy + dynamic fee sweep; CR cache fix |
| Liquidation / SP / bad debt | ⚠️ | SP drain post-mint ops risk (ATTACK5) |
| Integer / rounding | ✅ | `DTSCMath.mulDiv`; zero-payout revert |
| Invariants / fuzz | ✅ | 4096 invariant calls + adversarial fuzz |
| Fork / integration | ⚠️ | pHEX read-only fork; live `endStake` fork needed |
| Documentation / ops | ⏳ | `AUDIT_PACKAGE.md` ready; external audit pending |

**Recommendation:** 2–3 external audits (Spearbit / Code4rena / OpenZeppelin) before immutable deploy.

---

## Fixed (Design/Ops open issues — June 2026)

| ID | Issue | Fix |
|----|-------|-----|
| H-08b | Spot fallback on borrow oracle | Removed; TWAP + `lastTwapPrice` cache only; `TwapInsufficientHistory` |
| H-08c | Chainlink redundancy | Optional `chainlinkFeed` on `HexPriceAggregator` (min price floor) |
| M-05 | Registered liquidation without HEX | `RegisteredLiquidationDisabled` revert at start of `liquidate()` |
| M-07b | SP drain post-mint | Dynamic `MIN_SP_DEBT_COVERAGE_BPS` (3% of total debt) on `mintDtsc` |
| L-03 | `getTwapAndSpot()` aggregator misleading | Real min TWAP/spot from underlying oracles |

**New tests:** `OpenIssuesFix.t.sol` (OPEN01–05), `MockChainlinkFeed.sol`.

---

## Open — ops / mainnet wiring only

### H-08 (remaining): Multi-block TWAP pump >12h
12h TWAP + Chainlink floor **reduce** risk; full mitigation requires a live Chainlink feed on PulseChain + 2h keeper.  
**Ops:** `script/PreDeployChecklist.s.sol`, `script/VerifyLiquidity.s.sol`.

### M-07 (remaining): SP drains after mint + early unstake
`unbackedDebtBlocksMint()` blocks new mints; residual debt socialized (ATTACK5 documented).  
**Ops:** SP TVL monitoring, governance policy.

### L-01: RedemptionHandler without `nonReentrant`
Low risk with CEI + VM guard.

### L-02: `uint64` timestamp overflow (~2554)

---

## Attack Test Matrix (156 tests PASS)

| Category | Tests | Result |
|----------|-------|--------|
| Registered walk-away | ATTACK1 | ✅ Blocked (custodial-only) |
| Liquidation HEX bonus | ATTACK2 | ✅ Custodial pays HEX |
| Oracle pump-dump borrow | ATTACK3 | ⚠️ Multi-block underwater (H-08 partial) |
| Redemption HEX payout | ATTACK4 | ✅ |
| Empty SP bad debt | ATTACK5 | ⚠️ Residual debt if SP drains post-mint |
| SP offset accounting | ATTACK6, 26 | ✅ P-factor correct |
| Recovery mode | ATTACK7, 25 | ✅ Blocks mint, exits on recovery |
| Cooldown bypass | ATTACK8 | ✅ Blocked |
| Double collateral | ATTACK9 | ✅ Blocked |
| Over-borrow | ATTACK10 | ✅ Blocked |
| Redemption griefing | ATTACK11 | ✅ Lowest CR first |
| Custodial close | ATTACK12 | ✅ HEX returned |
| No penalty inflation | ATTACK13 | ✅ |
| Spot manipulation | ATTACK14, 29, 37 | ✅ Mint path TWAP-only; liquidation min(TWAP,spot) |
| SP coverage gate | ATTACK36 | ✅ Mint blocked if SP < 10k DTSC |
| CR cache | ATTACK38 | ✅ Lowest-CR cached |
| Bad debt recovery | ATTACK39 | ✅ Recovery mode on threshold |
| Thin pool oracle | ATTACK15, 33 | ✅ Reverts |
| Redemption refund | ATTACK16, 17 | ✅ Unused DTSC refunded |
| Access control | ATTACK19-22, 30-31, 35 | ✅ |
| Double liquidation | ATTACK23 | ✅ |
| Healthy vault liquidate | ATTACK24 | ✅ Reverts |
| Close with debt | ATTACK27 | ✅ Reverts |
| Repay + close | ATTACK28 | ✅ |
| Custodial redemption stake | ATTACK34 | ✅ Hearts extracted |
| Fuzz valuation | 512 runs | ✅ |
| Fuzz SP offset | 512 runs | ✅ |
| Invariants | 4096 calls | ✅ |

---

## Test Coverage Matrix

| Area | Covered | Missing |
|------|---------|---------|
| Valuation tiers | ✅ | Edge days exactly 2000/4000 |
| Vault mint/cooldown | ✅ | — |
| Stability pool | ✅ | Multi-user claim after offset |
| Redemption | ✅ | Partial fill edge cases |
| Oracle manipulation | ✅ | Multi-block TWAP attack sim |
| pHEX-only collateral | ✅ | — |
| Invariant tests | ✅ | totalDebt ≤ supply backing (economic) |

---

## Recommended pre-launch sequence (DTSC token still off-chain)

1. ✅ H-08 same-block mitigation (TWAP collateral + `lastTwapPrice` cache)
2. ✅ M-07 bad debt policy + `MIN_SP_COVERAGE_DTSC` gate
3. ✅ M-04 CR cache for redemption
4. ✅ Audit package (`docs/AUDIT_PACKAGE.md`) + bug bounty draft (`docs/BUG_BOUNTY.md`)
5. ⏳ External audits (2–3 firms) — package ready, outreach needed
6. ⏳ Live PulseChain liquidity check (`script/PreDeployChecklist.s.sol`, `script/VerifyLiquidity.s.sol`)
7. ⏳ Chainlink redundancy (Phase 2 — `IChainlinkFeed` interface only)
8. **Immutable deploy only after your explicit approval**

---

## Verification commands

```powershell
cd "C:\Users\KQHEX\Documents\dtsc-protocol"
& "$env:USERPROFILE\.foundry\bin\forge.exe" test
$env:FOUNDRY_PROFILE='ci'; & "$env:USERPROFILE\.foundry\bin\forge.exe" test
```

**Current status: 156/156 tests PASS — DTSC token not yet deployed**