# arb_jp_realtime_spread v3 (Claude advisor)

ユーザー提供 `arb_jp_realtime_spread_v2.py`（国内スポット両建てアービトラージ /
ペーパー）のカスタム版。v2 の発注・エッジ計算ロジックは無変更で、
**Claude アドバイザー**を別スレッドとして追加した。

## v3 で追加されたもの

- `ClaudeAdvisor`: `--claude-interval` 分ごと（既定30分）に、取引所ごとの気配と
  データ鮮度、fees/slip 想定、エッジ系列の統計、直近ペーパートレード、現在の閾値
  (`base_th_jpy` / `safety_mult` / `min_extra_edge_jpy`) を Claude に渡し、
  設定レビューと調整案を受け取る。
- 出力は `output/claude_advisor.md` に追記 + コンソール要約。
- **完全アドバイザリー**: 発注ロジック・閾値には一切自動介入しない。
  ペーパートレードのまま。

## 使い方

```bash
pip install anthropic requests pyyaml matplotlib
export ANTHROPIC_API_KEY=sk-ant-...      # 未設定ならアドバイザーは静かに無効
python arb_jp_realtime_spread_v3_claude.py --cfg config_arb.yaml \
    --claude-interval 30 --claude-model claude-opus-4-8
```

`--claude-interval 0` で v2 と完全に同じ動作になる。

## 注意

- アービトラージ本体はレイテンシ勝負なので、LLM をトリガー経路に入れるのは
  設計として誤り。だからこの統合は「運用レビュー係」に限定してある。
- 実弾化の際の主要リスク（片足約定、送金滞留、在庫偏り、出来高の薄さ）は
  アドバイザーのレポート項目に含めてあるが、コードはペーパー専用。
