/**
 * Format a number with commas (e.g., 1,234,567)
 */
export function formatNumber(value: number | bigint, decimals = 0): string {
  const num = typeof value === 'bigint' ? Number(value) : value
  return num.toLocaleString('en-US', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

/**
 * Format a large number with abbreviation (e.g., 1.2M, 45.3K)
 */
export function formatCompact(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`
  return value.toFixed(0)
}

/**
 * Format wei value to human-readable token amount
 */
export function formatTokenAmount(wei: bigint, decimals = 18, displayDecimals = 2): string {
  const divisor = 10n ** BigInt(decimals)
  const whole = wei / divisor

  if (displayDecimals === 0) {
    return formatNumber(Number(whole))
  }

  const fraction = wei % divisor
  const fractionStr = fraction.toString().padStart(decimals, '0').slice(0, displayDecimals)
  return `${formatNumber(Number(whole))}.${fractionStr}`
}

/**
 * Format native currency amount from wei to human-readable
 */
export function formatNative(wei: bigint): string {
  const val = Number(wei) / 1e18
  if (val < 0.001) return '< 0.001'
  if (val < 1) return val.toFixed(4)
  return val.toFixed(3)
}

/**
 * Parse a wei string (from API) to a human-scale number (divides by 1e18).
 * Useful for converting raw $BUBBLE amounts for display.
 */
export function parseBubble(wei: string): number {
  return Number(BigInt(wei)) / 1e18
}

/**
 * Truncate an address (e.g., 0x1234...5678)
 */
export function truncateAddress(address: string, chars = 4): string {
  return `${address.slice(0, chars + 2)}...${address.slice(-chars)}`
}

/**
 * Map raw blockchain/wallet error messages to user-friendly descriptions.
 */
export function friendlyError(error: unknown): string {
  const msg = error instanceof Error ? error.message : String(error ?? '')
  const lower = msg.toLowerCase()

  if (lower.includes('user rejected') || lower.includes('user denied'))
    return 'Transaction was cancelled in your wallet.'
  if (lower.includes('insufficient funds'))
    return 'Insufficient funds to cover the transaction and gas fees.'
  if (lower.includes('nonce'))
    return 'Transaction conflict. Please try again or reset your wallet nonce.'
  if (lower.includes('creditslocked'))
    return 'Efficiency credits are locked for 1 hour after earning. Please wait before upgrading.'
  if (lower.includes('execution reverted'))
    return 'Transaction failed on-chain. The contract rejected the operation.'
  if (lower.includes('gas'))
    return 'Gas estimation failed. The transaction may not succeed — try adjusting parameters.'
  if (lower.includes('timeout') || lower.includes('timed out'))
    return 'Network request timed out. Please check your connection and try again.'
  if (lower.includes('network') || lower.includes('fetch'))
    return 'Network error. Please check your internet connection.'
  if (lower.includes('already known') || lower.includes('replacement'))
    return 'A similar transaction is already pending. Wait for it to complete or speed it up in your wallet.'

  // Fallback: truncate raw message
  return msg.length > 150 ? `${msg.slice(0, 150)}...` : msg || 'An unexpected error occurred.'
}
