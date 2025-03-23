;; DeFi Yield Farming Contract - (MVP)
;; Liquidity pool registration and yield reporting

;; Constants
(define-constant contract-owner tx-sender)
(define-constant min-deposit u100000000) ;; 100 STX minimum deposit
(define-constant reward-per-epoch u1000000) ;; 1 STX per valid yield report

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-POOL-EXISTS (err u402))
(define-constant ERR-INVALID-DEPOSIT (err u403))
(define-constant ERR-POOL-NOT-FOUND (err u404))
(define-constant ERR-INVALID-YIELD (err u405))

;; Pool tracking
(define-map pool-index uint (string-ascii 24))
(define-map pool-managers principal (string-ascii 24))
(define-data-var pool-counter uint u0)

;; Data structures
(define-map liquidity-pools
    { pool-id: (string-ascii 24) }
    {
        manager: principal,
        total-liquidity: uint,
        total-epochs: uint,
        risk-profile: {
            volatility: int,
            impermanent-loss: int
        }
    }
)

(define-map yield-reports
    { 
        pool-id: (string-ascii 24),
        epoch: uint 
    }
    {
        apr: int,
        tvl: uint,
        fees-generated: uint,
        impermanent-loss: uint
    }
)

;; Pool registration
(define-public (register-pool (pool-id (string-ascii 24)) 
                            (volatility int)
                            (impermanent-loss int))
    (let ((existing-pool (map-get? liquidity-pools {pool-id: pool-id})))
        (if (is-some existing-pool)
            ERR-POOL-EXISTS
            (begin
                (map-set liquidity-pools
                    {pool-id: pool-id}
                    {
                        manager: tx-sender,
                        total-liquidity: u0,
                        total-epochs: u0,
                        risk-profile: {
                            volatility: volatility,
                            impermanent-loss: impermanent-loss
                        }
                    })
                (map-set pool-managers tx-sender pool-id)
                (map-set pool-index (var-get pool-counter) pool-id)
                (var-set pool-counter (+ (var-get pool-counter) u1))
                (ok true)))))

;; Deposit tokens for pool
(define-public (deposit-liquidity (pool-id (string-ascii 24)) (amount uint))
    (let ((pool (unwrap! (map-get? liquidity-pools {pool-id: pool-id})
                        ERR-POOL-NOT-FOUND)))
        (if (and
            (is-eq tx-sender (get manager pool))
            (>= amount min-deposit))
            (begin
                (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
                (map-set liquidity-pools
                    {pool-id: pool-id}
                    (merge pool {total-liquidity: (+ (get total-liquidity pool) amount)}))
                (ok true))
            ERR-INVALID-DEPOSIT)))

;; Submit yield data
(define-public (submit-yield (pool-id (string-ascii 24))
                           (epoch uint)
                           (apr int)
                           (tvl uint)
                           (fees-generated uint)
                           (impermanent-loss uint))
    (let ((pool (unwrap! (map-get? liquidity-pools {pool-id: pool-id})
                        ERR-POOL-NOT-FOUND)))
        (if (is-eq tx-sender (get manager pool))
            (begin
                (map-set yield-reports
                    {
                        pool-id: pool-id,
                        epoch: epoch
                    }
                    {
                        apr: apr,
                        tvl: tvl,
                        fees-generated: fees-generated,
                        impermanent-loss: impermanent-loss
                    })
                (map-set liquidity-pools
                    {pool-id: pool-id}
                    (merge pool 
                        {total-epochs: (+ (get total-epochs pool) u1)}))
                (ok true))
            ERR-NOT-AUTHORIZED)))

;; Read-only functions
(define-read-only (get-pool-info (pool-id (string-ascii 24)))
    (map-get? liquidity-pools {pool-id: pool-id}))

(define-read-only (get-yield-data (pool-id (string-ascii 24)) 
                                 (epoch uint))
    (map-get? yield-reports {pool-id: pool-id, epoch: epoch}))

(define-read-only (get-pool-by-index (index uint))
    (map-get? pool-index index))

(define-read-only (get-manager-pool (manager principal))
    (map-get? pool-managers manager))

(define-read-only (get-pool-count)
    (var-get pool-counter))

;; Withdraw liquidity (emergency function)
(define-public (emergency-withdraw (pool-id (string-ascii 24)))
    (let ((pool (unwrap! (map-get? liquidity-pools {pool-id: pool-id})
                        ERR-POOL-NOT-FOUND)))
        (if (and
            (is-eq tx-sender (get manager pool))
            (> (get total-liquidity pool) u0))
            (begin
                (try! (as-contract 
                    (stx-transfer? (get total-liquidity pool) 
                                 contract-owner 
                                 (get manager pool))))
                (map-set liquidity-pools
                    {pool-id: pool-id}
                    (merge pool {total-liquidity: u0}))
                (ok true))
            ERR-NOT-AUTHORIZED)))