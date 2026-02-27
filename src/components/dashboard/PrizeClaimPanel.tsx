'use client'

import { useState, useEffect } from 'react'
import { cn } from '@/lib/utils/cn'
import { TerminalHeader } from '@/components/shared/TerminalHeader'
import { Button } from '@/components/shared/Button'
import { ProgressBar } from '@/components/shared/ProgressBar'
import {
  useCurrentRound,
  useRoundInfo,
  usePlayerClaim,
  useWithdrawVested,
  formatNativePrize,
} from '@/hooks/blockchain/use-prize-claim'
import { NATIVE_CURRENCY } from '@/lib/config/chain'
import { DataLabel } from '@/components/shared/DataLabel'
import { DataValue } from '@/components/shared/DataValue'

export function PrizeClaimPanel() {
  const { data: currentRound } = useCurrentRound()
  const roundId = currentRound as bigint | undefined

  // Check previous rounds for unclaimed prizes (check last 3 rounds)
  const roundsToCheck = roundId
    ? [roundId, roundId > 1n ? roundId - 1n : undefined, roundId > 2n ? roundId - 2n : undefined].filter(
        (r): r is bigint => r !== undefined && r > 0n,
      )
    : []

  if (!roundId || roundId === 0n) {
    return (
      <div className="widget-hover-border rounded-xl border border-border-primary bg-bg-secondary p-4">
        <TerminalHeader status="PENDING" statusColor="yellow">PRIZES</TerminalHeader>
        <div className="mt-3 flex flex-col items-center gap-2 py-4">
          <span className="font-mono text-2xl tabular-nums text-text-muted">0.00 {NATIVE_CURRENCY.symbol}</span>
          <p className="font-mono text-xs text-text-muted text-center">
            Faction war prizes are distributed weekly in {NATIVE_CURRENCY.symbol}.
            <br />
            First round ends after Week 1.
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="widget-hover-border rounded-xl border border-border-primary bg-bg-secondary p-4 space-y-3">
      <TerminalHeader live status={`${roundsToCheck.length} rounds`} statusColor="muted">PRIZES</TerminalHeader>
      {roundsToCheck.map((rid) => (
        <RoundClaimRow key={rid.toString()} roundId={rid} isCurrentRound={rid === roundId} />
      ))}
    </div>
  )
}

function RoundClaimRow({ roundId, isCurrentRound }: { roundId: bigint; isCurrentRound: boolean }) {
  const { data: roundInfo } = useRoundInfo(roundId)
  const round = roundInfo as
    | { merkleRoot: string; prizePool: bigint; totalClaimed: bigint; startTime: bigint; endTime: bigint; finalized: boolean }
    | undefined
  const {
    totalAmount,
    claimedAmount,
    withdrawableAmount,
    hasClaim,
    isFullyVested,
  } = usePlayerClaim(roundId)
  const { withdraw, isPending, isConfirming } = useWithdrawVested()

  // Don't show rows with no relevant data
  if (!round || !round.finalized) {
    if (isCurrentRound) {
      return (
        <div className="rounded-lg border border-border-primary bg-bg-tertiary/50 p-3">
          <div className="flex items-center justify-between">
            <span className="font-mono text-xs text-text-muted">Round {roundId.toString()}</span>
            <span className="inline-flex items-center gap-1.5 font-mono text-[10px] font-bold uppercase tracking-wider text-phase-yellow">
              <span className="relative flex h-1.5 w-1.5">
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-phase-yellow/60" />
                <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-phase-yellow" />
              </span>
              In Progress
            </span>
          </div>
          <p className="prize-amount-glow font-mono text-sm font-bold tabular-nums text-text-primary mt-1 cursor-default">
            {round ? formatNativePrize(round.prizePool) : '...'} {NATIVE_CURRENCY.symbol}
            <span className="ml-1 text-[10px] font-normal text-text-muted">prize pool</span>
          </p>
        </div>
      )
    }
    return null
  }

  if (!hasClaim) return null

  const vestingProgress =
    totalAmount > 0n ? Number((claimedAmount * 10000n) / totalAmount) / 100 : 0

  return (
    <div
      className={cn(
        'rounded-lg border p-3 space-y-2',
        isFullyVested && claimedAmount >= totalAmount
          ? 'border-border-primary bg-bg-tertiary opacity-60'
          : withdrawableAmount > 0n
            ? 'border-bubble/30 bg-bubble/5'
            : 'border-border-primary bg-bg-tertiary',
      )}
    >
      <div className="flex items-center justify-between">
        <span className="font-mono text-xs text-text-muted">Round {roundId.toString()}</span>
        <span className="prize-amount-glow font-mono text-xs font-bold text-text-primary cursor-default">
          {formatNativePrize(totalAmount)} {NATIVE_CURRENCY.symbol}
        </span>
      </div>

      {/* Vesting progress */}
      <div className="space-y-1">
        <div className="flex justify-between">
          <DataLabel>Vested</DataLabel>
          <DataValue color="muted" className="text-[10px]">
            {vestingProgress.toFixed(1)}%
          </DataValue>
        </div>
        <ProgressBar value={vestingProgress} />
      </div>

      {/* Withdraw button */}
      {withdrawableAmount > 0n && (
        <Button
          onClick={() => withdraw(roundId)}
          disabled={isPending || isConfirming}
          variant="secondary"
          size="sm"
          className={cn('w-full', !isPending && !isConfirming && 'claim-btn-shimmer')}
        >
          {isPending
            ? 'Confirming...'
            : isConfirming
              ? 'Withdrawing...'
              : `Withdraw ${formatNativePrize(withdrawableAmount)} ${NATIVE_CURRENCY.symbol}`}
        </Button>
      )}

      {isFullyVested && claimedAmount >= totalAmount && (
        <p className="font-mono text-[10px] text-text-secondary text-center">Fully withdrawn</p>
      )}
    </div>
  )
}
