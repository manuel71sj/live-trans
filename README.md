# live-trans

## 릴리스

main에 push하면 이 맥에서 앱을 빌드해 GitHub Releases에 올린다. 버전은 `0.1.<커밋 수>`이고 커밋 수가 빌드 번호다(태그 `v0.1.<커밋 수>`).
앞자리 `0.1`은 `project.yml`의 `MARKETING_VERSION`에서 바꾼다. 변경 이력은 직전 릴리스 이후 커밋 제목이다.
push 직전에 빌드하므로 빌드가 실패하면 push도 중단된다. 클론마다 한 번 켠다:

```sh
git config core.hooksPath scripts/hooks
```
