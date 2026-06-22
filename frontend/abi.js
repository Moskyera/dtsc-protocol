export const HEX_ABI = [
  "function stakeCount(address) view returns (uint256)",
  "function stakeLists(address,uint256) view returns (uint40 stakeId, uint72 stakedHearts, uint72 stakeShares, uint16 lockedDay, uint16 stakedDays, uint16 unlockedDay, bool isAutoStake)",
  "function globalInfo() view returns (uint256[13])",
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
];

export const DTSC_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function totalSupply() view returns (uint256)",
];

export const VAULT_ABI = [
  "function openVaultWithExistingStake(uint256 stakeIndex) returns (uint256)",
  "function openVaultWithNewStake(uint256 heartsAmount, uint256 stakedDays) returns (uint256)",
  "function mintDtsc(uint256 vaultId, uint256 amount)",
  "function repayDtsc(uint256 vaultId, uint256 amount)",
  "function closeVault(uint256 vaultId)",
  "function getOwnerVaults(address) view returns (uint256[])",
  "function getVault(uint256) view returns (tuple(address owner, uint8 mode, uint40 stakeId, uint256 stakeIndex, uint256 effectiveValueUsd, uint256 debtDtsc, uint256 minCollateralRatioBps, uint64 openedAt, uint64 cooldownEndsAt, bool active))",
  "function getVaultCollateralRatio(uint256) view returns (uint256)",
  "function nextVaultId() view returns (uint256)",
];

export const VALUATION_ABI = [
  "function calculateEffectiveValue(address,uint256) view returns (tuple(uint256 effectiveValueUsd, uint256 principalValueUsd, uint256 earnedRewardsUsd, uint256 longBonusUsd, uint256 timeDiscountUsd, uint8 tier, uint256 daysRemaining, uint256 minCollateralRatioBps))",
  "function maxBorrowable(address,uint256,bool) view returns (uint256, tuple(uint256 effectiveValueUsd, uint256 principalValueUsd, uint256 earnedRewardsUsd, uint256 longBonusUsd, uint256 timeDiscountUsd, uint8 tier, uint256 daysRemaining, uint256 minCollateralRatioBps))",
];

export const STABILITY_POOL_ABI = [
  "function deposit(uint256)",
  "function withdraw(uint256)",
  "function claimRewards() returns (uint256)",
  "function deposits(address) view returns (uint256)",
  "function claimableReward(address) view returns (uint256)",
  "function totalDeposits() view returns (uint256)",
];

export const ORACLE_ABI = [
  "function getPrice() view returns (uint256)",
  "function getTwapAndSpot() view returns (uint256, uint256)",
  "function update()",
];

export const REDEMPTION_ABI = [
  "function redeem(uint256,uint256)",
  "function previewRedemptionFee(uint256) view returns (uint256,uint256)",
];