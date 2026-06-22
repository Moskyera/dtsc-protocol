import { BrowserProvider, Contract, formatUnits, parseUnits, MaxUint256 } from "https://cdn.jsdelivr.net/npm/ethers@6.13.5/+esm";
import { PULSECHAIN, KNOWN_ADDRESSES, loadContracts, saveContracts } from "./config.js";
import {
  HEX_ABI, DTSC_ABI, VAULT_ABI, VALUATION_ABI,
  STABILITY_POOL_ABI, ORACLE_ABI, REDEMPTION_ABI,
} from "./abi.js";

const HEARTS_PER_HEX = 10n ** 8n;
const MIN_STAKE_DAYS = 2000n;

let provider;
let signer;
let account;
let contracts = loadContracts();

const $ = (id) => document.getElementById(id);

function short(addr) {
  if (!addr) return "—";
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function setStatus(msg, type = "") {
  const el = $("status");
  el.textContent = msg;
  el.className = `status ${type}`;
}

async function ensurePulseChain() {
  const hex = PULSECHAIN.chainIdHex;
  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: hex }],
    });
  } catch (err) {
    if (err.code === 4902) {
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: hex,
          chainName: PULSECHAIN.name,
          nativeCurrency: { name: "PLS", symbol: "PLS", decimals: 18 },
          rpcUrls: [PULSECHAIN.rpcUrl],
          blockExplorerUrls: [PULSECHAIN.blockExplorer],
        }],
      });
    } else {
      throw err;
    }
  }
}

async function connectWallet() {
  if (!window.ethereum) {
    setStatus("Εγκατάστησε MetaMask ή compatible wallet", "error");
    return;
  }
  await ensurePulseChain();
  provider = new BrowserProvider(window.ethereum);
  const accounts = await provider.send("eth_requestAccounts", []);
  signer = await provider.getSigner();
  account = accounts[0];
  $("walletAddr").textContent = short(account);
  $("connectBtn").textContent = "Συνδεδεμένο";
  setStatus("Συνδέθηκες στο PulseChain", "ok");
  await refreshAll();
}

function bindContracts() {
  contracts = {
    dtsc: $("addrDtsc").value.trim(),
    vaultManager: $("addrVault").value.trim(),
    stabilityPool: $("addrSp").value.trim(),
    redemptionHandler: $("addrRedeem").value.trim(),
    valuation: $("addrValuation").value.trim(),
    oracle: $("addrOracle").value.trim(),
  };
  saveContracts(contracts);
}

async function refreshAll() {
  if (!account) return;
  bindContracts();
  await Promise.all([
    loadStakes(),
    loadVaults(),
    loadBalances(),
    loadOracle(),
    loadStabilityPool(),
  ]);
}

async function loadOracle() {
  if (!contracts.oracle) return;
  const oracle = new Contract(contracts.oracle, ORACLE_ABI, provider);
  try {
    const price = await oracle.getPrice();
    const [twap, spot] = await oracle.getTwapAndSpot();
    $("hexPrice").textContent = `$${formatUnits(price, 18)}`;
    $("hexTwap").textContent = formatUnits(twap, 18);
    $("hexSpot").textContent = formatUnits(spot, 18);
  } catch {
    $("hexPrice").textContent = "—";
  }
}

async function loadBalances() {
  if (!contracts.dtsc) return;
  const dtsc = new Contract(contracts.dtsc, DTSC_ABI, provider);
  const bal = await dtsc.balanceOf(account);
  $("dtscBalance").textContent = `${formatUnits(bal, 18)} DTSC`;
}

async function loadStakes() {
  const list = $("stakesList");
  list.innerHTML = "";
  const hex = new Contract(KNOWN_ADDRESSES.HEX, HEX_ABI, provider);
  const g = await hex.globalInfo();
  const currentDay = g[4];
  const count = await hex.stakeCount(account);

  if (count === 0n) {
    list.innerHTML = "<p class='muted'>Δεν βρέθηκαν stakes ≥2000 ημέρες.</p>";
    return;
  }

  for (let i = 0n; i < count; i++) {
    const s = await hex.stakeLists(account, i);
    const maturity = BigInt(s.lockedDay) + BigInt(s.stakedDays);
    const remaining = maturity > currentDay ? maturity - currentDay : 0n;
    if (remaining < MIN_STAKE_DAYS) continue;

    const hearts = BigInt(s.stakedHearts);
    const hexAmt = Number(hearts) / Number(HEARTS_PER_HEX);
    let evText = "";
    if (contracts.valuation) {
      try {
        const val = new Contract(contracts.valuation, VALUATION_ABI, provider);
        const v = await val.calculateEffectiveValue(account, i);
        evText = ` · EV $${formatUnits(v.effectiveValueUsd, 18)}`;
      } catch { /* skip */ }
    }

    const div = document.createElement("div");
    div.className = "stake-card";
    div.innerHTML = `
      <div class="stake-meta">
        <strong>Stake #${i}</strong>
        <span class="badge">${remaining}d remaining</span>
      </div>
      <div class="stake-detail">${hexAmt.toLocaleString()} HEX · ID ${s.stakeId}${evText}</div>
      <button class="btn secondary" data-stake="${i}">Άνοιγμα Vault</button>
    `;
    div.querySelector("button").onclick = () => openVault(Number(i));
    list.appendChild(div);
  }
}

async function openVault(stakeIndex) {
  if (!contracts.vaultManager) {
    setStatus("Ορίσε VaultManager address", "error");
    return;
  }
  const vault = new Contract(contracts.vaultManager, VAULT_ABI, signer);
  setStatus("Ανοίγει vault…");
  const tx = await vault.openVaultWithExistingStake(stakeIndex);
  await tx.wait();
  setStatus("Vault δημιουργήθηκε!", "ok");
  await loadVaults();
}

