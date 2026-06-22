# DTSC Bug Bounty (Draft — pre-mainnet)

**Status:** Not live until DTSC is deployed and audits complete.  
**Asset:** DTSC protocol contracts on PulseChain (custodial vaults, oracle, stability pool).

---

## In scope

- Smart contracts in `src/` after immutable deploy
- Economic attacks: oracle manipulation, redemption/liquidation bugs, SP accounting
- Access control bypasses on VaultManager, StabilityPool, PenaltyRouter

## Out of scope

- eHEX / non-pHEX collateral
- Frontend/UI issues without on-chain impact
- Known issues in `docs/AUDIT_FINDINGS.md` marked open
- Centralization of oracle keepers (documented operational risk)

---

## Severity rewards (template — adjust before launch)

| Severity | Examples | Suggested reward |
|----------|----------|------------------|
| Critical | Unbacked DTSC mint, theft of vault HEX, permanent freeze | $25,000+ |
| High | Bad debt not recorded, redemption drain, SP insolvency | $5,000–$25,000 |
| Medium | Griefing, incorrect CR cache, fee bypass | $1,000–$5,000 |
| Low | Gas, informational | $100–$1,000 |

---

## Reporting

1. Email / Immunefi (TBD when live)
2. Include: PoC on PulseChain fork, affected contracts, suggested fix
3. No public disclosure before fix deployed

---

## Safe harbor

Good-faith research on testnet/fork encouraged. Do not attack mainnet user funds without authorization.