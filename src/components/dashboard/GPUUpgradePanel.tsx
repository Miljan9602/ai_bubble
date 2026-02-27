'use client'

import { useState, useEffect, useMemo, useCallback } from 'react'
import { useReadContract, useAccount } from 'wagmi'
import { cn } from '@/lib/utils/cn'
import { GPU_TIERS } from '@/lib/constants/gpu-tiers'
import { formatTokenAmount, formatNumber, friendlyError } from '@/lib/utils/format'
import { useGPUUpgrade } from '@/hooks/blockchain/use-gpu-upgrade'
import { useBubbleBalance } from '@/hooks/blockchain/use-bubble-balance'
import { CONTRACTS } from '@/lib/config/chain'
import { computeActualCost } from '@/lib/upgrade-advisor'
import { Button } from '@/components/shared/Button'
import { GPUTierBadge } from '@/components/shared/GPUTierBadge'
import { TerminalHeader } from '@/components/shared/TerminalHeader'
import { DataLabel } from '@/components/shared/DataLabel'
import { DataValue } from '@/components/shared/DataValue'

// ---------------------------------------------------------------------------
// ABI fragment for reading efficiency credits
// ---------------------------------------------------------------------------

const EFFICIENCY_CREDITS_ABI = [
  {
    name: 'efficiencyCredits',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'creditUnlockTime',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface GPUUpgradePanelProps {
  tokenId: number
}

type TierState = 'completed' | 'current' | 'next' | 'locked'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getTierState(tier: number, currentTier: number): TierState {
  if (tier < currentTier) return 'completed'
  if (tier === currentTier) return 'current'
  if (tier === currentTier + 1) return 'next'
  return 'locked'
}

function computeDeficit(cost: bigint, balance: bigint): bigint {
  if (balance >= cost) return 0n
  return cost - balance
}

function estimateFarmDays(deficit: bigint, yieldPerDay: number): number {
  if (deficit <= 0n || yieldPerDay <= 0) return 0
  const yieldWeiPerDay = BigInt(yieldPerDay) * 10n ** 18n
  if (yieldWeiPerDay === 0n) return Infinity
  return Math.ceil(Number(deficit) / Number(yieldWeiPerDay))
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

/** Circled tier number badge */
function TierNumberBadge({ tier, state }: { tier: number; state: TierState }) {
  return (
    <div
      className={cn(
        'flex h-8 w-8 shrink-0 items-center justify-center rounded-full font-mono text-xs font-bold',
        state === 'completed' && 'bg-bubble/20 text-bubble',
        state === 'current' && 'bg-bubble text-black',
        state === 'next' && 'bg-bg-tertiary text-text-primary border border-border-secondary',
        state === 'locked' && 'bg-bg-tertiary/50 text-text-muted border border-dashed border-border-primary/50',
      )}
    >
      {state === 'completed' ? (
        <svg
          className="completed-check-glow h-4 w-4"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={3}
          aria-hidden="true"
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
        </svg>
      ) : (
        tier
      )}
    </div>
  )
}

/** Vertical connector line between tiers */
function ConnectorLine({ fromState }: { fromState: TierState }) {
  return (
    <div className="absolute left-[15px] top-8 bottom-0 w-px">
      {fromState === 'completed' ? (
        <div className="h-full w-full bg-bubble/50" />
      ) : fromState === 'current' ? (
        <div className="connector-dash-animate h-full w-full" />
      ) : (
        <div className="h-full w-full border-l border-dashed border-border-primary/50" />
      )}
    </div>
  )
}

/** Lock icon for locked tiers */
function LockIcon() {
  return (
    <svg
      className="h-4 w-4 text-text-muted"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={2}
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
      />
    </svg>
  )
}

// ---------------------------------------------------------------------------
// Tier row
// ---------------------------------------------------------------------------

interface TierRowProps {
  tier: number
  state: TierState
  currentYieldPerDay: number
  balance: bigint
  credits: bigint
  isLast: boolean
  isUpgrading: boolean
  showConfirm: boolean
  onRequestUpgrade: () => void
  onConfirmUpgrade: () => void
  onCancelUpgrade: () => void
}

function TierRow({
  tier,
  state,
  currentYieldPerDay,
  balance,
  credits,
  isLast,
  isUpgrading,
  showConfirm,
  onRequestUpgrade,
  onConfirmUpgrade,
  onCancelUpgrade,
}: TierRowProps) {
  const data = GPU_TIERS[tier]
  const actualCost = computeActualCost(data.upgradeCost, credits)
  const hasDiscount = credits > 0n && data.upgradeCost > 0n && actualCost < data.upgradeCost
  const canAfford = balance >= actualCost
  const deficit = computeDeficit(actualCost, balance)
  const farmDays = estimateFarmDays(deficit, currentYieldPerDay)

  return (
    <div className="relative">
      {/* Connector line */}
      {!isLast && <ConnectorLine fromState={state} />}

      {/* Row card */}
      <div
        className={cn(
          'tier-row-hover relative flex items-start gap-3 rounded-lg p-3',
          // Completed
          state === 'completed' &&
            'bg-bg-tertiary/50 border-l-2 border-bubble/50 opacity-70',
          // Current
          state === 'current' &&
            'bg-bubble/5 border border-bubble/30 shadow-[0_0_15px_rgba(57,255,20,0.08)]',
          // Next
          state === 'next' && 'bg-bg-secondary border border-border-primary',
          // Locked
          state === 'locked' &&
            'bg-bg-tertiary/30 border border-dashed border-border-primary/50 opacity-50',
        )}
      >
        {/* Tier number badge */}
        <TierNumberBadge tier={tier} state={state} />

        {/* Center content */}
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <span
              className={cn(
                'font-mono font-bold text-sm',
                state === 'completed' && 'text-text-secondary',
                state === 'current' && 'text-text-primary',
                state === 'next' && 'text-text-primary',
                state === 'locked' && 'text-text-muted',
              )}
            >
              {data.name}
            </span>

            <span className="font-mono text-xs text-bubble font-semibold">
              x{data.multiplier}
            </span>

            {state === 'current' && (
              <span className="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-mono font-bold uppercase tracking-wider bg-bubble/20 text-bubble">
                Current
              </span>
            )}

            {state === 'locked' && <LockIcon />}
          </div>

          {/* Yield info */}
          <div className="mt-1 flex items-center gap-3">
            <DataLabel>Yield/day</DataLabel>
            <DataValue
              color={state === 'locked' ? 'muted' : 'default'}
              className="text-xs"
            >
              {formatNumber(data.yieldPerDay)} $BUBBLE
            </DataValue>
          </div>

          {/* Next tier: upgrade cost & hint */}
          {state === 'next' && (
            <div className="mt-2 space-y-2">
              <div className="flex items-center gap-3">
                <DataLabel>Upgrade cost</DataLabel>
                <div className="flex items-center gap-1.5">
                  {hasDiscount && (
                    <span className="font-mono text-xs text-text-muted line-through">
                      {formatTokenAmount(data.upgradeCost, 18, 0)}
                    </span>
                  )}
                  <DataValue color="bubble" className="text-xs">
                    {formatTokenAmount(actualCost, 18, 0)} $BUBBLE
                  </DataValue>
                  {hasDiscount && (
                    <span className="font-mono text-[10px] text-bubble font-semibold">
                      (credits)
                    </span>
                  )}
                </div>
              </div>

              {!canAfford && (
                <p className="font-mono text-[11px] text-phase-yellow">
                  Need {formatTokenAmount(deficit, 18, 0)} more $BUBBLE
                  {farmDays > 0 && farmDays < Infinity && (
                    <span className="text-text-muted">
                      {' '}
                      (~{farmDays}d farming)
                    </span>
                  )}
                </p>
              )}
            </div>
          )}

          {/* Maintenance info for higher tiers */}
          {state === 'next' && data.maintenanceCost > 0n && (
            <div className="mt-1 flex items-center gap-3">
              <DataLabel>Weekly maint.</DataLabel>
              <DataValue color="muted" className="text-xs">
                {formatTokenAmount(data.maintenanceCost, 18, 0)} $BUBBLE
              </DataValue>
            </div>
          )}

          {/* Maintenance warning */}
          {state === 'next' && data.maintenanceCost > 0n && (
            <div className="mt-2 rounded-md bg-phase-yellow/10 border border-phase-yellow/20 px-2.5 py-1.5">
              <p className="font-mono text-[10px] text-phase-yellow leading-relaxed">
                Missing weekly maintenance of {formatTokenAmount(data.maintenanceCost, 18, 0)} $BUBBLE will reset your GPU to Tier 0 (Stock CPU).
              </p>
            </div>
          )}
        </div>

        {/* Right side: action area */}
        {state === 'next' && !showConfirm && (
          <div className="shrink-0 flex flex-col items-end gap-1">
            <Button
              variant="primary"
              size="sm"
              loading={isUpgrading}
              disabled={!canAfford || isUpgrading}
              onClick={onRequestUpgrade}
              className={cn(canAfford && !isUpgrading && 'upgrade-btn-pulse')}
            >
              Upgrade
            </Button>
          </div>
        )}

        {/* Inline confirmation */}
        {state === 'next' && showConfirm && !isUpgrading && (
          <div className="shrink-0 flex flex-col items-end gap-1.5">
            <div className="rounded-md bg-bg-tertiary border border-border-secondary px-3 py-2 text-right">
              <p className="font-mono text-[10px] text-text-muted uppercase tracking-wider mb-1">
                Upgrade to
              </p>
              <p className="font-mono text-xs font-bold text-text-primary">
                {data.name} (x{data.multiplier})
              </p>
              <p className="font-mono text-[10px] text-bubble mt-0.5 tabular-nums">
                Cost: {formatTokenAmount(actualCost, 18, 0)} $BUBBLE
              </p>
            </div>
            <div className="flex gap-1.5">
              <Button
                variant="ghost"
                size="sm"
                onClick={onCancelUpgrade}
              >
                Cancel
              </Button>
              <Button
                variant="primary"
                size="sm"
                onClick={onConfirmUpgrade}
              >
                Confirm Upgrade
              </Button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Main Component
// ---------------------------------------------------------------------------

export function GPUUpgradePanel({ tokenId }: GPUUpgradePanelProps) {
  const [showAllTiers, setShowAllTiers] = useState(false)
  const [successMessage, setSuccessMessage] = useState<string | null>(null)
  const [showUpgradeConfirm, setShowUpgradeConfirm] = useState(false)

  const { address } = useAccount()

  const {
    upgrade,
    effectiveTier,
    status,
    error,
    reset,
  } = useGPUUpgrade(tokenId)

  const { balance } = useBubbleBalance()

  // Read efficiency credits
  const { data: creditsRaw } = useReadContract({
    address: CONTRACTS.BUBBLE_TOKEN,
    abi: EFFICIENCY_CREDITS_ABI,
    functionName: 'efficiencyCredits',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })
  const credits = (creditsRaw as bigint | undefined) ?? 0n

  // Read credit unlock time (M-05: 1hr lock after earning)
  const { data: unlockTimeRaw } = useReadContract({
    address: CONTRACTS.BUBBLE_TOKEN,
    abi: EFFICIENCY_CREDITS_ABI,
    functionName: 'creditUnlockTime',
    args: address ? [address] : undefined,
    query: { enabled: !!address && credits > 0n },
  })
  const creditUnlockTime = Number((unlockTimeRaw as bigint | undefined) ?? 0n)
  const creditsLocked = credits > 0n && creditUnlockTime > Math.floor(Date.now() / 1000)

  const currentTier = effectiveTier ?? 0
  const isUpgrading = status === 'pending' || status === 'confirming'

  // Handle upgrade flow: request → confirm → execute
  const handleRequestUpgrade = useCallback(() => {
    setSuccessMessage(null)
    setShowUpgradeConfirm(true)
  }, [])

  const handleConfirmUpgrade = useCallback(() => {
    setShowUpgradeConfirm(false)
    reset()
    upgrade()
  }, [upgrade, reset])

  const handleCancelUpgrade = useCallback(() => {
    setShowUpgradeConfirm(false)
  }, [])

  // Handle success state
  const isSuccess = status === 'success'

  // Show success message when upgrade completes
  useEffect(() => {
    if (isSuccess && currentTier < 5) {
      const nextTierData = GPU_TIERS[currentTier + 1]
      if (nextTierData) {
        setSuccessMessage(
          `Upgraded to ${nextTierData.name}! Yield multiplier is now x${nextTierData.multiplier}.`,
        )
      }
    }
  }, [isSuccess, currentTier])

  // Determine which tiers to display on mobile
  const visibleTiers = useMemo(() => {
    if (showAllTiers) return GPU_TIERS

    // By default show: completed tiers (last one only), current, and next
    const relevant: typeof GPU_TIERS = []
    for (const tierData of GPU_TIERS) {
      const state = getTierState(tierData.tier, currentTier)
      if (state === 'completed' && tierData.tier === currentTier - 1) {
        relevant.push(tierData)
      } else if (state === 'current' || state === 'next') {
        relevant.push(tierData)
      }
    }
    // Always include tier 0 if it is current
    if (relevant.length === 0) {
      relevant.push(GPU_TIERS[0])
    }
    return relevant
  }, [currentTier, showAllTiers])

  // Token not loaded yet
  if (tokenId === undefined) {
    return (
      <div className="rounded-xl border border-border-primary bg-bg-secondary p-4">
        <TerminalHeader>GPU Upgrade</TerminalHeader>
        <p className="mt-4 font-mono text-sm text-text-muted text-center">
          Connect wallet and mint an NFT to access GPU upgrades.
        </p>
      </div>
    )
  }

  return (
    <div className="widget-hover-border rounded-xl border border-border-primary bg-bg-secondary p-4">
      {/* Header */}
      <div className="flex items-center gap-3 mb-4">
        <TerminalHeader className="flex-1" status={currentTier === 5 ? 'MAX' : `T${currentTier}/5`} statusColor={currentTier === 5 ? 'green' : 'muted'}>GPU Upgrade</TerminalHeader>
        <GPUTierBadge tier={currentTier} />
      </div>

      {/* Efficiency credits info */}
      {credits > 0n && (
        <div className={cn(
          'mb-4 rounded-lg p-3 flex items-center gap-2',
          creditsLocked
            ? 'bg-phase-yellow/5 border border-phase-yellow/20'
            : 'bg-bubble/5 border border-bubble/20',
        )}>
          <svg
            className={cn('h-4 w-4 shrink-0', creditsLocked ? 'text-phase-yellow' : 'text-bubble')}
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d={creditsLocked ? 'M12 15v2m0 0a2 2 0 100-4 2 2 0 000 4zm6-6V7a6 6 0 10-12 0v4' : 'M13 10V3L4 14h7v7l9-11h-7z'}
            />
          </svg>
          <p className={cn('font-mono text-xs', creditsLocked ? 'text-phase-yellow' : 'text-bubble')}>
            {formatTokenAmount(credits, 18, 0)} efficiency credits
            {creditsLocked ? ' — locked (unlocks in <1hr)' : ' (1.5x value on upgrades)'}
          </p>
        </div>
      )}

      {credits === 0n && (
        <div className="mb-4 rounded-lg bg-bg-tertiary/50 border border-border-primary p-3 flex items-center gap-2">
          <svg
            className="h-4 w-4 text-text-muted shrink-0"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M13 10V3L4 14h7v7l9-11h-7z"
            />
          </svg>
          <p className="font-mono text-[10px] text-text-muted">
            Buy $BUBBLE on the DEX to earn efficiency credits (1.5x value on upgrades).
          </p>
        </div>
      )}

      {/* Success message */}
      {successMessage && (
        <div className="mb-4 rounded-lg bg-bubble/10 border border-bubble/30 p-3 flex items-start gap-2" role="status">
          <svg
            className="h-4 w-4 text-bubble shrink-0 mt-0.5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M5 13l4 4L19 7"
            />
          </svg>
          <p className="font-mono text-xs text-bubble">{successMessage}</p>
        </div>
      )}

      {/* Error message */}
      {error && (
        <div className="mb-4 rounded-lg bg-phase-red/10 border border-phase-red/30 p-3" role="alert">
          <p className="font-mono text-xs text-phase-red">
            Upgrade failed: {friendlyError(error)}
          </p>
        </div>
      )}

      {/* Tier ladder */}
      <div className="space-y-3">
        {/* Collapsed indicator for mobile */}
        {!showAllTiers && currentTier > 1 && (
          <div className="flex items-center gap-2 px-3 py-1">
            <div className="h-px flex-1 bg-bubble/20" />
            <span className="font-mono text-[10px] text-text-muted uppercase tracking-wider">
              {currentTier - 1} tier{currentTier - 1 > 1 ? 's' : ''} completed
            </span>
            <div className="h-px flex-1 bg-bubble/20" />
          </div>
        )}

        {visibleTiers.map((tierData) => {
          const state = getTierState(tierData.tier, currentTier)
          return (
            <TierRow
              key={tierData.tier}
              tier={tierData.tier}
              state={state}
              currentYieldPerDay={GPU_TIERS[currentTier].yieldPerDay}
              balance={balance}
              credits={credits}
              isLast={
                showAllTiers
                  ? tierData.tier === 5
                  : tierData.tier === visibleTiers[visibleTiers.length - 1].tier
              }
              isUpgrading={isUpgrading}
              showConfirm={showUpgradeConfirm}
              onRequestUpgrade={handleRequestUpgrade}
              onConfirmUpgrade={handleConfirmUpgrade}
              onCancelUpgrade={handleCancelUpgrade}
            />
          )
        })}

        {/* Locked tiers hint when collapsed */}
        {!showAllTiers && currentTier < 4 && (
          <div className="flex items-center gap-2 px-3 py-1">
            <div className="h-px flex-1 bg-border-primary/50" />
            <span className="font-mono text-[10px] text-text-muted uppercase tracking-wider">
              {4 - currentTier} more tier{4 - currentTier > 1 ? 's' : ''} locked
            </span>
            <div className="h-px flex-1 bg-border-primary/50" />
          </div>
        )}
      </div>

      {/* Show all tiers toggle */}
      <button
        onClick={() => setShowAllTiers((prev) => !prev)}
        aria-expanded={showAllTiers}
        className="mt-4 w-full flex items-center justify-center gap-2 py-2 font-mono text-xs text-text-secondary hover:text-text-primary hover:bg-bg-tertiary/50 border border-transparent hover:border-border-primary rounded-lg underline underline-offset-4 decoration-border-primary hover:decoration-text-secondary transition-all focus-visible:ring-2 focus-visible:ring-bubble focus-visible:ring-offset-2 focus-visible:ring-offset-bg-primary"
      >
        <span>{showAllTiers ? 'Collapse tiers' : 'Show all tiers'}</span>
        <svg
          className={cn(
            'h-3 w-3 transition-transform duration-200',
            showAllTiers && 'rotate-180',
          )}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
          aria-hidden="true"
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      {/* Max tier message */}
      {currentTier === 5 && (
        <div className="mt-4 rounded-lg bg-bubble/5 border border-bubble/20 p-3 text-center">
          <p className="font-mono text-xs text-bubble font-semibold">
            MAX TIER REACHED
          </p>
          <p className="mt-1 font-mono text-[11px] text-text-muted">
            B200 -- x8 multiplier -- {formatNumber(80_000)} $BUBBLE/day
          </p>
        </div>
      )}
    </div>
  )
}
