// Checks the app's math against the deployed contracts on a local anvil chain, to the wei.
// Run after ./scripts/local-chain.sh:  LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts/parity.test.ts
// The suite moves the chain forward and reverts it to a snapshot at the end, so it can run again.
import { readFileSync } from 'node:fs'
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  parseEventLogs,
  type Abi,
  type Address,
  type Hex,
} from 'viem'
import { foundry } from 'viem/chains'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { demoPythAbi, faucetAbi, lendingMarketAbi, oracleAbi, rateModelAbi } from '../src/abi'
import { marketAbi, tokenAbi } from '../src/lib/abi'
import {
  absorbPreview,
  accrue,
  borrowCapacity,
  borrowRate,
  debtUSD,
  liquidationCapacity,
  mirroredPrice,
  presentValue,
  principalValue,
  quoteCollateral,
  reserves,
  settle,
  supplyRate,
  utilization,
  type CollateralParams,
  type Holding,
  type MarketState,
  type Price,
  type RateModel,
} from '../src/lib/market'
import { buildPriceUpdate } from '../src/lib/pyth'

const rpc = process.env.LOCAL_RPC
const deployer = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address
// anvil's default accounts 1 and 3, unlocked on a local node
const alice = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address
const bob = '0x90F79bf6EB2c4f870365E785982E1f101E93b906' as Address

const mockFeedAbi = parseAbi([
  'function setAnswer(int256 answer, uint256 updatedAt)',
  'function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)',
])

interface Token {
  address: Address
  chainlinkFeed: Address
  pythFeedId: Hex
}
type Collateral = Token & CollateralParams
interface LocalDeployment {
  market: Address
  rateModel: Address
  oracle: Address
  pyth: Address
  faucet: Address
  demoConfBps: number
  USDC: Token
  WETH: Collateral
  WBTC: Collateral
}

