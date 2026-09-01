# Rudis 구현 계획 — Day by Day (하루 최대 2시간)

**전제:** 코드는 100% 직접 작성. 이 문서는 각 날의 목표·구현 방향·확인 기준만 제시한다.
**규칙:**
- 하루 2시간을 넘기지 않는다. 못 끝냈으면 다음 날로 넘긴다 — 계획은 Day 번호 기준이라 밀려도 깨지지 않는다.
- 매일 끝에 "확인 기준"을 통과시키고 커밋한다. 커밋 단위 = Day 단위.
- 막히면 코드를 받지 말고 "방향"만 질문한다 (예: "가드가 await를 못 넘는 이유가 뭐야?").

전체 흐름: **M1 에코 서버(D1–3) → M2 RESP(D4–9) → M3 저장소(D10–14) → M4 만료(D15–18) → M5 마무리(D19–22)**

---

## M1. 에코 서버 (Day 1–3) — RESP 없이 뼈대만

### Day 1 — 프로젝트 셋업 + TCP accept 루프
- 방향: `cargo new`, `tokio`(full features)와 `tracing` 추가. `main.rs`에서 `TcpListener::bind` → 루프에서 `accept` → 연결마다 `tokio::spawn`.
- 학습 포인트: `#[tokio::main]`이 실제로 뭘 만드는지, `async fn`과 Future의 관계.
- 확인 기준: 서버 실행 후 `telnet`/`nc`로 두 개 이상 동시 접속이 되고, 각 접속이 로그에 찍힌다.

### Day 2 — 에코 루프
- 방향: 연결 태스크 안에서 `read` → 받은 바이트 그대로 `write_all`. 소켓을 읽기/쓰기로 나눌지(`split`) 고민해 보기. read가 0을 반환하는 의미(EOF) 처리.
- 학습 포인트: 소유권 — 소켓을 태스크로 move하는 것, 버퍼 재사용.
- 확인 기준: `nc`로 보낸 문자열이 그대로 돌아온다. 클라이언트가 끊어도 서버가 죽지 않는다.

### Day 3 — 우아한 종료
- 방향: `tokio::signal::ctrl_c` + `broadcast` 채널. accept 루프와 각 연결 태스크에서 `tokio::select!`로 종료 신호를 함께 기다린다.
- 학습 포인트: `select!`의 취소 안전성(cancellation safety) — 왜 어떤 Future는 select에서 끊겨도 안전하고 어떤 건 아닌지.
- 확인 기준: Ctrl+C 시 새 접속은 거부되고, 연결된 클라이언트는 정리된 후 프로세스가 깨끗하게 종료된다.

## M2. RESP 프로토콜 (Day 4–9) — 이 프로젝트의 심장

### Day 4 — Frame 타입 설계
- 방향: `resp/mod.rs`에 `enum Frame` (Simple, Error, Integer, Bulk, Array, Null). Bulk의 페이로드를 `Vec<u8>`로 할지 `Bytes`로 할지 트레이드오프 정리(복사 vs 참조 카운트). RESP2 명세를 직접 읽는다.
- 확인 기준: Frame enum + 단위 테스트용 생성 헬퍼가 컴파일된다. 각 variant가 어떤 wire 포맷인지 주석으로 설명돼 있다.

### Day 5 — 인코더 (쉬운 쪽 먼저)
- 방향: `Frame -> bytes` 직렬화. 파서보다 쉬워서 먼저 하면 wire 포맷이 손에 익는다. `BufWriter` 또는 `BytesMut`에 쓰기.
- 확인 기준: 각 variant의 인코딩 결과가 명세와 일치하는 단위 테스트 통과 (`+OK\r\n`, `$5\r\nhello\r\n` 등).

### Day 6–7 — 증분 파서 (이틀 배정, 제일 어려움)
- 방향: `BytesMut`에서 소비하며 `Ok(Some(Frame))` / `Ok(None)`(바이트 부족) / `Err`(위반) 반환. 먼저 "완전한 프레임이 버퍼에 있는지 검사(check)"와 "실제 파싱(parse)"을 분리할지, 한 번에 할지 결정. `\r\n`을 못 찾았을 때가 곧 `Ok(None)`이다.
- 학습 포인트: 부분 입력 상태 관리, 커서 되돌리기, 슬라이스 수명.
- 확인 기준: 유효한 프레임을 **모든 바이트 위치에서 두 조각으로 쪼개** 넣어도 파싱되는 테스트 통과. 중첩 Array도 처리.

### Day 8 — Connection 통합
- 방향: `connection.rs`에서 소켓 read → 버퍼 누적 → 파서 호출 → Frame 반환하는 `read_frame`, 반대로 `write_frame`. Day 2의 에코 루프를 "Frame 에코"로 교체.
- 확인 기준: raw TCP 테스트 클라이언트로 Frame을 보내면 같은 Frame이 돌아온다.

### Day 9 — PING / ECHO + redis-cli 첫 대화 🎉
- 방향: `cmd/mod.rs`에 `enum Command` + `Frame(Array) -> Command` 파싱. 모르는 명령은 `-ERR unknown command` 응답(연결 유지). inline command는 무시해도 됨(redis-cli는 Array로 보낸다).
- 확인 기준: **`redis-cli -p <port> ping` 이 `PONG`을 돌려준다.** 여기가 첫 마일스톤 보상.

## M3. 저장소 (Day 10–14)

