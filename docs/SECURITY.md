# DTSC Security & Audit Checklist

## Pre-Audit Requirements

### Critical Paths
- [ ] TShareValuation — EV calculation correctness
- [ ] HexPriceOracle — TWAP manipulation resistance
- [ ] VaultManager — mint/repay/liquidate/early unstake
- [ ] StabilityPool — deposit/withdraw/reward accounting
- [ ] RedemptionHandler — debt reduction ordering
- [ ] PenaltyRouter — 80/20 split integrity
- [ ] BuybackBurn — swap slippage + burn authorization
- [ ] RecoveryModule — system CR thresholds
- [ ] DTSC — minter lock irreversibility

### Access Control
- [ ] `dtsc.lockWiring()` called post-deploy
- [ ] All one-time setters renounced
- [ ] No remaining `deployer` addresses
- [ ] Only authorized minters can mint/burn

### Economic Invariants
- [ ] Total debt ≤ sum of max borrowable per vault
- [ ] System CR triggers recovery mode correctly
- [ ] Penalty mint bounded by vault debt
- [ ] SP offset cannot exceed totalDeposits
- [ ] Redemption cannot create negative debt

### Oracle Security
- [ ] Pair address verified on-chain
- [ ] min(TWAP, spot) always used
- [ ] Stale TWAP fallback documented
- [ ] EV hard cap enforced

### HEX Integration
- [ ] stakeLists/stakeCount ABI matches PulseChain HEX
- [ ] globalInfo()[4] day index verified
- [ ] calcPayoutRewards range correct
- [ ] Custodial startStake minimum 2000 days

## Known Limitations

1. **Registered stakes** cannot be physically locked — reliance on monitoring + penalties
2. **Penalty minting** on early unstake creates bounded inflation compensated by burns elsewhere
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
forge test --gas-report
forge coverage
```

Target: >90% line coverage on `src/core/` and `src/valuation/`.

## Incident Response

1. Pause frontend (contracts are immutable — cannot pause on-chain)
2. Communicate via official channels
3. Stability Pool depositors absorb losses per design
4. Post-mortem + audit remediation for v2 if needed