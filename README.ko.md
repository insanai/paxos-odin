# paxos-odin

I/O를 전혀 하지 않는 Paxos 라이브러리. Odin으로 작성되었습니다.

[English](README.md) · 한국어

## 문제, 그리고 요령

세 대의 컴퓨터가 하나의 목록을, 같은 순서로, 영원히 유지해야 합니다. 어느 컴퓨터든
죽었다가 다시 살아날 수 있고, 그 사이의 네트워크는 메시지를 잃어버리거나, 중복하거나,
지연시키거나, 순서를 뒤바꿀 수 있습니다. 이것이 Paxos가 푸는 문제이고, 이
라이브러리가 하는 일의 전부입니다.

요령은 라이브러리가 아무것도 소유하지 않는다는 점입니다. 소켓도, 스레드도, 시계도,
파일도 없습니다. `Node`는 여러분의 메모리에 있는 하나의 값입니다. 메시지나 tick,
제안(proposal)을 건네주면 `Effects` 배치를 돌려줍니다: 영속화해야 할 레코드,
보내야 할 envelope, 방금 결정된 항목, 그리고 피어가 요청한 과거 이력. I/O는
여러분의 프로그램이 합니다.

노드 내부에서는 decree(교서)마다 Lamport의 세 변수(promise, 투표의 ballot, 투표의
value)가 고정된 윈도우 위의 병렬 배열에 저장되며, 사용 중인 슬롯과 결정된 슬롯을
위한 비트맵이 함께 있습니다. ballot은 64비트 정수 하나입니다. 값은 밖으로 나갈 때
절대 복사되지 않습니다: 레코드나 메시지는 장부(ledger) 안의 값을 가리키고,
직렬화할 때 호스트가 그 값을 복사합니다.

규칙은 하나입니다. **한 배치의 모든 write를 영속화한 뒤에야 같은 배치의 메시지를
전송하고**, 그 다음 `confirm_writes_durable`를 호출합니다. 확인 전에 메시지를
읽거나, 확인되지 않은 write가 남아 있는 배치를 리셋하면, 위반 내용과 고치는 방법을
적은 진단 메시지를 출력하고 프로세스가 정지합니다. 이 게이트는 기본으로 켜져
있으며, 아래의 네 가지 규칙에 대해 감사(audit)를 마친 호스트만 끌 수 있습니다.

## 요약

- Classic(단일 결정)과 안정 리더 및 청크 단위 복구를 갖춘 Multi-Paxos.
- 옵션으로 순환 슬롯 소유(rotating slot ownership): 각 멤버가 1단계 없이 자신의
  슬롯에 제안하고, 유휴 소유자는 건너뛰며, 크래시한 소유자는 취소(revocation)되고,
  취소된 값은 재제출됩니다(Mencius를 따르되, Synod의 ballot 규칙 위에서).
- Odin `dev-2026-09`용으로 작성. 의존성은 `base:`와 `core:`뿐.
- 전이(transition) 중 할당도 값 복사도 없습니다. 모든 용량은 컴파일 타임
  매개변수이며, 내구성 상태는 배열의 구조체(struct of arrays)입니다.
- 크래시와 재시작, 메시지 유실, 중복, 지연, 재정렬을 견딤. 비잔틴 장애는 다루지 않음.
- 최대 65,535개 멤버; 2의 거듭제곱이면 어떤 크기든 되는 윈도우; 1,024 투표자
  정족수까지 테스트됨.
- 책에 실린 안전성 논증: 공리, 16개의 보조정리(lemma), 그리고 합의 정리(agreement
  theorem). 각 보조정리는 그것을 충족시키는 프로시저를 명시합니다(POD 0008).
- 재구성 가능한 복제 로그: 정지 표지(stop sign)가 하나의 구성(configuration)을
  봉인하고, 구성 검사 envelope이 이전 구성의 트래픽을 거부.
