;; DAO Governance Protocol - Advanced Voting System for Stacks
;; Features: Proposal Management, Delegated Voting, Quadratic Voting, Treasury Management

;; Constants
(define-constant DAO_FOUNDER tx-sender)
(define-constant ERR_UNAUTHORIZED_MEMBER (err u801))
(define-constant ERR_INVALID_PROPOSAL (err u802))
(define-constant ERR_VOTING_CLOSED (err u803))
(define-constant ERR_ALREADY_VOTED (err u804))
(define-constant ERR_INSUFFICIENT_TOKENS (err u805))
(define-constant ERR_INVALID_DELEGATION (err u806))
(define-constant ERR_PROPOSAL_NOT_PASSED (err u807))
(define-constant ERR_EXECUTION_FAILED (err u808))
(define-constant ERR_INVALID_THRESHOLD (err u809))
(define-constant ERR_TREASURY_INSUFFICIENT (err u810))

;; Data Variables
(define-data-var dao-token-supply uint u1000000) ;; 1M governance tokens
(define-data-var proposal-counter uint u0)
(define-data-var voting-period uint u1008) ;; 1 week voting period
(define-data-var execution-delay uint u144) ;; 1 day execution delay
(define-data-var quorum-threshold uint u100000) ;; 10% of total supply
(define-data-var proposal-threshold uint u10000) ;; 1% to create proposal
(define-data-var dao-active bool true)

;; Data Maps
(define-map governance-tokens principal uint)
(define-map dao-proposals
  uint
  {
    proposer: principal,
    title: (string-ascii 128),
    description: (string-ascii 512),
    proposal-type: (string-ascii 32), ;; "treasury", "parameter", "upgrade", "general"
    target-contract: (optional principal),
    function-call: (optional (string-ascii 128)),
    parameters: (optional (string-ascii 256)),
    funding-amount: uint,
    voting-start: uint,
    voting-end: uint,
    execution-time: uint,
    votes-for: uint,
    votes-against: uint,
    votes-abstain: uint,
    total-voters: uint,
    status: (string-ascii 16), ;; "active", "passed", "failed", "executed", "cancelled"
    quadratic-voting: bool
  }
)

(define-map member-votes
  {member: principal, proposal-id: uint}
  {
    vote-choice: (string-ascii 16), ;; "for", "against", "abstain"
    vote-weight: uint,
    voting-power-used: uint,
    timestamp: uint
  }
)

(define-map vote-delegations
  principal
  {
    delegate: principal,
    delegated-power: uint,
    delegation-start: uint,
    auto-delegate: bool
  }
)

(define-map member-profiles
  principal
  {
    join-date: uint,
    proposals-created: uint,
    votes-cast: uint,
    delegation-power: uint,
    reputation-score: uint,
    member-tier: (string-ascii 16) ;; "bronze", "silver", "gold", "diamond"
  }
)

(define-map treasury-allocations
  (string-ascii 32)
  uint
)

(define-map proposal-comments
  {proposal-id: uint, comment-id: uint}
  {
    commenter: principal,
    comment: (string-ascii 280),
    timestamp: uint,
    support-level: (string-ascii 16) ;; "support", "oppose", "neutral"
  }
)

(define-map dao-committees
  (string-ascii 32)
  {
    committee-members: (list 10 principal),
    committee-head: principal,
    specialization: (string-ascii 64),
    decision-weight: uint
  }
)

;; Comment counter for each proposal
(define-map proposal-comment-counters uint uint)

;; Authorization Functions
(define-private (is-dao-founder)
  (is-eq tx-sender DAO_FOUNDER)
)

(define-private (has-governance-tokens (member principal) (required-amount uint))
  (>= (default-to u0 (map-get? governance-tokens member)) required-amount)
)

(define-private (get-voting-power (member principal))
  (let (
    (base-tokens (default-to u0 (map-get? governance-tokens member)))
    (delegation-info (map-get? vote-delegations member))
  )
    (match delegation-info
      delegation-data
      (if (> (get delegated-power delegation-data) u0)
        u0 ;; If delegated, member has no voting power
        base-tokens)
      base-tokens
    )
  )
)

(define-private (get-delegated-power (delegate principal))
  (fold check-delegation-power (list tx-sender) u0) ;; Simplified - in practice would iterate through all members
)

