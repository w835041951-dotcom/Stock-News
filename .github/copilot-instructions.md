# Stock News — Copilot Instructions

本工作区是 **A 股市场分析工具集**，通过 PowerShell 7 + Python 获取实时行情、财报、全球热搜，进行量化选股和持仓管理。

---

# 全局约定：用户偏好与快速收敛

所有 skill 的输出都应遵循以下从历史交互中学习到的偏好规则，目标是 **第一次回复就让用户满意**。

### 核心原则：最小化 → 按需扩展

1. **首次回复给最短版本**：不要提供多个版本让用户选，直接给一个最简洁的版本。用户如果需要更多细节会主动要求。
2. **严格遵循用户关键词边界**：用户说了什么就输出什么，不要自行添加用户没提到的内容（如额外的 action items、后续步骤、补充说明等）。
3. **不要画蛇添足**：用户的中文关键词就是输出的 **完整范围**，忠实翻译/转化即可，不要扩展、embellish 或加戏。
4. **一个版本，不要多选项**：除非用户明确要求"给我几个版本"，否则只输出一个最佳版本。
5. **上下文精准**：如果用户在多轮对话中逐步澄清了意图，后续回复应直接反映最终意图，不要再带上之前被否定的内容。

### 情绪与收益导向偏好（当前用户）

1. **先讲机会，再讲风险**：涉及市场/持仓分析时，先给赚钱机会与积极信号，再补充风险点。
2. **语气稳，不制造恐慌**：避免过度悲观或惊吓式表达，保持支持性、建设性语气。
3. **给可执行结论**：风险提示后补一句可执行建议，帮助用户稳住节奏与心态。

### 历史教训（所有 skill 通用）

| 反模式 | 正确做法 |
|--------|----------|
| 给 2-3 个版本让用户选 | 直接给 1 个最好的 |
| 用户说 A，输出 A+B+C | 只输出 A |
| 输出太长，用户说 "short" | 首次就给最短版本 |
| 猜测用户没说的意图并加入 | 只做用户明确要求的 |
| 多轮修正后仍包含被否定的内容 | 每轮清除被否定的部分 |

---

# 全局约定：PowerShell 执行环境

## PowerShell 版本要求

**所有脚本必须使用 PowerShell 7 执行。** PS 5.1 会导致格式字符串解析失败。

- pwsh 路径：`C:\Program Files\PowerShell\7\pwsh.exe`
- 执行方式：`& "C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -File "script.ps1"`

### 批量分析标准模式

**不要**用 `-Command` 内联多行脚本（`$`、`@`、`;` 会被终端转义导致 ParserError）。  
**必须**把逻辑写到临时 `.ps1` 文件，再用 `-File` 执行，结果输出到 JSON 文件再读取：

```powershell
# 1. 写脚本到临时文件
$script | Out-File 'Q:\stock-news\temp\run.ps1' -Encoding utf8
# 2. 用 Start-Process -Wait（比 & 更可靠，输出不丢失）
Start-Process "C:\Program Files\PowerShell\7\pwsh.exe" -ArgumentList "-NoProfile","-File","...\run.ps1" -Wait -NoNewWindow
# 3. 读 JSON 结果
Get-Content '...\result.json' | ConvertFrom-Json
```

---

# 当前用户

当用户说"我的"、"my"时，使用以下身份信息：

| 属性 | 值 |
|------|---|
| **Alias** | `hongyangwan` |
| **Email** | `hongyangwan@microsoft.com` |
| **Display Name** | Hongyang Wan |

## 本地路径

| Repo | 本地路径 |
|------|---------|
| Stock-News | `Q:\stock-news` |
| MyClaw | `Q:\MyClaw` |

## 快捷指令映射

当用户说以下话时，自动执行对应操作：