- 비투표 learner: `Node`로도, 연속 릴리스만 하는 작은 `Learner`로도 제공.
- 모든 오류 값이 스스로를 설명함: `explain_error`가 제목, 원인, 힌트를 돌려줌.

## 가져오기

저장소를 복사하거나 서브모듈로 두고 `src` 패키지를 경로로 import 합니다:

```odin
import paxos "path/to/paxos-odin/src"
```

또는 빌드 시 컬렉션으로 등록하고 이름으로 import 합니다:

```sh
odin build . -collection:paxos=path/to/paxos-odin
```

```odin
import paxos "paxos:src"
```

요구 사항: 라이브러리와 도구에는 Odin `dev-2026-09` 이상; 책과 POD 빌드에는
Typst 0.15; `make check`에는 Python 3.

## API 맛보기

`Node`와 `Effects`는 같은 매개변수로 선언합니다: 값 타입, 멤버 용량, 윈도우
크기(2의 거듭제곱), 복구 청크입니다. 매개변수가 다르면 컴파일러가 거부합니다.
`Effects`의 제로 값은 바로 사용할 수 있습니다.

```odin
package main

import "core:fmt"
import paxos "../src"

Command :: struct {
	client_id:  u32,
	request_id: u32,
	amount:     i64,
}

// Node와 Effects는 같은 매개변수로 선언해야 한다.
Node    :: paxos.Node(Command, 3, 64, 16)
Effects :: paxos.Effects(Command, 3, 64, 16)

// 호스트 루프: 영속화, 확인, 전송, 적용.
host_commit :: proc(effects: ^Effects) {
	for w in paxos.writes_slice(effects) {
		_ = w // 저널에 append; 투표나 결정이 그 값을 가리킴
	}
	// 여기서 저널을 fsync
	paxos.confirm_writes_durable(effects)
	for envelope in paxos.messages_slice(effects) {
		_ = envelope // 전송 계층에 넘김
	}
	for entry in paxos.committed_slice(effects) {
		_ = entry.value^ // 슬롯 순서대로 적용; 포인터는 다음 전이 전까지 유효함
	}
	for request in paxos.requests_slice(effects) {
		_ = request // 트림된 이력을 호스트 저널에서 제공
	}
}

main :: proc() {
	membership: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	assert(paxos.init(&membership, ids[:]) == .None)

	node: Node
	assert(paxos.init(&node, 1, membership) == .None)
	// 또는 동점 처리용 priority를 주어:
	assert(paxos.init(&node, 1, membership, paxos.Node_Options{priority = 1}) == .None)

	effects: Effects
	noop := Command{}
	assert(paxos.campaign(&node, noop, &effects) == .None)
	host_commit(&effects)

	// 전송 계층이 이 노드 앞으로 디코딩한 envelope마다:
	envelope: paxos.Envelope(Command)
	if err := paxos.step(&node, envelope, &effects); err != .None {
		fmt.eprintln(paxos.explain_error(err))
	}
	host_commit(&effects)

	// 노드가 리더가 되면 제안한다. 슬롯이 오류와 함께 반환된다.
	slot, err := paxos.propose(&node, Command{client_id = 1, request_id = 7, amount = 10}, &effects)
	if err != .None {
		fmt.eprintln(paxos.explain_error(err))
	}
	host_commit(&effects)
	fmt.println("proposed in slot", slot)

	// 호스트 tick마다 논리 시계를 한 번 전진시킨다.
	assert(paxos.tick(&node, noop, &effects) == .None)
	host_commit(&effects)
}
```

