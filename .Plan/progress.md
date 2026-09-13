# Rudis 진행 기록

| Day | 날짜 | 상태 | 메모 |
|-----|------|------|------|
| 1 | 2026-09-01 | 완료 | cargo init, TCP accept 루프 + 연결마다 spawn, tracing 로그 |
| 2 | 2026-09-13 | 완료 | 에코 루프 (read -> write_all, EOF 처리) |
| 3 | 2026-09-13 | 완료 | 우아한 종료: ctrl_c + broadcast 종료 신호 + mpsc guard로 태스크 drain. select! 문법 정리. client/echo-client.ps1 추가 |
