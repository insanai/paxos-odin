package paxos

// Paxos-Odin: a deterministic, bounded, data-oriented implementation of Classic and
// Multi-Paxos.
//
// The library performs zero I/O and owns zero threads or clocks. A Node consumes
// messages and emits Effects. The safety invariant the host must keep: persist every
// Effects.write before transmitting any Effects.message from the same transition, then
// call confirm_writes_durable.
//
// The design follows Lamport's variables directly. An acceptor's ledger holds, per
// decree, the greatest ballot it promised (maxBal), the ballot and value of its last
// vote (maxVBal, maxVal), and the decision once one is known. A ballot is one 64-bit
// integer so B1 is integer comparison; quorums are validated so B2 holds; phase one
// re-proposes the greatest vote so B3 holds. The book derives the safety theorem from
// these three conditions and maps every lemma to a procedure.
//
// Protocol obligations (the D1/L1/S1 labels are project conventions):
//   - B1: ballot uniqueness       (round, priority, node) packed into one ordered integer
//   - B2: quorum intersection      read_quorum + write_quorum > member count
//   - B3: max-vote preservation    phase two re-proposes the greatest vote seen in phase one
//   - D1: indelible ink            promises and votes are durable before any reply leaves
//   - L1: contiguous delivery      decisions are released in slot order without gaps
//   - S1: stop-sign sealing        nothing above a decided stop sign is released in its epoch

VERSION :: "0.2.0"

// Capacity defaults shared by Node, Effects, Replicated_Log_Node, and Learner.
DEFAULT_MAX_MEMBERS        :: 7
DEFAULT_WINDOW_SLOTS       :: 256
DEFAULT_CHUNK_SLOTS        :: 64
DEFAULT_MAX_METADATA_BYTES :: 256
DEFAULT_MAX_ENTRIES        :: 256

DEFAULT_ELECTION_TIMEOUT_TICKS   :: 10
DEFAULT_HEARTBEAT_INTERVAL_TICKS :: 3
DEFAULT_RESEND_INTERVAL_TICKS    :: 10

// Member indexes and ballot node fields are 16 bits wide.
MAX_SUPPORTED_MEMBERS :: 65535

// Internal invariant checks run in debug builds by default. Enable them in a release
// build with -define:PAXOS_INVARIANT_CHECKS=true, or disable them in a debug build
// (for example to profile with symbols) with -define:PAXOS_INVARIANT_CHECKS=false.
INVARIANT_CHECKS :: #config(PAXOS_INVARIANT_CHECKS, ODIN_DEBUG)

// ---------------------------------------------------------------------------
// The unified surface: one verb per operation, dispatched on the first argument.
//
//   paxos.init(&node, 1, membership)          paxos.init(&log, 1, epoch, membership)
//   paxos.campaign(&node, noop, &effects)     paxos.campaign(&log, noop, &effects)
//   paxos.propose(&node, value, &effects)     paxos.propose(&log, value, &effects)
//   paxos.step(&node, envelope, &effects)     paxos.step(&log, log_envelope, &effects)
//
// The long spellings (node_propose, replicated_log_propose, learner_learn_chosen)
// remain available when a call site wants to name its receiver type.
// ---------------------------------------------------------------------------

init :: proc{
	node_init,
	effects_init,
	membership_init,
	replicated_log_init,
	learner_init,
	stop_sign_init,
}

init_learner       :: proc{node_init_learner, replicated_log_init_learner}
restore            :: proc{node_restore, replicated_log_restore}
restore_learner    :: proc{node_restore_learner, replicated_log_restore_learner}
continue_at        :: proc{node_continue_at, replicated_log_continue_at}
begin_recovery     :: proc{node_begin_recovery, replicated_log_begin_recovery}