| 用户说 | 实际操作 |
|-------|---------|
| "股票推荐" / "推荐股票" | `.\Get-MarketHotspot.ps1 -Action recommend` |
| "今日热点" / "市场热点" | `.\Get-MarketHotspot.ps1 -Action all` |
| "热门板块" | `.\Get-MarketHotspot.ps1 -Action sectors` |
| "财经新闻" / "最新新闻" | `.\Get-MarketHotspot.ps1 -Action news` |
| "热搜" / "社会热点" / "trending" | `.\Get-TrendingTopics.ps1 -Action all` |
| "国内热搜" / "百度热搜" | `.\Get-TrendingTopics.ps1 -Action cn` |
| "美国热搜" / "US trends" | `.\Get-TrendingTopics.ps1 -Action us` |
| "日本热搜" / "JP trends" | `.\Get-TrendingTopics.ps1 -Action jp` |
| "欧洲热搜" / "EU trends" | `.\Get-TrendingTopics.ps1 -Action eu` |
| "国际热搜" / "intl trends" | `.\Get-TrendingTopics.ps1 -Action intl` |
| "查股票 XXX" / "财报 XXX" / "stock XXX" | `.\Get-StockDetail.ps1 -Code XXX` |
| "席勒估值 XXX" / "CAPE XXX" / "席勒市盈率 XXX" | `.\Get-CapeValuation.ps1 -Code XXX` |
| "找合作股 XXX" / "关联A股 XXX" / "partner stocks XXX" | `.\Get-PartnerStocks.ps1 -Target XXX` |
| "美股强势" / "US leaders" / "美股映射A股" | `.\Get-USStrongAStocks.ps1` |
| "alpha" / "选股" / "信息差" / "alpha signal" | `.\Get-AlphaSignal.ps1` |
| "买点 XXX" / "几点入手 XXX" / "entry timing XXX" | `.\Get-EntryTiming.ps1 -Code XXX` |
| "我的股票" / "看看我的股票" / "持仓" | `.\Get-Watchlist.ps1` |
| "看看推荐" / "推荐追踪" / "watchlist" | `.\Get-Watchlist.ps1` |
| "更新行情" / "记录今天" | `.\Get-Watchlist.ps1 -Action update` |
| "添加持仓 XXX" | `.\Get-Watchlist.ps1 -Action add -Type holding -Code XXX` |
| "添加推荐 XXX" | `.\Get-Watchlist.ps1 -Action add -Type rec -Code XXX` |
| "回测" / "推荐表现" / "backtest" | `.\Get-Backtest.ps1` |
| "早报" / "今日早报" / "daily brief" | `.\Get-DailyBrief.ps1` |
| "帮我写回复" / "回复邮件" / "reply" | Polish Word: 生成邮件回复 |
| "回复 teams" / "teams 消息" | Polish Word: 生成 Teams 消息 |
| "polish" / "润色" | Polish Word: 润色已有文本 |

---

# Stock News & Recommendation

## 目的

获取A股市场最新财经新闻、热门板块行情，分析市场热点并推荐A股主板+创业板股票（排除科创板/北交所）。

## 数据来源

- **东方财富 (East Money)** push2 API：行业板块、概念板块、板块成分股实时行情、K线、资金流
- **新浪财经 (Sina Finance)** 滚动新闻 API：最新财经要闻
- **雪球 / 36Kr**：情绪分析
- **Yahoo Finance**：美股行情
- **Akshare (Python)**：A 股历史财务数据

## 脚本总览