describe.skipIf(!rpc)('parity with the contracts on a local chain', () => {
  // Read lazily: the local deployment file is not committed, and a skipped suite still gets collected.
  let d: LocalDeployment
  let collaterals: Collateral[]
  let snapshot: Hex
  const pub = createPublicClient({ chain: foundry, transport: http(rpc) })
  const wallet = createWalletClient({ chain: foundry, transport: http(rpc), account: deployer })
  const baseScale = 10n ** 6n
  const feedDecimals = 8

  beforeAll(async () => {
    const raw = JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8'))
    const params = (c: Record<string, unknown>): Collateral => ({
      ...(c as unknown as Token),
      decimals: Number(c.decimals),
      borrowCollateralFactor: BigInt(c.borrowCollateralFactor as number),
      liquidateCollateralFactor: BigInt(c.liquidateCollateralFactor as number),
      liquidationFactor: BigInt(c.liquidationFactor as number),
      storeFrontPriceFactor: BigInt(c.storeFrontPriceFactor as number),
    })
    d = { ...raw, WETH: params(raw.WETH), WBTC: params(raw.WBTC) }
    collaterals = [d.WETH, d.WBTC]
    snapshot = await pub.request({ method: 'evm_snapshot' as never })
  })

  afterAll(async () => {
    if (snapshot) await pub.request({ method: 'evm_revert' as never, params: [snapshot] as never })
  })

  async function readState(blockNumber?: bigint): Promise<MarketState> {
    const s = await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'getMarketState', blockNumber })
    return {
      supplyIndex: BigInt(s.baseSupplyIndex),
      borrowIndex: BigInt(s.baseBorrowIndex),
      lastAccrualTime: BigInt(s.lastAccrualTime),
      pauseFlags: Number(s.pauseFlags),
      totalSupplyBase: BigInt(s.totalSupplyBase),
      totalBorrowBase: BigInt(s.totalBorrowBase),
    }
  }

  async function readModel(): Promise<RateModel> {
    const get = (functionName: 'BASE_RATE' | 'SLOPE_LOW' | 'SLOPE_HIGH' | 'KINK' | 'RESERVE_FACTOR') =>
      pub.readContract({ address: d.rateModel, abi: rateModelAbi, functionName })
    const [baseRate, slopeLow, slopeHigh, kink, reserveFactor] = await Promise.all(
      (['BASE_RATE', 'SLOPE_LOW', 'SLOPE_HIGH', 'KINK', 'RESERVE_FACTOR'] as const).map(get),
    )
    return { baseRate, slopeLow, slopeHigh, kink, reserveFactor }
  }

  /** Sends a call from an unlocked account at a pinned timestamp and returns its receipt. */
  async function send(from: Address, address: Address, abi: Abi | readonly unknown[], functionName: string, args: readonly unknown[], at?: bigint, value?: bigint) {
    if (at !== undefined) await pub.request({ method: 'evm_setNextBlockTimestamp' as never, params: [Number(at)] as never })
    // Fixed gas: an estimate made at the previous block's timestamp can miss the accrual the call pays for.
    const hash = await wallet.writeContract({ account: from, address, abi: abi as Abi, functionName, args, value, gas: 3_000_000n } as never)
    const receipt = await pub.waitForTransactionReceipt({ hash })
    expect(receipt.status, `${functionName} from ${from}`).toBe('success')
    return receipt
  }

  const latestTime = async () => (await pub.getBlock()).timestamp
  const principalOf = async (account: Address, blockNumber?: bigint) =>
    BigInt(await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'getPrincipal', args: [account], blockNumber }))
  const signedBalance = async (account: Address, blockNumber?: bigint) => {
    const read = (functionName: 'balanceOf' | 'borrowBalanceOf') =>
      pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName, args: [account], blockNumber })
    return (await read('balanceOf')) - (await read('borrowBalanceOf'))
  }

  /** Sets every mock Chainlink feed, keeping the answer unless a new one is given, as fresh as the chain. */
  async function setFeeds(answers: Partial<Record<'USDC' | 'WETH' | 'WBTC', bigint>> = {}) {
    const now = await latestTime()
    for (const key of ['USDC', 'WETH', 'WBTC'] as const) {
      const feed = d[key].chainlinkFeed
      const [, current] = await pub.readContract({ address: feed, abi: mockFeedAbi, functionName: 'latestRoundData' })
      await send(deployer, feed, mockFeedAbi, 'setAnswer', [answers[key] ?? current, now])
    }
  }

  /** The update the app would send at `publishTime`, and the prices the app expects the oracle to return. */
  async function appPrices(publishTime: bigint): Promise<{ update: Hex[]; base: Price; prices: Price[] }> {
    const feeds = [d.USDC, d.WETH, d.WBTC]
    const answers = await Promise.all(
      feeds.map(async (f) => (await pub.readContract({ address: f.chainlinkFeed, abi: mockFeedAbi, functionName: 'latestRoundData' }))[1]),
    )
    const confBps = BigInt(d.demoConfBps)
    const update = buildPriceUpdate(
      feeds.map((f, i) => ({ pythFeedId: f.pythFeedId, answer: answers[i], decimals: feedDecimals })),
      confBps,
      publishTime,
    )
    const prices = answers.map((a) => mirroredPrice(a, feedDecimals, confBps))
    return { update, base: prices[0], prices: prices.slice(1) }
  }

  async function holdingsOf(account: Address, prices: Price[], blockNumber?: bigint): Promise<Holding[]> {
    const balances = await Promise.all(
      collaterals.map((c) => pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'userCollateral', args: [account, c.address], blockNumber })),
    )
    return collaterals.map((c, i) => ({ params: c, balance: BigInt(balances[i]), price: prices[i] })).filter((h) => h.balance > 0n)
  }

  /** Simulates a market call at a mined block and returns the decoded custom error it reverts with. */
  async function revertOf(from: Address, functionName: string, args: readonly unknown[], blockNumber: bigint) {
    try {
      await pub.simulateContract({ account: from, address: d.market, abi: marketAbi, functionName, args, value: 100n, blockNumber } as never)
    } catch (err) {
      const reverted = err instanceof BaseError ? (err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null) : null
      if (reverted?.data) return { name: reverted.data.errorName, args: reverted.data.args as readonly unknown[] }
      throw err
    }
    throw new Error(`${functionName} did not revert`)
  }

  /** Gives an account testnet tokens and posts its collateral. */
  async function fund(account: Address, usdc: bigint, weth: bigint, wbtc: bigint) {
    for (const [token, amount] of [[d.USDC.address, usdc], [d.WETH.address, weth], [d.WBTC.address, wbtc]] as const) {
      if (amount === 0n) continue
      await send(deployer, d.faucet, faucetAbi, 'mint', [token, account, amount])
      await send(account, token, tokenAbi, 'approve', [d.market, 2n ** 255n])
    }
    if (weth > 0n) await send(account, d.market, lendingMarketAbi, 'supply', [d.WETH.address, weth])
    if (wbtc > 0n) await send(account, d.market, lendingMarketAbi, 'supply', [d.WBTC.address, wbtc])
  }

  /**
   * Runs one base call at a pinned timestamp and checks the principal it leaves against the app's
   * settle(), projected with the app's own accrue() to that timestamp.
   */
  async function expectSettle(account: Address, functionName: 'supply' | 'withdraw', amount: bigint, withPrices: boolean) {
    const m = await readModel()
    const before = await readState()
    const p0 = await principalOf(account)
    const at = (await latestTime()) + 7n
    const args = functionName === 'supply' ? [d.USDC.address, amount] : [d.USDC.address, amount, withPrices ? (await appPrices(at)).update : []]
    const receipt = await send(account, d.market, lendingMarketAbi, functionName, args, at, withPrices ? 100n : undefined)
    const projected = accrue(before, m, at)
    const after = await readState(receipt.blockNumber)
    expect(after.supplyIndex).toBe(projected.supplyIndex)
    expect(after.borrowIndex).toBe(projected.borrowIndex)
    const delta = functionName === 'supply' ? amount : -amount
    const expected = principalValue(presentValue(p0, projected) + delta, projected)
    expect(await principalOf(account, receipt.blockNumber)).toBe(expected)
    expect(await signedBalance(account, receipt.blockNumber)).toBe(settle(p0, delta, projected))
  }

  it('matches the rate model and utilization exactly', async () => {
    const m = await readModel()
    const s = await readState()
    const u = utilization(s)
    expect(u).toBe(await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'getUtilization' }))
    for (const x of [0n, u, m.kink, 10n ** 18n, 10n ** 18n + 7n]) {
      expect(borrowRate(m, x)).toBe(await pub.readContract({ address: d.rateModel, abi: rateModelAbi, functionName: 'getBorrowRate', args: [x] }))
      expect(supplyRate(m, x)).toBe(await pub.readContract({ address: d.rateModel, abi: rateModelAbi, functionName: 'getSupplyRate', args: [x] }))
    }
  })

  it('projects both indexes to what accrue() writes', async () => {
    const m = await readModel()
    const before = await readState()
    // Let an hour pass so the projection covers a real window.
    await pub.request({ method: 'evm_increaseTime' as never, params: [3600] as never })
    // Fixed gas: estimated at the previous block's timestamp, accrue() looks like a no-op and the
    // estimate is too low for the real call, which writes both indexes (the app adds a margin too).
    const hash = await wallet.writeContract({ address: d.market, abi: lendingMarketAbi, functionName: 'accrue', gas: 200_000n })
    const receipt = await pub.waitForTransactionReceipt({ hash })
    expect(receipt.status).toBe('success')
    const block = await pub.getBlock({ blockNumber: receipt.blockNumber })
    const after = await readState()
    const projected = accrue(before, m, block.timestamp)
    expect(projected.supplyIndex).toBe(after.supplyIndex)
    expect(projected.borrowIndex).toBe(after.borrowIndex)
  })

  it('matches balanceOf and borrowBalanceOf at the stored index', async () => {
    const s = await readState()
    for (const account of [deployer, d.faucet as Address, '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address]) {
      const principal = await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'getPrincipal', args: [account] })
      const pv = presentValue(BigInt(principal), s)
      const supplied = await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'balanceOf', args: [account] })
      const borrowed = await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'borrowBalanceOf', args: [account] })
      expect(pv).toBe(supplied - borrowed)
    }
  })

  it('reads every price the way the app mirrors it, and quotes the storefront to the wei', async () => {
    // Prices with digits below the confidence floor, so the floor in both mirrors is exercised.
    await setFeeds({ USDC: 99_983_438n, WETH: 250_384_000_013n, WBTC: 8_468_753_650_563n })
    const at = (await latestTime()) + 3n
    const { update, base, prices } = await appPrices(at)
    const fee = await pub.readContract({ address: d.pyth, abi: demoPythAbi, functionName: 'getUpdateFee', args: [update] })
    const { blockNumber } = await send(deployer, d.pyth, demoPythAbi, 'updatePriceFeeds', [update], at, fee)

    for (const [token, expected] of [[d.USDC, base], [d.WETH, prices[0]], [d.WBTC, prices[1]]] as const) {
      const [price, conf] = await pub.readContract({ address: d.oracle, abi: oracleAbi, functionName: 'getPrice', args: [token.address], blockNumber })
      expect({ price, conf }).toEqual(expected)
    }
    for (const [i, c] of collaterals.entries()) {
      for (const amount of [1n, 999_999n, 1_000_000n, 3_860_000_000n, 123_456_789_012n]) {
        const onChain = await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'quoteCollateral', args: [c.address, amount], blockNumber })
        expect(quoteCollateral(c, prices[i], base, baseScale, amount), `${c.address} ${amount}`).toBe(onChain)
      }
    }
  })

  it('leaves the principal the app predicts after a supply, withdraw, borrow and repay', async () => {
    await setFeeds()
    await fund(bob, 20_000_000_000n, 4_987_654_321_098_765_431n, 0n)
    await expectSettle(bob, 'supply', 7_777_777_777n, false)
    await expectSettle(bob, 'withdraw', 1_234_567_891n, false)
    // Crosses from a supply into a debt in one call, the way the app borrows from a supply.
    const supplied = await signedBalance(bob)
    await expectSettle(bob, 'withdraw', supplied + 2_345_678_901n, true)
    await expectSettle(bob, 'supply', 500_000_001n, false)
    // Repays the rest and crosses back into a supply.
    const owed = -(await signedBalance(bob))
    await expectSettle(bob, 'supply', owed + 1_000_000_003n, false)
  })

  it('reports the same debt and capacities that the market checks', async () => {
    await setFeeds()
    // Odd collateral amounts, so every collateral valuation leaves a remainder to round.
    await fund(alice, 0n, 5_123_456_789_012_345_679n, 20_000_001n)
    await expectSettle(alice, 'withdraw', 1_000_000_000n, true)

    // Mine a block at a known timestamp, then simulate at that block: accrue() inside the call is then
    // a no-op, and the app and the contract read the same stored indexes.
    const at = (await latestTime()) + 5n
    const { blockNumber } = await send(deployer, d.market, lendingMarketAbi, 'accrue', [], at)
    const s = await readState(blockNumber)
    const { update, base, prices } = await appPrices(at)
    const holdings = await holdingsOf(alice, prices, blockNumber)
    const p = await principalOf(alice, blockNumber)

    const tooMuch = 100_000_000_000n
    const notCollateralized = await revertOf(alice, 'withdraw', [d.USDC.address, tooMuch, update], blockNumber)
    expect(notCollateralized.name).toBe('NotCollateralized')
    expect(notCollateralized.args[1]).toBe(debtUSD(-settle(p, -tooMuch, s), base, baseScale))
    expect(notCollateralized.args[2]).toBe(borrowCapacity(holdings))

    const notLiquidatable = await revertOf(deployer, 'absorb', [alice, update], blockNumber)
    expect(notLiquidatable.name).toBe('NotLiquidatable')
    expect(notLiquidatable.args[1]).toBe(debtUSD(-presentValue(p, s), base, baseScale))
    expect(notLiquidatable.args[2]).toBe(liquidationCapacity(holdings))

    // A debt below the minimum is checked after the principal round trip, rounded up.
    const dust = 1_000_001n
    const carol = '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65' as Address // anvil account 4
    await fund(carol, 0n, 10n ** 18n, 0n)
    const at2 = (await latestTime()) + 5n
    const mined = await send(deployer, d.market, lendingMarketAbi, 'accrue', [], at2)
    const s2 = await readState(mined.blockNumber)
    const minBorrow = await revertOf(carol, 'withdraw', [d.USDC.address, dust, (await appPrices(at2)).update], mined.blockNumber)
    expect(minBorrow.name).toBe('MinBorrowNotMet')
    expect(minBorrow.args[0]).toBe(-settle(0n, -dust, s2))
  })

  it('settles an absorb the way the app previews it, with a surplus and with bad debt', async () => {
    for (const [account, drop] of [[alice, 10n], [bob, 35n]] as const) {
      await setFeeds()
      // Borrow close to the account's capacity at today's prices, then let prices fall by `drop` percent.
      const at = (await latestTime()) + 5n
      const { base, prices } = await appPrices(at)
      const s = await readState()
      const owed = -presentValue(await principalOf(account), s)
      const capacity = borrowCapacity(await holdingsOf(account, prices))
      const room = (capacity * baseScale * 97n) / (100n * (base.price + base.conf)) - owed
      if (room > 0n) await expectSettle(account, 'withdraw', room, true)

      const [, eth] = await pub.readContract({ address: d.WETH.chainlinkFeed, abi: mockFeedAbi, functionName: 'latestRoundData' })
      const [, btc] = await pub.readContract({ address: d.WBTC.chainlinkFeed, abi: mockFeedAbi, functionName: 'latestRoundData' })
      await setFeeds({ WETH: (eth * (100n - drop)) / 100n, WBTC: (btc * (100n - drop)) / 100n })

      const m = await readModel()
      const before = await readState()
      const absorbAt = (await latestTime()) + 5n
      const fallen = await appPrices(absorbAt)
      const projected = accrue(before, m, absorbAt)
      const holdings = await holdingsOf(account, fallen.prices)
      const debt = -presentValue(await principalOf(account), projected)
      const preview = absorbPreview(debt, fallen.base, baseScale, holdings, projected)

      const receipt = await send(deployer, d.market, lendingMarketAbi, 'absorb', [account, fallen.update], absorbAt, 100n)
      const [event] = parseEventLogs({ abi: lendingMarketAbi, eventName: 'AbsorbDebt', logs: receipt.logs })
      expect(event.args.debtAbsorbed).toBe(preview.debtBase)
      expect(event.args.badDebt).toBe(preview.badDebt)
      const seized = parseEventLogs({ abi: lendingMarketAbi, eventName: 'AbsorbCollateral', logs: receipt.logs })
      expect(seized.reduce((sum, e) => sum + e.args.usdValue, 0n)).toBe(preview.seizedUSD)
      expect(await signedBalance(account, receipt.blockNumber)).toBe(preview.surplus)
      // The case this account was set up to reach.
      expect(account === alice ? preview.surplus > 0n : preview.badDebt > 0n).toBe(true)
    }
  })

  it('derives reserves from cash, borrows and supply exactly as getReserves does', async () => {
    const blockNumber = await pub.getBlockNumber()
    const cash = await pub.readContract({ address: d.USDC.address, abi: tokenAbi, functionName: 'balanceOf', args: [d.market], blockNumber })
    const onChain = await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'getReserves', blockNumber })
    expect(reserves(cash, await readState(blockNumber))).toBe(onChain)
  })
})
