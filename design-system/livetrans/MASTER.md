# LiveTrans 디자인 시스템

ui-ux-pro-max(v2.15.0) 검색 결과를 macOS 네이티브 읽기 앱에 맞게 조정한 기준이다.
검색어: `real-time transcription translation productivity tool` (`--design-system`, variance 3 · motion 2 · density 6),
`japanese korean multilingual reading` (typography), `dynamic type dark mode semantic color` (swiftui).

## 스타일 방향 — Minimalism & Swiss Style

- 내용이 주인공인 읽기 화면. 원문 왼쪽, 번역 오른쪽의 2열 격자 하나로 끝낸다.
- 그림자·그라데이션·카드 없음. 구조는 괘선 하나와 여백으로만 나눈다.
- 색은 정보를 나타낼 때만 쓴다: 브랜드 블루(확정·포커스), 호박색(1차 번역), 빨강(녹음 중). 바탕과 글자는 네이비 계열.
- 움직임은 상태가 바뀔 때만 쓴다: 1차 번역 → 보정본 색 전환 0.6초, 녹음 표시등 깜빡임. 동작 줄이기 설정을 따른다.
- DB가 추천한 랜딩 패턴(제품 데모·스크롤 연출)과 GSAP 모션은 웹 마케팅용이라 쓰지 않는다.

## 컬러 팔레트 — 네이비 + 블루

DB `B2B Service` 팔레트(Primary 네이비 `#0F172A`, Accent 블루 `#0369A1`, Background `#F8FAFC`)를 바탕으로 한다.
처음 추천된 `Productivity Tool` 청록 팔레트는 사용자 요청으로 바꿨다.

| 역할 | 라이트 | 다크 | 쓰임 | DB 원값과 차이 |
|---|---|---|---|---|
| Primary (블루) | `#0369A1` | `#38BDF8` | 보정본 글자, 버튼 강조·포커스 | DB Accent 그대로 (5.9:1) |
| Background | `#F8FAFC` | `#0F172A` | 열 머리·하단 상태 줄 바탕 | 그대로. 다크는 DB 네이비 |
| Surface | `#FFFFFF` | `#131E33` | 읽기 영역 바탕 | DB Card |
| Foreground (네이비) | `#0F172A` | `#E2E8F0` | 원문 본문 | DB Primary 네이비를 글자색으로 |
| Muted Foreground | `#64748B` | `#94A3B8` | 번역 중, 전사 중, 보조 문구 | `#475569`보다 옅게 해 본문과 구분 (4.5:1 이상) |
| Border | `#E2E8F0` | `#1E293B` | 가운데 괘선, 구분선 | 네이비 계열 슬레이트로 지정 |
| Draft (호박) | `#B45309` | `#FBBF24` | 1차 번역 글자 | 팔레트 밖에서 추가. 녹음 빨강과 색상이 겹치지 않게 호박색 |
| Destructive | `#DC2626` | `#F87171` | 녹음 중 표시등과 "듣는 중" | 그대로 |

번역 단계: 번역 중 = Muted Foreground, 1차 번역 = Draft, 보정본 = Primary.
블루와 호박색은 적록 색각 이상에서도 구분되는 짝이다. 대비는 라이트·다크 모두 4.5:1 이상이다.

## 타이포그래피 — Japanese Elegant (Serif 제목 + Sans 본문)

DB 조합은 Noto Serif JP / Noto Sans JP다. Noto는 macOS에 기본으로 없어서 같은 역할의 시스템 서체로 바꾼다.

| 역할 | 서체 | 크기 |
|---|---|---|
| 제목(빈 화면 안내, 열 머리) | 시스템 세리프(New York) → Hiragino Mincho ProN W6 → AppleMyungjo | 22 / 13 semibold |
| 원문 본문 | 시스템 산세리프(SF) → Hiragino Sans(일본어) / Apple SD Gothic Neo(한국어) | 15, 행간 +5 |
| 번역 본문 | 같은 산세리프, 한 단계 크게 | 17, 행간 +4 |
| 보조(상태 줄, 범례) | 같은 산세리프 | 12 |

세리프는 대체 글꼴을 직접 지정한다. 지정하지 않으면 한자는 명조, 가나 일부는 고딕으로 섞인다.

## 레이아웃

- 컨트롤(언어 선택, 원문 복사, 시작/중지)은 창 툴바. 버튼은 아이콘과 글자를 함께 보인다.
- 본문 최대 폭 1080pt, 열 좌우 여백 24pt, 문단 위아래 14pt. 창 최소 폭 760pt.
- 진행 중 문단은 맨 아래, 가운데 괘선 위에 빨간 표시등.

## 금지

- 보라 그라데이션, 같은 카드 반복, 그림자 장식
- 대비 4.5:1 미만 글자색, 색만으로 상태 전달(범례를 항상 같이 둔다)
- 이모지 아이콘(SF Symbols 사용)
