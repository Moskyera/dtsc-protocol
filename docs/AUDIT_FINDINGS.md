# DTSC — Internal Security Review (Pre-Audit)

**Ημερομηνία:** Ιούνιος 2026  
**Κατάσταση:** Pre-mainnet — **όχι immutable** μέχρι external audits + κλείσιμο open issues  
**Collateral:** Μόνο **pHEX T-shares** στο PulseChain — eHEX εκτός scope (τελείως)

---

## Διορθώθηκαν σε αυτό το review

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| C-01 | CRITICAL | `stakeKeyToVaultId` δεν καθαριζόταν στο `reportEarlyUnstake` | `_clearStakeKey()` |
| C-02 | CRITICAL | `notifyReward()` ανοιχτό σε όλους | Μόνο `penaltyRouter` |
| C-03 | CRITICAL | `setRedemptionHandler` / `setStabilityPool` χωρίς access control | `onlyDeployer` + `finalizeSetup()` |
| H-01 | HIGH | `stakeIndex` άκυρο μετά HEX list reorder | `_syncStakeIndex` + `effectiveValueSafe` |
| H-02 | HIGH | Redemption μόνο σε underwater vaults | `findLowestCrActiveVault()` |
| M-01 | MEDIUM | Principal truncation (hearts → hex division) | Τιμή ανά hearts |
| M-02 | MEDIUM | `globalInfo()[4]` αντί `currentDay()` | Προστέθηκε στο IHEX |

---

## Διορθώθηκαν (Security Hardening v2)

| ID | Fix |
|----|-----|
| C-04 | Redemption πληρώνει HEX από custodial vaults |
| C-05 | Liquidation bonus 7.5% HEX σε custodial |
| C-06 | Αφαίρεση penalty mint — μόνο SP `offsetDebt` |
| H-03 | `registeredVaultsEnabled = false` by default |
| H-04 | `closeVault` καλεί `endStake` + επιστρέφει HEX |
| M-03 | Stability Pool Liquity P-factor + burn DTSC στο offset |
| NEW | Oracle min liquidity + 2h staleness guard |
| NEW | `nonReentrant` σε κρίσιμα VaultManager paths |

---

## Διορθώθηκαν (Audit v3 — Ιούνιος 2026)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| H-07 | HIGH | `RedemptionHandler.redeem()` έκαιγε **όλο** το DTSC ακόμα κι αν `maxVaults` ή CR έλεγαν μικρό fill — χαμένα κεφάλαια | Pull → process → burn μόνο applied+fee → **refund** unused |
| M-06 | MEDIUM | `BuybackBurn.receivePenalty()` δημόσιο — οποιος μπορούσε να κάψει DTSC στο contract | `setPenaltyRouter()` + μόνο `penaltyRouter` |
| H-05 | HIGH | USDC depeg / thin-pool pump | Aggregator guard ±5% vs cross-rate |
| H-06 | HIGH | TWAP 2-slot | 8-slot `TwapRingBuffer` |
| COLL-01 | POLICY | Μόνο pHEX | `VaultManager` rejects `hexContract != PHEX` on chain 369 |

---

## Διορθώθηκαν (Audit v4 — Ιούνιος 2026)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| H-08 | HIGH | Spot pump στο mint path (`getPrice()` / fallback σε live reserves) | `getCollateralPrice()` για borrow/mint· TWAP-only με `lastTwapPrice` cache όταν cumulative αμετάβλητο· `TShareValuation.calculateEffectiveValueForBorrow` |
| M-07 | MEDIUM | Residual bad debt χωρίς recovery policy | `RecoveryModule.recordBadDebt()` + threshold `BAD_DEBT_RECOVERY_THRESHOLD_DTSC`· `MIN_SP_COVERAGE_DTSC` gate στο `mintDtsc` |
| M-04 | MEDIUM | Redemption O(n) scan κάθε redeem | CR cache (`cachedLowestCrVaultId`, `_recomputeCrCache`) — invalidation σε state changes |

**Νέα attack tests:** ATTACK36 (SP coverage gate), ATTACK37 (TWAP collateral ignores spot pump), ATTACK38 (CR cache), ATTACK39 (bad debt → recovery).

---

## Διορθώθηκαν (Bounty-hunter review — Ιούνιος 2026)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| H-NEW-01 | HIGH | `claimRewards()` μηδένιζε claimable λόγω `_accrue()` πριν claim | `_syncDeposit()` + `rewardDebt += reward` στο claim |
| H-NEW-02 | HIGH | Registered redemption έκαιγε DTSC χωρίς HEX | Redemption μόνο σε custodial vaults (`_scanLowestCr` + `applyRedemption`) |
| H-NEW-03 | MEDIUM | Μόνιμο recovery από `totalBadDebtDtsc` latch | Recovery από live CR· `unbackedDebtBlocksMint()` gate στο mint |
| M-NEW-04 | MEDIUM | CR cache stale μετά `refreshVault()` | `_recomputeCrCache()` στο `refreshVault()` |

---

## Διορθώθηκαν (Professional audit alignment — Ιούνιος 2026)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| M-NEW-05 | MEDIUM | CR cache stale όταν vault γίνεται debt-free μέσα σε `redeem(maxVaults>1)` | `_recomputeCrCache()` πάντα στο `applyRedemption` + στο `refreshVault` ακόμα κι αν debt=0 |
| M-NEW-06 | MEDIUM | Debt μειωνόταν χωρίς HEX payout (100% EES edge) | Revert + debt restore αν `heartsPaid == 0` |
| M-NEW-07 | LOW | `BuybackBurn.setPenaltyRouter()` race (πρώτος caller) | `onlyDeployer` one-shot + renounce |

