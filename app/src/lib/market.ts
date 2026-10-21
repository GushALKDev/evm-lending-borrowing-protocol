// Market math, mirrored from the contracts so the app can preview what a call will do before sending
// it. Every function keeps the contract's rounding direction (Guide 2, Section 10): what an account
// holds rounds down, what it owes rounds up. All values are bigint at the contract's own scales.

export const BASE_INDEX_SCALE = 10n ** 15n
export const RATE_SCALE = 10n ** 18n
export const FACTOR_SCALE = 10_000n
export const SECONDS_PER_YEAR = 31_536_000n

export const PAUSE = {
  SUPPLY: 1 << 0,
  TRANSFER: 1 << 1,
  WITHDRAW: 1 << 2,
  ABSORB: 1 << 3,
  BUY: 1 << 4,
  BORROW: 1 << 5,
} as const

/** floor(a * b / d) for non-negative operands, like Solady's fullMulDiv. */
export function mulDiv(a: bigint, b: bigint, d: bigint): bigint {
  return (a * b) / d
}

/** ceil(a * b / d) for non-negative operands, like Solady's fullMulDivUp. */
export function mulDivUp(a: bigint, b: bigint, d: bigint): bigint {
  const p = a * b
  return p === 0n ? 0n : (p - 1n) / d + 1n
}

/* ------------------------------------------------------------------ */
/* Interest rate model                                                 */
/* ------------------------------------------------------------------ */

export interface RateModel {
  baseRate: bigint
  slopeLow: bigint
  slopeHigh: bigint
  kink: bigint
  reserveFactor: bigint
}

/** InterestRateModel.getBorrowRate: per-second rate at 1e18 scale. */
export function borrowRate(m: RateModel, utilization: bigint): bigint {
  if (utilization <= m.kink) return m.baseRate + mulDivUp(m.slopeLow, utilization, RATE_SCALE)
  const rateAtKink = m.baseRate + mulDivUp(m.slopeLow, m.kink, RATE_SCALE)
  return rateAtKink + mulDivUp(m.slopeHigh, utilization - m.kink, RATE_SCALE)
}

/** InterestRateModel.getSupplyRate: derived as borrowRate * U * (1 - RF), both steps floored. */
export function supplyRate(m: RateModel, utilization: bigint): bigint {
  const toSuppliers = mulDiv(borrowRate(m, utilization), utilization, RATE_SCALE)
  return mulDiv(toSuppliers, RATE_SCALE - m.reserveFactor, RATE_SCALE)
}

/** Annual rate at 1e18 scale (APR, no compounding), from a per-second rate. */
export function perSecondToAnnual(rate: bigint): bigint {
  return rate * SECONDS_PER_YEAR
}

/* ------------------------------------------------------------------ */
/* Indexes and balances                                                */
/* ------------------------------------------------------------------ */

export interface MarketState {
  supplyIndex: bigint
  borrowIndex: bigint
  lastAccrualTime: bigint
  pauseFlags: number
  totalSupplyBase: bigint
  totalBorrowBase: bigint
}

export const pvSupply = (principal: bigint, s: MarketState) => mulDiv(principal, s.supplyIndex, BASE_INDEX_SCALE)
export const pvBorrow = (principal: bigint, s: MarketState) => mulDivUp(principal, s.borrowIndex, BASE_INDEX_SCALE)

export function totalSupply(s: MarketState): bigint {
  return pvSupply(s.totalSupplyBase, s)
}

export function totalBorrow(s: MarketState): bigint {
  return pvBorrow(s.totalBorrowBase, s)
}

/** LendingMarket.getUtilization: floored, may exceed 1e18 after reserves are paid out. */
export function utilization(s: MarketState): bigint {
  const supplied = totalSupply(s)
  if (supplied === 0n) return 0n
  return mulDiv(totalBorrow(s), RATE_SCALE, supplied)
}

/**
 * LendingMarket._accrue projected to `now`. The market's views read the stored indexes, which only
 * move when someone transacts; projecting them shows balances as the next transaction will see them.
 */
