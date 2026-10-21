import type { CollateralInfo, Deployment } from '../config/deployment'
import type { AccountData, LiveData, StaticData } from '../hooks/useMarketData'
import {
  accrue,
  borrowRate,
  health,
  mirroredPrice,
  perSecondToAnnual,
  presentValue,
  reserves,
  supplyRate,
  totalBorrow,
  totalSupply,
  utilization,
  type Health,
  type Holding,
  type MarketState,
  type Price,
} from './market'

export interface CollateralView {
  info: CollateralInfo
  price: Price
  /** Chainlink round time, and whether the oracle would still accept it as an anchor */
  updatedAt: bigint
  anchorFresh: boolean
  totalPosted: bigint
  inventory: bigint
}

export interface AccountView {
  principal: bigint
  /** Signed present value at the projected index: positive supplies, negative borrows */
  balance: bigint
  supplied: bigint
  /**
   * Supplied balance at the latest block's timestamp. Never above what the account holds when its next
   * call runs, so it is the safe figure for a full withdrawal; the wall-clock projection can run ahead.
   */
  suppliedAtChain: bigint
  borrowed: bigint
  holdings: Holding[]
  collateral: bigint[]
  health: Health
  data: AccountData
}

export interface MarketModel {
  deployment: Deployment
  static: StaticData
  /** Market state with both indexes projected to `now` */
  state: MarketState
  now: bigint
  cash: bigint
  totalSupply: bigint
  totalBorrow: bigint
  reserves: bigint
  utilization: bigint
  supplyApr: bigint
  borrowApr: bigint
  basePrice: Price
  baseAnchorFresh: boolean
  collaterals: CollateralView[]
  account: AccountView | null
}

export function buildModel(
  d: Deployment,
  st: StaticData,
  live: LiveData,
  account: AccountData | undefined,
  now: bigint,
  chainTime: bigint,
): MarketModel {
  const state = accrue(live.state, st.rateModel, now)
  const chainState = accrue(live.state, st.rateModel, chainTime)
  const u = utilization(state)
  const priceOf = (i: number) => mirroredPrice(live.rounds[i].answer, st.feedDecimals[i], d.demoConfBps)
  const fresh = (i: number, heartbeat: number) => live.rounds[i].updatedAt + BigInt(heartbeat) >= now

  const basePrice = priceOf(0)
  const collaterals: CollateralView[] = d.collaterals.map((info, i) => ({
    info,
    price: priceOf(i + 1),
    updatedAt: live.rounds[i + 1].updatedAt,
    anchorFresh: fresh(i + 1, info.anchorHeartbeat),
    totalPosted: live.totalsCollateral[i],
    inventory: live.inventory[i],
  }))

  let accountView: AccountView | null = null
  if (account) accountView = buildAccount(account, state, st, basePrice, collaterals, chainState)

  return {
    deployment: d,
    static: st,
    state,
    now,
    cash: live.cash,
    totalSupply: totalSupply(state),
    totalBorrow: totalBorrow(state),
    reserves: reserves(live.cash, state),
    utilization: u,
    supplyApr: perSecondToAnnual(supplyRate(st.rateModel, u)),
    borrowApr: perSecondToAnnual(borrowRate(st.rateModel, u)),
    basePrice,
    baseAnchorFresh: fresh(0, d.base.anchorHeartbeat),
    collaterals,
    account: accountView,
  }
}

export function buildAccount(
  data: Pick<AccountData, 'principal' | 'collateral'> & Partial<AccountData>,
  state: MarketState,
  st: StaticData,
  basePrice: Price,
  collaterals: CollateralView[],
  chainState: MarketState = state,
): AccountView {
  const balance = presentValue(data.principal, state)
  const atChain = presentValue(data.principal, chainState)
  const borrowed = balance < 0n ? -balance : 0n
  const holdings: Holding[] = collaterals
    .map((c, i) => ({ params: c.info.params, balance: data.collateral[i], price: c.price }))
    .filter((h) => h.balance > 0n)
  return {
    principal: data.principal,
    balance,
    supplied: balance > 0n ? balance : 0n,
    suppliedAtChain: atChain > 0n ? atChain : 0n,
    borrowed,
    holdings,
    collateral: data.collateral,
    health: health(borrowed, basePrice, st.baseScale, holdings),
    data: data as AccountData,
  }
}