| 脚本 | 功能 | 典型耗时 |
|------|------|----------|
| `Get-AlphaSignal.ps1` | **主入口**：6 段式全市场分析 + AI TOP10 选股 | 3~6 分钟 |
| `Get-MarketHotspot.ps1` | 热点板块 + 情绪指数 + 板块龙头推荐 | 2~4 分钟 |
| `Get-StockDetail.ps1` | 单股基本面：财报、PE、PB、ROE、分红 | 10~30 秒 |
| `Get-CapeValuation.ps1` | 席勒 PE 估值：10 年 EPS 均值、历史百分位 | 20~60 秒 |
| `Get-EntryTiming.ps1` | 盘中买点：主力资金流向 + 最佳入场时间窗 | 5~15 秒 |
| `Get-PartnerStocks.ps1` | 美股/A股联动：新闻证据挖掘 + 关系评分 | 1~3 分钟 |
| `Get-USStrongAStocks.ps1` | 美股强势股→18 大主题→A 股候选 | 1~2 分钟 |
| `Get-Watchlist.ps1` | 自选股 / 持仓管理：历史记录 + 实时行情 | 5~30 秒 |
| `Get-TrendingTopics.ps1` | 全球热搜（百度/谷歌/头条）趋势先行指标 | 10~30 秒 |
| `Get-Backtest.ps1` | 回测：追踪历史推荐的实际涨跌表现 + 胜率统计 | 1~3 分钟 |
| `Get-DailyBrief.ps1` | 每日早报：一句话总结 + TOP3 + 热点，可保存桌面 | 3~5 分钟 |

---

## 使用方式

### 基本命令

```powershell
# 全部信息（新闻 + 板块 + 推荐）
.\Get-MarketHotspot.ps1

# 仅查看最新新闻
.\Get-MarketHotspot.ps1 -Action news

# 仅查看热门板块（行业 + 概念）
.\Get-MarketHotspot.ps1 -Action sectors

# 仅查看股票推荐
.\Get-MarketHotspot.ps1 -Action recommend

# 指定返回数量
.\Get-MarketHotspot.ps1 -Action all -TopN 15

# 静默模式（返回对象，不输出格式化文本）
.\Get-MarketHotspot.ps1 -Action sectors -Quiet
```

### Action 参数

| Action | 说明 |
|--------|------|
| `news` | 仅显示最新财经新闻 |
| `sectors` | 仅显示热门行业 + 概念板块排行 |
| `recommend` | 分析热门板块并推荐主板+创业板股票 |
| `all` | 全部信息（默认） |

---

## 推荐逻辑

1. 获取行业板块涨幅 Top 5 + 概念板块涨幅 Top 5
2. 对每个热门板块，查询成分股前 30 名
3. 过滤：仅保留 A 股主板+创业板股票
   - 沪市主板：60xxxx
   - 深市主板：000xxx / 001xxx / 002xxx
   - 创业板：300xxx
4. 排除：科创板(688xxx)、北交所(8xxxxx)
5. 去重后按涨幅排序，返回 Top N 推荐

### 噪音概念过滤

自动过滤以下噪音概念板块：昨日涨停、昨日首板、昨日连板、百元股、破净股、低价股、新股与次新股、融资融券、股权转让等。

---

## 行为规范

1. **展示结果时**：以表格或列表形式展示，包含股票代码、名称、价格、涨跌幅、所属板块；对推荐股默认追加"几点入手更好"。
2. **始终附带免责声明**：此为数据分析参考，不构成投资建议。
3. **非交易时段 API 限制**：东方财富板块 API 在非交易时段（晚上/凌晨）会间歇性失败（`ResponseEnded`），导致板块/成分股数据为空。降级策略：① 用新浪财经新闻推断热门主线 → ② 手动指定代表代码池 → ③ 逐只调用 `Get-StockDetail.ps1 -Action price -Quiet` 获取近一周/一月涨跌幅 → ④ 按 `Month1Change` 排序筛低位 → ⑤ 调用 `Get-CapeValuation.ps1` 估值。
4. **网络错误时**：展示错误信息，建议检查网络连接。

## 前置要求

1. 需要网络连接（访问东方财富和新浪财经 API）
2. **PowerShell 7**（`C:\Program Files\PowerShell\7\pwsh.exe`）— 必须用 PS7，PS5.1 有格式字符串解析错误

---

## Trending Topics — 全球热搜聚合（Get-TrendingTopics.ps1）

### 目的

聚合国内外非财经类热搜/趋势话题，用于早期发现可能影响市场的社会热点事件，做到"快人一步，先行入场"。