`paxos.init`, `paxos.campaign`, `paxos.propose`, `paxos.step`, `paxos.tick`은
수신자 타입에 따라 디스패치되는 proc group입니다. 긴 이름(`node_propose`,
`replicated_log_propose`, `learner_learn_chosen`)도 그대로 쓸 수 있습니다.
레코드와 envelope은 노드의 장부(ledger) 안에 있는 값을 가리키며 그 노드의 다음
전이 전까지 유효합니다. 프로세스 내 전송 계층은 envelope을 큐에 넣을 때, 코덱이
하듯이 그 값을 복사합니다(예제의 `Packet` 타입처럼). 이 루프의 완전한 실행 가능
버전이 [`examples/counter.odin`](examples/counter.odin)이며, 출력은 다음과
같습니다:

```
$ odin run examples/counter.odin -file
node 1 is the leader
proposed request 101 in slot 1
slot 1: +10 -> counter = 10
proposed request 102 in slot 2
slot 2: +25 -> counter = 35
proposed request 201 in slot 3
slot 3: -5 -> counter = 30
counter = 30 on all 3 nodes
```

순환 슬롯 소유(rotating slot ownership)를 쓰면 캠페인(campaign)이 없습니다:
각 노드가 자신이 소유한 슬롯에 제안하고, 클러스터가 그것들을 동시에 결정합니다.

```odin
owners: [3]Node
for &node, i in owners {
	assert(paxos.init(&node, paxos.Node_Id(i + 1), membership,
		paxos.Node_Options{rotating_ownership = true}) == .None)
}
slot, err := paxos.propose(&owners[1], Command{amount = 5}, &effects) // 노드 2는 슬롯 2, 5, 8, ...을 소유
```

복제 로그는 값 타입이 `Entry`인 `Node`를 감쌉니다. `Entry`는 명령이거나, 현재
구성을 봉인하고 다음 구성을 지명하는 정지 표지(stop sign)입니다.

```odin
Log         :: paxos.Replicated_Log_Node(Command, 3, 64, 16)
Entry       :: paxos.Entry(Command, 3)
Log_Effects :: paxos.Effects(Entry, 3, 64, 16)

log: Log
effects: Log_Effects
assert(paxos.init(&log, 1, 1, membership) == .None)     // 노드 1, 구성 1
assert(paxos.campaign(&log, Command{}, &effects) == .None)

// 구성 1을 봉인하고 구성 2를 지명한다.
next := [3]paxos.Node_Id{1, 2, 4}
if _, err := paxos.log_reconfigure(&log, 2, next[:], nil, &effects); err != .None {
	fmt.eprintln(paxos.explain_error(err))
}

// 나가는 메시지에는 구성 id를 찍고, 들어오는 메시지는 검사한다.
for m in paxos.messages_slice(&effects) {
	stamped := paxos.log_envelope(&log, m)
	_ = paxos.log_step(&log, stamped, &effects)   // 오래된 메시지면 .Configuration_Mismatch
}

// 정지 표지가 결정되면 다음 구성은 stop_slot + 1에서 시작한다.
if stop, decided := paxos.log_stop_sign(&log); decided {
	next_log: Log
	_ = paxos.log_init_from_stop(&next_log, 1, stop, paxos.log_stop_slot(&log), paxos.log_trim_anchor(&log))
}
```

여러 전이를 하나의 스토리지 배리어 뒤로 묶는 호스트는 `Node`와 `Effects`를 다섯
번째 매개변수 `.Host_Managed`로 선언하여 런타임 게이트를 끌 수 있습니다. 이는
모드가 아니라 감사를 거친 예외입니다. 그런 호스트는 구조적으로 다음을 보장해야
합니다:

1. 한 전이의 모든 write는 그 전이의 어떤 메시지가 피어에 도달하기 전에 내구성을 가진다;
2. 확인되지 않은 write를 담고 있는 배치는 절대 버리지 않는다;
3. 커밋된 항목은 커밋 레코드가 내구성을 가진 뒤에만 적용한다;
4. write와 배리어 사이의 크래시는 저널에서 복구하며, 완료되지 않은 write를 확인
   처리하는 방식으로 넘기지 않는다.

전체 API 레퍼런스는 책의 Part VII입니다. `make docs`를 실행한 뒤
`docs/build/paxos-spec.pdf`를 여세요.

