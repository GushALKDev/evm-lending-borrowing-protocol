import type { Address, Hex } from 'viem'
import type { CollateralParams } from '../lib/market'

// Deployment files are written by script/testnet/DeployTestnet.s.sol, one per chain id.
interface RawToken {
  address: Address
  chainlinkFeed: Address
  pythFeedId: Hex
  anchorHeartbeat: number
}

interface RawCollateral extends RawToken {
  borrowCollateralFactor: number
  liquidateCollateralFactor: number
  liquidationFactor: number
  storeFrontPriceFactor: number
  supplyCap: string
  decimals: number
}

interface RawDeployment {
  chainId: number
  deployBlock: number
  market: Address
  rateModel: Address
  oracle: Address
  pyth: Address
  faucet: Address
  demoConfBps: number
  USDC: RawToken
  WETH: RawCollateral
  WBTC: RawCollateral
}

export type AssetSymbol = 'USDC' | 'WETH' | 'WBTC'

export interface TokenInfo {
  symbol: AssetSymbol
  name: string
  address: Address
  decimals: number
  chainlinkFeed: Address
  pythFeedId: Hex
  anchorHeartbeat: number
  /** Decimals shown for amounts of this token in the interface */
  shown: number
}

export interface CollateralInfo extends TokenInfo {
  params: CollateralParams
  supplyCap: bigint
}

export interface Deployment {
  chainId: number
  deployBlock: bigint
  market: Address
  rateModel: Address
  oracle: Address
  pyth: Address
  faucet: Address
  demoConfBps: bigint
  base: TokenInfo
  collaterals: CollateralInfo[]
}

const files = import.meta.glob<RawDeployment>('./deployments/*.json', { eager: true, import: 'default' })

function collateral(symbol: AssetSymbol, name: string, raw: RawCollateral, shown: number): CollateralInfo {
  return {
    symbol,
    name,
    address: raw.address,
    decimals: raw.decimals,
    chainlinkFeed: raw.chainlinkFeed,
    pythFeedId: raw.pythFeedId,
    anchorHeartbeat: raw.anchorHeartbeat,
    shown,
    supplyCap: BigInt(raw.supplyCap),
    params: {
      decimals: raw.decimals,
      borrowCollateralFactor: BigInt(raw.borrowCollateralFactor),
      liquidateCollateralFactor: BigInt(raw.liquidateCollateralFactor),
      liquidationFactor: BigInt(raw.liquidationFactor),
      storeFrontPriceFactor: BigInt(raw.storeFrontPriceFactor),
    },
  }
}

export function loadDeployment(chainId: number): Deployment | null {
  const raw = files[`./deployments/${chainId}.json`]
  if (!raw) return null
  return {
    chainId: raw.chainId,
    deployBlock: BigInt(raw.deployBlock),
    market: raw.market,
    rateModel: raw.rateModel,
    oracle: raw.oracle,
    pyth: raw.pyth,
    faucet: raw.faucet,
    demoConfBps: BigInt(raw.demoConfBps),
    base: {
      symbol: 'USDC',
      name: 'USD Coin',
      address: raw.USDC.address,
      decimals: 6,
      chainlinkFeed: raw.USDC.chainlinkFeed,
      pythFeedId: raw.USDC.pythFeedId,
      anchorHeartbeat: raw.USDC.anchorHeartbeat,
      shown: 2,
    },
    // Order matches the market's assetsIn bit offsets: WETH is 0, wBTC is 1.
    collaterals: [collateral('WETH', 'Wrapped Ether', raw.WETH, 4), collateral('WBTC', 'Wrapped BTC', raw.WBTC, 6)],
  }
}
