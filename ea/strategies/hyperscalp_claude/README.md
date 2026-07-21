# AMOS HyperScalp DualEngine v1.30 (Claude Gate)

ユーザー提供 `AMOS_HyperScalp_DualEngine_v1_21.mq5` のカスタム版。
v1.21 の全ロジック（レンジ圧縮検出 → ICT バイアス → スイープ後の
12本リミット・クラスター → Giveback 一括利確）は無変更で、
クラスター発射の直前に **Claude エージェント判定** を差し込んだ。

## 動作モード（InpClaudeMode）

| モード | 動作 |
|---|---|
| `CLAUDE_OFF` | v1.21 と完全同一（API を一切呼ばない） |
| `CLAUDE_ADVISORY`（既定） | 判定を取得してパネル/ログに記録するだけ。発射条件は従来通り |
| `CLAUDE_GATE` | Claude の direction が一致し confidence ≥ `InpClaudeMinConf` のときのみ発射 |

## 実装上のポイント

- 判定は発射候補が立った瞬間のみ取得し、`InpClaudeCooldownSec`（既定300s）
  キャッシュ。毎ティック API を叩かない。
- 応答は `{"direction":"BUY|SELL|NONE","confidence":0-100,"reason":"..."}` の
  JSON を強制し、素朴なパーサで読む。
- API 失敗時の挙動は `InpClaudeFailOpen`（既定 true = 従来条件のみで発射）。
- ストラテジーテスターでは WebRequest が使えないため Claude は自動素通し
  （= バックテストは v1.21 と同一結果になる）。
- API キーは input のみ。コード埋め込み禁止。

## セットアップ

1. ツール > オプション > エキスパートアドバイザ で
   `https://api.anthropic.com` を WebRequest 許可 URL に追加
2. `InpAnthropicKey` に API キーを設定
3. まず `CLAUDE_ADVISORY` で判定ログを貯めて、Claude の direction と
   実際のバスケット損益の一致率を確認してから GATE に昇格させること

## 正直な注意

このEAの本体はスイープ後の平均回帰リミット群であり、当セッションの実データ
検証（`docs/inbox/mathematical_framework.md`）では、レンジ検出ゲートは正しい
方向の工夫だが、LLM 判定そのものは検証済みエッジではない。ADVISORY で一致率を
測る → 有意なら GATE、が唯一の誠実な昇格経路。
