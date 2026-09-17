// Matched in-process driver; helpers adapted from paxos-zig's benchmark (MIT).
use omnipaxos::macros::Entry;
use omnipaxos::messages::Message;
use omnipaxos::util::LogEntry;
use omnipaxos::{ClusterConfig, OmniPaxos, OmniPaxosConfig, ServerConfig};
use omnipaxos_storage::memory_storage::MemoryStorage;
use std::collections::VecDeque;
use std::time::Instant;
#[derive(Clone, Debug, Entry, PartialEq)]
struct Value { words: [u64; WORDS] }
const WORDS: usize = match option_env!("PAYLOAD_WORDS") {
    Some(s) => { let b = s.as_bytes(); let mut n = 0; let mut i = 0;
        while i < b.len() { n = n * 10 + (b[i] - b'0') as usize; i += 1; } n }, None => 1,
};
trait Payload: omnipaxos::storage::Entry + Clone {}
impl Payload for Value {}
fn value(seq: u64) -> Value { let mut v = Value { words: [0; WORDS] }; v.words[0] = seq; v }
fn drive_epoch(nodes: &mut [OmniPaxos<Value, MemoryStorage<Value>>],
    messages: &mut VecDeque<Message<Value>>, leader: usize, depth: usize) -> u64 {
    let mut count = 0;
    for first in (1..=4096).step_by(depth) {
        for seq in first..(first + depth).min(4097) { nodes[leader].append(value(seq as u64)).unwrap(); }
        drain(nodes, messages, &mut count);
    }
    count
}
#[inline(never)]
fn measured_epoch(nodes: &mut [OmniPaxos<Value, MemoryStorage<Value>>],
    messages: &mut VecDeque<Message<Value>>, leader: usize, depth: usize) -> u64 {
    drive_epoch(nodes,messages,leader,depth)
}
fn epoch(n: u64, depth: usize, warmup: bool) -> (u128,u64) {
    let mut nodes = build_cluster::<Value>(n);
    let mut queue = VecDeque::new();
    elect_leader(&mut nodes, &mut queue);
    let leader = current_leader(&nodes);
    let start = Instant::now();
    let messages = if warmup { drive_epoch(&mut nodes, &mut queue, leader, depth) }
        else { measured_epoch(&mut nodes, &mut queue, leader, depth) };
    let ns = start.elapsed().as_nanos();
    for node in &nodes {
        let entries = node.read_decided_suffix(0).expect("missing decisions");
        assert_eq!(entries.len(),4096);
        for (i, entry) in entries.iter().enumerate() {
            match entry { LogEntry::Decided(v) => assert_eq!(v, &value(i as u64+1)),
                _ => panic!("undecided entry") }
        }
    }
    (ns,messages)
}
fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(args.len(),4,"Hint: pass members, depth, epochs");
    let n: u64 = args[1].parse().unwrap();
    let depth: usize = args[2].parse().unwrap();
    let epochs: usize = args[3].parse().unwrap();
    assert!([3,5].contains(&n) && [1,8,64].contains(&depth) && epochs > 0);
    epoch(n,depth,true);
    let (mut ns,mut messages) = (0,0);
    for _ in 0..epochs { let (t,m) = epoch(n,depth,false); ns+=t; messages+=m; }
    println!("{{\"ns_total\":{ns},\"messages\":{messages},\"values\":{},\"validated\":true}}",4096*epochs);
}
fn build_cluster<T: Payload>(node_count: u64) -> Vec<OmniPaxos<T, MemoryStorage<T>>> {
    let members: Vec<u64> = (1..=node_count).collect();
    (1..=node_count)
        .map(|pid| {
            let config = OmniPaxosConfig {
                cluster_config: ClusterConfig {
                    configuration_id: 1,
                    nodes: members.clone(),
                    ..Default::default()
                },
                server_config: ServerConfig {
                    pid,
                    election_tick_timeout: 2,
                    resend_message_tick_timeout: 10_000,
                    ..Default::default()
                },
            };
            config
                .build(MemoryStorage::default())
                .expect("invalid OmniPaxos configuration")
        })
        .collect()
}

fn elect_leader<T: Payload>(
    nodes: &mut [OmniPaxos<T, MemoryStorage<T>>],
    messages: &mut VecDeque<Message<T>>,
) {
    let mut message_count = 0;
    for _ in 0..100 {
        for node in nodes.iter_mut() {
            node.tick();
        }
        drain(nodes, messages, &mut message_count);
        if nodes.iter().all(|node| node.get_current_leader().is_some()) {
            return;
        }
    }
    panic!("leader election did not finish");
}

fn current_leader<T: Payload>(nodes: &[OmniPaxos<T, MemoryStorage<T>>]) -> usize {
    let leader = nodes[0].get_current_leader().expect("leader missing");
    assert!(
        nodes
            .iter()
            .all(|node| node.get_current_leader() == Some(leader))
    );
    (leader - 1) as usize
}

fn drain<T: Payload>(
    nodes: &mut [OmniPaxos<T, MemoryStorage<T>>],
    messages: &mut VecDeque<Message<T>>,
    message_count: &mut u64,
) {
    loop {
        for node in nodes.iter_mut() {
            for message in node.outgoing_messages() {
                messages.push_back(message);
                *message_count += 1;
            }
        }
        let Some(message) = messages.pop_front() else {
            return;
        };
        let receiver = message.get_receiver() as usize - 1;
        nodes[receiver].handle_incoming(message);
    }
}