(define-private (check-delegation-power (member principal) (acc uint))
  (match (map-get? vote-delegations member)
    delegation-data
    (if (is-eq (get delegate delegation-data) tx-sender)
      (+ acc (get delegated-power delegation-data))
      acc)
    acc
  )
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
        delegation-power: u0,
        reputation-score: u100,
        member-tier: "bronze"
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

;; Delegation Functions
(define-public (delegate-voting-power (delegate principal) (amount uint) (auto-delegate bool))
  (let (
    (delegator-tokens (default-to u0 (map-get? governance-tokens tx-sender)))
    (current-delegation (map-get? vote-delegations tx-sender))
  )
    (asserts! (not (is-eq tx-sender delegate)) ERR_INVALID_DELEGATION)
    (asserts! (<= amount delegator-tokens) ERR_INSUFFICIENT_TOKENS)
    (asserts! (> amount u0) ERR_INVALID_PROPOSAL)
    
    ;; Create or update delegation
    (map-set vote-delegations tx-sender {
      delegate: delegate,
      delegated-power: amount,
      delegation-start: block-height,
      auto-delegate: auto-delegate
    })
    
    ;; Update delegate's profile
    (match (map-get? member-profiles delegate)
      profile-data
      (map-set member-profiles delegate 
        (merge profile-data {delegation-power: (+ (get delegation-power profile-data) amount)}))
      ;; Create profile if doesn't exist
      (map-set member-profiles delegate {
        join-date: block-height,
        proposals-created: u0,
        votes-cast: u0,
        delegation-power: amount,
        reputation-score: u100,
        member-tier: "bronze"
      })
    )
    
    (print {
      event: "voting-power-delegated",
      delegator: tx-sender,
      delegate: delegate,
      amount: amount,
      auto-delegate: auto-delegate
    })
    
    (ok amount)
  )
)

(define-public (revoke-delegation)
  (let (
    (delegation-info (unwrap! (map-get? vote-delegations tx-sender) ERR_INVALID_DELEGATION))
    (delegate (get delegate delegation-info))
    (delegated-amount (get delegated-power delegation-info))
  )
    ;; Remove delegation
    (map-delete vote-delegations tx-sender)
    
    ;; Update delegate's profile
    (match (map-get? member-profiles delegate)
      profile-data
      (map-set member-profiles delegate 
        (merge profile-data {delegation-power: (- (get delegation-power profile-data) delegated-amount)}))
      true
    )
    
    (print {
      event: "delegation-revoked",
      delegator: tx-sender,
      delegate: delegate,
      amount: delegated-amount
    })
    
    (ok delegated-amount)
  )
)

;; Proposal Management Functions
(define-public (create-proposal
  (title (string-ascii 128))
  (description (string-ascii 512))
  (proposal-type (string-ascii 32))
  (target-contract (optional principal))
  (function-call (optional (string-ascii 128)))
  (parameters (optional (string-ascii 256)))
  (funding-amount uint)
  (quadratic-voting bool))
  (let (
    (proposal-id (+ (var-get proposal-counter) u1))
    (proposer-tokens (get-voting-power tx-sender))
  )
    (asserts! (var-get dao-active) ERR_UNAUTHORIZED_MEMBER)
    (asserts! (>= proposer-tokens (var-get proposal-threshold)) ERR_INSUFFICIENT_TOKENS)
    
    ;; Validate funding request
    (if (> funding-amount u0)
      (asserts! (<= funding-amount (default-to u0 (map-get? treasury-allocations "available"))) ERR_TREASURY_INSUFFICIENT)
      true
    )
    
    ;; Create proposal
    (map-set dao-proposals proposal-id {
      proposer: tx-sender,
      title: title,
      description: description,
      proposal-type: proposal-type,
      target-contract: target-contract,
      function-call: function-call,
      parameters: parameters,
      funding-amount: funding-amount,
      voting-start: block-height,
      voting-end: (+ block-height (var-get voting-period)),
      execution-time: (+ (+ block-height (var-get voting-period)) (var-get execution-delay)),
      votes-for: u0,
      votes-against: u0,
      votes-abstain: u0,
      total-voters: u0,
      status: "active",
      quadratic-voting: quadratic-voting
    })
    
    ;; Initialize comment counter
    (map-set proposal-comment-counters proposal-id u0)
    
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
(define-public (cast-vote (proposal-id uint) (vote-choice (string-ascii 16)) (vote-weight uint))
  (let (
    (proposal-data (unwrap! (map-get? dao-proposals proposal-id) ERR_INVALID_PROPOSAL))
    (voter-power (+ (get-voting-power tx-sender) (get-delegated-power tx-sender)))
    (voting-power-to-use (if (get quadratic-voting proposal-data)
                          (calculate-quadratic-vote-cost vote-weight)
                          vote-weight))
  )
    (asserts! (is-eq (get status proposal-data) "active") ERR_VOTING_CLOSED)
    (asserts! (< block-height (get voting-end proposal-data)) ERR_VOTING_CLOSED)
    (asserts! (is-none (map-get? member-votes {member: tx-sender, proposal-id: proposal-id})) ERR_ALREADY_VOTED)
    (asserts! (<= voting-power-to-use voter-power) ERR_INSUFFICIENT_TOKENS)
    (asserts! (> vote-weight u0) ERR_INVALID_PROPOSAL)
    
    ;; Record vote
    (map-set member-votes {member: tx-sender, proposal-id: proposal-id} {
      vote-choice: vote-choice,
      vote-weight: vote-weight,
      voting-power-used: voting-power-to-use,
      timestamp: block-height
    })
    
    ;; Update proposal vote counts
    (let (
      (updated-proposal (merge proposal-data {
        votes-for: (if (is-eq vote-choice "for") 
                     (+ (get votes-for proposal-data) vote-weight) 
                     (get votes-for proposal-data)),
        votes-against: (if (is-eq vote-choice "against") 
                        (+ (get votes-against proposal-data) vote-weight) 
                        (get votes-against proposal-data)),
        votes-abstain: (if (is-eq vote-choice "abstain") 
                        (+ (get votes-abstain proposal-data) vote-weight) 
                        (get votes-abstain proposal-data)),
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
      vote-weight: vote-weight,
      voting-power-used: voting-power-to-use
    })
    
    (ok vote-weight)
  )
)

;; Quadratic voting cost calculation
(define-private (calculate-quadratic-vote-cost (vote-weight uint))
  (* vote-weight vote-weight) ;; Quadratic cost: weight^2
)

;; Proposal Execution Functions
(define-public (finalize-proposal (proposal-id uint))
  (let (
    (proposal-data (unwrap! (map-get? dao-proposals proposal-id) ERR_INVALID_PROPOSAL))
    (total-votes (+ (+ (get votes-for proposal-data) (get votes-against proposal-data)) (get votes-abstain proposal-data)))
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

(define-public (execute-proposal (proposal-id uint))
  (let (
    (proposal-data (unwrap! (map-get? dao-proposals proposal-id) ERR_INVALID_PROPOSAL))
  )
    (asserts! (is-eq (get status proposal-data) "passed") ERR_PROPOSAL_NOT_PASSED)
    (asserts! (>= block-height (get execution-time proposal-data)) ERR_VOTING_CLOSED)
    
    ;; Execute based on proposal type
    (let (
      (execution-result (execute-proposal-action proposal-data))
    )
      (if execution-result
        (begin
          (map-set dao-proposals proposal-id (merge proposal-data {status: "executed"}))
          (print {
            event: "proposal-executed",
            proposal-id: proposal-id,
            proposer: (get proposer proposal-data),
            proposal-type: (get proposal-type proposal-data)
          })
          (ok true)
        )
        (begin
          (map-set dao-proposals proposal-id (merge proposal-data {status: "failed"}))
          ERR_EXECUTION_FAILED
        )
      )
    )
  )
)

(define-private (execute-proposal-action (proposal-data (tuple (proposer principal) (title (string-ascii 128)) (description (string-ascii 512)) (proposal-type (string-ascii 32)) (target-contract (optional principal)) (function-call (optional (string-ascii 128))) (parameters (optional (string-ascii 256))) (funding-amount uint) (voting-start uint) (voting-end uint) (execution-time uint) (votes-for uint) (votes-against uint) (votes-abstain uint) (total-voters uint) (status (string-ascii 16)) (quadratic-voting bool))))
  (let (
    (prop-type (get proposal-type proposal-data))
    (funding-amount (get funding-amount proposal-data))
  )
    (if (is-eq prop-type "treasury")
      ;; Treasury proposal - transfer funds
      (begin
        (map-set treasury-allocations "allocated" 
          (+ (default-to u0 (map-get? treasury-allocations "allocated")) funding-amount))
        (map-set treasury-allocations "available" 
          (- (default-to u0 (map-get? treasury-allocations "available")) funding-amount))
        true
      )
      ;; Parameter proposal - update DAO parameters
      (if (is-eq prop-type "parameter")
        (execute-parameter-change proposal-data)
        ;; Other proposal types would be handled here
        true
      )
    )
  )
)

(define-private (execute-parameter-change (proposal-data (tuple (proposer principal) (title (string-ascii 128)) (description (string-ascii 512)) (proposal-type (string-ascii 32)) (target-contract (optional principal)) (function-call (optional (string-ascii 128))) (parameters (optional (string-ascii 256))) (funding-amount uint) (voting-start uint) (voting-end uint) (execution-time uint) (votes-for uint) (votes-against uint) (votes-abstain uint) (total-voters uint) (status (string-ascii 16)) (quadratic-voting bool))))
  ;; Simplified parameter change execution
  ;; In practice, this would parse parameters and update specific variables
  true
)

;; Community Functions
(define-public (add-proposal-comment 
  (proposal-id uint) 
  (comment (string-ascii 280)) 
  (support-level (string-ascii 16)))
  (let (
    (proposal-exists (is-some (map-get? dao-proposals proposal-id)))
    (comment-count (default-to u0 (map-get? proposal-comment-counters proposal-id)))
    (comment-id (+ comment-count u1))
  )
    (asserts! proposal-exists ERR_INVALID_PROPOSAL)
    (asserts! (has-governance-tokens tx-sender u1) ERR_UNAUTHORIZED_MEMBER)
    
    ;; Add comment
    (map-set proposal-comments {proposal-id: proposal-id, comment-id: comment-id} {
      commenter: tx-sender,
      comment: comment,
      timestamp: block-height,
      support-level: support-level
    })
    
    ;; Update comment counter
    (map-set proposal-comment-counters proposal-id comment-id)
    
    (print {
      event: "comment-added",
      proposal-id: proposal-id,
      comment-id: comment-id,
      commenter: tx-sender,
      support-level: support-level
    })
    
    (ok comment-id)
  )
)

(define-public (create-committee 
  (committee-name (string-ascii 32))
  (members (list 10 principal))
  (committee-head principal)
  (specialization (string-ascii 64))
  (decision-weight uint))
  (begin
    (asserts! (is-dao-founder) ERR_UNAUTHORIZED_MEMBER)
    (asserts! (<= decision-weight u100) ERR_INVALID_THRESHOLD)
    
    (map-set dao-committees committee-name {
      committee-members: members,
      committee-head: committee-head,
      specialization: specialization,
      decision-weight: decision-weight
    })
    
    (print {
      event: "committee-created",
      committee-name: committee-name,
      committee-head: committee-head,
      member-count: (len members)
    })
    
    (ok committee-name)
  )
)

;; Treasury Management Functions
(define-public (deposit-to-treasury (amount uint) (allocation-type (string-ascii 32)))
  (let (
    (current-allocation (default-to u0 (map-get? treasury-allocations allocation-type)))
  )
    (asserts! (> amount u0) ERR_INVALID_PROPOSAL)
    
    ;; Update treasury allocation
    (map-set treasury-allocations allocation-type (+ current-allocation amount))
    
    (print {
      event: "treasury-deposit",
      depositor: tx-sender,
      amount: amount,
      allocation-type: allocation-type
    })
    
    (ok amount)
  )
)

;; Administrative Functions
(define-public (update-dao-parameters 
  (new-voting-period (optional uint))
  (new-execution-delay (optional uint))
  (new-quorum-threshold (optional uint))
  (new-proposal-threshold (optional uint)))
  (begin
    (asserts! (is-dao-founder) ERR_UNAUTHORIZED_MEMBER)
    
    ;; Update parameters if provided
    (match new-voting-period period (var-set voting-period period) true)
    (match new-execution-delay delay (var-set execution-delay delay) true)
    (match new-quorum-threshold quorum (var-set quorum-threshold quorum) true)
    (match new-proposal-threshold threshold (var-set proposal-threshold threshold) true)
    
    (print {
      event: "dao-parameters-updated",
      admin: tx-sender,
      voting-period: (var-get voting-period),
      execution-delay: (var-get execution-delay),
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

(define-read-only (get-delegation-info (member principal))
  (map-get? vote-delegations member)
)

(define-read-only (get-governance-balance (member principal))
  (default-to u0 (map-get? governance-tokens member))
)

(define-read-only (get-total-voting-power (member principal))
  (+ (get-voting-power member) (get-delegated-power member))
)

(define-read-only (get-proposal-comment (proposal-id uint) (comment-id uint))
  (map-get? proposal-comments {proposal-id: proposal-id, comment-id: comment-id})
)

(define-read-only (get-committee-info (committee-name (string-ascii 32)))
  (map-get? dao-committees committee-name)
)

(define-read-only (get-treasury-balance (allocation-type (string-ascii 32)))
  (default-to u0 (map-get? treasury-allocations allocation-type))
)

(define-read-only (get-dao-metrics)
  {
    token-supply: (var-get dao-token-supply),
    proposal-counter: (var-get proposal-counter),
    voting-period: (var-get voting-period),
    execution-delay: (var-get execution-delay),
    quorum-threshold: (var-get quorum-threshold),
    proposal-threshold: (var-get proposal-threshold),
    dao-active: (var-get dao-active)
  }
)

(define-read-only (calculate-proposal-outcome (proposal-id uint))
  (match (map-get? dao-proposals proposal-id)
    proposal-data
    (let (
      (total-votes (+ (+ (get votes-for proposal-data) (get votes-against proposal-data)) (get votes-abstain proposal-data)))
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