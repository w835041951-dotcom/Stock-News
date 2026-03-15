# MyClaw Stock-News 使用说明书

> A 股智能分析工具集 · PowerShell 版
> 涵盖：AI 选股 · 热点追踪 · 估值分析 · 盘中买点 · 美股联动 · 自选股管理 · 回测验证 · 每日早报

---

## 目录

1. [项目简介](#1-项目简介)
2. [环境准备](#2-环境准备)
3. [快速上手（5 分钟）](#3-快速上手5-分钟)
4. [脚本功能总览](#4-脚本功能总览)
5. [详细用法](#5-详细用法)
   - [Get-AlphaSignal — 每日 AI 选股](#51-get-alphasignal--每日-ai-选股主入口)
   - [Get-MarketHotspot — 热点板块分析](#52-get-markethotspot--热点板块分析)
   - [Get-StockDetail — 单股详情](#53-get-stockdetail--单股详情)
   - [Get-CapeValuation — 席勒 PE 估值](#54-get-capevaluation--席勒-pe-估值)
   - [Get-EntryTiming — 盘中买点](#55-get-entrytiming--盘中买点)
   - [Get-PartnerStocks — 美股联动 A 股](#56-get-partnerstocks--美股联动-a-股)
   - [Get-USStrongAStocks — 美股强势主题](#57-get-usstrongastocks--美股强势主题)
   - [Get-Watchlist — 自选股管理](#58-get-watchlist--自选股管理)
   - [Get-TrendingTopics — 全球热搜](#59-get-trendingtopics--全球热搜)
   - [Get-Backtest — 历史推荐回测](#510-get-backtest--历史推荐回测)
   - [Get-DailyBrief — 每日早报](#511-get-dailybrief--每日早报)
6. [自动化配置（定时任务）](#6-自动化配置定时任务)
7. [评分体系说明](#7-评分体系说明)
8. [常见问题](#8-常见问题)
9. [数据来源说明](#9-数据来源说明)

---

## 1. 项目简介

本工具集是一套基于 PowerShell 的 A 股辅助分析框架，通过调用东方财富、新浪财经、雪球、36Kr、Yahoo Finance 等多个公开数据接口，提供：

| 功能方向 | 解决的问题 |
|---------|-----------|
| 每日 AI 选股 | 自动筛选出当日最具潜力的 10 支股票并打分 |
| 热点板块追踪 | 找出当日资金流入最强的板块及其概念龙头 |
| 基本面估值 | 席勒 PE（CAPE）及 PE/PB 多维估值，判断高低位 |
| 盘中买点 | 分析主力资金流向 + 最佳介入时间窗口 |
| 美股联动 | 美股大涨后，秒找对应 A 股主题受益标的 |
| 自选股管理 | 记录持仓成本，实时展示盈亏与走势 |

**适用人群**：有一定 A 股投资经验，希望借助数据辅助决策的个人投资者。

> **免责声明**：本工具仅供参考，不构成投资建议。市场有风险，投资须谨慎。

---

## 2. 环境准备

### 2.1 必要软件

| 软件 | 版本要求 | 用途 |
|------|---------|------|
| PowerShell | 7.0 及以上（推荐 7.4+） | 运行所有脚本 |
| Python | 3.10 及以上 | EPS 历史数据 + 合作伙伴搜索 |
| pip 包：akshare | 最新版 | 获取 A 股历史财务数据 |
| pip 包：requests | 最新版 | HTTP 请求 |

### 2.2 安装检查

```powershell
# 检查 PowerShell 版本（需 ≥ 7.0）
pwsh --version

# 检查 Python
python --version

# 安装 Python 依赖
pip install akshare requests
```

### 2.3 执行策略设置（首次使用）

若提示脚本无法执行，以管理员身份运行 PowerShell 并执行：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 2.4 切换到脚本目录

```powershell
cd q:\MyClaw\stock-news
```

---

## 3. 快速上手（5 分钟）

**场景：今天开盘前，我想知道该买什么。**

```powershell
# 步骤 1：查看今日 AI 选股推荐（约 3~5 分钟完成）
.\Get-AlphaSignal.ps1

# 步骤 2：对感兴趣的股票查看盘中买点（例如貌似不错的 000001）
.\Get-EntryTiming.ps1 -Code 000001

# 步骤 3：加入自选股跟踪
.\Get-Watchlist.ps1 -Action add -Type rec -Code 000001 -Name 平安银行 -RecPrice 12.50 -Source AlphaSignal
```

**场景：美股昨晚大涨，想找 A 股受益标的。**

```powershell
# 查看美股强势股映射的 A 股主题（约 1 分钟）
.\Get-USStrongAStocks.ps1 -TopUS 10
```

---

## 4. 脚本功能总览

| 脚本文件 | 一句话功能 | 典型耗时 |
|---------|-----------|--------|
| `Get-AlphaSignal.ps1` | **主入口**：6 段式全市场分析 + AI TOP10 选股 | 3~6 分钟 |
| `Get-MarketHotspot.ps1` | 热点板块 + 情绪指数 + 板块龙头推荐 | 2~4 分钟 |
| `Get-StockDetail.ps1` | 单股基本面：财报、PE、PB、ROE、分红 | 10~30 秒 |
| `Get-CapeValuation.ps1` | 席勒 PE 估值：10 年 EPS 均值、历史百分位 | 20~60 秒 |
| `Get-EntryTiming.ps1` | 盘中买点：主力资金流向 + 最佳入场时间窗 | 5~15 秒 |
| `Get-PartnerStocks.ps1` | 美股→A 股联动：新闻证据挖掘 + 关系评分 | 1~3 分钟 |
| `Get-USStrongAStocks.ps1` | 美股强势股→18 大主题→A 股候选 | 1~2 分钟 |
| `Get-Watchlist.ps1` | 自选股 / 持仓管理：历史记录 + 实时行情 | 5~30 秒 |
| `Get-TrendingTopics.ps1` | 全球热搜（百度/谷歌/头条）趋势先行指标 | 10~30 秒 |
| `Get-Backtest.ps1` | **NEW** 回测：追踪历史推荐的实际涨跌表现 + 胜率统计 | 1~3 分钟 |
| `Get-DailyBrief.ps1` | **NEW** 每日早报：一句话总结 + TOP3 + 热点，可保存桌面 | 3~5 分钟 |
| `Register-DailyTasks.ps1` | 注册 Windows 定时任务，每日自动运行 | 立即 |

---

## 5. 详细用法

### 5.1 Get-AlphaSignal — 每日 AI 选股（主入口）

**功能**：综合全球趋势、市场情绪、热点板块、基本面、技术面、估值六个维度，输出得分最高的 TOP N 只股票及理由。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-TopN` | int | 10 | 最终推荐股票数量 |
| `-Quiet` | switch | 关 | 仅返回对象，不打印表格（用于管道/脚本内调用） |

#### 示例

```powershell
# 最常用：获取今日 TOP 10 推荐
.\Get-AlphaSignal.ps1

# 获取 TOP 15（更多候选）
.\Get-AlphaSignal.ps1 -TopN 15

# 静默模式，将结果存入变量供后续处理
$result = .\Get-AlphaSignal.ps1 -Quiet
$result.Recommendations | Select-Object Code, Name, TotalScore | Sort-Object -Descending TotalScore
```

#### 输出说明

控制台分段输出：
1. **全球趋势热词** — 今日非金融领域热搜关键词
2. **市场情绪指数** — 1（极度悲观）到 10（极度乐观）
3. **信息差分析** — 热点话题 vs 新闻覆盖度的差距（越大越值得关注）
4. **热点板块** — 资金净流入最强的板块 + 近期回调幅度
5. **候选股票评分** — 基本面(0-40) + 技术面(0-30) + 估值(0-30) = 总分 100
6. **最终推荐** — 综合排名 + 买入时机建议

---

### 5.2 Get-MarketHotspot — 热点板块分析

**功能**：独立运行的市场热点扫描器，获取当日资金主攻方向。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Action` | string | all | `news`=仅新闻情绪、`sectors`=仅板块、`recommend`=仅推荐股、`all`=全部 |
| `-TopN` | int | 10 | 返回数量 |
| `-Quiet` | switch | 关 | 静默模式 |

#### 示例

```powershell
# 全量分析（情绪 + 板块 + 推荐）
.\Get-MarketHotspot.ps1

# 只想快速看热点板块
.\Get-MarketHotspot.ps1 -Action sectors -TopN 20

# 只看今日市场情绪
.\Get-MarketHotspot.ps1 -Action news

# 只要推荐股（TOP 5）
.\Get-MarketHotspot.ps1 -Action recommend -TopN 5
```

---

### 5.3 Get-StockDetail — 单股详情

**功能**：快速查询一只股票的基本面数据：实时行情、近期涨跌、财报摘要、分红情况、行业估值对比。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Code` | string | **必填** | 股票代码，支持 `600519` / `SH600519` / `sz000001` 格式 |
| `-Action` | string | all | `all`=全部、`finance`=财报、`price`=行情、`valuation`=估值 |
| `-Quiet` | switch | 关 | 静默模式 |

#### 示例

```powershell
# 贵州茅台完整基本面
.\Get-StockDetail.ps1 -Code 600519

# 只看财务报表
.\Get-StockDetail.ps1 -Code 000001 -Action finance

# 只看实时行情
.\Get-StockDetail.ps1 -Code 300750 -Action price
```

#### 输出包含

- 当前价、PE(TTM)、PB、市值
- 近 1 周 / 近 1 月涨跌幅
- 最近 4 季度：营收、净利润、净利率、ROE
- 股息率 (TTM) + 近期分红历史
- 行业名称 + 行业中位 PE

---

### 5.4 Get-CapeValuation — 席勒 PE 估值

**功能**：基于 10 年均值 EPS 计算 CAPE（席勒 PE），评估股票是否被低估/高估，并给出历史百分位。

> 主要适用于**周期性行业**（钢铁、化工、煤炭、有色、汽车等）。银行、白酒等非周期行业建议用普通 PE/PB 评估。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Code` | string | **必填** | 股票代码 |
| `-Years` | int | 10 | EPS 均值窗口年数（3~15） |
| `-AnnualInflationRate` | double | 无 | 通胀率（%），用于计算实际 CAPE，如 `2.5` |
| `-Quiet` | switch | 关 | 静默模式 |

#### 示例

```powershell
# 标准 CAPE（10年均值EPS）
.\Get-CapeValuation.ps1 -Code 600519

# 使用 8 年数据（历史较短时适用）
.\Get-CapeValuation.ps1 -Code 000001 -Years 8

# 含通胀调整的实际 CAPE（假设年通胀 2.5%）
.\Get-CapeValuation.ps1 -Code 601398 -AnnualInflationRate 2.5

# 静默模式，取估值对象
$val = .\Get-CapeValuation.ps1 -Code 600519 -Quiet
Write-Host "CAPE: $($val.CAPE)  等级: $($val.CapeLevel)"
```

#### 估值等级

| CAPE 水平 | 等级 | 含义 |
|-----------|------|------|
| 历史低位 | Low | 低估，关注机会 |
| 历史中位 | Neutral | 合理 |
| 历史高位 | High | 偏贵，谨慎 |
| 极度高位 | Very High | 泡沫风险 |

---

### 5.5 Get-EntryTiming — 盘中买点

**功能**：分析当日分钟级主力资金流向，判断最佳入场时间窗口，给出买入/等待/回避建议。

> **建议在开盘期间（09:30~15:00）使用**，盘后数据为当日收盘数据。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Code` | string | **必填** | 股票代码 |
| `-Quiet` | switch | 关 | 静默模式 |

#### 示例

```powershell
# 查看平安银行今日买点
.\Get-EntryTiming.ps1 -Code 000001

# 静默模式管道使用
$timing = .\Get-EntryTiming.ps1 -Code 600519 -Quiet
Write-Host "动作: $($timing.Action)  置信度: $($timing.Confidence)"
```

#### 输出字段说明

| 字段 | 含义 |
|------|------|
| `IntradayBias` | 盘面偏强 / 震荡 / 偏弱 |
| `FundFlowBias` | 主力资金方向（净流入/流出） |
| `PriceVsAvgPct` | 当前价偏离均价线百分比 |
| `PrimaryWindow` | 首选入场时间窗（如 10:00~10:30） |
| `SecondaryWindow` | 备选入场时间窗 |
| `Action` | 操作建议（分批低吸 / 不追高 / 等待确认 / 回避） |
| `Confidence` | 置信度（35%~82%） |

---

### 5.6 Get-PartnerStocks — 美股联动 A 股

**功能**：输入一只美股代码，通过新闻证据挖掘找出最相关的 A 股合作/受益/竞争标的，并给出关联强度评分。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Target` | string | **必填** | 美股代码或公司名（如 `NVDA` / `英伟达`） |
| `-TopN` | int | 10 | 返回候选数量 |
| `-Days` | int | 60 | 新闻回溯天数 |
| `-UseWebSearch` | bool | true | 是否启用网络搜索（更准但更慢） |
| `-Quiet` | switch | 关 | 静默模式 |

#### 示例

```powershell
# 查找英伟达相关 A 股
.\Get-PartnerStocks.ps1 -Target NVDA

# 查找特斯拉相关 A 股，扩大到 15 只
.\Get-PartnerStocks.ps1 -Target TSLA -TopN 15

# 快速模式（不使用网络+搜索，仅用缓存数据）
.\Get-PartnerStocks.ps1 -Target MSFT -UseWebSearch $false

# 追溯更长时间（90天）的新闻
.\Get-PartnerStocks.ps1 -Target AAPL -Days 90
```

#### 输出包含

- A 股公司名称 + 代码
- 关联类型（供应商 / 客户 / 竞争 / 主题受益）
- 置信度评分 + 新闻条数
- 营收同比、净利同比、PE、PB
- 盘中买点建议

---

### 5.7 Get-USStrongAStocks — 美股强势主题

**功能**：自动抓取当日美股涨幅榜，映射到 18 大主题，再找出对应 A 股候选标的并评估。比手动找快 100 倍。

#### 支持的 18 大主题

`AI`、`EV`（新能源车）、`Cloud`（云计算）、`Semiconductor`（半导体）、`Healthcare`、`Energy`、`Finance`、`Consumer`（消费）、`Industrial`、`Materials`（原材料）、`Telecom`、`Media`、`Retail`、`Defense`（军工）、`Logistics`（物流）、`Agriculture`（农业）、`Tourism`（旅游）、`Biotech`

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-TopUS` | int | 8 | 抓取美股涨幅榜前 N 名 |
| `-TopA` | int | 5 | 每个主题返回 A 股候选数 |
| `-Days` | int | 90 | 联动搜索回溯天数 |
| `-UseWebSearch` | switch | 关 | 启用深度合作伙伴搜索（更慢） |
| `-Quiet` | switch | 关 | 静默模式 |

#### 示例

```powershell
# 最常用：快速看当日美股强势→A股主题
.\Get-USStrongAStocks.ps1

# 看美股前 12 强，每主题给 8 个 A 股候选
.\Get-USStrongAStocks.ps1 -TopUS 12 -TopA 8

# 深度模式（启用新闻搜索，更精准但需 3+ 分钟）
.\Get-USStrongAStocks.ps1 -UseWebSearch
```

---

### 5.8 Get-Watchlist — 自选股管理

**功能**：维护一份自选股清单（持仓 + 推荐观察），记录成本价、数量，实时展示持仓盈亏和历史价格。

数据保存在脚本目录下的 `watchlist.json` 文件中。

#### 参数

| 参数 | 类型 | 说明 |
|------|------|------|
| `-Action` | string | `show`=展示、`add`=添加、`remove`=删除、`update`=更新、`history`=历史 |
| `-Type` | string | `holding`=持仓、`rec`=观察推荐 |
| `-Code` | string | 股票代码 |
| `-Name` | string | 股票名称 |
| `-Cost` | double | 持仓成本价（元/股） |
| `-Qty` | int | 持股数量（股） |
| `-PartnerStock` | string | 持仓/推荐关联股票信息，支持 `编号,名称,关联;编号,名称,关联` 或 JSON |
| `-RecPrice` | double | 推荐时价格 |
| `-Source` | string | 推荐来源标注（如 `AlphaSignal`） |
| `-Days` | int | history 模式下回溯天数，默认 7 |
| `-IncludeCAPE` | bool | 是否计算 CAPE 估值，默认开（关闭更快） |
| `-Quiet` | switch | 静默模式 |

#### 示例

```powershell
# 查看当前自选股列表（含实时行情）
.\Get-Watchlist.ps1

# 添加持仓股票（平安银行，成本 12.5 元，买了 1000 股）
.\Get-Watchlist.ps1 -Action add -Type holding -Code 000001 -Name 平安银行 -Cost 12.50 -Qty 1000

# 添加/更新持仓并写入关联股票信息（简写）
.\Get-Watchlist.ps1 -Action add -Type holding -Code 000001 -PartnerStock "600036,招商银行,同业对标;002142,宁波银行,区域同业"

# 添加/更新持仓并写入关联股票信息（JSON）
.\Get-Watchlist.ps1 -Action add -Type holding -Code 000001 -PartnerStock '[{"code":"600036","name":"招商银行","relation":"同业对标"},{"code":"002142","name":"宁波银行","relation":"区域同业"}]'

# 添加观察推荐股（从 AlphaSignal 推荐）
.\Get-Watchlist.ps1 -Action add -Type rec -Code 600519 -Name 贵州茅台 -RecPrice 1500 -Source AlphaSignal

# 添加/更新推荐并写入关联股票信息
.\Get-Watchlist.ps1 -Action add -Type rec -Code 600519 -PartnerStock "000858,五粮液,白酒同业;000568,泸州老窖,白酒同业"

# 删除一只股票
.\Get-Watchlist.ps1 -Action remove -Code 000001

# 查看最近 30 天价格历史
.\Get-Watchlist.ps1 -Action history -Days 30

# 快速展示（不计算 CAPE，更快）
.\Get-Watchlist.ps1 -IncludeCAPE $false
```

---

### 5.9 Get-TrendingTopics — 全球热搜

**功能**：抓取各地区热搜排行，用于发现未被市场充分讨论的潜在热点（信息差）。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Action` | string | all | `cn`=中国、`us`=美国、`jp`=日本、`eu`=欧洲、`all`=全部 |
| `-TopN` | int | 15 | 每个来源展示条数 |
| `-Quiet` | switch | 关 | 静默模式 |

#### 示例

```powershell
# 全球热搜一览
.\Get-TrendingTopics.ps1

# 只看中国热搜（百度 + 头条）
.\Get-TrendingTopics.ps1 -Action cn

# 只看美国热搜（Google Trends）
.\Get-TrendingTopics.ps1 -Action us -TopN 20
```

---

### 5.10 Get-Backtest — 历史推荐回测

**功能**：读取 `recommendations-log.csv`（由 `Get-AlphaSignal.ps1` 每次运行自动写入），通过东方财富历史 K 线 API 查询推荐后 1日/1周/1月 的实际涨跌，计算胜率和平均收益率。

> **数据积累**：每次运行 `Get-AlphaSignal.ps1` 会自动追加当天推荐到 CSV，不会重复写入。积累 1-2 周后回测数据才有参考意义。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Days` | int | 30 | 回溯多少天的推荐记录 |
| `-SignalFilter` | string | 全部 | 按信号类型过滤：`价值洼地` / `景气反转` / `主题热点` |
| `-Quiet` | switch | 关 | 静默模式，返回对象 |

#### 示例

```powershell
# 查看最近30天推荐的实际表现
.\Get-Backtest.ps1

# 只看"价值洼地"信号的胜率
.\Get-Backtest.ps1 -SignalFilter 价值洼地

# 回溯更长时间
.\Get-Backtest.ps1 -Days 90
```

#### 输出包含

- 每条推荐记录的 1日/1周/1月 实际收益率
- 全量汇总：平均收益率、胜率、最大/最小绩效
- 按信号类型分组对比：价值洼地 vs 景气反转 vs 主题热点

---

### 5.11 Get-DailyBrief — 每日早报

**功能**：一键生成格式化的纯文本早报，适合每天开盘前快速浏览，也可以保存备份、分享给朋友。

#### 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Top` | int | 3 | 早报中展示的推荐股票数 |
| `-Save` | switch | 关 | 保存早报到桌面（文件名：`YYYY-MM-DD-A股早报.txt`） |
| `-Quiet` | switch | 关 | 静默模式，返回对象 |

#### 示例

```powershell
# 生成今日早报（控制台显示）
.\Get-DailyBrief.ps1

# 生成 TOP5 早报并保存桌面
.\Get-DailyBrief.ps1 -Top 5 -Save

# 获取早报对象（用于进一步处理）
$brief = .\Get-DailyBrief.ps1 -Quiet
Write-Host "今日情绪: $($brief.SentimentLabel)"
```

#### 早报样例

```
========================================================
  A股早报  2025年03月13日
========================================================

  市场情绪：7/10（偏乐观）
  情绪指标：[■■■■■■■□□□]
  多头信号 12 条 | 空头信号 4 条

  看多要点：央行维持宽松，A股流动性充裕

--------------------------------------------------------

  今日信号分布：价值洼地 2只  景气反转 1只  主题热点 7只

  TOP 3 推荐

  ★ 1. 贵州茅台（600519）  评分 87  [价值洼地]
     现价:1498.00 元  PEG=1.23
     止损参考:1378.16 元  仓位建议:15-20%  预计持有:长线 3-6月
     买点:10:00-10:30  操作:分批低吸
     主力净流入偏强，价格接近均线支撑

  ★ 2. ...
```

---

## 6. 自动化配置（定时任务）

每天自动运行分析，把结果输出到桌面文件，省去手动操作。

### 注册任务（需要管理员权限）

```powershell
# 以管理员身份在 PowerShell 中执行
cd q:\MyClaw\stock-news
.\Register-DailyTasks.ps1
```

注册后将创建两个 Windows 定时任务：

| 任务名 | 触发时间 | 输出文件（桌面） |
|--------|---------|----------------|
| `MyClaw_USReport_0500` | 每天 05:00 | `YYYY-MM-DD-美股强势.txt` |
| `MyClaw_AlphaSignal_0900` | 每天 09:00 | `YYYY-MM-DD-AlphaSignal.txt` |

### 卸载任务

```powershell
.\Register-DailyTasks.ps1 -Unregister
```

### 手动执行脚本并保存输出

```powershell
# 手动生成 AlphaSignal 报告到桌面
.\Get-AlphaSignal.ps1 > "$env:USERPROFILE\Desktop\$(Get-Date -Format 'yyyy-MM-dd')-AlphaSignal.txt"
```

---

## 7. 评分体系说明

`Get-AlphaSignal.ps1` 和 `Get-MarketHotspot.ps1` 使用同一套三维评分体系（满分 100 分）：

### 三维评分结构

| 维度 | 满分 | 主要指标 |
|------|------|---------|
| 基本面 | 40 | 营收增速 + 净利增速 + ROE + 毛利率 + **PEG** + **财报趋势** |
| 技术面 | 30 | 近一周/近一月回调幅度 + RSI 超卖 |
| 估值面 | 30 | 周期股用 CAPE + PE；非周期股用 PE + PB + **相对行业PE** |

### 新增改进项

**PEG（市盈增长比）** = PE(TTM) ÷ 净利润增速（增速>5%时生效）
- PEG < 0.5：+8分（增长极便宜）
- PEG 0.5~1.0：+5分
- PEG 1.0~1.5：+2分
- PEG > 3.0：-3分

**相对行业PE修正**（非周期股）
- PE / 行业中位PE < 0.8：+5分（比行业便宜20%以上）
- PE / 行业中位PE > 1.3：-3分（比行业贵30%以上）

**财报趋势**（最近3季度対比）
- 毛利率持续改善：+5分；持续恶化：-3分
- ROE 持续改善：+3分；持续恶化：-2分

**流动性过滤**：换手率 < 0.3% 的股票自动排除推荐

**缓存版本管理**：缓存 key 内含版本号（当前 `v4`），数据结构变更后旧缓存自动失效，不再出现字段丢失问题。

### 运行诊断（每次运行后自动输出）

`Get-AlphaSignal.ps1` 运行结束时，底部会打印一行诊断摘要：

```
──────────────────────────────────────────────────────
  运行诊断
    各步耗时: S1_热搜 3.2s  |  S2_新闻 8.1s  |  S3_信息差 1.0s  |  S4_板块 45.3s  |  S5_K线 22.6s  |  S6_评分 98.4s
    总耗时: 178.6s  |  缓存命中: 23  |  API失败: 2  |  跳过股票: 4
```

| 指标 | 含义 |
|------|------|
| 各步耗时 | 每个阶段的用时，快速定位慢在哪一步 |
| 总耗时 | 脚本端到端运行时间 |
| 缓存命中 | 从磁盘缓存读取的次数（越高越快） |
| API失败 | 网络请求失败次数（>5 时建议检查网络） |
| 跳过股票 | 因换手率过低被过滤掉的股票数量 |

### 信号类型

每只推荐股票会标注以下信号类型：

| 信号类型 | 判断条件 | 建议持有时长 | 仓位参考 |
|---------|---------|------------|--------|
| 价值洼地 | CAPE 低估 或 PE 低于行业均值 80% | 长线 3-6月 | 15-20%（高分） |
| 景气反转 | 营收增速 > 25% 且 净利增速 > 25% | 波段 1-2月 | 10-15% |
| 主题热点 | 其余情况 | 短线 1-2周 | 5-10% |

### 止损参考

默认止损位 = 当前价 × 92%（即下跌 8% 止损），作为参考而非绝对规则。

---

## 8. 常见问题

**Q: 提示"无法加载文件，因为在此系统上禁止运行脚本"**
A: 以管理员身份运行 PowerShell，执行：
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Q: Get-CapeValuation 提示 Python 未找到**
A: 确认 Python 已安装并配置了以下路径之一：
- `C:\Dev\MyClaw\.venv\Scripts\python.exe`
- `C:\Users\<用户名>\AppData\Local\Programs\Python\Python3xx\python.exe`
- 或系统 PATH 中的 `python` 命令

**Q: 输出中文乱码**
A: 确认在 PowerShell 7+ 中运行（不是 Windows PowerShell 5.1）。可运行 `pwsh` 进入 PowerShell 7。

**Q: 某些股票找不到数据**
A: 本工具**不支持**科创板（688xxx）和北交所（8xxxxx）股票，仅支持：
- 沪市主板（6xxxxx）
- 深市主板 + 创业板（0xxxxx, 1xxxxx, 2xxxxx, 3xxxxx）

**Q: 运行很慢**
A: 工具使用磁盘缓存（位于 `%TEMP%\MyClaw_StockCache`），首次运行较慢（5~10 分钟），之后 4 小时内重复运行会快很多。可以用 `-Quiet` 减少输出开销。运行结束后查看底部的**运行诊断**，"各步耗时"可以精确定位是哪个阶段慢（通常是 S4_板块 和 S6_评分，因为涉及大量逐股 API 调用）。

**Q: 数据准确吗？**
A: 数据实时来源于东方财富、新浪、雪球等公开接口，与通常行情软件一致。但网络波动或接口更新可能导致个别数据缺失，建议结合正规行情软件交叉验证。

---

## 9. 数据来源说明

| 数据类型 | 来源 |
|---------|------|
| A 股实时行情、板块、资金流 | 东方财富（东财）API |
| 财务报表、PE/PB/分红 | 东方财富 F10 数据 |
| 历史 EPS（10年+） | Akshare（AKShare Python 库）|
| 市场新闻 | 新浪财经、东财资讯 |
| 情绪分析 | 雪球、36Kr、东财 |
| 美股行情 | Yahoo Finance |
| 全球热搜 | 百度热搜、头条热榜、Google Trends |
| 合作伙伴新闻搜索 | Google / Bing（需网络访问） |

所有数据均为公开接口，不需要任何 API Key 或账号。

---

*文档生成时间：2026-03，适用版本：MyClaw stock-news（main 分支）*
