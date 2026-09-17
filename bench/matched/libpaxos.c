// Pure in-process driver for LibPaxos3 d255f8b; no event loop or storage adapter.
#include "acceptor.h"
#include "learner.h"
#include "paxos.h"
#include "proposer.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifndef PAYLOAD_WORDS
#define PAYLOAD_WORDS 1
#endif
#define W 4096
#define MAX_N 5
#define MAX_DEPTH 64
struct value { uint64_t words[PAYLOAD_WORDS]; };
static int members;
static struct value delivered_values[MAX_N][W];
static struct proposer *proposer;
static struct acceptor *acceptors[MAX_N];
static struct learner *learners[MAX_N];
static uint64_t delivered[MAX_N], messages;
static void check(int ok) {
    if (!ok) { fprintf(stderr,"Matched C driver failed. Hint: inspect protocol delivery.\n"); exit(1); }
}
static uint64_t now(void) {
    struct timespec t; check(clock_gettime(CLOCK_MONOTONIC,&t)==0);
    return (uint64_t)t.tv_sec*1000000000ULL+t.tv_nsec;
}
static void prepare(void) {
    paxos_prepare req; proposer_prepare(proposer,&req);
    for (int i=0;i<members;i++) {
        paxos_message reply={0}; paxos_prepare retry={0}; messages++;
        check(acceptor_receive_prepare(acceptors[i],&req,&reply));
        check(reply.type==PAXOS_PROMISE); messages++;
        check(!proposer_receive_promise(proposer,&reply.u.promise,&retry));
        paxos_message_destroy(&reply);
    }
}
static void drive_epoch(int depth) {
    for (uint64_t first=1;first<=W;first+=depth) {
        paxos_message replies[MAX_DEPTH][MAX_N];
        int count = (int)((W-first+1)<(uint64_t)depth ? (W-first+1):(uint64_t)depth);
        for (int j=0;j<count;j++) {
            struct value value={0}; value.words[0]=first+j;
            proposer_propose(proposer,(char*)&value,sizeof(value));
        }
        for (int j=0;j<count;j++) {
            paxos_accept req; check(proposer_accept(proposer,&req));
            for (int i=0;i<members;i++) {
                memset(&replies[j][i],0,sizeof(paxos_message)); messages++;
                check(acceptor_receive_accept(acceptors[i],&req,&replies[j][i]));
                check(replies[j][i].type==PAXOS_ACCEPTED);
            }
        }
        for (int j=0;j<count;j++) {
            for (int i=0;i<members;i++) {
                paxos_accepted *a=&replies[j][i].u.accepted;
                proposer_receive_accepted(proposer,a);
                for (int k=0;k<members;k++) { learner_receive_accepted(learners[k],a); messages++; }
                paxos_message_destroy(&replies[j][i]);
            }
            prepare(); // Native preexecution work remains inside the timed interval.
        }
        for (int k=0;k<members;k++) {
            paxos_accepted out={0};
            while (learner_deliver_next(learners[k],&out)) {
                check(delivered[k]<W && out.value.paxos_value_len==sizeof(struct value));
                memcpy(&delivered_values[k][delivered[k]++],out.value.paxos_value_val,sizeof(struct value));
                paxos_accepted_destroy(&out);
            }
        }
    }
}
__attribute__((noinline)) static void measured_epoch(int depth) { drive_epoch(depth); }
static uint64_t epoch(int depth,int warmup) {
    proposer=proposer_new(0,members); check(proposer!=NULL);
    for (int i=0;i<members;i++) {
        acceptors[i]=acceptor_new(i); learners[i]=learner_new(members);
        check(acceptors[i] && learners[i]); delivered[i]=0;
    }
    for (int i=0;i<128;i++) prepare();
    messages=0;
    uint64_t start=now();
    if (warmup) drive_epoch(depth); else measured_epoch(depth);
    uint64_t elapsed=now()-start;
    // Full ordered payload validation, not just a checksum.
    for (int k=0;k<members;k++) {
        for (uint64_t i=0;i<delivered[k];i++) {
            struct value expected={0}; expected.words[0]=i+1;
            check(memcmp(&delivered_values[k][i],&expected,sizeof(expected))==0);
        }
        check(delivered[k]==W);
        learner_free(learners[k]); acceptor_free(acceptors[k]);
    }
    proposer_free(proposer); return elapsed;
}
int main(int argc,char **argv) {
    check(argc==4); members=atoi(argv[1]); int depth=atoi(argv[2]), epochs=atoi(argv[3]);
    check((members==3 || members==5) && (depth==1 || depth==8 || depth==64) && epochs>0);
    paxos_config.verbosity=PAXOS_LOG_ERROR; epoch(depth,1);
    uint64_t ns=0,msg=0;
    for (int i=0;i<epochs;i++) { ns+=epoch(depth,0); msg+=messages; }
    printf("{\"ns_total\":%llu,\"messages\":%llu,\"values\":%d,\"validated\":true}\n",
        (unsigned long long)ns,(unsigned long long)msg,W*epochs);
}
