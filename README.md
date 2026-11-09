# live-trans

## 릴리스

main에 push하면 이 맥에서 앱을 빌드해 GitHub Releases에 올린다(태그 `v<커밋 수>`, 직전 릴리스 이후 커밋 제목이 변경 이력).
push 직전에 빌드하므로 빌드가 실패하면 push도 중단된다. 클론마다 한 번 켠다:

```sh
git config core.hooksPath scripts/hooks
```
