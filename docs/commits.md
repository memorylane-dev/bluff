# Commit Rules

이 저장소는 Conventional Commits를 사용한다.

## 형식

```txt
<type>: <summary>
```

## 권장 type

- `feat`: 사용자에게 보이는 기능 추가
- `fix`: 버그 수정
- `docs`: 문서 변경
- `refactor`: 동작 변경 없는 구조 개선
- `test`: 테스트 추가 또는 수정
- `chore`: 빌드, 설정, 기타 관리 작업

## 원칙

- 한 커밋에는 하나의 변경 의도만 담는다.
- 커밋 전 `npm run build`를 통과시키는 것을 기본으로 한다.
- DB 스키마 변경과 클라이언트 변경이 강하게 연결되어 있으면 같은 커밋에 포함할 수 있다.