## 동작한다는 것을 어떻게 아는가

**안전성 논증(safety argument).** 책은 모델을 공리로 서술하고 Lamport의
B1–B3로부터 합의(agreement)를 증명한 다음, 청크 단위 복구, 경계 지어진 윈도우,
내구성 순서, 순환 슬롯 소유, 정지 표지가 각각 그 정리를 보존함을 증명합니다.
모든 보조정리는 자신의 전제를 충족시키는 프로시저와, 그것을 실행하는 테스트 또는
오라클을 명시합니다(POD 0008).

**테스트.** `make test`는 `tests/`의 69개 테스트를 실행합니다. 여기에는 972건의
선출 매트릭스(세 투표자에 대한 무투표 / ballot 1 / ballot 2의 모든 배정, 모든
첫 응답 순서, 교차하는 모든 정족수 쌍; 이전 정족수가 고른 값은 살아남아야 함),
POD 0007에 기록된 리뷰에서 나온 21개의 회귀 테스트, 5개의 순환 슬롯 소유
시나리오(동시 소유자, 건너뛰기, 크래시한 소유자의 취소, 발견한 투표를 유지하는
취소, 재제출), 그리고 유실·중복·재정렬 결함의 16개 시드 각각으로 실행되는 4개의
재구성 시나리오(그중 하나는 순환 슬롯 소유 아래)가 포함됩니다.

**시뮬레이터.** `sim/`은 하나의 시드로 1~5개의 투표자를 구동합니다. 리더가 하나인
방식으로, 또는 `--ownership` 아래에서는 모든 노드가 자신의 슬롯에 제안하는
방식으로 동작합니다. 각 스텝은 큐에 있는 임의의 envelope을 전달하거나, 노드를
tick 하거나, 제안(때로는 배치)을 하거나, 링크를 끊거나 복구하거나, (읽기 정족수는
살려 둔 채) 노드를 크래시시키거나, 재생한 저널로부터 노드를 재시작하거나,
재연결을 보고합니다. 크래시는 호스트 커밋 시퀀스 안의 세 지점에 떨어질 수
있습니다: write 이전, write의 일부 접두 이후, 모든 write와 메시지의 일부 접두
이후. 오라클은 모든 전이 뒤에 실행됩니다: 합의(슬롯당 하나의 값, 첫 내구성
정족수가 확정), 유효성(제안된 값 또는 no-op만), promise 역행 없음, promise
아래로의 투표 없음, ballot과 슬롯당 하나의 값, 연속 릴리스. 결함 단계가 끝나면
하네스는 모든 링크를 복구하고 모든 노드를 재시작한 뒤, 새 제안이 결정되고 모든
노드가 golden 로그 전체를 갖고 있기를 요구합니다. 실패 시 재생 명령을
출력합니다: `paxos-sim --seed=N --steps=N --nodes=N --verbose`. 커밋 수준이
아니라 투표 수준에서 합의를 검사하는 이 하네스가 재설계 과정의 유일한 안전성
버그를 찾아냈습니다: 소유자의 round-zero accept가 스토리지 배리어보다 먼저
나가서, 재시작한 소유자가 새 값에 자신의 ballot을 재사용하는 문제였습니다. 이제
round-zero accept는 배리어를 기다립니다.

**계약 픽스처.** `tools/check_contracts.py`는 거부되어야 하는 아홉 개의
프로그램(윈도우 0, 2의 거듭제곱이 아닌 윈도우, 청크 0, 윈도우보다 큰 청크, 멤버
0, 멤버 65,536개, learner 윈도우 0, 비교 불가능한 값 타입, `Node`와 다른
`Effects` 매개변수)을 컴파일하고 각 진단에 힌트가 있는지 확인합니다. 그런 다음
네 개의 내구성 픽스처를 `-debug`와 `-o:speed` 양쪽으로 빌드하여, 두 오용은
지정된 진단과 함께 중단되고 두 올바른 순서는 실행되는지 확인합니다.

