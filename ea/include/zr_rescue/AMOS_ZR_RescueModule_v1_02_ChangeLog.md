# AMOS_ZR_RescueModule v1.02 ChangeLog

## Purpose
Combine the two BT presets into one adaptive rescue model.

- Standard rescue: Fixed + FirstAnchor
- Defensive rescue: Rolling + Expanding
- Automatic switching by MarketState, DD, spread, turn count, and policy.

## Added

### Adaptive Scheme
```mq5
input ENUM_ZR_ADAPTIVE_SCHEME InpZRAdaptiveScheme = ZR_SCHEME_AUTO_STATE;
```

Modes:

```text
ZR_SCHEME_MANUAL
ZR_SCHEME_FIXED_FIRST
ZR_SCHEME_ROLLING_EXPANDING
ZR_SCHEME_AUTO_STATE
```

### Standard Scheme
```mq5
InpZRStandardZoneFactor = 1.00
InpZRStandardAnchorMode = ZR_ANCHOR_FIRST
```

Used mainly for STATE_RANGE / normal rescue where profit rotation and shorter basket duration matter.

### Defensive Scheme
```mq5
InpZRDefenseZoneFactor = 1.10
InpZRDefenseAnchorMode = ZR_ANCHOR_ROLLING
```

Used when danger rises: DD, spread, CHAOS, TREND risk, or rescue turn count.

### Danger Score
Internal `GetZRDangerScore()` selects between standard and defensive schemes.

Triggers include:

- STATE_CHAOS
- DD near rescue limit
- spread near upper limit
- trend defense mode
- rescue turn count >= threshold
- exit-only policy

### Scheme Log
`ZR_SCHEME` log event is emitted when the active scheme changes.

## Recommended Default

```text
InpZRAdaptiveScheme = ZR_SCHEME_AUTO_STATE
Standard = Fixed + FirstAnchor + 1.00
Defense  = Rolling + Expanding + 1.10
```

## Test File

`AMOS_ZR_BT_Preset_AutoAdaptive_Optimal.set`
