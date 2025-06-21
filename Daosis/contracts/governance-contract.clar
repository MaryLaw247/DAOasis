;; DAO Governance Protocol - Basic Voting System for Stacks

;; Constants
(define-constant DAO_FOUNDER tx-sender)
(define-constant ERR_UNAUTHORIZED_MEMBER (err u801))
(define-constant ERR_INVALID_PROPOSAL (err u802))
(define-constant ERR_VOTING_CLOSED (err u803))
(define-constant ERR_ALREADY_VOTED (err u804))
(define-constant ERR_INSUFFICIENT_TOKENS (err u805))
(define-constant ERR_PROPOSAL_NOT_PASSED (err u807))

;; Data Variables
(define-data-var dao-token-supply uint u1000000) ;; 1M governance tokens
(define-data-var proposal-counter uint u0)
(define-data-var voting-period uint u1008) ;; 1 week voting period
(define-data-var quorum-threshold uint u100000) ;; 10% of total supply
(define-data-var proposal-threshold uint u10000) ;; 1% to create proposal

;; Data Maps
(define-map governance-tokens principal uint)
(define-map dao-proposals
  uint
  {
    proposer: principal,
    title: (string-ascii 128),
    description: (string-ascii 512),
    proposal-type: (string-ascii 32), ;; "treasury", "parameter", "general"
    funding-amount: uint,
    voting-start: uint,
    voting-end: uint,
    votes-for: uint,
    votes-against: uint,
    total-voters: uint,
    status: (string-ascii 16) ;; "active", "passed", "failed"
  }
)

(define-map member-votes
  {member: principal, proposal-id: uint}
  {
    vote-choice: (string-ascii 16), ;; "for", "against"
    vote-weight: uint,
    timestamp: uint
  }
)

(define-map member-profiles
  principal
  {
    join-date: uint,
    proposals-created: uint,
    votes-cast: uint,
    reputation-score: uint
  }
)

;; Authorization Functions
(define-private (is-dao-founder)
  (is-eq tx-sender DAO_FOUNDER)
)

(define-private (has-governance-tokens (member principal) (required-amount uint))
  (>= (default-to u0 (map-get? governance-tokens member)) required-amount)
)

(define-private (get-voting-power (member principal))
  (default-to u0 (map-get? governance-tokens member))
)

;; Token Management Functions
(define-public (mint-governance-tokens (recipient principal) (amount uint))
  (let (
    (current-balance (default-to u0 (map-get? governance-tokens recipient)))
  )
    (asserts! (is-dao-founder) ERR_UNAUTHORIZED_MEMBER)
    (asserts! (> amount u0) ERR_INVALID_PROPOSAL)
    
    ;; Mint tokens
    (map-set governance-tokens recipient (+ current-balance amount))
    (var-set dao-token-supply (+ (var-get dao-token-supply) amount))
    
    ;; Initialize member profile if new
    (if (is-eq current-balance u0)
      (map-set member-profiles recipient {
        join-date: block-height,
        proposals-created: u0,
        votes-cast: u0,
        reputation-score: u100
      })
      true
    )
    
    (print {
      event: "governance-tokens-minted",
      recipient: recipient,
      amount: amount,
      new-balance: (+ current-balance amount)
    })
    
    (ok amount)
  )
)

(define-public (transfer-tokens (recipient principal) (amount uint))
  (let (
    (sender-balance (default-to u0 (map-get? governance-tokens tx-sender)))
    (recipient-balance (default-to u0 (map-get? governance-tokens recipient)))
  )
    (asserts! (>= sender-balance amount) ERR_INSUFFICIENT_TOKENS)
    (asserts! (> amount u0) ERR_INVALID_PROPOSAL)
    
    ;; Transfer tokens
    (map-set governance-tokens tx-sender (- sender-balance amount))
    (map-set governance-tokens recipient (+ recipient-balance amount))
    
    (print {
      event: "tokens-transferred",
      sender: tx-sender,
      recipient: recipient,
      amount: amount
    })
    
    (ok amount)
  )
)

;; Proposal Management Functions
(define-public (create-proposal
  (title (string-ascii 128))
  (description (string-ascii 512))
  (proposal-type (string-ascii 32))
  (funding-amount uint))
  (let (
    (proposal-id (+ (var-get proposal-counter) u1))
    (proposer-tokens (get-voting-power tx-sender))
  )
    (asserts! (>= proposer-tokens (var-get proposal-threshold)) ERR_INSUFFICIENT_TOKENS)
    
    ;; Create proposal
    (map-set dao-proposals proposal-id {
      proposer: tx-sender,
      title: title,
      description: description,
      proposal-type: proposal-type,
      funding-amount: funding-amount,
      voting-start: block-height,
      voting-end: (+ block-height (var-get voting-period)),
      votes-for: u0,
      votes-against: u0,
      total-voters: u0,
      status: "active"
    })
    
    ;; Update proposer's profile
    (match (map-get? member-profiles tx-sender)
      profile-data
      (map-set member-profiles tx-sender 
        (merge profile-data {
          proposals-created: (+ (get proposals-created profile-data) u1),
          reputation-score: (+ (get reputation-score profile-data) u10)
        }))
      true
    )
    
    ;; Update counter
    (var-set proposal-counter proposal-id)
    
    (print {
      event: "proposal-created",
      proposal-id: proposal-id,
      proposer: tx-sender,
      title: title,
      proposal-type: proposal-type,
      funding-amount: funding-amount
    })
    
    (ok proposal-id)
  )
)

