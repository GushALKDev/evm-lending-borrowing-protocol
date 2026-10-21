import type { AssetSymbol } from '../config/deployment'

// Neutral glyphs rather than the issuers' logos: these are testnet stand-ins, not the real tokens.
const tokenColors: Record<AssetSymbol, [string, string]> = {
  USDC: ['#46668a', '#ffffff'],
  WETH: ['#5b6662', '#ffffff'],
  WBTC: ['#b0812f', '#ffffff'],
}

export function TokenIcon({ symbol }: { symbol: AssetSymbol }) {
  const [bg, fg] = tokenColors[symbol]
  const letter = symbol === 'WBTC' ? 'B' : symbol === 'WETH' ? 'E' : '$'
  return (
    <svg className="token-icon" viewBox="0 0 22 22" aria-hidden="true">
      <circle cx="11" cy="11" r="11" fill={bg} />
      <text x="11" y="15" textAnchor="middle" fontSize="11.5" fontWeight="600" fill={fg} fontFamily="IBM Plex Sans, sans-serif">
        {letter}
      </text>
    </svg>
  )
}

export function Mark() {
  return (
    <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden="true">
      <rect width="32" height="32" rx="8" fill="var(--ink)" />
      <rect x="6" y="9" width="8" height="5" rx="1.5" fill="var(--seg-cash)" />
      <rect x="15" y="9" width="11" height="5" rx="1.5" fill="var(--seg-borrow)" />
      <rect x="6" y="18" width="15" height="5" rx="1.5" fill="var(--seg-supply)" />
      <rect x="22" y="18" width="4" height="5" rx="1.5" fill="var(--seg-reserve)" />
    </svg>
  )
}

export function ToastIcon({ tone }: { tone: 'pending' | 'success' | 'error' }) {
  if (tone === 'pending')
    return (
      <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
        <circle cx="9" cy="9" r="7" fill="none" stroke="currentColor" strokeWidth="2" strokeDasharray="30 14" />
      </svg>
    )
  if (tone === 'success')
    return (
      <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
        <circle cx="9" cy="9" r="8" fill="currentColor" />
        <path d="M5.5 9.2l2.3 2.3 4.7-4.9" fill="none" stroke="var(--surface)" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
    )
  return (
    <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
      <circle cx="9" cy="9" r="8" fill="currentColor" />
      <path d="M9 5v5M9 12.6v.1" stroke="var(--surface)" strokeWidth="1.9" strokeLinecap="round" />
    </svg>
  )
}

export function CloseIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  )
}
