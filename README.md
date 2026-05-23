# Bluff

`누구도 괜찮지 않은 밤` 멤버들이 모여 가볍게 할 수 있는 블러프 주사위 게임입니다.

대표 이미지는 `public/meeting-title.png`, `public/meeting-interview.png`에 있습니다.

## 로컬 실행

```bash
npm install
cp .env.example .env
npm run dev
```

`.env`에는 Supabase 프로젝트의 URL과 anon key를 넣습니다.

## 룰 시뮬레이션

```bash
npm run simulate
```

## Supabase 설정

1. Supabase 프로젝트를 만든다.
2. SQL editor에서 `supabase/migrations` 안의 SQL 파일을 번호 순서대로 실행한다.
3. Vercel 프로젝트 환경 변수에 `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`를 등록한다.

## 게임 데이터 초기화

테스트 중 생긴 기존 방과 라운드 데이터를 모두 지우려면 Supabase SQL editor에서
`supabase/reset_game_data.sql`을 실행한다.

## 배포

```bash
npm run build
npx vercel deploy --prod
```

## 구현 범위

- 첫 라운드 시작자 랜덤
- 시작 주사위는 최대 40개를 인원수로 나눈 몫만 사용
- 선언 맵은 생존 인원이 많을수록 상한이 조금 늘어남
- 일반 선언 `1~5`, `6`은 와일드
- 특수 `6` 선언은 진짜 `6`만 계산
- 블러프 결과 차이만큼 주사위 차감
- 정확히 맞추면 아무도 잃지 않고 블러프한 사람이 다음 라운드 시작
- 새 라운드마다 생존자 주사위 재굴림
- 30분 동안 명시적 동작이 없는 방은 자동 종료
- Supabase RPC에서 동시 블러프 잠금 처리
