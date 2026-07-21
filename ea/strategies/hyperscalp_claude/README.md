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

## バックテスト結果（実XAUUSD 1m, 2026-01〜07, `scripts/hyperscalp_bt.py`）

メカニカル本体（Claudeゲート除外 = テスター相当）を実データで検証した:

| 変種 | net/月 | +CB@15/月 | maxDD | 備考 |
|---|---|---|---|---|
| A) v1.21そのまま (SL=レンジ−$2) | −$17 | −$7 | 1.2% | **欠陥**: SL逆転ガードで12本中11本が拒否され実質1本(rejected 4,323/4,716) |
| B) 意図通り12本 (SL=最深指値−$2) | −$139 | −$117 | 12.9% | フル・クラスターはトレンド期に逆張りナンピンとして負ける |

**既知の欠陥**: デフォルト(ステップ150pt=$1.50, SlBufferDollars=$2)では
BUY指値 i≥2 が `SL >= price` となり EA 自身のガードで拒否される。
12本撃ちたいなら SL をクラスター最深部の下に置く必要があるが、
その場合の成績が B — つまり「直すと余計に負ける」。
このEAの本体は逆張り平均回帰であり、当期間の実データでは
どちらの読みでも負のEV。ADVISORY モードでの運用データ収集以外の
実弾投入は非推奨。

## 正直な注意

このEAの本体はスイープ後の平均回帰リミット群であり、当セッションの実データ
検証（`docs/inbox/mathematical_framework.md`）では、レンジ検出ゲートは正しい
方向の工夫だが、LLM 判定そのものは検証済みエッジではない。ADVISORY で一致率を
測る → 有意なら GATE、が唯一の誠実な昇格経路。