**`make check`.** 스타일(POD 0001의 Zen 제약, `-vet -strict-style`), `-debug`와
`-o:speed`의 테스트, 계약 픽스처, 10,000 스텝짜리 시뮬레이션 120회(1, 3, 5 노드
× 20 시드 × 두 모드; `--seeds`와 `--steps`로 확대), counter 예제, 벤치마크 JSON
스키마, 그리고 CLI가 실패한 하위 프로세스를 전파하는지를 검사합니다. 모든 것은
임시 디렉터리에서 빌드되므로 오래된 바이너리가 실패를 가릴 수 없습니다.

이 저장소에는 모델 검사된 명세가 없습니다. 증거는 유한하고 실행 가능한 것이지,
전수 탐색이 아닙니다.

## 벤치마크

네 가지 구현이 이 머신에서 한 세션 동안, 하나씩 차례로 같은 워크로드를
실행했습니다: 이 라이브러리, [paxos-zig](https://github.com/insanai/paxos-zig)
0.7.0, [OmniPaxos](https://github.com/haraldng/omnipaxos) 0.2.2(Rust),
[LibPaxos3](https://bitbucket.org/sciascid/libpaxos)(C). `make bench-compare`가
이들을 실행하고 하나의 귀속 가능한 결과 파일을 기록합니다; 아래 표는 손으로
입력한 것이 아니라 그 파일에서 읽은 값입니다.

호스트: AMD Ryzen 7 5800H with Radeon Graphics, Linux 7.0.0-28-generic, odin version dev-2026-09-nightly:a2fb372, zig 0.16.0, rustc 1.98.1 (48a229cea 2026-09-01); Odin 빌드 옵션 `-o:speed -no-bounds-check -microarch:native`; `bench/results/latest.json`에 2026-09-16T23:53:16Z 기록.

커밋된 값 하나당 나노초, 인프로세스 전송, 직렬화 없음, 반복 표본의 중앙값 (낮을수록 좋음):

| 워크로드 | paxos-odin | paxos-zig | OmniPaxos | LibPaxos3 |
|---|---:|---:|---:|---:|
| 3 투표자, 8 B, 한 번에 하나 | 148 | 113 | 1,010 | 2,280 |
| 3 투표자, 8 B, 8개 동시 진행 | 144 | 115 | 198 | – |
| 3 투표자, 8 B, 64개 동시 진행 | 141 | 113 | 83 | – |
| 5 투표자, 8 B, 한 번에 하나 | 191 | 219 | 2,721 | – |
| 5 투표자, 8 B, 8개 동시 진행 | 182 | 210 | 446 | – |
| 3 투표자, 1 KiB, 한 번에 하나 | 505 | 2,719 | 1,244 | – |
| 3 투표자, 1 KiB, 8개 동시 진행 | 552 | 2,707 | 423 | – |
| 3 소유자, 8 B, 한 번에 하나, 순환 슬롯 소유 | 161 | – | – | – |
| 3 소유자, 8 B, 8개 동시 진행, 순환 슬롯 소유 | 154 | – | – | – |

노드마다 저널 파일을 두고 호스트 커밋 라운드마다 저장 장벽(`fsync`)을 두면
(같은 ZFS 볼륨):

| 라이브러리 | 모드 | 값당 | 값당 fsync |
|---|---|---:|---:|
| paxos-odin | 커밋 라운드마다 fsync, 값 하나 | 27.49 ms | 6.00 |
| paxos-odin | 커밋 라운드마다 fsync, 값 8개 | 3.71 ms | 0.75 |
| paxos-zig | fsync-each | 27.54 ms | – |
| paxos-zig | group8 | 3.53 ms | – |

있는 그대로 읽어야 합니다. 3 투표자, 8바이트 값에서는 paxos-zig가 값당 20%에서
30% 더 저렴하고, 5 투표자에서는 이 라이브러리가 약 10% 더 저렴하며, 1 KiB
값에서는 이 라이브러리가 값당 다섯 배 이상 더 저렴합니다. 값이 제안과 커밋 사이에 절대 복사되지 않기 때문입니다: 레코드와
메시지는 장부(ledger) 안의 그 한 사본을 가리킵니다. 순환 슬롯 소유는 같은 세
노드에서 단일 리더와 값당 비용 차이가 10분의 1 이내이며, 그 대가로 모든 노드가
리더로의 왕복 없이 제안할 수 있습니다. OmniPaxos는 한 번에
하나씩 처리하는 모드에서 할당과 잠금 비용을 치르며, 두 행에서만 앞섭니다:
동시에 64개를 처리할 때와 1 KiB 값을 8개 동시에 처리할 때로, 이때 많은 항목을
적은 수의 envelope으로 묶기 때문입니다. 이
라이브러리와 paxos-zig는 항상 값마다 envelope 하나를 보냅니다. LibPaxos3는
1단계 사전 실행이 포함된 더 무거운 12-envelope 경로를 실행합니다. 이 수치들 중
어느 것도 서비스 지연 시간이 아니며, 내구성 행들은 비용이 프로토콜이 아니라
디스크에서 나온다는 것을 보여줍니다: `fsync`가 경로에 들어가면 경계가 있는 두
라이브러리는 서로 몇 퍼센트 차이로 수렴합니다.

```sh
make bench                                   # 이 라이브러리, 인메모리 모드
make bench-durable                           # 저널과 fsync 모드 추가
make bench-compare                           # 네 구현 모두 실행, bench/results/ 기록
./bin/paxos-bench --iterations=N --json      # 기계 판독 가능 보고서
```

## 책과 POD

`make docs`는 `docs/book.typ`를 `docs/build/paxos-spec.pdf`로, POD 인덱스를
`docs/build/pod-index.pdf`로, 등록된 모든 POD 레코드를
`docs/build/pod-NNNN-<slug>.pdf`로 컴파일합니다.

책은 서문과 학습 방법 장, 그리고 여덟 개의 부(part)로 이루어집니다:

| 부 | 장 |
|---|---|
| I. One decision | Foundations of Consensus |
| II. The complete ballot | The Single-Decree Protocol |
| III. A sequence of decisions | Multi-Paxos Log Replication |
| III. (continued) | The Safety Argument: axioms, lemmas, and the agreement theorem |
| IV. The Odin library | Bounded Core State Machine; Advanced Replicated Log Features; Rotating Slot Ownership; Writing Reviewable Consensus Code |
| V. Three worked systems | 복제 카운터, 키-값 호스트 설계, 다중 리전 배치 |
| VI. Evidence | Validation, Testing, and Operations |
| VII. Desk reference | Consensus Desk Reference |
| VIII. Conformance | Lamport Conformance Appendix |

Paxos Odin Discussions(POD)는 설계 기록으로, `docs/pod/records/` 아래에 Typst
파일 하나씩 있습니다. 목록의 원본은 `docs/pod/registry.typ`이며, 이 글을 쓰는
시점에는 다음이 등록되어 있습니다:

| POD | 제목 | 상태 |
|---|---|---|
| 0001 | The Paxos Odin Discussion Process | committed |
| 0002 | Paxos-Odin: Architecture and Pure State Machine Design | committed |
| 0003 | Durability Contracts, Window Reuse, and Trim Anchors | committed |
| 0004 | Fast-Path Leader Leases and Linearizable Read Verification | discussion |
| 0005 | The Idiomatic Odin API Surface | committed |
| 0006 | Reconfiguration and Epoch Isolation | committed |
| 0007 | Review Findings and Verification Evidence | committed |
| 0008 | Safety Argument: Axioms, Lemmas, and Proof Obligations | committed |
| 0009 | The Data-Oriented Ledger | committed |
| 0010 | Rotating Slot Ownership | committed |

`./bin/paxos-cli pod list`, `pod new <slug>`, `pod promote <slug>`로 레코드를
관리합니다.

## 범위와 운영 계약

- **멤버십은 `Node`마다 고정입니다.** 구성 변경은 결정된 정지 표지(stop sign)에서
  시작하는 새 `Node`(또는 `Replicated_Log_Node`)이며, 이전 것은 봉인됩니다.
- **슬롯은 절대 리셋되지 않는 전역 `u64` 값입니다.** 다음 구성은 stop 슬롯 + 1에서
  이어집니다. `Global_Slot_Exhausted`는 로그를 끝내며 절대 되감지 않습니다.
- **역압(backpressure)은 `Window_Full`입니다.** 메모리 floor 위로 열린 슬롯이
  `WINDOW_SLOTS`를 넘게 만드는 제안은 거부됩니다. 릴리스된 접두를 전달하고
  영속화한 뒤 `advance_memory_floor`를 호출하세요.
- **`committed_slice`는 복구 피드가 아닙니다.** 이번 전이에서 결정된 항목만 담습니다.
  메모리 floor 아래의 이력은 `Serve_Range_Request`에 따라 호스트의 저널이나
  이미지에서 나옵니다.
- **값은 고정 크기이며 복사가 아니라 참조됩니다.** 장부(ledger)는 윈도우 셀마다
  값을 하나씩 저장하고, 레코드·메시지·커밋된 항목은 그 값을 가리키며 그 노드의
  다음 전이 전까지 유효합니다. 그 전에 직렬화하거나 복사하세요. 값은 `==`로
  비교되므로 고정 크기 레코드나 id를 선호하세요.
- **윈도우는 2의 거듭제곱입니다.** 셀을 찾을 때 `WINDOW_SLOTS`는 나누는 것이
  아니라 마스킹되며, 컴파일러는 다른 크기를 힌트와 함께 거부합니다.
- **소유 순서는 id 오름차순입니다.** `init`이 멤버십을 정렬하므로, 호스트가 id를
  어떤 순서로 나열했든 슬롯 `s`는 모든 노드에서 순위 `(s - 1) mod N`의 멤버가
  소유합니다. 정체된 접두는
  `election_timeout_ticks` 이후 취소되며, 윈도우가 가득 차면 모든 소유자에게
  역압(backpressure)이 적용됩니다.
- **노드 id는 0이 아니며 절대 재사용하지 않습니다.** 0은 센티널입니다. 하나의 id는
  클러스터의 수명 동안 하나의 내구성 저널을 가리킵니다.
- **타임아웃된 제안은 실패했다고 알 수 없습니다.** 나중에 선택될 수 있습니다. 다시
  제안하면 두 번 결정될 수 있으니, 명령에 id를 두고 애플리케이션에서 중복을
  제거하세요.
- **`is_leader_caught_up`은 lease가 아닙니다.** 리더가 물려받은 접두를 전달했다는
  뜻일 뿐입니다. 선형화 가능한 읽기에는 호스트 정족수, 읽기 배리어, 또는 올바르게
  구현된 lease가 필요하며, 이 라이브러리는 그중 어느 것도 제공하지 않습니다.

## 개발

| 명령 | 하는 일 |
|---|---|
| `make build` | `bin/paxos.o`, `bin/paxos-sim`, `bin/paxos-bench`, `bin/paxos-cli` 빌드 |
| `make test` | `odin test tests` |
| `make vet` | 모든 패키지를 `-vet -strict-style`로 `odin check` |
| `make check` | `tools/check.py`의 전체 검증 실행 |
| `make sim` | 시드 고정 시뮬레이션 1회(`--seed=42 --steps=1024`) |
| `make bench` | 인메모리 벤치마크 |
| `make bench-durable` | 저널과 커밋 라운드당 `fsync`를 포함한 벤치마크 |
| `make example` | `odin run examples/counter.odin -file` |
| `make docs` | 책과 POD 레코드를 PDF로 컴파일 |
| `make clean` | `bin/`과 `docs/build/` 제거 |

`./build.sh`는 `bin/paxos-cli`를 부트스트랩합니다. 명령은 `build
[all|lib|test|sim|bench|cli]`, `test`, `sim [--seed=N] [--steps=N] [--nodes=N]
[--verbose]`, `bench [--iterations=N] [--json] [--durable] [--journal-dir=PATH]`,
`example`, `docs [all|book|index|pod|pod-NNNN|releases|html]`, `check`,
`pod list|new|promote`입니다. `sim`은 `--ownership`도 받고, `bench`는
`--only=WORKLOAD`를 받습니다.

스타일: InsanAI를 위한 Odin의 선(Zen, POD 0001): 소프트 99열, 하드 108열, 파일당 최대 1,408줄, 프로시저 본문 최대 70줄의 로직, 탭 들여쓰기, 모든 패키지가 `-vet -strict-style`를 통과. 라이브러리는
완전히 매개변수화되어 있으므로, 본문은 그것을 인스턴스화하는 패키지를 통해
검사됩니다. 두 README와 [`CONTRIBUTING.md`](CONTRIBUTING.md)를 제외한 문서는
Typst로 작성합니다. 변경을 올리기 전에 `CONTRIBUTING.md`를 읽어 주세요.

## 디렉터리 구조

```
paxos-odin/
├── src/                     라이브러리 패키지
│   ├── paxos.odin           VERSION, 기본값, proc group, 짧은 이름
│   ├── ballot.odin          Node_Id, Slot, packed Ballot, cell_of
│   ├── bit_set.odin         Bit_Set(N): word 단위로 스캔하는 고정 비트맵
│   ├── membership.odin      정렬된 인덱스와 정족수 크기를 가진 Membership
│   ├── ledger.odin          Ledger: 열(column) 형태의 Lamport 변수; Write 레코드
│   ├── messages.odin        아홉 개의 메시지, Envelope, Committed, 호스트 요청
│   ├── effects.odin         Effects와 내구성 게이트
│   ├── node.odin            Node, Node_Options, init/restore/조회
│   ├── election.odin        1단계: 캠페인, promise, 청크 단위 복구
│   ├── consensus.odin       2단계: accept, 결정, tick, step
│   ├── ownership.odin       순환 슬롯 소유: 제안, 건너뛰기, 취소, 재제출
│   ├── replicated_log.odin  Replicated_Log_Node, Stop_Sign, Entry, Log_Envelope
│   ├── learner.odin         Learner: 인증된 결정의 연속 릴리스
│   └── errors.odin          Error와 explain_error
├── examples/counter.odin    3노드 복제 카운터
├── tests/                   69개 테스트(odin test tests)와 공유 하네스
├── sim/                     결정론적 결함 시뮬레이터(paxos-sim), 두 모드 모두
├── bench/                   인메모리 및 durable 벤치마크(paxos-bench); results/
├── cli/                     paxos-cli: build, test, sim, bench, example, check, docs, pod
├── tools/                   check.py, check_style.py, check_contracts.py, bench_compare.py
├── docs/
│   ├── book.typ, book/      책(Typst)
│   ├── pod/                 POD 레코드, 레지스트리, 인덱스, 번들, 템플릿
│   ├── shared/              Typst 테마와 POD 레이아웃
│   ├── releases/            릴리스 노트(Typst; 0.1.0.typ, 0.2.0.typ)
│   └── build/               컴파일된 PDF와 HTML
├── Makefile
├── build.sh
├── CONTRIBUTING.md
└── LICENSE
```

## 라이선스

MIT. [LICENSE](LICENSE)를 참조하세요.
