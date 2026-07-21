# -*- coding: utf-8 -*-
"""
arb_jp_realtime_spread_v3_claude.py
- ベース: ユーザー提供 v2（国内スポット同時両建てアービトラージ / ペーパー）
- v3: Claudeエージェント（アドバイザー）を統合
    * 一定間隔で 取引所の鮮度・直近トレード・エッジ系列・現在の閾値設定 を
      Claude (Anthropic SDK) に渡し、設定の妥当性チェックと調整案を受け取る
    * 完全にアドバイザリー: 発注ロジックには一切介入しない（ペーパーのまま）
    * 出力: output/claude_advisor.md に追記 + コンソールに要約
    * ANTHROPIC_API_KEY 未設定 or --claude-interval 0 なら完全に無効
- 依存: pip install anthropic requests pyyaml matplotlib
"""
from __future__ import annotations
import argparse, threading, time, os, csv, yaml, requests, platform
from datetime import datetime, timezone, timedelta
from collections import deque

def jst(): return timezone(timedelta(hours=9))
def ts_jst(ts): return ts.astimezone(jst()).strftime("%H:%M:%S")
def safe_mkdir(p): os.makedirs(p, exist_ok=True)
def now_utc(): return datetime.now(timezone.utc)

try:
    import matplotlib
    if platform.system()=="Windows":
        try: matplotlib.use("TkAgg", force=True)
        except Exception: pass
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation
except Exception:
    plt=None; FuncAnimation=None

STALE_SEC = 5  # 5s以上古いデータは無効

class Venue:
    def __init__(self, cfg: dict):
        self.name = cfg["name"]; self.enabled = bool(cfg.get("enabled", True))
        self.ticker_url = cfg["ticker_url"]; self.method = cfg.get("method","GET")
        self.params = cfg.get("params",{})
        self.key_bid = cfg.get("key_bid","best_bid"); self.key_ask = cfg.get("key_ask","best_ask")
        self.can_buy  = bool(cfg.get("buy_allowed",True)); self.can_sell = bool(cfg.get("sell_allowed",True))
        self.fees_bps = float(cfg.get("fees_bps",0)); self.slip_bps = float(cfg.get("slippage_bps",0))
        self.best_bid=None; self.best_ask=None; self.last_ts=None
        self._sess = requests.Session(); self._sess.headers.update({"User-Agent":"jp-arb-bot/1.2"})
    def _dig(self, obj, dotted, default=None):
        cur=obj
        for k in dotted.split("."):
            if isinstance(cur, dict) and k in cur: cur=cur[k]
            else: return default
        return cur
    def poll(self, timeout=1.5):
        if not self.enabled: return
        try:
            r = self._sess.get(self.ticker_url, params=self.params, timeout=timeout) if self.method=="GET" \
                else self._sess.post(self.ticker_url, json=self.params, timeout=timeout)
            if r.status_code!=200: return
            d = r.json()
            bid = self._dig(d, self.key_bid, None); ask = self._dig(d, self.key_ask, None)
            if bid is None or ask is None: return
            self.best_bid=float(bid); self.best_ask=float(ask); self.last_ts=now_utc()
        except Exception: return
    def fresh(self)->bool:
        return self.last_ts is not None and (now_utc()-self.last_ts).total_seconds() <= STALE_SEC
    def cost_jpy(self, px: float)->float:
        return px * (self.fees_bps + self.slip_bps) * 1e-4

