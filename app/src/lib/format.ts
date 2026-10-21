import { RATE_SCALE } from './market'

const groupInt = (s: string) => s.replace(/\B(?=(\d{3})+(?!\d))/g, ',')

/**
 * Formats a fixed-point bigint. Truncates toward zero, so a balance is never shown higher than it is.
 * `shown` is the number of decimals displayed; trailing zeros are kept for column alignment.
 */
export function formatFixed(value: bigint, decimals: number, shown: number): string {
  const negative = value < 0n
  const abs = negative ? -value : value
  const scale = 10n ** BigInt(decimals)
  const int = abs / scale
  let out = groupInt(int.toString())
  if (shown > 0) {
    const frac = (abs % scale).toString().padStart(decimals, '0').slice(0, shown).padEnd(shown, '0')
    out += `.${frac}`
  }
  return negative ? `-${out}` : out
}

/** Compact form for large totals: 1.25M, 340.5K. */
export function formatCompact(value: bigint, decimals: number): string {
  const n = Number(value) / 10 ** decimals
  const abs = Math.abs(n)
  if (abs >= 1e9) return `${(n / 1e9).toFixed(2)}B`
  if (abs >= 1e6) return `${(n / 1e6).toFixed(2)}M`
  if (abs >= 1e4) return `${(n / 1e3).toFixed(1)}K`
  return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

/** USD value at 1e18 scale. */
export function formatUsd(value18: bigint, shown = 2): string {
  const negative = value18 < 0n
  const s = formatFixed(negative ? -value18 : value18, 18, shown)
  return `${negative ? '-' : ''}$${s}`
}

/** Fraction at 1e18 scale as a percentage. */
export function formatPct(value18: bigint, shown = 2): string {
  return `${formatFixed(value18 * 100n, 18, shown)}%`
}

/** Basis points as a percentage: 8000 -> 80%. */
export function formatBps(bps: bigint): string {
  const whole = bps / 100n
  const frac = bps % 100n
  return frac === 0n ? `${whole}%` : `${whole}.${frac.toString().padStart(2, '0').replace(/0$/, '')}%`
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

/** Parses a user-typed decimal amount into base units; null if it is not a valid number. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim().replace(/,/g, '')
  if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null
  const [int, frac = ''] = s.split('.')
  if (frac.length > decimals) return null
  return BigInt(int || '0') * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0')
}

/** Inverse of parseAmount for Max buttons: no grouping, trailing zeros trimmed. */
export function toInput(value: bigint, decimals: number): string {
  const scale = 10n ** BigInt(decimals)
  const frac = (value % scale).toString().padStart(decimals, '0').replace(/0+$/, '')
  return frac ? `${value / scale}.${frac}` : `${value / scale}`
}

export const ONE = RATE_SCALE

export function relativeTime(seconds: number): string {
  if (seconds < 60) return `${Math.max(0, Math.round(seconds))} s`
  if (seconds < 3600) return `${Math.round(seconds / 60)} min`
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ${Math.round((seconds % 3600) / 60)} min`
  return `${Math.round(seconds / 86_400)} days`
}
