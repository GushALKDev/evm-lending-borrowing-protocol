import { describe, expect, it } from 'vitest'
import { buildPriceUpdate } from './pyth'
import {
  RATE_SCALE,
  SECONDS_PER_YEAR,
  absorbPreview,
  accrue,
  borrowRate,
  health,
  maxCollateralWithdraw,
  maxDebtFor,
  mirroredPrice,
  mulDivUp,
  presentValue,
  quoteCollateral,
  storefrontDiscount,
  supplyRate,
  type Holding,
  type MarketState,
  type RateModel,
} from './market'
import { formatFixed, parseAmount, toInput } from './format'

// The reference curve from script/Deploy.s.sol.
const model: RateModel = {
  baseRate: 0n,
  slopeLow: 50_000_000_000_000_000n / SECONDS_PER_YEAR,
  slopeHigh: RATE_SCALE / SECONDS_PER_YEAR,
  kink: 800_000_000_000_000_000n,
  reserveFactor: 100_000_000_000_000_000n,
}

const weth = {
  decimals: 18,
  borrowCollateralFactor: 8_000n,
  liquidateCollateralFactor: 8_500n,
  liquidationFactor: 9_300n,
  storeFrontPriceFactor: 5_000n,
}

const usdcPrice = mirroredPrice(100_000_000n, 8, 5n) // $1, 5 bps
const ethPrice = mirroredPrice(400_000_000_000n, 8, 5n) // $4,000, 5 bps

describe('rate model', () => {
  it('borrows at about 4% APR at the 80% kink', () => {
    const apr = borrowRate(model, model.kink) * SECONDS_PER_YEAR
    expect(Number(apr) / 1e18).toBeCloseTo(0.04, 6)
  })

  it('rounds the borrow rate up and the supply rate down, so supply never exceeds U * borrow', () => {
    for (const u of [0n, 1n, 123_456_789n, model.kink, RATE_SCALE, RATE_SCALE + 1n]) {
      const b = borrowRate(model, u)
      const s = supplyRate(model, u)
      expect(s * RATE_SCALE <= b * u).toBe(true)
    }
  })
})

describe('accrual projection', () => {
  const state: MarketState = {
    supplyIndex: 10n ** 15n,
    borrowIndex: 10n ** 15n,
    lastAccrualTime: 1_000n,
    pauseFlags: 0,
    totalSupplyBase: 2_000_000_000_000n,
    totalBorrowBase: 1_000_000_000_000n,
  }

  it('grows the borrow index faster than the supply index', () => {
    const next = accrue(state, model, 1_000n + SECONDS_PER_YEAR)
    expect(next.borrowIndex > next.supplyIndex).toBe(true)
    expect(next.supplyIndex > state.supplyIndex).toBe(true)
  })

  it('does nothing when no time has passed', () => {
    expect(accrue(state, model, 1_000n)).toBe(state)
  })

  it('rounds a debt up and a supply down', () => {
    const s = { ...state, supplyIndex: 1_000_000_000_000_001n, borrowIndex: 1_000_000_000_000_001n }
    expect(presentValue(1_000_000n, s)).toBe(1_000_000n)
    expect(presentValue(-1_000_000n, s)).toBe(-1_000_001n)
  })
})

describe('health', () => {
  const holdings: Holding[] = [{ params: weth, balance: 10n ** 18n, price: ethPrice }]

  it('values collateral at the low edge for capacity and the high edge for absorb', () => {
    const h = health(3_000_000_000n, usdcPrice, 10n ** 6n, holdings)
    // 1 WETH at 4,000 * (1 - 0.0005) * 80% = 3,198.40
    expect(h.borrowCapacity).toBe(3_198_400_000_000_000_000_000n)
    // 1 WETH at 4,000 * (1 + 0.0005) * 85% = 3,401.70
    expect(h.liquidationCapacity).toBe(3_401_700_000_000_000_000_000n)
    // 3,000 USDC at 1.0005
    expect(h.debtUSD).toBe(3_001_500_000_000_000_000_000n)
    expect(h.isBorrowCollateralized).toBe(true)
    expect(h.isLiquidatable).toBe(false)
  })

  it('caps the debt so the account stays within capacity', () => {
    const h = health(0n, usdcPrice, 10n ** 6n, holdings)
    const max = maxDebtFor(h.borrowCapacity, usdcPrice, 10n ** 6n)
    expect(health(max, usdcPrice, 10n ** 6n, holdings).isBorrowCollateralized).toBe(true)
    expect(health(max + 1n, usdcPrice, 10n ** 6n, holdings).isBorrowCollateralized).toBe(false)
  })

  it('lets an indebted account remove collateral only down to its capacity', () => {
    const h = health(1_000_000_000n, usdcPrice, 10n ** 6n, holdings)
    const max = maxCollateralWithdraw(holdings[0], holdings, h.debtUSD, 0n)
    const left: Holding[] = [{ ...holdings[0], balance: holdings[0].balance - max }]
    expect(health(1_000_000_000n, usdcPrice, 10n ** 6n, left).isBorrowCollateralized).toBe(true)
    const tooMuch: Holding[] = [{ ...holdings[0], balance: holdings[0].balance - max - 10n ** 12n }]
    expect(health(1_000_000_000n, usdcPrice, 10n ** 6n, tooMuch).isBorrowCollateralized).toBe(false)
  })
})

describe('absorb and storefront', () => {
  it('credits 93% of the mid value against the debt', () => {
    const p = absorbPreview(3_500_000_000n, usdcPrice, 10n ** 6n, [{ params: weth, balance: 10n ** 18n, price: ethPrice }])
    expect(p.seizedUSD).toBe(4_000n * 10n ** 18n)
    expect(p.creditBase).toBe(3_720_000_000n)
    expect(p.surplus).toBe(220_000_000n)
    expect(p.badDebt).toBe(0n)
  })

  it('sells at 3.5% below the oracle price', () => {
    expect(storefrontDiscount(weth)).toBe(350n)
    const quote = quoteCollateral(weth, ethPrice, usdcPrice, 10n ** 6n, 3_860_000_000n)
    // 3,860 / (4,000 * 0.965) = 1 WETH
    expect(quote).toBe(10n ** 18n)
  })

  it('mulDivUp matches ceil', () => {
    expect(mulDivUp(7n, 1n, 2n)).toBe(4n)
    expect(mulDivUp(0n, 5n, 3n)).toBe(0n)
  })
})

describe('price update', () => {
  it('encodes one MockPyth-style entry per feed', () => {
    const update = buildPriceUpdate(
      [{ pythFeedId: `0x${'11'.repeat(32)}`, answer: 400_000_000_000n, decimals: 8 }],
      5n,
      1_800_000_000n,
    )
    expect(update).toHaveLength(1)
    // bytes32 id + two 4-word Price structs = 9 words
    expect((update[0].length - 2) / 64).toBe(9)
  })
})

describe('formatting', () => {
  it('truncates instead of rounding up', () => {
    expect(formatFixed(1_999_999n, 6, 2)).toBe('1.99')
    expect(formatFixed(-1_234_567_890n, 6, 2)).toBe('-1,234.56')
  })

  it('parses and prints amounts', () => {
    expect(parseAmount('1,000.5', 6)).toBe(1_000_500_000n)
    expect(parseAmount('1.1234567', 6)).toBeNull()
    expect(toInput(1_000_500_000n, 6)).toBe('1000.5')
  })
})