### 数据来源

| 来源 | 地区 | API |
|------|------|-----|
| 百度热搜 | CN | `https://top.baidu.com/api/board?platform=wise&tab=realtime` |
| 头条热榜 | CN | `https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc` |
| Google Trends | US | `https://trends.google.com/trending/rss?geo=US` |
| Google Trends | JP | `https://trends.google.com/trending/rss?geo=JP` |
| Google Trends | DE | `https://trends.google.com/trending/rss?geo=DE` |
| Google Trends | GB | `https://trends.google.com/trending/rss?geo=GB` |
| Google Trends | FR | `https://trends.google.com/trending/rss?geo=FR` |

### 使用方式

```powershell
.\Get-TrendingTopics.ps1 -Action all       # 全部（国内 + 国际）
.\Get-TrendingTopics.ps1 -Action cn        # 仅国内（百度 + 头条）
.\Get-TrendingTopics.ps1 -Action us        # 仅美国
.\Get-TrendingTopics.ps1 -Action jp        # 仅日本
.\Get-TrendingTopics.ps1 -Action eu        # 仅欧洲（DE + GB + FR）
.\Get-TrendingTopics.ps1 -Action intl      # 全部国际
.\Get-TrendingTopics.ps1 -Action all -TopN 10
.\Get-TrendingTopics.ps1 -Action cn -Quiet # 静默模式
```

### 行为规范

1. **展示结果时**：按地区分组展示，标注来源和标签颜色。
2. **始终附带免责声明**：此为非财经类趋势数据，用于早期信号检测，不构成投资建议。
3. **网络错误时**：展示错误信息，单个源失败不影响其他源输出。

---

## Stock Detail — 个股财报与涨跌幅 + 估值拓展（Get-StockDetail.ps1）

### 目的

获取A股个股的实时行情、近一周/近一月涨跌幅、最近4期财报核心经营指标，以及股息率(TTM)、行业对标(PE中位)、CAPE历史分位等估值补充信息。

### 使用方式

```powershell
.\Get-StockDetail.ps1 -Code 600519                    # 全部信息
.\Get-StockDetail.ps1 -Code 000001 -Action finance     # 仅财报
.\Get-StockDetail.ps1 -Code SH600519 -Action price     # 仅行情
.\Get-StockDetail.ps1 -Code 600519 -Action valuation   # 财报 + 估值拓展
.\Get-StockDetail.ps1 -Code 600519 -Quiet              # 静默模式
```

### 行为规范

1. **输入股票名称而非代码时**：提示用户提供6位代码，或根据已知信息推断代码。
2. **展示结果时**：财报以表格形式对比多期数据，涨跌幅用颜色区分（红涨绿跌），估值信息突出关键指标。
3. **始终附带免责声明**：此为数据展示，不构成投资建议。

---

## Alpha Signal — 6段式 AI 选股（Get-AlphaSignal.ps1）

### 目的

综合全球趋势、市场情绪、热点板块、基本面、技术面、估值六个维度，输出得分最高的 TOP N 只股票及理由。
每次运行自动将推荐写入 `recommendations-log.csv` 供 `Get-Backtest.ps1` 回测验证。

### 工作流程（6 段式）

1. **全球趋势热词** — 百度热搜 + 头条热榜 + Google Trends(US/JP/EU)
2. **市场情绪指数** — 多空新闻分析，1（极度悲观）到 10（极度乐观）
3. **信息差分析** — 热点话题 vs 新闻覆盖度的差距（越大越值得关注）
4. **热点板块** — 资金净流入最强的板块 + 近期回调幅度
5. **候选股票评分** — 基本面(0-40) + 技术面(0-30) + 估值(0-30) = 总分 100
6. **最终推荐** — 综合排名 + 信号类型 + 买入时机 + 止损参考

### 三维评分体系（满分 100）