**Νέα tests:** `AuditProfessional.t.sol` (AUDIT01–05), `AdversarialRedemption.t.sol`, `RedemptionPolicyParamSweep.t.sol`.

---

## Τι ελέγχουν επαγγελματικά audits (OpenZeppelin / Trail of Bits / Coinspect Liquity-Bold scope)

| Κατηγορία | DTSC status | Σχόλιο |
|-----------|-------------|--------|
| Access control / CEI | ✅ | `finalizeSetup`, minter ACL, deployer-only setters |
| Reentrancy | ✅ | VM + RedemptionHandler guards· SP optional hardening (L-01) |
| Oracle / TWAP | ⚠️ | Same-block ✅ (H-08)· multi-block pump ανοιχτό |
| Economic / redemption | ✅ | Hybrid policy + dynamic fee sweep· CR cache fix |
| Liquidation / SP / bad debt | ⚠️ | SP drain post-mint ops risk (ATTACK5) |
| Integer / rounding | ✅ | `DTSCMath.mulDiv`· zero-payout revert |
| Invariants / fuzz | ✅ | 4096 invariant calls + adversarial fuzz |
| Fork / integration | ⚠️ | pHEX read-only fork· χρειάζεται live `endStake` fork |
| Documentation / ops | ⏳ | `AUDIT_PACKAGE.md` έτοιμο· external audit pending |

**Σύσταση:** 2–3 external audits (Spearbit / Code4rena / OpenZeppelin) πριν immutable deploy.

---

## Διορθώθηκαν (Design/Ops open issues — Ιούνιος 2026)

| ID | Issue | Fix |
|----|-------|-----|
| H-08b | Spot fallback στο borrow oracle | Αφαιρέθηκε· μόνο TWAP + `lastTwapPrice` cache· `TwapInsufficientHistory` |
| H-08c | Chainlink redundancy | Προαιρετικό `chainlinkFeed` στο `HexPriceAggregator` (min price floor) |
| M-05 | Registered liquidation χωρίς HEX | `RegisteredLiquidationDisabled` revert στην αρχή του `liquidate()` |
| M-07b | SP drain post-mint | Dynamic `MIN_SP_DEBT_COVERAGE_BPS` (3% του total debt) στο `mintDtsc` |
| L-03 | `getTwapAndSpot()` aggregator misleading | Πραγματικό min TWAP/spot από underlying oracles |

**Νέα tests:** `OpenIssuesFix.t.sol` (OPEN01–05), `MockChainlinkFeed.sol`.

---

## Ανοιχτά — μόνο ops / mainnet wiring

### H-08 (υπόλοιπο): Multi-block TWAP pump >12h
12h TWAP + Chainlink floor **μειώνουν** το ρίσκο· πλήρες mitigation χρειάζεται live Chainlink feed στο PulseChain + keeper 2h.  
**Ops:** `script/PreDeployChecklist.s.sol`, `script/VerifyLiquidity.s.sol`.

### M-07 (υπόλοιπο): SP αδειάζει μετά mint + early unstake
Το `unbackedDebtBlocksMint()` κλειδώνει νέα mint· residual debt socialized (ATTACK5 documented).  
**Ops:** SP TVL monitoring, governance policy.

### L-01: RedemptionHandler χωρίς `nonReentrant`
Χαμηλό risk με CEI + VM guard.

### L-02: `uint64` timestamp overflow (~2554)

---

## Attack Test Matrix (74 tests PASS)

| Κατηγορία | Tests | Αποτέλεσμα |
|-----------|-------|------------|
| Registered walk-away | ATTACK1 | ✅ Blocked (custodial-only) |
| Liquidation HEX bonus | ATTACK2 | ✅ Custodial pays HEX |
| Oracle pump-dump borrow | ATTACK3 | ⚠️ Multi-block underwater (H-08 partial) |
| Redemption HEX payout | ATTACK4 | ✅ |
| Empty SP bad debt | ATTACK5 | ⚠️ Residual debt αν SP αδειάσει post-mint |
| SP offset accounting | ATTACK6, 26 | ✅ P-factor σωστό |
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

## Προτεινόμενη σειρά πριν launch (DTSC token ακόμα off-chain)

1. ✅ H-08 same-block mitigation (TWAP collateral + `lastTwapPrice` cache)
2. ✅ M-07 bad debt policy + `MIN_SP_COVERAGE_DTSC` gate
3. ✅ M-04 CR cache για redemption
4. ✅ Audit package (`docs/AUDIT_PACKAGE.md`) + bug bounty draft (`docs/BUG_BOUNTY.md`)
5. ⏳ External audits (2–3 firms) — package έτοιμο, χρειάζεται outreach
6. ⏳ Live PulseChain liquidity check (`script/PreDeployChecklist.s.sol`, `script/VerifyLiquidity.s.sol`)
7. ⏳ Chainlink redundancy (Phase 2 — `IChainlinkFeed` interface only)
8. **Immutable deploy μόνο μετά δική σου έγκριση**

---

## Εντολές ελέγχου

```powershell
cd "C:\Users\KQHEX\Documents\dtsc-protocol"
& "$env:USERPROFILE\.foundry\bin\forge.exe" test
& "$env:USERPROFILE\.foundry\bin\forge.exe" test --profile ci
```

**Τρέχουσα κατάσταση: 156/156 tests PASS — DTSC token not yet deployed**