class State:
    def __init__(self, cfg):
        self.cfg = cfg
        self.venues = [Venue(v) for v in cfg["venues"] if v.get("enabled",True)]
        self.poll_ms = int(cfg.get("poll_ms",250))
        self.qty_jpy = float(cfg.get("qty_jpy",200000))
        self.edge_mode = str(cfg.get("edge_mode","net")).lower()  # 'gross' or 'net'
        self.base_th_jpy = float(cfg.get("base_th_jpy",1500))
        self.safety_mult = float(cfg.get("safety_mult",1.2))
        self.min_extra_edge = float(cfg.get("min_extra_edge_jpy",300))
        self.cooldown_sec = int(cfg.get("cooldown_sec",8))
        self.min_spacing_sec = int(cfg.get("min_trade_spacing_sec",10))
        self.last_trade_ts = now_utc()-timedelta(days=1)
        self.eq=deque(maxlen=6000); self.edge_g=deque(maxlen=6000); self.edge_n=deque(maxlen=6000); self.ts=deque(maxlen=6000)
        self.equity_sum=0.0
        out=os.path.join(os.getcwd(),"output"); safe_mkdir(out)
        self.equity_csv=os.path.join(out,"equity_live.csv")
        self.trades_csv=os.path.join(out,"trades_live.csv")
        self.png=os.path.join(out,"equity_live.png")
        if not os.path.exists(self.equity_csv):
            with open(self.equity_csv,"w",newline="",encoding="utf-8") as f:
                csv.writer(f).writerow(["time_jst","equity_jpy","gross_jpy","net_jpy"])
        if not os.path.exists(self.trades_csv):
            with open(self.trades_csv,"w",newline="",encoding="utf-8") as f:
                csv.writer(f).writerow(["time","buy","sell","buy_px","sell_px","qty_btc","gross","cost","net","pnl"])
        self._last_stat = 0
    def poller(self):
        while True:
            for v in self.venues: v.poll(timeout=1.2)
            time.sleep(self.poll_ms/1000.0)
    def best_opportunity(self):
        best=None
        fresh=[v for v in self.venues if v.enabled and v.fresh()]
        for buy in fresh:
            if not (buy.can_buy and buy.best_ask): continue
            for sell in fresh:
                if sell is buy or not (sell.can_sell and sell.best_bid): continue
                gross = sell.best_bid - buy.best_ask
                if best is None or gross>best[0]:
                    best=(gross, buy, sell, buy.best_ask, sell.best_bid)
        return best
    def tick(self):
        ts=now_utc(); opp=self.best_opportunity()
        gross=0.0; net=0.0
        if opp:
            gross, buy, sell, ask_px, bid_px = opp
            cost = self.safety_mult * (buy.cost_jpy(ask_px) + sell.cost_jpy(bid_px))
            net = gross - cost
            # ログ（2秒おき）
            now_s=int(time.time())
            if now_s != self._last_stat and now_s%2==0:
                self._last_stat=now_s
                print(f"[BEST] buy={buy.name}@{ask_px:.0f} sell={sell.name}@{bid_px:.0f} "
                      f"gross={gross:.0f} cost≈{cost:.0f} net≈{net:.0f}")
            # トリガー
            edge_for_trigger = gross if self.edge_mode=="gross" else net
            ok_thresh = edge_for_trigger >= self.base_th_jpy
            if self.edge_mode=="net":
                ok_thresh = ok_thresh and (net >= self.min_extra_edge)
            ok_spacing = (ts-self.last_trade_ts).total_seconds() >= max(self.cooldown_sec,self.min_spacing_sec)
            if ok_thresh and ok_spacing:
                qty_btc = max(1e-6, self.qty_jpy/max(ask_px,1.0))
                # 成行想定のフィル（保守的にスリップも考慮）
                buy_fill  = ask_px * (1 + buy.slip_bps*1e-4)
                sell_fill = bid_px * (1 - sell.slip_bps*1e-4)
                fee_buy  = buy_fill * buy.fees_bps*1e-4
                fee_sell = sell_fill* sell.fees_bps*1e-4
                # スリッページはフィル価格(buy_fill/sell_fill)に織り込み済みなので
                # ここでは手数料のみ（v2はここで二重控除していた）
                total_cost = (fee_buy+fee_sell)*qty_btc
                pnl = (sell_fill - buy_fill)*qty_btc - total_cost if self.edge_mode=="net" \
                      else (sell_fill - buy_fill)*qty_btc  # grossモードはコスト非考慮
                self.equity_sum += pnl; self.last_trade_ts=ts
                with open(self.trades_csv,"a",newline="",encoding="utf-8") as f:
                    csv.writer(f).writerow([ts_jst(ts), buy.name, sell.name, f"{buy_fill:.1f}", f"{sell_fill:.1f}",
                                            f"{qty_btc:.8f}", f"{gross:.1f}", f"{total_cost:.1f}", f"{net:.1f}", f"{pnl:.1f}"])
                print(f"[TRADE] BUY {buy.name} @{buy_fill:.0f} / SELL {sell.name} @{sell_fill:.0f} "
                      f"{self.edge_mode}= {edge_for_trigger:.0f}  pnl={pnl:.1f}")
        # series
        self.ts.append(ts); self.edge_g.append(gross); self.edge_n.append(net); self.eq.append(self.equity_sum)
        if len(self.ts)%max(1,int(2*1000/self.poll_ms))==0:
            with open(self.equity_csv,"a",newline="",encoding="utf-8") as f:
                csv.writer(f).writerow([ts_jst(ts), self.equity_sum, gross, net])

