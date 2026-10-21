// Checks the app's math against the deployed contracts on a local anvil chain, to the wei.
// Run after ./scripts/local-chain.sh:  LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts/parity.test.ts
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, http, type Address } from 'viem'
import { foundry } from 'viem/chains'
import { beforeAll, describe, expect, it } from 'vitest'
import { lendingMarketAbi, rateModelAbi } from '../src/abi'
import { accrue, borrowRate, supplyRate, utilization, presentValue, type MarketState, type RateModel } from '../src/lib/market'

const rpc = process.env.LOCAL_RPC
const deployer = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address

describe.skipIf(!rpc)('parity with the contracts on a local chain', () => {
  // Read lazily: the local deployment file is not committed, and a skipped suite still gets collected.
  let d: { market: Address; rateModel: Address; faucet: Address }
  beforeAll(() => {
    d = JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8'))
  })
  const pub = createPublicClient({ chain: foundry, transport: http(rpc) })
  const wallet = createWalletClient({ chain: foundry, transport: http(rpc), account: deployer })

  async function readState(): Promise<MarketState> {
    const s = await pub.readContract({ address: d.market, abi: lendingMarketAbi, functionName: 'getMarketState' })
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
})
