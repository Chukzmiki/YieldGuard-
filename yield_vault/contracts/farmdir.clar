;; DeFi Yield Farming Contract
;; Handles liquidity provider registration, yield reporting, and reward distribution

;; Constants
(define-constant contract-owner tx-sender)
(define-constant min-deposit u100000000) ;; 100 STX minimum deposit
(define-constant reward-per-epoch u1000000) ;; 1 STX per valid yield report
(define-constant max-yield-variance 10) ;; 10% maximum variance for yield verification
(define-constant min-verifiers u3) ;; Minimum verifiers for consensus

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-POOL-EXISTS (err u402))
(define-constant ERR-INVALID-DEPOSIT (err u403))
(define-constant ERR-POOL-NOT-FOUND (err u404))
(define-constant ERR-INVALID-YIELD (err u405))
(define-constant ERR-VERIFICATION-FAILED (err u406))

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
                        ERR-POOL-NOT-FOUND)))
        (if (is-some consensus)
            (let ((consensus-unwrapped (unwrap-panic consensus)))
                (if (and
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
                        (ok true))
                    ERR-VERIFICATION-FAILED))
            ERR-INVALID-YIELD)))

;; Private helper functions
(define-private (validate-variance (value int) (consensus int))
    (let ((variance (abs (- value consensus))))
        (<= (* variance 100) (* consensus max-yield-variance))))

(define-private (abs (value int))
    (if (< value 0)
        (* value -1)
        value))

;; Read-only functions
(define-read-only (get-pool-info (pool-id (string-ascii 24)))
    (map-get? liquidity-pools {pool-id: pool-id}))

(define-read-only (get-yield-data (pool-id (string-ascii 24)) 
                                 (epoch uint))
    (map-get? yield-reports {pool-id: pool-id, epoch: epoch}))

(define-read-only (get-consensus-yields (protocol-hash (string-ascii 16)) 
                                       (epoch uint))
    (map-get? consensus-yields {protocol-hash: protocol-hash, epoch: epoch}))


;; Enhanced DeFi Yield Farming Contract

;; Additional Constants
(define-constant PERFORMANCE-THRESHOLD u80) ;; Minimum performance score
(define-constant SLASHING-AMOUNT u10000000) ;; 10 STX slashing penalty
(define-constant MAX-INACTIVE-TIME u86400) ;; Max seconds without reporting (24 hours)
(define-constant GOVERNANCE-THRESHOLD u75) ;; 75% for proposal passing
(define-constant PROPOSAL-DURATION u604800) ;; 7 days in seconds

;; Additional Error Codes
(define-constant ERR-LOW-PERFORMANCE (err u407))
(define-constant ERR-INACTIVE-POOL (err u408))
(define-constant ERR-INSUFFICIENT-LIQUIDITY (err u409))
(define-constant ERR-INVALID-PROPOSAL (err u410))

;; Additional Maps
(define-map pool-metrics
    { pool-id: (string-ascii 24) }
    {
        last-report-timestamp: uint,
        consecutive-verifications: uint,
        total-rewards: uint,
        total-penalties: uint
    }
)

(define-map proposals
    { proposal-id: uint }
    {
        proposer: principal,
        title: (string-ascii 50),
        description: (string-ascii 500),
        parameter: (string-ascii 20),
        new-value: uint,
        votes-for: uint,
        votes-against: uint,
        status: (string-ascii 10),
        creation-timestamp: uint,
        end-timestamp: uint
    }
)

(define-map votes-cast
    { proposal-id: uint, voter: principal }
    { vote: bool }
)

(define-data-var proposal-counter uint u0)

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

;; Pool lookup functions
(define-read-only (get-pool-by-manager (manager principal))
    (let ((pool-id (map-get? pool-managers manager)))
        {pool-id: (default-to "" pool-id)}))

(define-read-only (get-manager-pool (manager principal))
    (map-get? pool-managers manager))

;; Vote function update
(define-public (vote-on-proposal (proposal-id uint) (vote-value bool) (current-timestamp uint))
    (let ((proposal (unwrap! (map-get? proposals {proposal-id: proposal-id})
                          ERR-INVALID-PROPOSAL))
          (pool-id (unwrap! (get-manager-pool tx-sender)
                           ERR-NOT-AUTHORIZED))
          (pool (unwrap! (get-pool-info pool-id)
                        ERR-NOT-AUTHORIZED)))
        (if (and
            (is-eq (get status proposal) "active")
            (< current-timestamp (get end-timestamp proposal))
            (is-none (map-get? votes-cast 
                            {proposal-id: proposal-id, voter: tx-sender})))
            (begin
                (map-set votes-cast
                    {proposal-id: proposal-id, voter: tx-sender}
                    {vote: vote-value})
                (map-set proposals
                    {proposal-id: proposal-id}
                    (merge proposal
                        {
                            votes-for: (+ (get votes-for proposal) 
                                        (if vote-value u1 u0)),
                            votes-against: (+ (get votes-against proposal)
                                           (if vote-value u0 u1))
                        }))
                (ok true))
            ERR-INVALID-PROPOSAL)))

;; Create proposal function update
(define-public (create-proposal 
    (title (string-ascii 50))
    (description (string-ascii 500))
    (parameter (string-ascii 20))
    (new-value uint)
    (current-timestamp uint))
    (let ((proposal-id (+ (var-get proposal-counter) u1))
          (pool-id (unwrap! (get-manager-pool tx-sender)
                           ERR-NOT-AUTHORIZED))
          (pool (unwrap! (get-pool-info pool-id)
                        ERR-NOT-AUTHORIZED)))
        (if (>= (get total-liquidity pool) (* min-deposit u2))
            (begin
                (map-set proposals
                    {proposal-id: proposal-id}
                    {
                        proposer: tx-sender,
                        title: title,
                        description: description,
                        parameter: parameter,
                        new-value: new-value,
                        votes-for: u0,
                        votes-against: u0,
                        status: "active",
                        creation-timestamp: current-timestamp,
                        end-timestamp: (+ current-timestamp PROPOSAL-DURATION)
                    })
                (var-set proposal-counter proposal-id)
                (ok proposal-id))
            ERR-INSUFFICIENT-LIQUIDITY)))

;; Execute proposal function
(define-public (execute-proposal (proposal-id uint) (current-timestamp uint))
    (let ((proposal (unwrap! (map-get? proposals {proposal-id: proposal-id})
                          ERR-INVALID-PROPOSAL)))
        (if (and
            (is-eq (get status proposal) "active")
            (>= current-timestamp (get end-timestamp proposal)))
            (let ((total-votes (+ (get votes-for proposal) (get votes-against proposal))))
                (if (and
                    (> total-votes u0)
                    (>= (* (get votes-for proposal) u100) (* total-votes GOVERNANCE-THRESHOLD)))
                    (begin
                        (map-set proposals
                            {proposal-id: proposal-id}
                            (merge proposal {status: "passed"}))
                        (ok true))
                    (begin
                        (map-set proposals
                            {proposal-id: proposal-id}
                            (merge proposal {status: "rejected"}))
                        (ok false))))
            ERR-INVALID-PROPOSAL)))