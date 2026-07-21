# AMOS_ZR_RescueModule v1.01 ChangeLog

## 1. PCI補完決済の厳密化
- `InpZRCommissionPerLotRound` を追加。
- `GetZRCompletionValue()` を以下へ変更。

```text
basket_profit + estimated_cb - total_commission - risk_penalty
```

- `total_commission = basket_total_lots * InpZRCommissionPerLotRound`。
- MT5側で手数料がポジション損益に反映される口座では `InpZRCommissionPerLotRound=0.0` のままにする。

## 2. 執行エラー時のフリーズガード
- `InpZROrderFailFreezeEnabled`
- `InpZROrderFailFreezePips`
- `InpZROrderFreezeBars`

`OpenZRPosition()` 失敗後、価格が元のゾーン境界から許容pips以上離れている場合、その場で追いかけ約定せず、フリーズして遅延約定を防止する。

## 3. ローリング&拡大係数のBT比較
同梱 `.set`:

- `AMOS_ZR_BT_Preset_Rolling_Expanding.set`
  - `InpZoneWidthFactor=1.10`
  - `InpZoneAnchorMode=ZR_ANCHOR_ROLLING`

- `AMOS_ZR_BT_Preset_Fixed_FirstAnchor.set`
  - `InpZoneWidthFactor=1.00`
  - `InpZoneAnchorMode=ZR_ANCHOR_FIRST`

比較指標:

```text
MaxDD%
BasketMaxHoldingMins
RescueTurnCount
RecoverySuccessRate
TotalCommission
CompletionValue
ProfitFactor
```

## 追加安全修正
- `STATE_BREAKOUT` を AMOS標準の `STATE_CHAOS` へ変更。
- CHAOS中は新規救出開始を禁止し、exit-only/lock管理へ寄せた。
- `ZR_LOT_ADDITION` の加算値を `InpZRAddLotStep` に分離。
