import { useEffect, useMemo, useState } from 'react'
import { useBlock, useConnection } from 'wagmi'
import { buildModel, type MarketModel } from '../lib/model'
import { useMarketData } from './useMarketData'

/** Wall-clock seconds, ticking once a second so projected balances move with accrued interest. */
export function useNow(intervalMs = 1_000): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)))
  useEffect(() => {
    const id = window.setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), intervalMs)
    return () => window.clearInterval(id)
  }, [intervalMs])
  return now
}

export function useModel(): { model: MarketModel | null; error: Error | null; isLoading: boolean } {
  const { address } = useConnection()
  const data = useMarketData(address)
  const now = useNow()
  // The latest block's timestamp: what the next call's simulation sees, and a floor for when it lands.
  const block = useBlock({ watch: true })
  const chainTime = block.data?.timestamp
  const model = useMemo(() => {
    if (!data.static || !data.live) return null
    const last = data.live.state.lastAccrualTime
    // Never project behind the last on-chain accrual if the visitor's clock runs slow.
    const t = now > last ? now : last
    const c = chainTime && chainTime > last ? chainTime : last
    return buildModel(data.deployment, data.static, data.live, data.account, t, c)
  }, [data.deployment, data.static, data.live, data.account, now, chainTime])
  return { model, error: (data.error as Error | null) ?? null, isLoading: data.isLoading }
}