| 维度 | 满分 | 主要指标 |
|------|------|----------|
| 基本面 | 40 | 营收增速 + 净利增速 + ROE + 毛利率 + **PEG** + **财报趋势** |
| 技术面 | 30 | 近一周/近一月回调幅度 + RSI 超卖 |
| 估值面 | 30 | 周期股用 CAPE + PE；非周期股用 PE + PB + **相对行业PE** |

**PEG 加分**：PE(TTM) ÷ 净利润增速。PEG<0.5 +8分、0.5~1.0 +5分、1.0~1.5 +2分、>3.0 -3分。
**相对行业PE**：PE/行业中位PE < 0.8 +5分；> 1.3 -3分。
**财报趋势**：最近3季毛利率/ROE 持续改善 +5/+3分；持续恶化 -3/-2分。
**流动性过滤**：换手率 < 0.3% 自动排除。

### 信号类型

| 信号类型 | 判断条件 | 建议持有时长 | 仓位参考 |
|---------|---------|------------|----------|
| 价值洼地 | CAPE 低估 或 PE 低于行业均值 80% | 长线 3-6月 | 15-20% |
| 景气反转 | 营收增速 > 25% 且 净利增速 > 25% | 波段 1-2月 | 10-15% |
| 主题热点 | 其余情况 | 短线 1-2周 | 5-10% |

止损参考 = 当前价 × 92%（下跌 8%）。

### 使用方式

```powershell
.\Get-AlphaSignal.ps1              # 默认 Top 10
.\Get-AlphaSignal.ps1 -TopN 15    # 指定数量
$result = .\Get-AlphaSignal.ps1 -Quiet  # 静默模式
```

---

## Watchlist — 持仓 + 推荐追踪（Get-Watchlist.ps1）

### 目的

维护持仓和推荐股列表，获取实时行情，记录每日收盘历史，追踪推荐 vs 实际表现。

### 数据文件

`watchlist.json` — 存储持仓、推荐、历史行情记录。

### 使用方式

```powershell
.\Get-Watchlist.ps1                                    # 查看持仓 + 推荐 + 行情 + CAPE
.\Get-Watchlist.ps1 -IncludeCAPE $false                # 跳过CAPE加速
.\Get-Watchlist.ps1 -Action update                      # 抓取行情并记录 history
.\Get-Watchlist.ps1 -Action add -Type holding -Code 600519 -Name "贵州茅台" -Cost 1800 -Qty 100
.\Get-Watchlist.ps1 -Action add -Type rec -Code 002171  # 添加推荐（自动获取价格）
.\Get-Watchlist.ps1 -Action remove -Code 300058
.\Get-Watchlist.ps1 -Action history -Days 30
```

---

## CAPE Valuation — 席勒市盈率估值（Get-CapeValuation.ps1）

### 目的

基于实时价格 + 历史 EPS 计算席勒市盈率（CAPE），用于中长期估值参考。

### 使用方式

```powershell
.\Get-CapeValuation.ps1 -Code 600519                   # 默认10年
.\Get-CapeValuation.ps1 -Code 000001 -Years 8          # 指定年数
.\Get-CapeValuation.ps1 -Code 600519 -AnnualInflationRate 2.0  # 含通胀
.\Get-CapeValuation.ps1 -Code 600519 -Quiet
```

### CAPE 等级

| 等级 | CAPE 区间 | 含义 |
|------|-----------|------|
| Low | < 15 | 明显低估，可积极持有 |
| Neutral | 15–20 | 合理区间 |
| High | 20–25 | 偏贵，需成长支撑 |
| Very High | > 25 | 高估，押预期而非历史盈利 |

---

## Partner Stocks — 美股/A股映射合作公司（Get-PartnerStocks.ps1）

### 目的

从目标公司出发，通过 Web 新闻搜索识别 A 股中可能存在"合作/供应链/客户"关系的公司。

### 使用方式

```powershell
.\Get-PartnerStocks.ps1 -Target NVDA                   # 美股→A股关联
.\Get-PartnerStocks.ps1 -Target 英伟达 -TopN 15 -Days 90
.\Get-PartnerStocks.ps1 -Target 东方铁塔               # A→A 模式
```