# ============================================================
# Claude アドバイザー（v3 追加）
#  - 発注ロジック非介入・レポート専用
#  - 別スレッドで interval ごとに実行。API失敗は警告のみで続行
# ============================================================
ADVISOR_SYSTEM = (
    "あなたは国内暗号資産スポットの取引所間アービトラージbot（ペーパートレード）の"
    "運用アドバイザーです。渡される情報は: 取引所ごとの気配とデータ鮮度、"
    "手数料/スリッページ想定(bps)、エッジ系列の統計、直近トレード、現在の閾値設定。"
    "以下を日本語で簡潔に報告してください:\n"
    "1. データ品質の異常（stale/欠損/明らかに不自然な気配）\n"
    "2. 現在の閾値(base_th_jpy, safety_mult, min_extra_edge_jpy)の妥当性と調整案（根拠つき）\n"
    "3. 手数料・スリッページ想定が直近の実勢と乖離していないか\n"
    "4. リスク注意点（片足約定・送金滞留・在庫偏りなど、実弾化した場合の論点）\n"
    "断定的な売買指示はせず、あくまで設定と運用のレビューに徹すること。"
)

class ClaudeAdvisor:
    def __init__(self, st: State, model: str, interval_min: int):
        self.st = st
        self.model = model
        self.interval = max(1, interval_min) * 60
        self.client = None
        self.out_md = os.path.join(os.getcwd(), "output", "claude_advisor.md")
        if not os.environ.get("ANTHROPIC_API_KEY"):
            print("[CLAUDE] ANTHROPIC_API_KEY 未設定のためアドバイザー無効")
            return
        try:
            import anthropic
            self.client = anthropic.Anthropic()  # キーは環境変数から
            print(f"[CLAUDE] アドバイザー有効: model={self.model} interval={interval_min}min")
        except Exception as e:
            print(f"[CLAUDE] anthropic SDK 利用不可 ({e}) — pip install anthropic")

    def _tail_csv(self, path: str, n: int = 15) -> str:
        try:
            with open(path, "r", encoding="utf-8") as f:
                rows = f.readlines()
            return "".join(rows[:1] + rows[-n:]) if len(rows) > n + 1 else "".join(rows)
        except Exception:
            return "(なし)"

    def _context(self) -> str:
        st = self.st
        lines = [f"時刻(JST): {ts_jst(now_utc())}  edge_mode={st.edge_mode}  paper equity={st.equity_sum:.0f} JPY"]
        lines.append(f"閾値設定: base_th_jpy={st.base_th_jpy} safety_mult={st.safety_mult} "
                     f"min_extra_edge_jpy={st.min_extra_edge} cooldown={st.cooldown_sec}s spacing={st.min_spacing_sec}s "
                     f"qty_jpy={st.qty_jpy}")
        lines.append("取引所状態:")
        for v in st.venues:
            age = "-" if v.last_ts is None else f"{(now_utc()-v.last_ts).total_seconds():.1f}s"
            lines.append(f"  {v.name}: bid={v.best_bid} ask={v.best_ask} age={age} fresh={v.fresh()} "
                         f"fees={v.fees_bps}bps slip={v.slip_bps}bps buy={v.can_buy} sell={v.can_sell}")
        g = [x for x in st.edge_g if x != 0.0]
        n_ = [x for x in st.edge_n if x != 0.0]
        if g:
            lines.append(f"エッジ統計(非ゼロ標本): gross n={len(g)} max={max(g):.0f} avg={sum(g)/len(g):.0f} / "
                         f"net n={len(n_)} max={(max(n_) if n_ else 0):.0f} avg={(sum(n_)/len(n_) if n_ else 0):.0f}")
        lines.append("直近トレード(paper):\n" + self._tail_csv(st.trades_csv))
        return "\n".join(lines)

    def run_once(self):
        if self.client is None: return
        msg = self.client.messages.create(
            model=self.model,
            max_tokens=1500,
            thinking={"type": "adaptive"},
            system=ADVISOR_SYSTEM,
            messages=[{"role": "user", "content": self._context()}],
        )
        text = "".join(b.text for b in msg.content if b.type == "text")
        if not text: return
        stamp = datetime.now(jst()).strftime("%Y-%m-%d %H:%M:%S")
        with open(self.out_md, "a", encoding="utf-8") as f:
            f.write(f"\n\n## {stamp} JST ({self.model})\n\n{text}\n")
        head = text.strip().splitlines()
        print(f"[CLAUDE] レポート更新 → {self.out_md}")
        for ln in head[:6]: print(f"[CLAUDE] {ln}")

    def loop(self):
        if self.client is None: return
        while True:
            time.sleep(self.interval)
            try:
                self.run_once()
            except Exception as e:
                print(f"[CLAUDE] アドバイザーエラー(継続): {e}")

