export const PULSECHAIN = {
  chainId: 369,
  chainIdHex: "0x171",
  name: "PulseChain",
  rpcUrl: "https://rpc.pulsechain.com",
  blockExplorer: "https://scan.pulsechain.com",
};

export const KNOWN_ADDRESSES = {
  HEX: "0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39",
  WPLS: "0xA1077a294dDE1B09bB078844df40758a5D0f9a27",
  PULSEX_ROUTER: "0x165C3410fC91EF562C50559f7d2289fEbed552d9",
};

export function loadContracts() {
  const stored = localStorage.getItem("dtsc_contracts");
  if (stored) {
    try {
      return JSON.parse(stored);
    } catch {
      /* fall through */
    }
  }
  return {
    dtsc: "",
    vaultManager: "",
    stabilityPool: "",
    redemptionHandler: "",
    valuation: "",
    oracle: "",
  };
}

export function saveContracts(contracts) {
  localStorage.setItem("dtsc_contracts", JSON.stringify(contracts));
}