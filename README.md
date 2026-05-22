# Bluff

`누구도 괜찮지 않은 밤` 멤버들이 모여 가볍게 할 수 있는 블러프 주사위 게임입니다.

대표 이미지는 `public/meeting-cover.svg`에 있습니다.

## 로컬 실행

```bash
npm install
cp .env.example .env
npm run dev
```

`.env`에는 Supabase 프로젝트의 URL과 anon key를 넣습니다.

## Supabase 설정

1. Supabase 프로젝트를 만든다.
2. SQL editor에서 `supabase/migrations/001_initial_schema.sql`을 실행한다.
3. Vercel 프로젝트 환경 변수에 `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`를 등록한다.

## 배포

```bash
npm run build
npx vercel deploy --prod
```

## 구현 범위

- 첫 라운드 시작자 랜덤
- 일반 선언 `1~5`, `6`은 와일드
- 특수 `6` 선언은 진짜 `6`만 계산
- 블러프 결과 차이만큼 주사위 차감
- 정확히 맞추면 아무도 잃지 않고 블러프한 사람이 다음 라운드 시작
- 새 라운드마다 생존자 주사위 재굴림
- Supabase RPC에서 동시 블러프 잠금 처리