campaign             :: proc{node_campaign, replicated_log_campaign}
propose              :: proc{node_propose, replicated_log_propose}
propose_batch        :: proc{node_propose_batch, replicated_log_propose_batch}
step                 :: proc{node_step, replicated_log_step, replicated_log_step_checked}
tick                 :: proc{node_tick, replicated_log_tick}
reconnected          :: proc{node_reconnected, replicated_log_reconnected}
request_catch_up     :: proc{node_request_catch_up, replicated_log_request_catch_up}
learn_chosen         :: proc{node_learn_chosen, replicated_log_learn_chosen, learner_learn_chosen}
set_campaign_enabled :: proc{node_set_campaign_enabled, replicated_log_set_campaign_enabled}
advance_memory_floor :: proc{node_advance_memory_floor, replicated_log_advance_memory_floor}
install_chosen_trim  :: proc{node_install_chosen_trim, replicated_log_install_chosen_trim}

current_leader       :: proc{node_current_leader, replicated_log_current_leader}
decided_through      :: proc{node_decided_through, replicated_log_decided_through}
leader_base          :: proc{node_leader_base, replicated_log_leader_base}
proposal_frontier    :: proc{node_proposal_frontier, replicated_log_proposal_frontier}
committed_at         :: proc{node_committed_at, replicated_log_read, learner_chosen_at}
read_decided         :: proc{node_read_decided, replicated_log_read_decided, learner_read_chosen}
is_leader_caught_up  :: proc{node_is_leader_caught_up, replicated_log_is_leader_caught_up}
is_campaign_enabled  :: proc{node_is_campaign_enabled, replicated_log_is_campaign_enabled}
memory_floor         :: proc{node_memory_floor, replicated_log_memory_floor}
trim_anchor          :: proc{node_trim_anchor, replicated_log_trim_anchor}
role                 :: proc{node_role, replicated_log_role}
ballot               :: proc{node_ballot, replicated_log_ballot}
id                   :: proc{node_id, replicated_log_id}
is_voting_member     :: proc{node_is_voting_member, replicated_log_is_voting_member}
ledger               :: proc{node_ledger, replicated_log_ledger}

// Effects: the host's side of the contract.
reset                       :: effects_reset
confirm_writes_durable      :: effects_confirm_writes_durable
writes_slice                :: effects_writes_slice
messages_slice              :: effects_messages_slice
committed_slice             :: effects_committed_slice
requests_slice              :: effects_requests_slice
requires_power_loss_barrier :: effects_requires_power_loss_barrier
pre_durable_messages        :: effects_pre_durable_messages
is_empty                    :: effects_is_empty

// Replicated log: the short spellings.
log_init              :: replicated_log_init
log_init_learner      :: replicated_log_init_learner
log_init_from_stop    :: replicated_log_init_from_stop
log_continue_at       :: replicated_log_continue_at
log_restore           :: replicated_log_restore
log_restore_learner   :: replicated_log_restore_learner
log_begin_recovery    :: replicated_log_begin_recovery
log_propose           :: replicated_log_propose
log_propose_batch     :: replicated_log_propose_batch
log_propose_stop_sign :: replicated_log_propose_stop_sign
log_reconfigure       :: replicated_log_propose_stop_sign
log_campaign          :: replicated_log_campaign
log_tick              :: replicated_log_tick
log_step              :: proc{replicated_log_step, replicated_log_step_checked}
log_envelope          :: replicated_log_envelope
log_learn_chosen      :: replicated_log_learn_chosen
log_reconnected       :: replicated_log_reconnected
log_request_catch_up  :: replicated_log_request_catch_up
log_is_sealed         :: replicated_log_is_sealed
log_stop_sign         :: replicated_log_stop_sign
log_stop_slot         :: replicated_log_stop_slot
log_pending_stop_sign :: replicated_log_pending_stop_sign
log_is_reconfigured   :: replicated_log_stop_sign
log_read              :: replicated_log_read
log_read_decided      :: replicated_log_read_decided
log_decided_through   :: replicated_log_decided_through
log_leader_base       :: replicated_log_leader_base
log_proposal_frontier :: replicated_log_proposal_frontier
log_advance_memory_floor :: replicated_log_advance_memory_floor
log_memory_floor      :: replicated_log_memory_floor
log_install_chosen_trim :: replicated_log_install_chosen_trim
log_trim_anchor       :: replicated_log_trim_anchor
log_current_leader    :: replicated_log_current_leader
log_configuration_id  :: replicated_log_configuration_id

// Learner: the short spellings.
learner_step :: learner_learn_chosen
learner_read :: learner_read_chosen
learner_get  :: learner_chosen_at
