# DTSC — External Audit Package

**Protocol:** Decentralized T-Share Coin (DTSC)  
**Network:** PulseChain (chain 369)  
**Collateral:** pHEX T-shares only (`0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39`)  
**Status:** Pre-deploy — DTSC token does not exist on-chain yet

---

## Scope

| In scope | Out of scope |
|----------|--------------|
| `src/core/*` (VaultManager, StabilityPool, RedemptionHandler, DTSC, RecoveryModule, PenaltyRouter, BuybackBurn) | Frontend |
| `src/oracle/*` (HexPriceOracle, HexPriceAggregator, TwapRingBuffer) | eHEX / bridge tokens |
| `src/valuation/TShareValuation.sol` | Immutable deployment |
| `src/deploy/DTSCDeployer.sol` | Chainlink integration (interface only) |
| `script/Deploy.s.sol`, `script/PreDeployChecklist.s.sol` | |

---

## Architecture summary

1. **Custodial vaults (v1 default):** User deposits pHEX → VaultManager stakes → T-shares collateralize DTSC mint.
2. **Stability Pool:** DTSC deposits absorb bad debt via P-factor (`offsetDebt`).
3. **Redemption:** Burn DTSC → receive pHEX from custodial vaults (lowest CR first).
4. **Oracle:** `min(TWAP, spot)` for liquidations; **TWAP-only** for borrow/mint (H-08).
5. **Recovery mode:** System CR < 150% OR bad debt ≥ threshold.

---

## Known risks (auditor focus)

| ID | Area | Question for auditors |
|----|------|---------------------|
| H-08 | Oracle | Is TWAP-only borrow sufficient vs multi-block manipulation? |
| M-07 | Bad debt | Is `recordBadDebt` + recovery mode economically sound? |
| M-04 | Gas | Is CR cache invalidation complete on all paths? |
| C-04/05 | Redemption/Liquidation | Custodial HEX extraction correctness after partial `endStake` |
| M-03 | Stability Pool | P-factor accounting vs `rewardDebt` after offset |

---

## Test evidence

```powershell
cd dtsc-protocol
& "$env:USERPROFILE\.foundry\bin\forge.exe" test
$env:FOUNDRY_PROFILE='ci'; & "$env:USERPROFILE\.foundry\bin\forge.exe" test
```

**Expected:** 156 tests PASS (23 suites), including attack scenarios, adversarial redemption, fuzz, invariants, and PulseChain fork tests.

---

## Pre-audit checklist

- [x] All tests pass locally and CI profile (156/156 — GitHub Actions)
- [x] `script/PreDeployChecklist.s.sol` run on PulseChain mainnet RPC (June 2026)
- [x] `docs/AUDIT_FINDINGS.md` reviewed
- [x] No immutable contracts deployed
- [x] Stability Pool seed plan documented — see `docs/LAUNCH.md` (≥ 10,000 DTSC before public mint)

**Remaining before external audit outreach:** share this repo URL + `AUDIT_FINDINGS.md` with selected firms.

---

## Suggested audit firms (contact separately)

- Trail of Bits, OpenZeppelin, Consensys Diligence, Sherlock (contest), Code4rena (contest)

Deliverables requested: full report, severity classification, fix review round.