export function accrue(s: MarketState, m: RateModel, now: bigint): MarketState {
  if (now <= s.lastAccrualTime) return s
  const elapsed = now - s.lastAccrualTime
  const u = utilization(s)
  const sr = supplyRate(m, u)
  const br = borrowRate(m, u)
  return {
    ...s,
    supplyIndex: s.supplyIndex + mulDiv(s.supplyIndex, sr * elapsed, RATE_SCALE),
    borrowIndex: s.borrowIndex + mulDivUp(s.borrowIndex, br * elapsed, RATE_SCALE),
    lastAccrualTime: now,
  }
}

/** Signed present value of a signed principal: positive supplies, negative borrows. */
export function presentValue(principal: bigint, s: MarketState): bigint {
  return principal >= 0n ? pvSupply(principal, s) : -pvBorrow(-principal, s)
}

/** LendingMarket.getReserves: cash + borrows - supply, signed. */
export function reserves(cash: bigint, s: MarketState): bigint {
  return cash + totalBorrow(s) - totalSupply(s)
}

/* ------------------------------------------------------------------ */
/* Prices                                                              */
/* ------------------------------------------------------------------ */

/** Mid price and confidence half width at 1e18 scale, as PythChainlinkOracle returns them. */
export interface Price {
  price: bigint
  conf: bigint
}

/**
 * The price the oracle will validate after the app pushes a Chainlink answer into DemoPyth: the
 * mantissa is the answer at the feed's decimals, the confidence is `confBps` of it, floored, and the
 * oracle scales both to 1e18.
 */
export function mirroredPrice(answer: bigint, feedDecimals: number, confBps: bigint): Price {
  const scale = 10n ** BigInt(18 - feedDecimals)
  return { price: answer * scale, conf: ((answer * confBps) / FACTOR_SCALE) * scale }
}

export function scalePrice(p: Price, factor: number): Price {
  // factor as basis points to stay in bigint
  const bps = BigInt(Math.round(factor * 10_000))
  return { price: (p.price * bps) / FACTOR_SCALE, conf: (p.conf * bps) / FACTOR_SCALE }
}

/* ------------------------------------------------------------------ */
/* Account health                                                      */
/* ------------------------------------------------------------------ */

export interface CollateralParams {
  decimals: number
  borrowCollateralFactor: bigint
  liquidateCollateralFactor: bigint
  liquidationFactor: bigint
  storeFrontPriceFactor: bigint
}

export interface Holding {
  params: CollateralParams
  balance: bigint
  price: Price
}

/** LendingMarket._debtUSD: debt at the high edge of the base price band, rounded up. */
export function debtUSD(borrowPV: bigint, base: Price, baseScale: bigint): bigint {
  return mulDivUp(borrowPV, base.price + base.conf, baseScale)
}

function collateralTerm(h: Holding, factor: bigint, edge: bigint): bigint {
  return mulDiv(h.balance * factor, edge, 10n ** BigInt(h.params.decimals) * FACTOR_SCALE)
}

/** LendingMarket._borrowCapacity: collateral at price - conf times borrowCF, each term floored. */
export function borrowCapacity(holdings: Holding[]): bigint {
  return holdings.reduce(
    (sum, h) => sum + collateralTerm(h, h.params.borrowCollateralFactor, h.price.price - h.price.conf),
    0n,
  )
}

/** LendingMarket._liquidationCapacity: collateral at price + conf times liquidateCF. */
export function liquidationCapacity(holdings: Holding[]): bigint {
  return holdings.reduce(
    (sum, h) => sum + collateralTerm(h, h.params.liquidateCollateralFactor, h.price.price + h.price.conf),
    0n,
  )
}

export interface Health {
  debtUSD: bigint
  borrowCapacity: bigint
  liquidationCapacity: bigint
  /** debt / borrowCapacity at 1e18, null when there is no capacity */
  capacityUsed: bigint | null
  /** liquidationCapacity / borrowCapacity at 1e18: where on the capacity scale absorb starts */
  liquidationPoint: bigint | null
  isBorrowCollateralized: boolean
  isLiquidatable: boolean
  /** Fraction (1e18) all collateral prices can fall before the account becomes absorbable */
  dropToLiquidation: bigint | null
}