def start_gui(st:State, save_every:int):
    if plt is None:
        print("[INFO] headless");
        while True: st.tick(); time.sleep(st.poll_ms/1000.0)
    fig, ax_eq = plt.subplots(figsize=(10,5))
    ax_ed = ax_eq.twinx()
    line_eq, = ax_eq.plot([], [], label="Equity (JPY)")
    line_g , = ax_ed.plot([], [], alpha=0.35, label="Gross Edge")
    line_n , = ax_ed.plot([], [], alpha=0.35, label="Net Edge")
    ax_eq.set_xlabel("Time (JST)"); ax_eq.set_ylabel("Equity (JPY)"); ax_ed.set_ylabel("Edge (JPY)")
    ax_eq.grid(True, alpha=0.3); ax_eq.legend(loc="upper left"); ax_ed.legend(loc="upper right")
    fig.suptitle("JP Spot Arbitrage – LIVE (dual-leg, paper) + Claude advisor")

    last_save=0.0
    def animate(_):
        for _ in range(max(1,int(600/st.poll_ms))): st.tick()
        xs=list(st.ts);
        if not xs: return line_eq, line_g, line_n
        line_eq.set_data(range(len(xs)), list(st.eq))
        line_g.set_data(range(len(xs)), list(st.edge_g))
        line_n.set_data(range(len(xs)), list(st.edge_n))
        ax_eq.relim(); ax_eq.autoscale_view(); ax_ed.relim(); ax_ed.autoscale_view()
        labels=[x.astimezone(jst()).strftime("%H:%M:%S") for x in xs]; ticks=[0, max(0,len(xs)//2), len(xs)-1]
        ax_eq.set_xticks(ticks); ax_eq.set_xticklabels([labels[i] for i in ticks])
        nonlocal last_save; now=time.time()
        if now-last_save>=save_every:
            try: fig.savefig(st.png, dpi=120, bbox_inches="tight")
            except Exception as e: print(f"[WARN] savefig: {e}")
            last_save=now
        return line_eq, line_g, line_n
    ani=FuncAnimation(fig, animate, interval=600, cache_frame_data=False, save_count=2000)
    fig._anim_ref=ani; plt.show()

def load_cfg(path):
    with open(path,"r",encoding="utf-8") as f: return yaml.safe_load(f) or {}

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--cfg", type=str, default="config_arb.yaml")
    ap.add_argument("--save-every", type=int, default=5)
    ap.add_argument("--claude-interval", type=int, default=30,
                    help="Claudeアドバイザーの実行間隔(分)。0で無効")
    ap.add_argument("--claude-model", type=str, default="claude-opus-4-8")
    args=ap.parse_args()
    cfg=load_cfg(args.cfg); st=State(cfg)
    threading.Thread(target=st.poller, daemon=True).start()
    if args.claude_interval > 0:
        adv = ClaudeAdvisor(st, args.claude_model, args.claude_interval)
        threading.Thread(target=adv.loop, daemon=True).start()
    start_gui(st, args.save_every)

if __name__=="__main__":
    main()