async function loadVaults() {
  const list = $("vaultsList");
  list.innerHTML = "";
  if (!contracts.vaultManager) return;

  const vault = new Contract(contracts.vaultManager, VAULT_ABI, provider);
  const ids = await vault.getOwnerVaults(account);

  if (ids.length === 0) {
    list.innerHTML = "<p class='muted'>Δεν έχεις ενεργά vaults.</p>";
    return;
  }

  for (const id of ids) {
    const v = await vault.getVault(id);
    if (!v.active) continue;
    const cr = v.debtDtsc > 0n
      ? await vault.getVaultCollateralRatio(id)
      : 0n;
    const cooldown = Number(v.cooldownEndsAt) * 1000;
    const canMint = Date.now() >= cooldown;

    const div = document.createElement("div");
    div.className = "vault-card";
    div.innerHTML = `
      <div class="vault-header">
        <strong>Vault #${id}</strong>
        <span class="badge ${canMint ? "ok" : "warn"}">${canMint ? "Ready" : "Cooldown"}</span>
      </div>
      <div class="vault-stats">
        <span>EV: $${formatUnits(v.effectiveValueUsd, 18)}</span>
        <span>Debt: ${formatUnits(v.debtDtsc, 18)} DTSC</span>
        <span>CR: ${v.debtDtsc > 0n ? (Number(cr) / 100).toFixed(1) + "%" : "∞"}</span>
      </div>
      <div class="vault-actions">
        <input type="number" placeholder="DTSC amount" class="input-sm" id="mint-${id}" />
        <button class="btn primary" data-mint="${id}" ${canMint ? "" : "disabled"}>Mint</button>
        <button class="btn secondary" data-repay="${id}">Repay</button>
      </div>
    `;
    div.querySelector("[data-mint]")?.addEventListener("click", () => mintDtsc(id));
    div.querySelector("[data-repay]")?.addEventListener("click", () => repayDtsc(id));
    list.appendChild(div);
  }
}

async function mintDtsc(vaultId) {
  const input = $(`mint-${vaultId}`);
  const amount = parseUnits(input.value || "0", 18);
  if (amount <= 0n) return;

  const dtsc = new Contract(contracts.dtsc, DTSC_ABI, signer);
  const vault = new Contract(contracts.vaultManager, VAULT_ABI, signer);
  const tx = await vault.mintDtsc(vaultId, amount);
  await tx.wait();
  setStatus(`Minted ${input.value} DTSC`, "ok");
  await refreshAll();
}

async function repayDtsc(vaultId) {
  const input = $(`mint-${vaultId}`);
  const amount = parseUnits(input.value || "0", 18);
  if (amount <= 0n) return;

  const dtsc = new Contract(contracts.dtsc, DTSC_ABI, signer);
  await (await dtsc.approve(contracts.vaultManager, amount)).wait();
  const vault = new Contract(contracts.vaultManager, VAULT_ABI, signer);
  await (await vault.repayDtsc(vaultId, amount)).wait();
  setStatus(`Repaid ${input.value} DTSC`, "ok");
  await refreshAll();
}

async function loadStabilityPool() {
  if (!contracts.stabilityPool) return;
  const sp = new Contract(contracts.stabilityPool, STABILITY_POOL_ABI, provider);
  const dep = await sp.deposits(account);
  const reward = await sp.claimableReward(account);
  const total = await sp.totalDeposits();
  $("spDeposit").textContent = formatUnits(dep, 18);
  $("spReward").textContent = formatUnits(reward, 18);
  $("spTotal").textContent = formatUnits(total, 18);
}

async function spDeposit() {
  const amount = parseUnits($("spAmount").value || "0", 18);
  const dtsc = new Contract(contracts.dtsc, DTSC_ABI, signer);
  await (await dtsc.approve(contracts.stabilityPool, amount)).wait();
  const sp = new Contract(contracts.stabilityPool, STABILITY_POOL_ABI, signer);
  await (await sp.deposit(amount)).wait();
  setStatus("Κατάθεση στο Stability Pool ολοκληρώθηκε", "ok");
  await loadStabilityPool();
}

async function spClaim() {
  const sp = new Contract(contracts.stabilityPool, STABILITY_POOL_ABI, signer);
  await (await sp.claimRewards()).wait();
  setStatus("Rewards claimed!", "ok");
  await refreshAll();
}

async function redeemDtsc() {
  const amount = parseUnits($("redeemAmount").value || "0", 18);
  const dtsc = new Contract(contracts.dtsc, DTSC_ABI, signer);
  await (await dtsc.approve(contracts.redemptionHandler, amount)).wait();
  const rh = new Contract(contracts.redemptionHandler, REDEMPTION_ABI, signer);
  await (await rh.redeem(amount, 20)).wait();
  setStatus("Redemption ολοκληρώθηκε", "ok");
  await refreshAll();
}

function initContractForm() {
  $("addrDtsc").value = contracts.dtsc;
  $("addrVault").value = contracts.vaultManager;
  $("addrSp").value = contracts.stabilityPool;
  $("addrRedeem").value = contracts.redemptionHandler;
  $("addrValuation").value = contracts.valuation;
  $("addrOracle").value = contracts.oracle;
}

$("connectBtn").addEventListener("click", connectWallet);
$("refreshBtn").addEventListener("click", refreshAll);
$("saveContractsBtn").addEventListener("click", () => { bindContracts(); setStatus("Addresses saved", "ok"); });
$("spDepositBtn").addEventListener("click", spDeposit);
$("spClaimBtn").addEventListener("click", spClaim);
$("redeemBtn").addEventListener("click", redeemDtsc);

initContractForm();