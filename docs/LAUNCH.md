# DTSC Launch Playbook

**Status:** Pre-deploy — DTSC token does not exist on-chain yet.  
**Network:** PulseChain (chain 369)  
**Collateral:** pHEX T-shares only (`0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39`)

---

## Pre-launch checklist

| Step | Status | Notes |
|------|--------|-------|
| 156 tests pass (local + CI) | Done | GitHub Actions on every push |
| Internal security review | Done | See `docs/AUDIT_FINDINGS.md` |
| Audit package prepared | Done | See `docs/AUDIT_PACKAGE.md` |
| PreDeployChecklist on PulseChain | Done | `script/PreDeployChecklist.s.sol` |
| External audits (2–3 firms) | Pending | Outreach required |
| Bug bounty live | Pending | Draft in `docs/BUG_BOUNTY.md` |
| Immutable deploy | **Blocked** | Requires explicit owner approval |

---

## Stability Pool seed plan

Public mint is gated by `MIN_SP_COVERAGE_DTSC` (**10,000 DTSC** minimum) and dynamic coverage (`MIN_SP_DEBT_COVERAGE_BPS` = 3% of total debt after each mint).

### Bootstrap sequence (post-deploy, before public mint)

1. **Deploy** via `script/Deploy.s.sol` and call `dtsc.lockWiring()` (one-shot wiring lock).
2. **Prime oracle** — seed 12h+ TWAP history via keeper updates every `< 2h` (`ORACLE_MAX_STALENESS`).
3. **Seed Stability Pool** — deposit **≥ 10,000 DTSC** from deployer/treasury wallet:
   - Approve `StabilityPool` for DTSC amount.
   - Call `StabilityPool.deposit(amount)`.
4. **Verify gate** — attempt a small test mint; confirm `mintDtsc` reverts if SP TVL drops below threshold.
5. **Announce** public mint only after SP seed + oracle primed.

### Ongoing ops

- Monitor SP TVL vs `totalDebt` (3% dynamic floor grows with debt).
- Keep oracle keeper running; optional Chainlink floor when feed is live on PulseChain.
- Run `script/VerifyLiquidity.s.sol` before high-traffic periods.

---

## Deploy commands

```bash
export PRIVATE_KEY=0x...
export PULSECHAIN_RPC_URL=https://rpc.pulsechain.com

# Pre-flight (read-only)
forge script script/PreDeployChecklist.s.sol --rpc-url $PULSECHAIN_RPC_URL

# Deploy (requires explicit approval)
forge script script/Deploy.s.sol --rpc-url $PULSECHAIN_RPC_URL --broadcast
```

---

## Post-deploy wiring

1. `finalizeSetup()` on VaultManager (if not done in deploy script).
2. `setPenaltyRouter()` on BuybackBurn (deployer one-shot).
3. Seed Stability Pool (≥ 10,000 DTSC).
4. Publish contract addresses in frontend `config.js` / UI.
5. Renounce deployer only after audits + owner sign-off.

---

## Immutable deploy gate

**Do not** broadcast immutable mainnet deploy until:

- External audits complete and fixes merged
- Owner explicitly approves mainnet launch
- SP seed wallet funded and ready
- Oracle keeper operational