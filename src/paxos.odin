package paxos

import "core:mem"

// Paxos-Odin: A deterministic, bounded implementation of Classic and Multi-Paxos.
//
// The library performs zero I/O and owns zero threads or clocks. A Node consumes
// messages and emits Effects. The safety invariant requires: persist Effects.writes
// before transmitting Effects.messages. After syncing a batch, call confirm_writes_durable().
//
// Complies with Leslie Lamport's theorems:
//   - B1(b): Ballot uniqueness (round, priority, node)
//   - B2(b): Quorum intersection (read_quorum + write_quorum > total)
//   - B3(b): Max-vote preservation (highest ballot vote chosen in Phase 2a)
//   - D1:    Indelible ink durability gating
//   - L1:    Contiguous log delivery
//   - S1:    Stop signs configuration sealing

VERSION :: "0.7.0"

// Ergonomic type aliases
Node_Id     :: NodeId
Log_Slot    :: Slot
Vote_Ballot :: Ballot

// Default consensus capacity constants
DEFAULT_MAX_MEMBERS        :: 7
DEFAULT_WINDOW_SLOTS       :: 256
DEFAULT_CHUNK_SLOTS        :: 64
DEFAULT_MAX_METADATA_BYTES :: 256

// Determines bitwise value equality for arbitrary payload types without requiring == operator.
values_equal :: proc(a, b: $T) -> bool {
	var_a := a
	var_b := b
	return mem.compare_ptrs(&var_a, &var_b, size_of(T)) == 0
}

// -------------------------------------------------------------
// Unified Idiomatic API Overloads and Aliases
// -------------------------------------------------------------

// Overloaded initialization procedure group for Node, Effects, Membership, Log, and Learner.
init :: proc{
	node_init,
	effects_init,
	membership_init,
	replicated_log_init,
	learner_init,
	stop_sign_init,
}

// Core Consensus Operations
campaign                     :: node_campaign
set_campaign_enabled         :: node_set_campaign_enabled
is_campaign_enabled          :: node_is_campaign_enabled
propose                      :: node_propose
propose_batch                :: node_propose_batch
step                         :: node_step
tick                         :: node_tick
reconnected                  :: node_reconnected
request_catch_up             :: node_request_catch_up
learn_chosen                 :: node_learn_chosen

// State Restoration & Trimming
restore                      :: node_restore
restore_with_priority        :: node_restore_with_priority
restore_at                   :: node_restore_at
continue_at                  :: node_continue_at
begin_recovery               :: node_begin_recovery
restore_learner              :: node_restore_learner
advance_memory_floor         :: node_advance_memory_floor
install_chosen_trim          :: node_install_chosen_trim
trim_anchor                  :: node_trim_anchor
memory_floor                 :: node_memory_floor

// Node Queries & State Inspection
current_leader               :: node_current_leader
decided_through              :: node_decided_through
leader_base                  :: node_leader_base
proposal_frontier            :: node_proposal_frontier
committed_at                 :: node_committed_at
read_decided                 :: node_read_decided
is_leader_caught_up          :: node_is_leader_caught_up
role                         :: node_role
ballot                       :: node_ballot
id                           :: node_id
is_voting_member             :: node_is_voting_member
durable_state                :: node_durable_state

// Effects Inspection & Durability Enforcement
confirm_writes_durable       :: effects_confirm_writes_durable
writes_slice                 :: effects_writes_slice
messages_slice               :: effects_messages_slice
committed_slice              :: effects_committed_slice
requests_slice               :: effects_requests_slice
requires_power_loss_barrier  :: effects_requires_power_loss_barrier
pre_durable_messages         :: effects_pre_durable_messages
reset                        :: proc{effects_reset}

// Replicated Command Log Operations
log_init                     :: replicated_log_init
log_init_learner             :: replicated_log_init_learner
log_init_from_stop           :: replicated_log_init_from_stop
log_continue_at              :: replicated_log_continue_at
log_restore                  :: replicated_log_restore
log_restore_with_priority    :: replicated_log_restore_with_priority
log_restore_at               :: replicated_log_restore_at
log_restore_learner          :: replicated_log_restore_learner
log_begin_recovery           :: replicated_log_begin_recovery
log_is_sealed                :: replicated_log_is_sealed
log_stop_sign                :: replicated_log_stop_sign
log_stop_slot                :: replicated_log_stop_slot
log_pending_stop_sign        :: replicated_log_pending_stop_sign
log_propose                  :: replicated_log_propose
log_propose_batch            :: replicated_log_propose_batch
log_propose_stop_sign        :: replicated_log_propose_stop_sign
log_reconfigure              :: replicated_log_reconfigure
log_campaign                 :: replicated_log_campaign
log_tick                     :: replicated_log_tick
log_step                     :: replicated_log_step
log_read                     :: replicated_log_read
log_decided_through          :: replicated_log_decided_through
log_leader_base              :: replicated_log_leader_base
log_proposal_frontier        :: replicated_log_proposal_frontier
log_advance_memory_floor     :: replicated_log_advance_memory_floor
log_memory_floor             :: replicated_log_memory_floor
log_install_chosen_trim      :: replicated_log_install_chosen_trim
log_trim_anchor              :: replicated_log_trim_anchor
log_current_leader           :: replicated_log_current_leader
log_configuration_id         :: replicated_log_configuration_id
log_is_reconfigured          :: replicated_log_is_reconfigured

// Learner Operations
learner_step                 :: learner_learn_chosen
learner_read                 :: learner_read_chosen
learner_get                  :: learner_chosen_at
