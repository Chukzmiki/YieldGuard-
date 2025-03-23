;; DeFi Yield Farming Contract - Stage 2
;; Added yield verification, consensus mechanism, and rewards

;; Constants
(define-constant contract-owner tx-sender)
(define-constant min-deposit u100000000) ;; 100 STX minimum deposit
(define-constant reward-per-epoch u1000000) ;; 1 STX per valid yield report
(define-constant max-yield-variance 10) ;; 10% maximum variance for yield verification
(define-constant min-verifiers u3) ;; Minimum verifiers for consensus
(define-constant PERFORMANCE-THRESHOLD u80) ;; Minimum performance score
(define-constant SLASHING-AMOUNT u10000000) ;; 10 STX slashing penalty
(define-constant MAX-INACTIVE-TIME u86400) ;; Max seconds without reporting (24 hours)

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-POOL-EXISTS (err u402))
(define-constant ERR-INVALID-DEPOSIT (err u403))
(define-constant ERR-POOL-NOT-FOUND (err u404))
(define-constant ERR-INVALID-YIELD (err u405))
(define-constant ERR-VERIFICATION-FAILED (err u406))
(define-constant ERR-LOW-PERFORMANCE (err u407))
(define-constant ERR-INACTIVE-POOL (err u408))

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
        performance-score: uint,
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
        impermanent-loss: uint,
        verified: bool
    }
)

(define-map consensus-yields
    { 
        protocol-hash: (string-ascii 16),
        epoch: uint 
    }
    {
        apr-avg: int,
        tvl-avg: uint,
        fees-avg: uint,
        impermanent-loss-avg: uint,
        reporter-count: uint
    }
)

(define-map pool-metrics
    { pool-id: (string-ascii 24) }
    {
        last-report-timestamp: uint,
        consecutive-verifications: uint,
        total-rewards: uint,
        total-penalties: uint
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
                        performance-score: u100,
                        total-epochs: u0,
                        risk-profile: {
                            volatility: volatility,
                            impermanent-loss: impermanent-loss
                        }
                    })
                (map-set pool-managers tx-sender pool-id)
                (map-set pool-index (var-get pool-counter) pool-id)
                (var-set pool-counter (+ (var-get pool-counter) u1))
                (map-set pool-metrics
                    {pool-id: pool-id}
                    {
                        last-report-timestamp: u0,
                        consecutive-verifications: u0,
                        total-rewards: u0,
                        total-penalties: u0
                    })
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
                        ERR-POOL-NOT-FOUND))
          (metrics (default-to 
                       {
                           last-report-timestamp: u0,
                           consecutive-verifications: u0,
                           total-rewards: u0,
                           total-penalties: u0
                       }
                       (map-get? pool-metrics {pool-id: pool-id}))))
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
                        impermanent-loss: impermanent-loss,
                        verified: false
                    })
                (map-set liquidity-pools
                    {pool-id: pool-id}
                    (merge pool 
                        {total-epochs: (+ (get total-epochs pool) u1)}))
                ;; Update last report timestamp
                (map-set pool-metrics
                    {pool-id: pool-id}
                    (merge metrics 
                        {last-report-timestamp: epoch}))
                (ok true))
            ERR-NOT-AUTHORIZED)))

;; Submit consensus data (for verifiers)
(define-public (submit-consensus-data 
                (protocol-hash (string-ascii 16))
                (epoch uint)
                (apr-avg int)
                (tvl-avg uint)
                (fees-avg uint)
                (impermanent-loss-avg uint))
    (let ((existing-data (map-get? consensus-yields 
                          {protocol-hash: protocol-hash, epoch: epoch})))
        (if (is-some existing-data)
            ;; Update existing consensus data
            (let ((unwrapped-data (unwrap-panic existing-data)))
                (map-set consensus-yields
                    {protocol-hash: protocol-hash, epoch: epoch}
                    {
                        apr-avg: (/ (+ (* (get apr-avg unwrapped-data) 
                                         (get reporter-count unwrapped-data))
                                     apr-avg)
                                  (+ (get reporter-count unwrapped-data) u1)),
                        tvl-avg: (/ (+ (* (get tvl-avg unwrapped-data) 
                                        (get reporter-count unwrapped-data))
                                    tvl-avg)
                                 (+ (get reporter-count unwrapped-data) u1)),
                        fees-avg: (/ (+ (* (get fees-avg unwrapped-data) 
                                         (get reporter-count unwrapped-data))
                                     fees-avg)
                                  (+ (get reporter-count unwrapped-data) u1)),
                        impermanent-loss-avg: (/ (+ (* (get impermanent-loss-avg unwrapped-data) 
                                                    (get reporter-count unwrapped-data))
                                                impermanent-loss-avg)
                                             (+ (get reporter-count unwrapped-data) u1)),
                        reporter-count: (+ (get reporter-count unwrapped-data) u1)
                    })
                (ok true))
            ;; Create new consensus data
            (begin
                (map-set consensus-yields
                    {protocol-hash: protocol-hash, epoch: epoch}
                    {
                        apr-avg: apr-avg,
                        tvl-avg: tvl-avg,
                        fees-avg: fees-avg,
                        impermanent-loss-avg: impermanent-loss-avg,
                        reporter-count: u1
                    })
                (ok true)))))