### A→A 模式

当 Target 为中文A股公司名时，自动切换 A→A 模式：
- 查询模板改为："{公司名} 合作/产业链/概念股/竞争对手" 等
- 跳过巨潮/东财公告搜索（避免返回目标自身公告）
- 自动排除目标公司本身（按名称+代码双重过滤）

### 全局推荐规则

所有"推荐类"脚本（MarketHotspot / AlphaSignal / PartnerStocks / USStrongAStocks）在输出推荐股票时，默认必须包含：
- 财报分析：最近一期营收同比、净利同比、ROE
- 估值分析：PE(TTM) + CAPE
- 日内时点：根据分时走势 + 资金流，给出更适合的入手时间窗口

---

## US Strong Leaders → A-share Mapping（Get-USStrongAStocks.ps1）

### 使用方式

```powershell
.\Get-USStrongAStocks.ps1                              # 默认内置字典
.\Get-USStrongAStocks.ps1 -TopUS 12 -TopA 6
.\Get-USStrongAStocks.ps1 -UseWebSearch -Days 90       # 深度Web搜索
```

---

## Entry Timing — 日内买点判断（Get-EntryTiming.ps1）

### 使用方式

```powershell
.\Get-EntryTiming.ps1 -Code 600519
.\Get-EntryTiming.ps1 -Code 300750 -Quiet
```

### 行为规范

1. **推荐股默认带买点**：当输出推荐股时，默认附带买点结论。
2. **先给时间，再给理由**：先说几点更适合入手，再用一句话解释。
3. **不鼓励追高**：若股价脱离均价线过远或主力资金转负，建议等午后或次日。

---

## Backtest — 历史推荐回测（Get-Backtest.ps1）

### 使用方式

```powershell
.\Get-Backtest.ps1                                     # 最近30天
.\Get-Backtest.ps1 -SignalFilter 价值洼地              # 按信号类型
.\Get-Backtest.ps1 -Days 90
```

---

## Daily Brief — 每日早报（Get-DailyBrief.ps1）

### 使用方式

```powershell
.\Get-DailyBrief.ps1                                   # 控制台显示
.\Get-DailyBrief.ps1 -Top 5 -Save                     # 保存到桌面
```

---

## 自动化定时任务（Register-DailyTasks.ps1）

```powershell
.\Register-DailyTasks.ps1              # 注册（需管理员）
.\Register-DailyTasks.ps1 -Unregister  # 卸载
```

| 任务名 | 触发时间 | 输出文件（桌面） |
|--------|---------|------------------|
| `MyClaw_USReport_0500` | 每天 05:00 | `YYYY-MM-DD-美股强势.txt` |
| `MyClaw_AlphaSignal_0900` | 每天 09:00 | `YYYY-MM-DD-AlphaSignal.txt` |

---

# Polish Word（邮件/Teams 回复生成）

## 目的

根据用户提供的 **关键词 / 要点**，生成专业、礼貌的英文回复文本，用于 Email 和 Teams 消息。

## 生成规则

- **默认英文**，除非用户明确要求中文
- **Microsoft 内部沟通风格**：专业但不过度正式，友好但高效
- **署名**：Hongyang（仅 Email）
- **默认语气**：casual

### Email 规则

1. `Hi <Name>,` 开头
2. 先 acknowledge 对方 → 再表达自己观点 → action items 用列表 → next steps
3. `Thanks,` + `Hongyang` 结尾
4. 3-8 句话

### Teams 消息

1. 1-3 句话，更口语化
2. 无 Subject/署名
3. 可用 emoji（👍✅🙏）

## 行为规范

1. **直接输出文本**：不需要运行任何脚本
2. **只给一个版本**
3. **中文关键词 → 英文输出**：忠实翻译要点范围，不添加用户没提到的内容
4. **Teams/Chat 极简**：默认 1 句话 + emoji
