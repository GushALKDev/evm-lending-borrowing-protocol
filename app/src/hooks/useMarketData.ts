import { useMemo } from 'react'
import type { Abi, Address } from 'viem'
import { useBalance, useReadContracts } from 'wagmi'
import { deployment } from '../config/chain'
import type { CollateralInfo, Deployment } from '../config/deployment'
import { chainlinkAbi, demoPythAbi, faucetAbi, marketAbi, oracleAbi, rateModelAbi, tokenAbi } from '../lib/abi'
import type { MarketState, RateModel } from '../lib/market'

export interface StaticData {
  rateModel: RateModel
  minBorrow: bigint
  targetReserves: bigint
  baseScale: bigint
  owner: Address
  guardian: Address
  maxStaleness: bigint
  maxConfidenceBps: bigint
  maxDeviationBps: bigint
  updateFee: bigint
  feedDecimals: number[] // base, then collaterals
}

export interface FeedRound {
  answer: bigint
  updatedAt: bigint
}

export interface LiveData {
  state: MarketState
  cash: bigint
  totalsCollateral: bigint[]
  inventory: bigint[]
  rounds: FeedRound[] // base, then collaterals
}

export interface AccountData {
  principal: bigint
  collateral: bigint[]
  wallet: { base: bigint; collaterals: bigint[]; eth: bigint | undefined }
  allowance: { base: bigint; collaterals: bigint[] }
  nextClaimAt: bigint
}

const REFRESH_MS = 6_000

interface Read {
  address: Address
  abi: Abi
  functionName: string
  args?: readonly unknown[]
}

const asReads = (reads: unknown[]) => reads as Read[]

function useReads(contracts: Read[], query: { enabled?: boolean; staleTime?: number; refetchInterval?: number }) {
  const res = useReadContracts({ allowFailure: false, contracts: contracts as never, query })
  return { ...res, data: res.data as unknown as readonly unknown[] | undefined }
}

function useStatic(d: Deployment) {
  const feeds = [d.base.chainlinkFeed, ...d.collaterals.map((c) => c.chainlinkFeed)]
  const res = useReads(
    asReads([
      { address: d.rateModel, abi: rateModelAbi, functionName: 'BASE_RATE' },
      { address: d.rateModel, abi: rateModelAbi, functionName: 'SLOPE_LOW' },
      { address: d.rateModel, abi: rateModelAbi, functionName: 'SLOPE_HIGH' },
      { address: d.rateModel, abi: rateModelAbi, functionName: 'KINK' },
      { address: d.rateModel, abi: rateModelAbi, functionName: 'RESERVE_FACTOR' },
      { address: d.market, abi: marketAbi, functionName: 'MIN_BORROW' },
      { address: d.market, abi: marketAbi, functionName: 'TARGET_RESERVES' },
      { address: d.market, abi: marketAbi, functionName: 'BASE_SCALE' },
      { address: d.market, abi: marketAbi, functionName: 'owner' },
      { address: d.market, abi: marketAbi, functionName: 'GUARDIAN' },
      { address: d.oracle, abi: oracleAbi, functionName: 'MAX_STALENESS' },
      { address: d.oracle, abi: oracleAbi, functionName: 'MAX_CONFIDENCE_BPS' },
      { address: d.oracle, abi: oracleAbi, functionName: 'MAX_DEVIATION_BPS' },
      { address: d.pyth, abi: demoPythAbi, functionName: 'SINGLE_UPDATE_FEE' },
      ...feeds.map((address) => ({ address, abi: chainlinkAbi, functionName: 'decimals' })),
    ]),
    { staleTime: Infinity },
  )
  const data = useMemo((): StaticData | undefined => {
    const r = res.data
    if (!r) return undefined
    return {
        rateModel: {
          baseRate: r[0] as bigint,
          slopeLow: r[1] as bigint,
          slopeHigh: r[2] as bigint,
          kink: r[3] as bigint,
          reserveFactor: r[4] as bigint,
        },
        minBorrow: r[5] as bigint,
        targetReserves: r[6] as bigint,
        baseScale: r[7] as bigint,
        owner: r[8] as Address,
        guardian: r[9] as Address,
        maxStaleness: r[10] as bigint,
        maxConfidenceBps: r[11] as bigint,
        maxDeviationBps: r[12] as bigint,
        updateFee: r[13] as bigint,
        feedDecimals: (r.slice(14) as number[]).map(Number),
    }
  }, [res.data])
  return { ...res, data }
}

