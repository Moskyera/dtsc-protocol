# DTSC Security & Audit Checklist

## Internal Review Status (June 2026)

| Item | Status |
|------|--------|
| 156 automated tests (attack, fuzz, invariant, fork) | ✅ Pass |
| GitHub Actions CI (`FOUNDRY_PROFILE=ci`) | ✅ Pass |
| Internal findings documented | ✅ `docs/AUDIT_FINDINGS.md` |
| PreDeployChecklist on PulseChain RPC | ✅ Pass |
| External audit | ⏳ Pending outreach |
| Immutable mainnet deploy | 🚫 Blocked until owner approval |

---

## Pre-Audit Requirements

### Critical Paths
- [x] TShareValuation — EV calculation correctness
- [x] HexPriceOracle — TWAP manipulation resistance
- [x] VaultManager — mint/repay/liquidate/early unstake
- [x] StabilityPool — deposit/withdraw/reward accounting
- [x] RedemptionHandler — debt reduction ordering
- [x] PenaltyRouter — 80/20 split integrity
- [x] BuybackBurn — swap slippage + burn authorization
- [x] RecoveryModule — system CR thresholds
- [x] DTSC — minter lock irreversibility (tested; verify on deploy)

### Access Control
- [ ] `dtsc.lockWiring()` called post-deploy
- [ ] All one-time setters renounced
- [ ] No remaining `deployer` addresses
- [x] Only authorized minters can mint/burn (unit tests)

### Economic Invariants
- [x] Total debt ≤ sum of max borrowable per vault
- [x] System CR triggers recovery mode correctly
- [x] Penalty mint bounded by vault debt (removed; SP offset only)
- [x] SP offset cannot exceed totalDeposits
- [x] Redemption cannot create negative debt

### Oracle Security
- [x] Pair address verified on-chain
- [x] min(TWAP, spot) for liquidations; TWAP-only for borrow
- [x] Stale TWAP fallback documented
- [x] EV hard cap enforced

### HEX Integration
- [x] stakeLists/stakeCount ABI matches PulseChain HEX
- [x] globalInfo()[4] day index verified
- [x] calcPayoutRewards range correct
- [x] Custodial startStake minimum 2000 days

---

## Known Limitations

1. **Registered stakes** cannot be physically locked — reliance on monitoring + penalties
2. **Early unstake penalties** route to Stability Pool offset (no penalty mint)
3. **USD pricing via WPLS** requires external WPLS/USD reference for true dollar peg
4. **BuybackBurn** requires DTSC liquidity on PulseX post-launch

## Recommended Audits

| Firm Type | Focus |
|-----------|-------|
| Tier-1 Solidity auditor | Full protocol |
| Economic auditor | Peg mechanism + EV model |
| Oracle specialist | TWAP + manipulation |

## Test Coverage

```bash
forge test
FOUNDRY_PROFILE=ci forge test
forge test --gas-report
```

**Current:** 156 tests across 23 suites (see GitHub Actions).

## Incident Response

1. Pause frontend (contracts are immutable — cannot pause on-chain)
2. Communicate via official channels
3. Stability Pool depositors absorb losses per design
4. Post-mortem + audit remediation for v2 if needed