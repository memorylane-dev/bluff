# Repository Guidelines

- `docs/rules.md`에 정리된 게임 룰을 우선한다.
- 구현은 단순하고 유지 보수하기 쉽게 유지한다.
- 멀티플레이어 판정은 클라이언트가 아니라 Supabase RPC에서 처리한다.
- Vercel에는 정적 웹 앱을 배포하고, 게임 상태/동시성은 Supabase가 담당한다.
- 중요한 변경은 작게 나누어 커밋한다.
- 테스트나 빌드를 실행하지 못한 경우 최종 응답에 명시한다.

# 코드 스타일

- TypeScript를 사용한다.
- UI는 React 컴포넌트를 작게 나누되, 과한 추상화는 피한다.
- 게임 룰 관련 상수와 타입은 한 곳에서 관리한다.
- 클라이언트에서 보이는 주사위는 본인 것만 표시한다.

# 커밋 규칙

- 커밋 메시지는 Conventional Commits 형식을 따른다.
- 예: `feat: add lobby creation flow`
- 예: `fix: prevent duplicate challenge resolution`
- 예: `docs: document bluff penalty rules`
- 한 커밋에는 하나의 의도만 담는다.