;; Voting Functions
(define-public (cast-vote (proposal-id uint) (vote-choice (string-ascii 16)))
  (let (
    (proposal-data (unwrap! (map-get? dao-proposals proposal-id) ERR_INVALID_PROPOSAL))
    (voter-power (get-voting-power tx-sender))
  )
    (asserts! (is-eq (get status proposal-data) "active") ERR_VOTING_CLOSED)
    (asserts! (< block-height (get voting-end proposal-data)) ERR_VOTING_CLOSED)
    (asserts! (is-none (map-get? member-votes {member: tx-sender, proposal-id: proposal-id})) ERR_ALREADY_VOTED)
    (asserts! (> voter-power u0) ERR_INSUFFICIENT_TOKENS)
    
    ;; Record vote
    (map-set member-votes {member: tx-sender, proposal-id: proposal-id} {
      vote-choice: vote-choice,
      vote-weight: voter-power,
      timestamp: block-height
    })
    
    ;; Update proposal vote counts
    (let (
      (updated-proposal (merge proposal-data {
        votes-for: (if (is-eq vote-choice "for") 
                     (+ (get votes-for proposal-data) voter-power) 
                     (get votes-for proposal-data)),
        votes-against: (if (is-eq vote-choice "against") 
                        (+ (get votes-against proposal-data) voter-power) 
                        (get votes-against proposal-data)),
        total-voters: (+ (get total-voters proposal-data) u1)
      }))
    )
      (map-set dao-proposals proposal-id updated-proposal)
    )
    
    ;; Update voter's profile
    (match (map-get? member-profiles tx-sender)
      profile-data
      (map-set member-profiles tx-sender 
        (merge profile-data {
          votes-cast: (+ (get votes-cast profile-data) u1),
          reputation-score: (+ (get reputation-score profile-data) u5)
        }))
      true
    )
    
    (print {
      event: "vote-cast",
      proposal-id: proposal-id,
      voter: tx-sender,
      vote-choice: vote-choice,
      vote-weight: voter-power
    })
    
    (ok voter-power)
  )
)

;; Proposal Execution Functions
(define-public (finalize-proposal (proposal-id uint))
  (let (
    (proposal-data (unwrap! (map-get? dao-proposals proposal-id) ERR_INVALID_PROPOSAL))
    (total-votes (+ (get votes-for proposal-data) (get votes-against proposal-data)))
    (quorum-met (>= total-votes (var-get quorum-threshold)))
    (proposal-passed (and quorum-met (> (get votes-for proposal-data) (get votes-against proposal-data))))
  )
    (asserts! (is-eq (get status proposal-data) "active") ERR_INVALID_PROPOSAL)
    (asserts! (>= block-height (get voting-end proposal-data)) ERR_VOTING_CLOSED)
    
    ;; Update proposal status
    (let (
      (new-status (if proposal-passed "passed" "failed"))
    )
      (map-set dao-proposals proposal-id (merge proposal-data {status: new-status}))
      
      (print {
        event: "proposal-finalized",
        proposal-id: proposal-id,
        status: new-status,
        total-votes: total-votes,
        quorum-met: quorum-met,
        votes-for: (get votes-for proposal-data),
        votes-against: (get votes-against proposal-data)
      })
      
      (ok {passed: proposal-passed, total-votes: total-votes})
    )
  )
)

;; Administrative Functions
(define-public (update-dao-parameters 
  (new-voting-period (optional uint))
  (new-quorum-threshold (optional uint))
  (new-proposal-threshold (optional uint)))
  (begin
    (asserts! (is-dao-founder) ERR_UNAUTHORIZED_MEMBER)
    
    ;; Update parameters if provided
    (match new-voting-period period (var-set voting-period period) true)
    (match new-quorum-threshold quorum (var-set quorum-threshold quorum) true)
    (match new-proposal-threshold threshold (var-set proposal-threshold threshold) true)
    
    (print {
      event: "dao-parameters-updated",
      admin: tx-sender,
      voting-period: (var-get voting-period),
      quorum-threshold: (var-get quorum-threshold),
      proposal-threshold: (var-get proposal-threshold)
    })
    
    (ok true)
  )
)

;; View Functions
(define-read-only (get-proposal-details (proposal-id uint))
  (map-get? dao-proposals proposal-id)
)

(define-read-only (get-member-profile (member principal))
  (map-get? member-profiles member)
)

(define-read-only (get-member-vote (member principal) (proposal-id uint))
  (map-get? member-votes {member: member, proposal-id: proposal-id})
)

(define-read-only (get-governance-balance (member principal))
  (default-to u0 (map-get? governance-tokens member))
)

(define-read-only (get-dao-metrics)
  {
    token-supply: (var-get dao-token-supply),
    proposal-counter: (var-get proposal-counter),
    voting-period: (var-get voting-period),
    quorum-threshold: (var-get quorum-threshold),
    proposal-threshold: (var-get proposal-threshold)
  }
)

(define-read-only (calculate-proposal-outcome (proposal-id uint))
  (match (map-get? dao-proposals proposal-id)
    proposal-data
    (let (
      (total-votes (+ (get votes-for proposal-data) (get votes-against proposal-data)))
      (quorum-met (>= total-votes (var-get quorum-threshold)))
      (majority-achieved (> (get votes-for proposal-data) (get votes-against proposal-data)))
    )
      {
        total-votes: total-votes,
        quorum-met: quorum-met,
        majority-achieved: majority-achieved,
        will-pass: (and quorum-met majority-achieved),
        participation-rate: (/ (* total-votes u10000) (var-get dao-token-supply))
      }
    )
    {total-votes: u0, quorum-met: false, majority-achieved: false, will-pass: false, participation-rate: u0}
  )
)