export function health(borrowPV: bigint, base: Price, baseScale: bigint, holdings: Holding[]): Health {
  const debt = debtUSD(borrowPV, base, baseScale)
  const cap = borrowCapacity(holdings)
  const liq = liquidationCapacity(holdings)
  return {
    debtUSD: debt,
    borrowCapacity: cap,
    liquidationCapacity: liq,
    capacityUsed: cap > 0n ? mulDiv(debt, RATE_SCALE, cap) : null,
    liquidationPoint: cap > 0n ? mulDiv(liq, RATE_SCALE, cap) : null,
    isBorrowCollateralized: debt <= cap,
    isLiquidatable: debt > liq,
    dropToLiquidation: debt > 0n && liq > 0n ? (debt >= liq ? 0n : RATE_SCALE - mulDivUp(debt, RATE_SCALE, liq)) : null,
  }
}

/** Largest total debt (base units) the capacity supports at the high edge of the base price. */
export function maxDebtFor(capacityUSD: bigint, base: Price, baseScale: bigint): bigint {
  return mulDiv(capacityUSD, baseScale, base.price + base.conf)
}

/**
 * Largest amount of one collateral an indebted account can remove while staying within capacity,
 * keeping `bufferBps` of the debt as margin for interest and price moves before the call lands.
 */
export function maxCollateralWithdraw(
  target: Holding,
  holdings: Holding[],
  debt: bigint,
  bufferBps: bigint,
): bigint {
  if (debt === 0n) return target.balance
  const need = mulDivUp(debt, FACTOR_SCALE + bufferBps, FACTOR_SCALE)
  const others = borrowCapacity(holdings.filter((h) => h !== target))
  if (others >= need) return target.balance
  const missing = need - others
  const edge = target.price.price - target.price.conf
  const keep = mulDivUp(missing, 10n ** BigInt(target.params.decimals) * FACTOR_SCALE, target.params.borrowCollateralFactor * edge)
  return keep >= target.balance ? 0n : target.balance - keep
}

/* ------------------------------------------------------------------ */
/* Absorb and the storefront                                           */
/* ------------------------------------------------------------------ */

export interface AbsorbPreview {
  seizedUSD: bigint
  creditUSD: bigint
  creditBase: bigint
  debtBase: bigint
  badDebt: bigint
  surplus: bigint
}

/** LendingMarket.absorb settlement: collateral credited at liquidationFactor of its mid value. */
export function absorbPreview(debtPV: bigint, base: Price, baseScale: bigint, holdings: Holding[]): AbsorbPreview {
  let seizedUSD = 0n
  let creditUSD = 0n
  for (const h of holdings) {
    const scale = 10n ** BigInt(h.params.decimals)
    seizedUSD += mulDiv(h.balance, h.price.price, scale)
    creditUSD += mulDiv(h.balance * h.params.liquidationFactor, h.price.price, scale * FACTOR_SCALE)
  }
  const creditBase = mulDiv(creditUSD, baseScale, base.price)
  return {
    seizedUSD,
    creditUSD,
    creditBase,
    debtBase: debtPV,
    badDebt: creditBase < debtPV ? debtPV - creditBase : 0n,
    surplus: creditBase > debtPV ? creditBase - debtPV : 0n,
  }
}

/** Storefront discount in basis points: storeFrontPriceFactor * (1 - liquidationFactor), floored. */
export function storefrontDiscount(p: CollateralParams): bigint {
  return mulDiv(p.storeFrontPriceFactor, FACTOR_SCALE - p.liquidationFactor, FACTOR_SCALE)
}

/** LendingMarket.quoteCollateral: collateral out for a base amount in, at the discounted ask. */
export function quoteCollateral(p: CollateralParams, asset: Price, base: Price, baseScale: bigint, baseAmount: bigint): bigint {
  const ask = mulDivUp(asset.price, FACTOR_SCALE - storefrontDiscount(p), FACTOR_SCALE)
  return mulDiv(baseAmount * base.price, 10n ** BigInt(p.decimals), baseScale * ask)
}