### Day 10 — 단일 샤드 Db + GET/SET
- 방향: `db.rs`에 `Db { inner: Arc<Mutex<HashMap<String, Entry>>> }` (일단 샤드 1개). `Entry { value: Bytes }`. GET/SET 명령 연결. 락 가드를 `.await` 전에 drop하는 구조를 처음부터 몸에 붙인다.
- 확인 기준: redis-cli에서 `set k v` → `get k` 왕복. 두 클라이언트가 같은 데이터를 본다.

### Day 11 — DEL / EXISTS + 타입 정리
- 방향: 가변 인자 명령(키 여러 개) 파싱, 삭제된 개수 응답. Command 파싱 에러(인자 개수 등)를 `-ERR wrong number of arguments`로.
- 확인 기준: `del`/`exists` 다중 키 동작, 잘못된 인자에 redis와 유사한 에러 문자열.

### Day 12–13 — 샤딩 (이틀)
- 방향: `Vec<Mutex<HashMap>>` 16샤드로 확장. `hash(key) % N`으로 샤드 선택 — 어떤 해셔를 쓸지(std `DefaultHasher`면 충분) 결정. 멀티 키 명령은 샤드를 하나씩 순회(락 두 개 동시 보유 금지).
- 학습 포인트: 왜 `tokio::sync::Mutex`가 아니라 `std::sync::Mutex`인지 스스로 설명할 수 있어야 한다.
- 확인 기준: 기존 테스트 전부 통과 + 여러 연결에서 서로 다른 키로 동시 set/get 하는 통합 테스트.

### Day 14 — INCR / DECR
- 방향: 값을 정수로 파싱 실패 시 `-ERR value is not an integer`. "읽고-수정하고-쓰기"가 한 락 안에서 원자적으로 일어나야 하는 이유를 정리.
- 확인 기준: 동시 접속 N개가 같은 키를 INCR해도 최종값이 정확하다 (경쟁 조건 테스트).

## M4. 만료 (Day 15–18)

### Day 15 — Entry에 만료 시각 + SET EX/PX
- 방향: `Entry { value, expires_at: Option<Instant> }`. SET 옵션 파싱(EX/PX/NX/XX 조합 규칙). 벽시계가 아니라 `Instant`를 쓰는 이유 정리.
- 확인 기준: `set k v ex 10` → `ttl k`가 대략 10을 반환(TTL은 Day 16이면 임시 구현으로 확인해도 됨).

### Day 16 — 지연(lazy) 만료 + EXPIRE/TTL
- 방향: GET 등 읽기 경로에서 만료 검사 → 만료면 삭제하고 nil. `EXPIRE`, `TTL`(-1: 만료 없음, -2: 키 없음) 구현.
- 확인 기준: `tokio::time::pause()` 기반 단위 테스트로 만료 전/후 동작이 결정적으로 검증된다.

### Day 17–18 — 능동 스위퍼 (이틀)
- 방향: 100ms 주기 백그라운드 태스크. 샤드별 무작위 샘플링으로 만료 키 제거. 서버 종료 시 스위퍼도 함께 정리. 샘플링 방식(몇 개씩, 어떻게 무작위로)은 단순하게 시작.
- 학습 포인트: 장수(long-lived) 태스크와 `Arc<Db>` 수명, 종료 신호 결합.
- 확인 기준: 읽지 않는 만료 키가 시간이 지나면 메모리에서 사라진다(키 카운트 로그로 확인).

## M5. 마무리 (Day 19–22)

### Day 19 — KEYS + glob 매처 직접 구현
- 방향: `*`, `?`, `[...]` 지원하는 매처를 재귀 또는 동적 계획법으로. 백트래킹이 필요한 케이스(`a*b*c`)를 테스트로 먼저 써보기.
- 확인 기준: glob 매처 단위 테스트 통과, redis-cli에서 `keys r*` 동작.

### Day 20 — 한계값 + 에러 정리
- 방향: 최대 프레임 크기 제한(초과 시 에러 후 연결 종료), 레이어별 `thiserror` enum 정리, `anyhow` 제거 확인.
- 확인 기준: 거대한 프레임을 보내는 악성 클라이언트에 서버가 메모리 폭발 없이 연결을 끊는다.

### Day 21 — tracing + 통합 테스트 정비
- 방향: 연결별 span(피어 주소, 연결 id), 스위퍼 카운터 로그. `tests/`에 서버 기동 → raw 클라이언트 시나리오 통합 테스트.
- 확인 기준: `cargo test` 한 방에 전부 통과, 로그로 연결 흐름 추적 가능.

### Day 22 — redis-benchmark + 회고
- 방향: `redis-benchmark -t set,get`으로 수치 측정. 병목 추측 → 확인. `.Plan/`에 회고 기록(배운 것, v2에서 다르게 할 것).
- 확인 기준: 벤치마크 수치 기록 완료. v2(자료형 확장 or AOF) 방향 메모 작성.

---

## 운영 방법
- 세션 시작: 오늘 Day의 "방향"만 읽고 시작. 설계 근거가 궁금하면 `system-design.md`의 해당 결정(D1–D5) 참조.
- 세션 종료: 확인 기준 체크 → 커밋 → 안 끝난 것은 그 Day에 그대로 남긴다.
- 2시간이 남았는데 Day가 끝났으면: 다음 Day를 당기지 말고, 오늘 코드에 테스트를 더 붙이거나 리팩터링한다 (진도보다 소화가 목표).
