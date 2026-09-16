# paxos-odin

[English](README.md) · 한국어

`paxos-odin`은 **Odin** 프로그래밍 언어로 구현된 순수하고 결정론적(deterministic)이며 경계가 정의된(bounded) Classic 및 Multi-Paxos 분산 합의 엔진입니다.

[`paxos-zig`](https://github.com/insanai/paxos-zig)의 엄격한 검증 원칙을 계승하여, 운영체제 리소스(소켓, 스레드, 시스템 시계)나 힙 동적 할당 없이 완전히 순수한 상태 기계(pure state machine)로 동작합니다. 프로젝트 문서화, Typst 기반 명세서 파이프라인, RFC 시스템은 [`zenfmt`](https://github.com/insanai/zenfmt)의 구조를 모델로 삼았으며, ZDS(Zen Discussion Series)를 **POD**(**Paxos Odin Discussions**)로 명명하여 운영합니다.

**현재 릴리스는 0.1.0입니다.** 핵심 아키텍처는 [POD 0002](docs/pod/records/0002-paxos-odin-architecture.typ)에, 내구성 계약 및 윈도우 트리밍은 [POD 0003](docs/pod/records/0003-durability-and-trimming.typ)에, RFC 프로세스는 [POD 0001](docs/pod/records/0001-pod-process.typ)에 상세히 명세되어 있습니다. (POD는 설계 기록이므로 영어로 작성 및 유지됩니다.)

---

## 핵심 아키텍처 원칙

1. **명시적 부수효과를 가진 순수 상태 기계 (Pure State Machine with Explicit Effects):**
   합의 노드는 어떠한 I/O 리소스도 직접 소유하지 않습니다. 모든 상태 전이(`step`, `propose`, `tick`, `reconnected`)는 호출자가 제공한 `Effects` 구조체에 결과를 기록합니다:
   - `writes`: 안정 저장소(디스크)에 반드시 영속화해야 하는 상태 델타(`Promise`, `Accept`, `Commit`, `TrimAnchor`).
   - `messages`: 피어 노드로 전송해야 할 아웃바운드 메시지(`Envelope`).
   - `committed`: 합의가 완료되어 호스트 상태 기계로 전달되는 연속적인 값들의 스트림.
   - `requests`: 메모리 윈도우 바닥 아래로 트리밍된 로그 구간에 대한 저널 복구 요청.

2. **런타임 강제 내구성 계약 (Runtime-Enforced Durability Contract):**
   Paxos의 근본 안전성 불변식:
   > **동일한 상태 전이에서 생성된 네트워크 메시지를 송신하기 전에, 모든 상태 쓰기(write)를 먼저 영속화해야 한다.**

   `paxos-odin`은 이 계약을 런타임에 엄격하게 검증합니다. 미확인 쓰기가 남아있는 상태에서 `messages_slice`를 호출하거나 상태 전이를 재진입하면, Elm 스타일의 상세 진단 리포트를 출력하며 즉시 중단(panic)됩니다. 파이프라이닝된 Phase 2 제안을 위해 검증된 `pre_durable_messages` 반복자도 제공합니다.

3. **제로 동적 할당 (Zero Dynamic Allocations):**
   모든 주요 구조체(`Node`, `Effects`, `Replicated_Log_Node`, `Learner`)는 컴파일 타임 상수(`MAX_MEMBERS`, `WINDOW_SLOTS`, `CHUNK_SLOTS`)를 기반으로 정적 배열과 비트셋(`Member_Set`, `Slot_Set`)을 사용하여 $O(1)$ 정족수 연산과 슬롯 추적을 수행합니다. 가비지 컬렉션이나 런타임 OOM(Out Of Memory)이 원천 배제됩니다.

4. **Stop Sign 기반 복제 로그 (Replicated Log with Stop Signs):**
   동적 멤버십 변경과 스냅샷을 위해 Lamport의 Stop Sign 규율을 지원합니다. 슬롯 $S$에 Stop Sign이 제안되면 해당 슬롯에서 로그가 봉인(sealed)되며, 새로운 에포크가 시작되기 전까지 추가 제안이 안전하게 거부됩니다.

5. **연속 보장 비투표 러너 (Contiguous-Only Non-Voting Learner):**
   비동기 슬라이딩 링 버퍼 윈도우(`MAX_ENTRIES`)와 갭 버퍼링을 갖추고 있어, 결정된 항목을 빈틈없이(strictly contiguous) 소비자에게 안전하게 전달합니다.

---

## 빠른 시작 (Quickstart)

### 요구 사양
- [Odin 컴파일러](https://odin-lang.org/) (`dev-2026-09` 이상)
- C 링커 / LLVM (`clang` 및 `lld`)
- [Typst](https://typst.app/) (`0.13.0` 이상, 명세서 PDF 빌드용)

### 빌드 및 CLI 준비
부트스트랩 스크립트를 실행하여 관리 CLI를 빌드합니다:

```sh
./build.sh
```

또는 `make` 사용:
```sh
make build
```

빌드된 실행 파일은 `bin/paxos-cli`에 생성됩니다.

---

## CLI 도구 사용법 (`paxos-cli`)

`paxos-cli`는 빌드, 테스트, 시뮬레이션, 벤치마크 및 Typst 명세서 관리를 위한 단일 인터페이스를 제공합니다:

```sh
# 모든 타깃 빌드 (cli, sim, bench)
./bin/paxos-cli build all

# 전체 단위 테스트 실행 (15개 테스트, 1ms 미만 소요)
./bin/paxos-cli test

# 결정론적 카오스 시뮬레이터 실행 (패킷 유실, 중복, 크래시, 네트워크 분할)
./bin/paxos-cli sim --seed=42 --steps=1024 --nodes=3

# 인메모리 합의 성능 벤치마크 실행
./bin/paxos-cli bench

# Typst 명세서 및 POD RFC 전체 PDF 컴파일
./bin/paxos-cli docs all

# Paxos Odin Discussions (POD) 관리
./bin/paxos-cli pod list
./bin/paxos-cli pod new fast-path-leases
./bin/paxos-cli pod promote fast-path-leases
```

---

## 인메모리 벤치마크 결과

`./bin/paxos-cli bench` 명령으로 순수 메모리 상태 기계 환경(3개 노드, I/O 없음)에서 측정한 성능 지표:

```
================================================================================
  PAXOS-ODIN IN-MEMORY WORKLOAD BENCHMARK
  Cluster: 3 nodes | Pure State Machine (Zero-I/O, In-Memory)
  Iterations: 10000 per mode
================================================================================
Mode                      Throughput         Latency / Op      Iterations
--------------------------------------------------------------------------------
Synchronous              1,494,926 ops/s        668.9 ns            10,000
Pipelined (16)             567,952 ops/s      1,760.7 ns            10,000
Batched (16)               500,606 ops/s      1,997.6 ns            10,000
================================================================================
```

---

## 결정론적 카오스 시뮬레이터

카오스 시뮬레이터(`sim/`)는 가혹한 결함 환경에서 클러스터의 불변식을 검증합니다:
- **SplitMix64 결정론적 난수 생성기**: `--seed=<N>` 인자로 100% 재현 가능한 실행 지원.
- **결함 주입 매트릭스**:
  - 비대칭 네트워크 분할 (도달 가능성 매트릭스 동적 전환).
  - 패킷 유실 및 중복 전송.
  - 임의 노드 충돌(crash) 및 재부팅 후 저널 재생 복구.
- **전역 안전성 오라클 (Safety Oracle)**:
  - 매 스텝마다 서로 다른 두 노드가 동일한 슬롯에 대해 서로 다른 값을 결정하지 않았는지 단언.
  - 최종 정온 상태(quiescence) 도달 시 모든 정상 노드가 동일한 로그로 수렴했는지 확인.

```sh
# 시드 1337로 1024 스텝 카오스 시뮬레이션 실행
./bin/paxos-cli sim --seed=1337 --steps=1024 --nodes=5
```

---

## Typst 명세서 및 문서화 파이프라인

모든 기술 사양은 [Typst](https://typst.app/)로 작성되어 학술 논문 수준의 조판과 수학적 정의, 시퀀스 다이어그램을 제공합니다.

### 문서 구조
- `docs/book.typ`: Paxos-Odin 종합 사양서 책:
  - 제1장: 개요 및 빠른 둘러보기
  - 제2장: Multi-Paxos 프로토콜 및 상태 전이
  - 제3장: 내구성 불변식 및 호스트 경계
  - 제4장: 복제 커맨드 로그 및 Stop Sign
  - 제5장: 러너 링 버퍼 및 갭 복구
  - 제6장: 윈도우 트리밍 및 가비지 컬렉션
  - 제7장: 결정론적 카오스 시뮬레이션
- `docs/pod/`: **Paxos Odin Discussions** (RFC 프로세스):
  - [POD 0001](docs/pod/records/0001-pod-process.typ): POD 프로세스 및 번호 부여 규칙
  - [POD 0002](docs/pod/records/0002-paxos-odin-architecture.typ): 순수 상태 기계 아키텍처
  - [POD 0003](docs/pod/records/0003-durability-and-trimming.typ): 내구성 계약 및 윈도우 트리밍
  - [POD 0004](docs/pod/records/0004-fast-path-leases.typ): 패스트 패스 리더 리스
- `docs/pod/registry.typ`: 전체 POD 제안서의 메타데이터 레지스트리.

### 문서 컴파일
```sh
./bin/paxos-cli docs all

# docs/build/ 디렉토리에 PDF 생성:
#   docs/build/paxos-spec.pdf
#   docs/build/pod-index.pdf
#   docs/build/pod-0001-pod-process.pdf
#   docs/build/pod-0002-paxos-odin-architecture.pdf
#   docs/build/pod-0003-durability-and-trimming.pdf
#   docs/build/pod-0004-fast-path-leases.pdf
```

---

## 프로젝트 디렉토리 구조

```
paxos-odin/
├── README.md               # 영문 개요 및 매뉴얼
├── README.ko.md            # 한국어 개요 및 매뉴얼
├── LICENSE                 # MIT 라이선스
├── Makefile                # make 명령어 정의
├── build.sh                # 부트스트랩 스크립트
├── src/                    # 핵심 라이브러리 패키지
│   ├── paxos.odin          # 패키지 루트 및 버전 상수
│   ├── bit_set.odin        # 제로 힙 비트셋 구현
│   ├── protocol.odin       # Multi-Paxos 상태 기계 및 전이 로직
│   ├── replicated_log.odin # 복제 로그, Stop Sign, 에포크 봉인
│   ├── learner.odin        # 연속성 보장 비투표 러너 윈도우
│   ├── host_managed.odin   # 호스트 관리 내구성 우회 모드
│   └── errors.odin         # Elm 스타일 진단 및 복구 힌트
├── cli/                    # 툴체인 CLI 구현
│   └── main.odin           # CLI 엔트리포인트
├── tests/                  # 단위 테스트 스위트
│   ├── test_protocol.odin  # 정족수 및 합의 상태 전이 테스트
│   ├── test_durability.odin# 내구성 안전성 계약 검증 테스트
│   ├── test_replicated_log.odin # 멤버십 변경 및 Stop Sign 테스트
│   ├── test_learner.odin   # 러너 갭 버퍼링 테스트
│   ├── test_bit_set.odin   # 비트셋 기본 테스트
│   └── test_errors.odin    # Elm 진단 출력 테스트
├── sim/                    # 결정론적 카오스 시뮬레이터
│   ├── main.odin           # 시뮬레이터 실행기
│   └── simulation.odin     # 결함 주입 매트릭스 및 오라클 검증
├── bench/                  # 인메모리 성능 벤치마크
│   └── main.odin           # 동기, 파이프라인, 배치 워크로드
└── docs/                   # 문서 및 Typst 명세서 스위트
    ├── book.typ            # 명세서 루트 문서
    ├── book/               # 개별 장별 명세
    ├── shared/             # 공유 스타일 및 테마
    └── pod/                # Paxos Odin Discussions (RFC 레코드 및 레지스트리)
```

---

## 라이선스

이 프로젝트는 MIT 라이선스에 따라 라이선스가 부여됩니다 — 자세한 내용은 [LICENSE](LICENSE) 파일을 참조하세요.