function useLive(d: Deployment) {
  const feeds = [d.base.chainlinkFeed, ...d.collaterals.map((c) => c.chainlinkFeed)]
  const n = d.collaterals.length
  const res = useReads(
    asReads([
      { address: d.market, abi: marketAbi, functionName: 'getMarketState' },
      { address: d.base.address, abi: tokenAbi, functionName: 'balanceOf', args: [d.market] },
      ...d.collaterals.map(
        (c) => ({ address: d.market, abi: marketAbi, functionName: 'totalsCollateral', args: [c.address] }),
      ),
      ...d.collaterals.map(
        (c) => ({ address: d.market, abi: marketAbi, functionName: 'getCollateralReserves', args: [c.address] }),
      ),
      ...feeds.map((address) => ({ address, abi: chainlinkAbi, functionName: 'latestRoundData' })),
    ]),
    { refetchInterval: REFRESH_MS },
  )
  const data = useMemo((): LiveData | undefined => {
    const r = res.data
    if (!r) return undefined
    {
        const s = r[0] as {
          baseSupplyIndex: bigint
          baseBorrowIndex: bigint
          lastAccrualTime: number
          pauseFlags: number
          totalSupplyBase: bigint
          totalBorrowBase: bigint
        }
        const rounds = r.slice(2 + 2 * n) as unknown as [bigint, bigint, bigint, bigint, bigint][]
        return {
          state: {
            supplyIndex: BigInt(s.baseSupplyIndex),
            borrowIndex: BigInt(s.baseBorrowIndex),
            lastAccrualTime: BigInt(s.lastAccrualTime),
            pauseFlags: Number(s.pauseFlags),
            totalSupplyBase: BigInt(s.totalSupplyBase),
            totalBorrowBase: BigInt(s.totalBorrowBase),
          },
          cash: r[1] as bigint,
          totalsCollateral: (r.slice(2, 2 + n) as bigint[]).map(BigInt),
          inventory: r.slice(2 + n, 2 + 2 * n) as bigint[],
          rounds: rounds.map((round) => ({ answer: round[1], updatedAt: round[3] })),
        }
    }
  }, [res.data, n])
  return { ...res, data }
}

function useAccount(d: Deployment, account: Address | undefined) {
  const user = account ?? '0x0000000000000000000000000000000000000000'
  const n = d.collaterals.length
  const tokens: (Deployment['base'] | CollateralInfo)[] = [d.base, ...d.collaterals]
  const eth = useBalance({ address: account, query: { enabled: !!account, refetchInterval: REFRESH_MS } })
  const reads = useReads(
    asReads([
      { address: d.market, abi: marketAbi, functionName: 'getPrincipal', args: [user] },
      ...d.collaterals.map(
        (c) => ({ address: d.market, abi: marketAbi, functionName: 'userCollateral', args: [user, c.address] }),
      ),
      ...tokens.map((t) => ({ address: t.address, abi: tokenAbi, functionName: 'balanceOf', args: [user] }) as const),
      ...tokens.map(
        (t) => ({ address: t.address, abi: tokenAbi, functionName: 'allowance', args: [user, d.market] }),
      ),
      { address: d.faucet, abi: faucetAbi, functionName: 'nextClaimAt', args: [user] },
    ]),
    { enabled: !!account, refetchInterval: REFRESH_MS },
  )
  const data = useMemo((): AccountData | undefined => {
    const r = reads.data
    if (!r || !account) return undefined
    const balances = r.slice(1 + n, 2 + 2 * n) as bigint[]
    const allowances = r.slice(2 + 2 * n, 3 + 3 * n) as bigint[]
    return {
      principal: BigInt(r[0] as bigint),
      collateral: (r.slice(1, 1 + n) as bigint[]).map(BigInt),
      // Unknown while loading, so the interface does not flash a no-gas warning.
      wallet: { base: balances[0], collaterals: balances.slice(1), eth: eth.data?.value },
      allowance: { base: allowances[0], collaterals: allowances.slice(1) },
      nextClaimAt: r[3 + 3 * n] as bigint,
    }
  }, [reads.data, account, n, eth.data?.value])
  return { data, isLoading: reads.isLoading, error: reads.error }
}

export function useMarketData(account: Address | undefined) {
  const d = deployment as Deployment
  const st = useStatic(d)
  const live = useLive(d)
  const acc = useAccount(d, account)
  return {
    deployment: d,
    static: st.data,
    live: live.data,
    account: acc.data,
    error: st.error ?? live.error ?? acc.error,
    isLoading: st.isLoading || live.isLoading,
    dataUpdatedAt: live.dataUpdatedAt,
  }
}