;; Verify yield and distribute rewards
(define-public (verify-yield (pool-id (string-ascii 24))
                           (epoch uint)
                           (protocol-hash (string-ascii 16)))
    (let ((data (unwrap! (map-get? yield-reports 
                          {pool-id: pool-id, epoch: epoch})
                       ERR-POOL-NOT-FOUND))
          (consensus (map-get? consensus-yields 
                      {protocol-hash: protocol-hash, epoch: epoch}))
          (pool (unwrap! (map-get? liquidity-pools {pool-id: pool-id})
                        ERR-POOL-NOT-FOUND))
          (metrics (default-to 
                   {
                       last-report-timestamp: u0,
                       consecutive-verifications: u0,
                       total-rewards: u0,
                       total-penalties: u0
                   }
                   (map-get? pool-metrics {pool-id: pool-id}))))
        (if (is-some consensus)
            (let ((consensus-unwrapped (unwrap-panic consensus)))
                (if (and
                    (>= (get reporter-count consensus-unwrapped) min-verifiers)
                    (validate-variance 
                        (get apr data)
                        (get apr-avg consensus-unwrapped))
                    (validate-variance 
                        (to-int (get tvl data))
                        (to-int (get tvl-avg consensus-unwrapped)))
                    (validate-variance 
                        (to-int (get fees-generated data))
                        (to-int (get fees-avg consensus-unwrapped)))
                    (validate-variance 
                        (to-int (get impermanent-loss data))
                        (to-int (get impermanent-loss-avg consensus-unwrapped))))
                    (begin
                        (try! (as-contract 
                            (stx-transfer? reward-per-epoch contract-owner 
                                         (get manager pool))))
                        (map-set yield-reports
                            {pool-id: pool-id, epoch: epoch}
                            (merge data {verified: true}))
                        ;; Update metrics
                        (map-set pool-metrics
                            {pool-id: pool-id}
                            (merge metrics 
                                {
                                    consecutive-verifications: (+ (get consecutive-verifications metrics) u1),
                                    total-rewards: (+ (get total-rewards metrics) reward-per-epoch)
                                }))
                        ;; Update performance score
                        (map-set liquidity-pools
                            {pool-id: pool-id}
                            (merge pool 
                                {performance-score: (min u100 (+ (get performance-score pool) u1))}))
                        (ok true))
                    (begin
                        ;; Verification failed, update metrics
                        (map-set pool-metrics
                            {pool-id: pool-id}
                            (merge metrics 
                                {consecutive-verifications: u0}))
                        ;; Decrease performance score
                        (map-set liquidity-pools
                            {pool-id: pool-id}
                            (merge pool 
                                {performance-score: (max u1 (- (get performance-score pool) u5))}))
                        ERR-VERIFICATION-FAILED)))
            ERR-INVALID-YIELD)))

;; Private helper functions
(define-private (validate-variance (value int) (consensus int))
    (let ((variance (abs (- value consensus))))
        (<= (* variance 100) (* consensus max-yield-variance))))

(define-private (abs (value int))
    (if (< value 0)
        (* value -1)
        value))

;; Quality Control Functions
(define-public (report-underperformance (pool-id (string-ascii 24)))
    (let ((pool (unwrap! (map-get? liquidity-pools {pool-id: pool-id})
                        ERR-POOL-NOT-FOUND))
          (metrics (default-to 
                     {
                         last-report-timestamp: u0,
                         consecutive-verifications: u0,
                         total-rewards: u0,
                         total-penalties: u0
                     }
                     (map-get? pool-metrics {pool-id: pool-id}))))
        (if (< (get performance-score pool) PERFORMANCE-THRESHOLD)
            (begin
                (try! (as-contract 
                    (stx-transfer? SLASHING-AMOUNT 
                                 (get manager pool)
                                 contract-owner)))
                (map-set pool-metrics
                    {pool-id: pool-id}
                    (merge metrics 
                        {total-penalties: (+ (get total-penalties metrics) u1)}))
                (ok true))
            ERR-INVALID-YIELD)))

(define-public (update-pool-status (pool-id (string-ascii 24)) (current-timestamp uint))
    (let ((pool (unwrap! (map-get? liquidity-pools {pool-id: pool-id})
                        ERR-POOL-NOT-FOUND))
          (metrics (default-to 
                     {
                         last-report-timestamp: u0,
                         consecutive-verifications: u0,
                         total-rewards: u0,
                         total-penalties: u0
                     }
                     (map-get? pool-metrics {pool-id: pool-id}))))
        (if (> (- current-timestamp (get last-report-timestamp metrics)) 
               MAX-INACTIVE-TIME)
            (begin
                (map-set liquidity-pools
                    {pool-id: pool-id}
                    (merge pool {performance-score: u0}))
                (ok true))
            ERR-INVALID-YIELD)))

;; Read-only functions
(define-read-only (get-pool-info (pool-id (string-ascii 24)))
    (map-get? liquidity-pools {pool-id: pool-id}))

(define-read-only (get-yield-data (pool-id (string-ascii 24)) 
                                 (epoch uint))
    (map-get? yield-reports {pool-id: pool-id, epoch: epoch}))

(define-read-only (get-consensus-yields (protocol-hash (string-ascii 16)) 
                                       (epoch uint))
    (map-get? consensus-yields {protocol-hash: protocol-hash, epoch: epoch}))

(define-read-only (get-pool-metrics (pool-id (string-ascii 24)))
    (map-get? pool-metrics {pool-id: pool-id}))

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