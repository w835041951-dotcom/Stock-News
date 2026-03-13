#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import datetime as dt
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from collections import defaultdict
from email.utils import parsedate_to_datetime
from html import unescape

import requests

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

ALIAS_MAP = {
    # ── AI / 半导体 ──────────────────────────────────────────────
    "NVDA":  ["英伟达", "NVIDIA", "NVDA"],
    "NVIDIA":["英伟达", "NVIDIA", "NVDA"],
    "英伟达":["英伟达", "NVIDIA", "NVDA"],
    "AMD":   ["AMD", "超威半导体", "Advanced Micro Devices"],
    "INTC":  ["英特尔", "Intel", "INTC"],
    "AVGO":  ["博通", "Broadcom", "AVGO"],
    "QCOM":  ["高通", "Qualcomm", "QCOM"],
    "MU":    ["美光科技", "Micron", "MU"],
    "MRVL":  ["美满电子", "Marvell", "MRVL"],
    "ARM":   ["ARM控股", "ARM Holdings", "ARM"],
    "TSM":   ["台积电", "TSMC", "TSM"],
    "ASML":  ["阿斯麦", "ASML", "光刻机"],
    "LRCX":  ["泛林集团", "Lam Research", "LRCX"],
    "AMAT":  ["应用材料", "Applied Materials", "AMAT"],
    "KLAC":  ["科磊", "KLA", "KLAC"],
    "ON":    ["安森美", "onsemi", "ON Semiconductor"],
    "MPWR":  ["芯源系统", "Monolithic Power", "MPWR"],
    "SMCI":  ["超微电脑", "Super Micro", "SMCI"],
    "MSFT":  ["微软", "Microsoft", "MSFT"],
    "GOOGL": ["谷歌", "Google", "Alphabet", "GOOGL"],
    "GOOG":  ["谷歌", "Google", "Alphabet", "GOOG"],
    "META":  ["Meta", "脸书", "Facebook", "META"],
    "CRM":   ["赛富时", "Salesforce", "CRM"],
    "PLTR":  ["帕兰提尔", "Palantir", "PLTR"],
    "AI":    ["C3.ai", "C3 AI", "AI"],
    "DELL":  ["戴尔", "Dell", "DELL"],
    "HPE":   ["慧与科技", "Hewlett Packard Enterprise", "HPE"],
    "CDNS":  ["楷登电子", "Cadence", "CDNS"],
    "SNPS":  ["新思科技", "Synopsys", "SNPS"],
    "MCHP":  ["微芯科技", "Microchip Technology", "MCHP"],
    "TXN":   ["德州仪器", "Texas Instruments", "TXN"],
    "NXPI":  ["恩智浦", "NXP Semiconductors", "NXPI"],
    "SWKS":  ["思佳讯", "Skyworks", "SWKS"],
    "QRVO":  ["科沃", "Qorvo", "QRVO"],
    "CEVA":  ["CEVA", "CEVA半导体", "CEVA IP"],
    "SITM":  ["SiTime", "硅时钟", "SITM"],
    "AXTI":  ["AXT", "美晶科技", "AXTI"],

    # ── 新能源 / EV ──────────────────────────────────────────────
    "TSLA":  ["特斯拉", "Tesla", "TSLA"],
    "TESLA": ["特斯拉", "Tesla", "TSLA"],
    "特斯拉":["特斯拉", "Tesla", "TSLA"],
    "NIO":   ["蔚来", "NIO", "蔚来汽车"],
    "XPEV":  ["小鹏汽车", "XPeng", "XPEV"],
    "LI":    ["理想汽车", "Li Auto", "LI"],
    "RIVN":  ["Rivian", "瑞偲", "RIVN"],
    "LCID":  ["Lucid", "路西德", "LCID"],
    "F":     ["福特", "Ford", "F"],
    "GM":    ["通用汽车", "General Motors", "GM"],
    "ENPH":  ["安费诺光", "Enphase", "ENPH"],
    "SEDG":  ["SolarEdge", "太阳能逆变器", "SEDG"],
    "FSLR":  ["第一太阳能", "First Solar", "FSLR"],
    "RUN":   ["Sunrun", "日照能", "RUN"],
    "PLUG":  ["Plug Power", "普拉格", "PLUG"],
    "BE":    ["Bloom Energy", "布鲁姆能源", "BE"],
    "BLDP":  ["巴拉德电源", "Ballard Power", "BLDP"],
    "ALB":   ["雅宝", "Albemarle", "ALB", "锂矿"],
    "SQM":   ["SQM", "智利化工矿业", "Sociedad Quimica"],
    "LAC":   ["锂美洲", "Lithium Americas", "LAC"],
    "LTHM":  ["Livent", "莱文特", "LTHM"],
    "PLL":   ["Piedmont Lithium", "皮德蒙锂", "PLL"],
    "CHPT":  ["ChargePoint", "充电点", "CHPT"],
    "BLNK":  ["Blink Charging", "眨眼充电", "BLNK"],
    "POWI":  ["Power Integrations", "电源集成", "POWI"],
    "STEM":  ["Stem", "储能", "STEM"],
    "ARRY":  ["阵列科技", "Array Technologies", "ARRY"],
    "NOVA":  ["Nova", "诺瓦", "NOVA"],
    "SPWR":  ["SunPower", "太阳能", "SPWR"],

    # ── 医药 / 生物科技 ──────────────────────────────────────────
    "LLY":   ["礼来", "Eli Lilly", "LLY"],
    "NVO":   ["诺和诺德", "Novo Nordisk", "NVO"],
    "JNJ":   ["强生", "Johnson Johnson", "JNJ"],
    "PFE":   ["辉瑞", "Pfizer", "PFE"],
    "MRK":   ["默沙东", "Merck", "MRK"],
    "ABBV":  ["艾伯维", "AbbVie", "ABBV"],
    "BMY":   ["百时美施贵宝", "Bristol Myers Squibb", "BMY"],
    "AMGN":  ["安进", "Amgen", "AMGN"],
    "GILD":  ["吉利德", "Gilead", "GILD"],
    "REGN":  ["再生元", "Regeneron", "REGN"],
    "VRTX":  ["福泰", "Vertex Pharmaceuticals", "VRTX"],
    "MRNA":  ["莫德纳", "Moderna", "MRNA"],
    "BIIB":  ["渤健", "Biogen", "BIIB"],
    "AZN":   ["阿斯利康", "AstraZeneca", "AZN"],
    "SNY":   ["赛诺菲", "Sanofi", "SNY"],
    "BNTX":  ["BioNTech", "百欧恩泰", "BNTX"],
    "BGNE":  ["百济神州", "BeiGene", "BGNE"],
    "ILMN":  ["因美纳", "Illumina", "ILMN"],
    "RGEN":  ["Repligen", "雷普利根", "RGEN"],
    "HALO":  ["Halozyme", "卤酶", "HALO"],
    "INSM":  ["Insmed", "因斯迈", "INSM"],
    "LEGN":  ["传奇生物", "Legend Biotech", "LEGN"],
    "RXRX":  ["Recursion", "递归制药", "RXRX"],

    # ── 消费 / 零售 ──────────────────────────────────────────────
    "AAPL":  ["苹果", "Apple", "AAPL"],
    "APPLE": ["苹果", "Apple", "AAPL"],
    "苹果":  ["苹果", "Apple", "AAPL"],
    "WMT":   ["沃尔玛", "Walmart", "WMT"],
    "COST":  ["好市多", "Costco", "COST"],
    "NKE":   ["耐克", "Nike", "NKE"],
    "SBUX":  ["星巴克", "Starbucks", "SBUX"],
    "MCD":   ["麦当劳", "McDonald's", "MCD"],
    "PG":    ["宝洁", "Procter Gamble", "PG"],
    "KO":    ["可口可乐", "Coca Cola", "KO"],
    "PEP":   ["百事可乐", "PepsiCo", "PEP"],
    "EL":    ["雅诗兰黛", "Estee Lauder", "EL"],
    "LULU":  ["露露柠檬", "Lululemon", "LULU"],
    "TGT":   ["塔吉特", "Target", "TGT"],
    "DG":    ["达乐零售", "Dollar General", "DG"],
    "AMZN":  ["亚马逊", "Amazon", "AMZN"],
    "HD":    ["家得宝", "Home Depot", "HD"],
    "LOW":   ["劳氏", "Lowe's", "LOW"],
    "YUM":   ["百胜餐饮", "Yum! Brands", "YUM"],
    "QSR":   ["餐饮品牌国际", "Restaurant Brands", "QSR"],
    "DLTR":  ["达乐树", "Dollar Tree", "DLTR"],
    "FIVE":  ["五分以下", "Five Below", "FIVE"],

    # ── 金融 ────────────────────────────────────────────────────
    "JPM":   ["摩根大通", "JPMorgan", "JPM"],
    "BAC":   ["美国银行", "Bank of America", "BAC"],
    "GS":    ["高盛", "Goldman Sachs", "GS"],
    "MS":    ["摩根士丹利", "Morgan Stanley", "MS"],
    "C":     ["花旗", "Citigroup", "Citibank", "C"],
    "WFC":   ["富国银行", "Wells Fargo", "WFC"],
    "BLK":   ["贝莱德", "BlackRock", "BLK"],
    "SCHW":  ["嘉信理财", "Charles Schwab", "SCHW"],
    "AXP":   ["美国运通", "American Express", "AXP"],
    "V":     ["Visa", "维萨", "V"],
    "MA":    ["万事达", "Mastercard", "MA"],
    "COF":   ["Capital One", "第一资本", "COF"],
    "DFS":   ["第一发现", "Discover Financial", "DFS"],
    "SPGI":  ["标普全球", "S&P Global", "SPGI"],
    "MCO":   ["穆迪", "Moody's", "MCO"],
    "ICE":   ["洲际交易所", "Intercontinental Exchange", "ICE"],
    "PYPL":  ["PayPal", "贝宝", "PYPL"],
    "SQ":    ["Block", "Square", "SQ"],
    "HOOD":  ["Robinhood", "罗宾汉", "HOOD"],
    "SOFI":  ["SoFi", "社会金融", "SOFI"],

    # ── 能源 / 石油 ──────────────────────────────────────────────
    "XOM":   ["埃克森美孚", "ExxonMobil", "XOM"],
    "CVX":   ["雪佛龙", "Chevron", "CVX"],
    "COP":   ["康菲", "ConocoPhillips", "COP"],
    "EOG":   ["EOG资源", "EOG Resources", "EOG"],
    "SLB":   ["斯伦贝谢", "Schlumberger", "SLB"],
    "OXY":   ["西方石油", "Occidental", "OXY"],
    "VLO":   ["瓦莱罗能源", "Valero", "VLO"],
    "MPC":   ["马拉松石油", "Marathon Petroleum", "MPC"],
    "PSX":   ["菲利普斯66", "Phillips 66", "PSX"],
    "HAL":   ["哈里伯顿", "Halliburton", "HAL"],
    "DVN":   ["戴文能源", "Devon Energy", "DVN"],
    "FANG":  ["钻石后背", "Diamondback Energy", "FANG"],
    "WMB":   ["威廉姆斯公司", "Williams Companies", "WMB"],
    "KMI":   ["金德摩根", "Kinder Morgan", "KMI"],
    "LNG":   ["切尼尔能源", "Cheniere Energy", "LNG"],

    # ── 化工 / 化肥 ──────────────────────────────────────────────
    "MOS":   ["马赛克", "Mosaic", "MOS", "磷肥"],
    "NTR":   ["纽崔恩", "Nutrien", "NTR", "钾肥"],
    "CF":    ["CF工业", "CF Industries", "CF"],
    "IPI":   ["摄政钾", "Intrepid Potash", "IPI"],
    "ICL":   ["以色列化学", "ICL Group", "ICL"],
    "DOW":   ["陶氏", "Dow", "Dow Chemical", "DOW"],
    "DD":    ["杜邦", "DuPont", "DD"],
    "LYB":   ["利安德巴塞尔", "LyondellBasell", "LYB"],
    "EMN":   ["伊士曼化学", "Eastman Chemical", "EMN"],
    "CE":    ["塞拉尼斯", "Celanese", "CE"],
    "CTVA":  ["科迪华", "Corteva", "CTVA", "农科"],
    "FMC":   ["富美实", "FMC", "FMC Corporation"],
    "APD":   ["空气化工", "Air Products", "APD"],
    "LIN":   ["林德", "Linde", "LIN"],
    "PPG":   ["PPG工业", "PPG Industries", "PPG"],

    # ── 有色金属 / 矿业 ──────────────────────────────────────────
    "FCX":   ["自由港麦克莫兰", "Freeport McMoRan", "FCX", "铜矿"],
    "NEM":   ["纽蒙特", "Newmont", "NEM", "金矿"],
    "GOLD":  ["巴里克黄金", "Barrick Gold", "GOLD"],
    "AEM":   ["安大略矿业", "Agnico Eagle", "AEM"],
    "WPM":   ["轮盘贵金属", "Wheaton Precious Metals", "WPM"],
    "RGLD":  ["皇家黄金", "Royal Gold", "RGLD"],
    "AA":    ["美国铝业", "Alcoa", "AA"],
    "X":     ["美国钢铁", "U.S. Steel", "X"],
    "CLF":   ["克利夫兰克里夫斯", "Cleveland Cliffs", "CLF"],
    "NUE":   ["纽柯钢铁", "Nucor", "NUE"],
    "STLD":  ["钢动力", "Steel Dynamics", "STLD"],
    "VALE":  ["淡水河谷", "Vale", "VALE"],
    "BHP":   ["必和必拓", "BHP", "BHP Group"],
    "RIO":   ["力拓", "Rio Tinto", "RIO"],
    "SCCO":  ["南方铜业", "Southern Copper", "SCCO"],
    "TECK":  ["泰克资源", "Teck Resources", "TECK"],
    "MP":    ["MP材料", "MP Materials", "MP", "稀土"],
    "HL":    ["赫克拉矿业", "Hecla Mining", "HL"],
    "CTRA":  ["科特拉能源", "Coterra Energy", "CTRA"],
    "APA":   ["APA", "APA Corporation"],
    "OLN":   ["奥林", "Olin", "OLN", "氯碱化工"],

    # ── 军工 / 航天 ──────────────────────────────────────────────
    "LMT":   ["洛克希德马丁", "Lockheed Martin", "LMT"],
    "RTX":   ["雷神技术", "Raytheon", "RTX"],
    "NOC":   ["诺斯罗普格鲁曼", "Northrop Grumman", "NOC"],
    "BA":    ["波音", "Boeing", "BA"],
    "GD":    ["通用动力", "General Dynamics", "GD"],
    "HII":   ["亨廷顿英戈尔斯", "Huntington Ingalls", "HII"],
    "LHX":   ["L3哈里斯", "L3Harris", "LHX"],
    "TDG":   ["穿油公司", "TransDigm", "TDG"],
    "HEI":   ["HEICO", "赫伊科", "HEI"],
    "KTOS":  ["科拉斯", "Kratos", "KTOS"],
    "AXON":  ["轴突", "Axon Enterprise", "AXON"],
    "LDOS":  ["莱多斯", "Leidos", "LDOS"],
    "SAIC":  ["科学应用国际", "SAIC", "Science Applications"],
    "CACI":  ["CACI国际", "CACI", "CACI International"],

    # ── 云计算 / SaaS / 网络安全 ─────────────────────────────────
    "SNOW":  ["Snowflake", "雪花", "SNOW"],
    "DDOG":  ["Datadog", "数据狗", "DDOG"],
    "NET":   ["Cloudflare", "云闪", "NET"],
    "ZS":    ["Zscaler", "泽斯凯勒", "ZS"],
    "CRWD":  ["CrowdStrike", "众击", "CRWD"],
    "PANW":  ["Palo Alto Networks", "帕洛奥托网络", "PANW"],
    "FTNT":  ["Fortinet", "飞塔", "FTNT"],
    "NOW":   ["ServiceNow", "服务现在", "NOW"],
    "WDAY":  ["Workday", "工作日", "WDAY"],
    "ORCL":  ["甲骨文", "Oracle", "ORCL"],
    "IBM":   ["IBM", "国际商业机器", "IBM"],
    "MDB":   ["MongoDB", "蒙古数据库", "MDB"],
    "TEAM":  ["Atlassian", "团队协作", "TEAM"],
    "HUBS":  ["HubSpot", "营销云", "HUBS"],
    "OKTA":  ["Okta", "身份安全", "OKTA"],
    "S":     ["SentinelOne", "哨兵一号", "S"],
    "CYBR":  ["CyberArk", "网络方舟", "CYBR"],
    "TENB":  ["Tenable", "特纳布", "TENB"],
    "QLYS":  ["Qualys", "优力思", "QLYS"],
    "HPQ":   ["惠普", "HP", "HPQ"],
    "SAP":   ["SAP", "思爱普", "SAP"],
    "INTU":  ["Intuit", "因特伊特", "INTU"],

    # ── 游戏 / 传媒 ──────────────────────────────────────────────
    "NFLX":  ["Netflix", "奈飞", "NFLX"],
    "DIS":   ["迪士尼", "Disney", "DIS"],
    "CMCSA": ["康卡斯特", "Comcast", "CMCSA"],
    "WBD":   ["华纳兄弟探索", "Warner Bros", "WBD"],
    "PARA":  ["派拉蒙", "Paramount", "PARA"],
    "EA":    ["艺电", "Electronic Arts", "EA"],
    "TTWO":  ["2K游戏", "Take-Two", "TTWO"],
    "RBLX":  ["Roblox", "罗布乐思", "RBLX"],
    "U":     ["Unity", "Unity Technologies", "U"],
    "SPOT":  ["Spotify", "声田", "SPOT"],
    "SNAP":  ["Snapchat", "Snap", "SNAP"],
    "ROKU":  ["Roku", "罗库", "ROKU"],
    "WMG":   ["华纳音乐", "Warner Music", "WMG"],
    "LYV":   ["Live Nation", "现场娱乐", "LYV"],

    # ── 地产 / REITs ─────────────────────────────────────────────
    "AMT":   ["美国电塔", "American Tower", "AMT"],
    "PLD":   ["普洛斯", "Prologis", "PLD"],
    "EQIX":  ["Equinix", "数据中心", "EQIX"],
    "SPG":   ["西蒙地产", "Simon Property", "SPG"],
    "O":     ["Realty Income", "房地产收入", "O"],
    "PSA":   ["公共储存", "Public Storage", "PSA"],
    "DLR":   ["数字地产", "Digital Realty", "DLR"],
    "WELL":  ["韦尔塔", "Welltower", "WELL"],
    "LEN":   ["莱纳房屋", "Lennar", "LEN"],
    "DHI":   ["D.R. Horton", "霍顿房屋", "DHI"],
    "TOL":   ["Toll Brothers", "坦纳", "TOL"],
    "NVR":   ["NVR", "NVR房屋"],
    "CSGP":  ["CoStar", "商业地产数据", "CSGP"],
    "Z":     ["Zillow", "地产平台", "Z"],

    # ── 交运 / 物流 ──────────────────────────────────────────────
    "UPS":   ["联合包裹", "UPS", "United Parcel Service"],
    "FDX":   ["联邦快递", "FedEx", "FDX"],
    "UNP":   ["联合太平洋铁路", "Union Pacific", "UNP"],
    "CSX":   ["CSX铁路", "CSX", "CSX Transportation"],
    "DAL":   ["达美航空", "Delta Air Lines", "DAL"],
    "UAL":   ["美国联合航空", "United Airlines", "UAL"],
    "LUV":   ["西南航空", "Southwest Airlines", "LUV"],
    "JBHT":  ["JB亨特", "J.B. Hunt", "JBHT"],
    "CHRW":  ["C.H. Robinson", "鲁滨逊物流", "CHRW"],
    "XPO":   ["XPO物流", "XPO Logistics", "XPO"],
    "SAIA":  ["赛亚货运", "Saia", "SAIA"],
    "ODFL":  ["老道明货运", "Old Dominion", "ODFL"],
    "EXPD":  ["快达物流", "Expeditors", "EXPD"],
    "GXO":   ["GXO物流", "GXO Logistics", "GXO"],

    # ── 农业 / 食品 ──────────────────────────────────────────────
    "ADM":   ["阿彻丹尼尔斯米德兰", "ADM", "Archer Daniels Midland"],
    "BG":    ["邦吉", "Bunge", "BG"],
    "INGR":  ["英格莱迪恩茨", "Ingredion", "INGR"],
    "DAR":   ["达灵格顿斯", "Darling Ingredients", "DAR"],
    "TSN":   ["泰森食品", "Tyson Foods", "TSN"],
    "HRL":   ["霍梅尔食品", "Hormel", "HRL"],
    "CAG":   ["康尼格拉", "Conagra", "CAG"],
    "SFM":   ["农贸集市", "Sprouts Farmers Market", "SFM"],
    "CALM":  ["卡缪农场", "Cal-Maine Foods", "CALM"],
    "VITL":  ["生命农场", "Vital Farms", "VITL"],
    "HZNP":  ["赫力子", "Horizon Therapeutics", "HZNP"],
    "BRFS":  ["巴西食品", "BRF", "BRFS"],

    # ── 电力 / 公用 ──────────────────────────────────────────────
    "NEE":   ["下一代能源", "NextEra Energy", "NEE"],
    "DUK":   ["杜克能源", "Duke Energy", "DUK"],
    "SO":    ["南方公司", "Southern Company", "SO"],
    "AEP":   ["美国电力", "American Electric Power", "AEP"],
    "D":     ["多米尼能源", "Dominion Energy", "D"],
    "EXC":   ["Exelon", "爱西龙", "EXC"],
    "SRE":   ["森普拉", "Sempra", "SRE"],
    "PCG":   ["太平洋煤气电力", "PG&E", "PCG"],
    "CEG":   ["星座能源", "Constellation Energy", "CEG"],
    "VST":   ["Vistra", "维斯特拉", "VST"],
    "ETR":   ["安特吉", "Entergy", "ETR"],
    "FE":    ["第一能源", "FirstEnergy", "FE"],
    "AES":   ["AES公司", "AES", "AES Corporation"],
    "PPL":   ["PPL公司", "PPL Corporation", "PPL"],
    "EIX":   ["爱迪生国际", "Edison International", "EIX"],

    # ── 机器人 / 自动化 ──────────────────────────────────────────
    "ISRG":  ["直觉外科", "Intuitive Surgical", "ISRG"],
    "HON":   ["霍尼韦尔", "Honeywell", "HON"],
    "ROK":   ["罗克韦尔自动化", "Rockwell Automation", "ROK"],
    "IRBT":  ["iRobot", "扫地机器人", "IRBT"],
    "CGNX":  ["康耐视", "Cognex", "CGNX"],
    "BRKS":  ["布鲁克斯自动化", "Brooks Automation", "BRKS"],
    "NVST":  ["恩维斯托", "Envista", "NVST"],
    "PTC":   ["PTC", "产品生命周期", "PTC"],
    "ENTG":  ["安特格里斯", "Entegris", "ENTG"],
    "ABB":   ["ABB", "ABB技术", "ABB asea"],
    "FANUC": ["发那科", "FANUC", "工业机器人"],
    "KEYB":  ["基恩士", "Keyence", "KEYB"],
    "TER":   ["泰瑞达", "Teradyne", "TER"],
    "NATI":  ["NI", "National Instruments", "NATI"],

    # ── 生物技术 CRO / CDMO ──────────────────────────────────────
    "IQV":   ["艾昆纬", "IQVIA", "IQV"],
    "CRL":   ["查尔斯河实验室", "Charles River", "CRL"],
    "MEDP":  ["美德同道", "Medpace", "MEDP"],
    "ICLR":  ["爱尔兰临床研究", "Icon", "ICLR"],
    "SYNH":  ["Syneos Health", "赛诺思", "SYNH"],
    "CTLT":  ["催化剂生物技术", "Catalent", "CTLT"],
    "PPD":   ["PPD", "药物研发"],
    "DOCS":  ["Doximity", "医生社交", "DOCS"],
    "ACCD":  ["Accolade", "健康导航", "ACCD"],

    # ── 半导体设备 ───────────────────────────────────────────────
    "ONTO":  ["堆叠", "Onto Innovation", "ONTO"],
    "ACLS":  ["轴科技", "Axcelis Technologies", "ACLS"],
    "COHU":  ["科胡", "Cohu", "COHU"],
    "UCTT":  ["超洁技术", "Ultra Clean Holdings", "UCTT"],
    "CAMT":  ["卡美", "Camtek", "CAMT"],
    "FORM":  ["FormFactor", "形态因子", "FORM"],
    "ICHR":  ["艾科华", "Ichor Holdings", "ICHR"],
    "MKSI":  ["MKS仪器", "MKS Instruments", "MKSI"],

    # ── 含连字符 ─────────────────────────────────────────────────
    "BRK-B": ["伯克希尔哈撒韦", "Berkshire Hathaway", "巴菲特", "BRK"],
}

RELATION_KEYWORDS = {
    "合作": ["合作", "联合", "联手", "战略合作", "合作伙伴", "签约", "协议"],
    "供应链": ["供应商", "供货", "采购", "供给", "供应链", "产业链", "配套", "核心材料"],
    "客户": ["客户", "订单", "中标", "出货", "导入"],
    "投资": ["投资", "参股", "入股", "并购", "收购"],
    "关联": ["同行", "龙头", "概念股", "受益", "竞争", "对比", "板块"],
}

EXCLUDE_WORDS = {
    "A股", "港股", "美股", "上市公司", "板块", "产业链", "概念股", "公司", "集团", "科技股", "龙头",
    "英伟达", "NVIDIA", "NVDA", "特斯拉", "Tesla", "苹果", "Apple", "微软", "Google"
}

HIGH_TRUST_SOURCES = {
    "上海证券交易所", "深圳证券交易所", "巨潮资讯网", "中国证监会", "证券时报", "财联社", "新浪财经", "中国证券报", "上海证券报", "每日经济新闻", "第一财经", "界面新闻"
}

MEDIUM_TRUST_SOURCES = {
    "腾讯网", "凤凰网", "东方财富网", "同花顺财经", "21财经", "澎湃新闻", "中国基金报"
}

BROKER_SOURCES = {
    "中信证券", "国泰君安", "华泰证券", "招商证券", "中金公司", "申万宏源", "天风证券", "国金证券", "海通证券"
}

COMMUNITY_SOURCES = {
    "雪球", "财富号", "股吧", "知乎", "微博", "淘股吧"
}

COMPANY_SUFFIXES = (
    "科技", "股份", "材料", "电子", "通信", "光电", "信息", "精密", "半导体", "电缆", "能源", "化工", "电气", "机电", "智造"
)

GENERIC_NAME_STOPS = {
    "中国半导体", "国际电子", "封装与材料", "五大科技", "核心材料", "供应链战场", "合作基础", "供应商资质"
}


def _is_astock_target(name: str) -> bool:
    """Detect if the target looks like a Chinese A-stock company name."""
    if re.search(r"[\u4e00-\u9fa5]{2,}", name) and name.upper() not in ALIAS_MAP and name not in ALIAS_MAP:
        return True
    return False


def normalize_target(target: str):
    raw = target.strip()
    key = raw.upper()
    aliases = ALIAS_MAP.get(key) or ALIAS_MAP.get(raw) or [raw]
    canonical = aliases[0]
    return canonical, list(dict.fromkeys([raw] + aliases))


def build_queries(aliases, relation_terms):
    primary = aliases[0]

    # Detect A-stock → A-stock mode
    if _is_astock_target(primary):
        return _build_astock_queries(aliases, relation_terms)

    queries = []
    for alias in aliases:
        for rel in relation_terms:
            queries.append(f"{alias} {rel} A股")
            queries.append(f"{alias} {rel} 供应链")
    queries.append(f"{primary} A股 产业链")
    queries.append(f"{primary} A股 合作")
    # Add site-specific announcement queries for major Chinese financial sites
    queries.append(f"site:cninfo.com.cn {primary} 合作")
    queries.append(f"site:eastmoney.com {primary} 公告 合作")
    return list(dict.fromkeys(queries))


def _build_astock_queries(aliases, relation_terms):
    """Build queries for A-stock → A-stock partner discovery.
    
    Strategy: search for industry-level relationships and multi-company mentions,
    not the target company's own announcements.
    """
    primary = aliases[0]
    queries = []
    # Direct partner/supply chain/customer mentions with OTHER companies
    for rel in ["合作", "供应商", "客户", "签约", "订单"]:
        queries.append(f"{primary} {rel}")
    # Industry chain: find articles that list multiple companies together
    queries.append(f"{primary} 产业链 上下游 龙头")
    queries.append(f"{primary} 概念股 龙头")
    queries.append(f"{primary} 同行业 上市公司")
    queries.append(f"{primary} 竞争对手")
    queries.append(f"{primary} 受益股")
    queries.append(f"{primary} 关联公司")
    queries.append(f"{primary} 战略合作 公告")
    # Broader industry search using East Money / Snowball
    queries.append(f"site:eastmoney.com {primary} 产业链")
    queries.append(f"site:xueqiu.com {primary} 同行 对比")
    return list(dict.fromkeys(queries))


def fetch_cninfo_announcements(keyword: str, max_items: int = 20):
    """Search 巨潮资讯 (CNINFO) for A-share company announcements mentioning the target."""
    url = "http://www.cninfo.com.cn/new/fulltextSearch/full"
    params = {
        "searchkey": keyword,
        "sdate": "",
        "edate": "",
        "isfulltext": "false",
        "sortfield": "pubdate",
        "sorttype": "desc",
        "pageNum": 1,
        "pageSize": max_items,
    }
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Referer": "http://www.cninfo.com.cn/new/fulltextSearch",
        "Accept": "application/json, text/plain, */*",
    }
    try:
        r = requests.post(url, data=params, headers=headers, timeout=15)
        r.raise_for_status()
        data = r.json()
        rows = []
        for item in (data.get("announcements") or [])[:max_items]:
            title = (item.get("announcementTitle") or "").strip()
            stock_name = (item.get("secName") or "").strip()
            stock_code = (item.get("secCode") or "").strip()
            pub_date_ts = item.get("announcementTime")
            link = ""
            if item.get("adjunctUrl"):
                link = f"http://static.cninfo.com.cn/{item['adjunctUrl']}"
            pub_date = None
            if pub_date_ts:
                try:
                    pub_date = dt.datetime.fromtimestamp(pub_date_ts / 1000, tz=dt.timezone.utc)
                except Exception:
                    pass
            if title:
                rows.append({
                    "title": f"[{stock_name}({stock_code})] {title}",
                    "link": link,
                    "description": f"{stock_name} {stock_code} {title}",
                    "source": "巨潮资讯网",
                    "pub_date": pub_date,
                    "provider": "cninfo",
                    "stock_name": stock_name,
                    "stock_code": stock_code,
                })
        return rows
    except Exception:
        return []


def fetch_eastmoney_announcements(keyword: str, max_items: int = 20):
    """Search East Money announcement center for A-share public disclosures."""
    url = "https://search-api-web.eastmoney.com/search/jsonp"
    params = {
        "cb": "jQuery",
        "param": json.dumps({
            "uid": "",
            "keyword": keyword,
            "type": ["announce"],
            "client": "web",
            "clientType": "web",
            "clientVersion": "curr",
            "param": {"announce": {"from": 0, "size": max_items, "market": "0,1"}},
        }),
        "cb": "cb",
    }
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Referer": "https://so.eastmoney.com/",
    }
    try:
        r = requests.get(url, params=params, headers=headers, timeout=15)
        r.raise_for_status()
        text = r.text
        # Strip JSONP wrapper  cb({...})
        m = re.search(r"cb\((\{.*\})\)", text, re.DOTALL)
        if not m:
            return []
        data = json.loads(m.group(1))
        hits = (data.get("data") or {}).get("announce", {}).get("hits") or []
        rows = []
        for item in hits[:max_items]:
            src = item.get("_source") or {}
            title = (src.get("title") or "").strip()
            stock_name = (src.get("stockName") or "").strip()
            stock_code = (src.get("stockCode") or "").strip()
            link = src.get("pdfUrl") or src.get("url") or ""
            pub_str = src.get("publishDate") or src.get("noticeDate") or ""
            pub_date = None
            if pub_str:
                try:
                    pub_date = dt.datetime.fromisoformat(pub_str[:10]).replace(tzinfo=dt.timezone.utc)
                except Exception:
                    pass
            if title:
                rows.append({
                    "title": f"[{stock_name}({stock_code})] {title}",
                    "link": link,
                    "description": f"{stock_name} {stock_code} {title}",
                    "source": "东方财富网",
                    "pub_date": pub_date,
                    "provider": "eastmoney_announce",
                    "stock_name": stock_name,
                    "stock_code": stock_code,
                })
        return rows
    except Exception:
        return []


def parse_pubdate(pub: str):
    if not pub:
        return None
    try:
        return parsedate_to_datetime(pub).astimezone(dt.timezone.utc)
    except Exception:
        return None


def parse_rss_items(xml_text: str, max_items: int, provider: str):
    try:
        root = ET.fromstring(xml_text)
    except Exception:
        return []

    channel = root.find("channel")
    if channel is None:
        return []

    rows = []
    for idx, item in enumerate(channel.findall("item")):
        if idx >= max_items:
            break
        title = unescape((item.findtext("title") or "").strip())
        link = (item.findtext("link") or "").strip()
        desc = unescape((item.findtext("description") or "").strip())
        pub_date = parse_pubdate(item.findtext("pubDate") or "")

        source = ""
        source_node = item.find("source")
        if source_node is not None and source_node.text:
            source = unescape(source_node.text.strip())

        # Bing RSS often encodes source in title suffix: "... - SourceName"
        if provider == "bing" and not source and " - " in title:
            parts = title.rsplit(" - ", 1)
            if len(parts) == 2 and len(parts[1]) <= 20:
                title = parts[0].strip()
                source = parts[1].strip()

        rows.append(
            {
                "title": title,
                "link": link,
                "description": desc,
                "source": source,
                "pub_date": pub_date,
                "provider": provider,
            }
        )
    return rows


def fetch_google_news_rss(query: str, max_items: int = 25):
    url = "https://news.google.com/rss/search"
    params = {
        "q": query,
        "hl": "zh-CN",
        "gl": "CN",
        "ceid": "CN:zh-Hans",
    }
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    }

    try:
        r = requests.get(url, params=params, timeout=15, headers=headers)
        r.raise_for_status()
    except Exception:
        return []

    return parse_rss_items(r.text, max_items=max_items, provider="google")


def fetch_bing_news_rss(query: str, max_items: int = 25):
    url = "https://www.bing.com/news/search"
    params = {
        "q": query,
        "format": "rss",
        "setlang": "zh-CN",
        "cc": "CN",
    }
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    }

    try:
        r = requests.get(url, params=params, timeout=15, headers=headers)
        r.raise_for_status()
    except Exception:
        return []

    return parse_rss_items(r.text, max_items=max_items, provider="bing")


def is_mainboard(code: str):
    return bool(re.match(r"^(60\d{4}|000\d{3}|001\d{3}|002\d{3})$", code))


def clean_code(token: str):
    t = token.upper().replace("SH", "").replace("SZ", "")
    return t if is_mainboard(t) else ""


def infer_tier(source: str, title: str):
    s = (source or "").strip()
    t = title or ""
    if s in HIGH_TRUST_SOURCES or any(k in t for k in ("公告", "投资者关系", "临时公告", "交易所")):
        return "company_announcement"
    if s in BROKER_SOURCES or "研报" in t:
        return "broker_report"
    if s in MEDIUM_TRUST_SOURCES:
        return "mainstream_media"
    if s in COMMUNITY_SOURCES:
        return "community_post"
    return "mainstream_media"


def tier_weight(tier: str):
    return {
        "company_announcement": 5,
        "mainstream_media": 3,
        "broker_report": 2,
        "community_post": 1,
    }.get(tier, 2)


def extract_candidates(article_text: str):
    candidates = []

    # Pattern 1: name(code) / name（code）
    for m in re.finditer(r"([\u4e00-\u9fa5A-Za-z]{2,20})\s*[\(（]((?:SH|SZ)?(?:60\d{4}|000\d{3}|001\d{3}|002\d{3}))[\)）]", article_text):
        name = m.group(1).strip()
        code = clean_code(m.group(2).strip())
        if code and name and name not in EXCLUDE_WORDS:
            candidates.append((name, code))

    # Pattern 2: code appears alone
    for m in re.finditer(r"(?<!\d)(?:SH|SZ)?(60\d{4}|000\d{3}|001\d{3}|002\d{3})(?!\d)", article_text.upper()):
        code = clean_code(m.group(0))
        if code:
            candidates.append((f"Unknown_{code}", code))

    # Pattern 3: company-like names with common suffixes (no code)
    token_pat = r"([\u4e00-\u9fa5]{2,6}(?:" + "|".join(COMPANY_SUFFIXES) + r"))"
    for m in re.finditer(token_pat, article_text):
        name = m.group(1).strip()
        if name in EXCLUDE_WORDS or len(name) < 3:
            continue
        if len(name) > 10:
            continue
        if name in GENERIC_NAME_STOPS:
            continue
        if any(bad in name for bad in ("供应商", "合作基础", "进展", "分析", "核心", "材料上", "供应链", "巨头")):
            continue
        if any(sym in name for sym in ("与", "和", "及")):
            continue
        candidates.append((name, ""))

    dedup = {}
    for name, code in candidates:
        key = f"{name}|{code}"
        dedup[key] = (name, code)
    return list(dedup.values())


def detect_relation_text(text: str):
    labels = []
    for k, words in RELATION_KEYWORDS.items():
        if any(w in text for w in words):
            labels.append(k)
    return labels


def in_days(pub_date, days: int):
    if pub_date is None:
        return True
    now = dt.datetime.now(dt.timezone.utc)
    return pub_date >= (now - dt.timedelta(days=days))


def compute_confidence(article_count: int, mention_count: int, relation_diversity: int):
    score = article_count * 12 + mention_count * 5 + relation_diversity * 8
    return int(min(100, score))


def source_weight(source: str):
    src = (source or "").strip()
    if src in HIGH_TRUST_SOURCES:
        return 3
    if src in MEDIUM_TRUST_SOURCES:
        return 2
    return 1


def relation_strength(rel_counter, article_count: int, weighted_strength: int):
    supply_hits = rel_counter.get("供应链", 0)
    coop_hits = rel_counter.get("合作", 0)
    customer_hits = rel_counter.get("客户", 0)

    # Official direct cooperation should be strict: repeated cooperation/customer signals + enough article support.
    if coop_hits >= 3 and customer_hits >= 2 and article_count >= 4 and weighted_strength >= 24:
        return "Direct"

    # Trading-use strong correlation: supply-chain evidence is treated as strong practical linkage.
    if supply_hits >= 1 and article_count >= 1:
        return "Strong-Indirect"

    if supply_hits >= 1 or coop_hits >= 1 or customer_hits >= 1:
        return "Indirect"

    return "Weak"


def main():
    parser = argparse.ArgumentParser(description="Find A-share partner candidates from a US stock context")
    parser.add_argument("--target", required=True, help="US stock ticker or company name, e.g. NVDA/英伟达")
    parser.add_argument("--topn", type=int, default=10)
    parser.add_argument("--days", type=int, default=60)
    parser.add_argument("--max-per-query", type=int, default=20)
    parser.add_argument("--sources", default="google,bing", help="comma-separated news sources: google,bing")
    args = parser.parse_args()

    try:
        canonical, aliases = normalize_target(args.target)

        # For A-stock targets, dynamically add target name to exclude words
        if _is_astock_target(canonical):
            for a in aliases:
                EXCLUDE_WORDS.add(a)

        relation_terms = ["合作", "供应商", "客户", "产业链", "订单"]
        queries = build_queries(aliases, relation_terms)
        source_set = {s.strip().lower() for s in str(args.sources).split(",") if s.strip()}
        if not source_set:
            source_set = {"google"}

        all_articles = []
        seen_links = set()

        def _add_rows(rows, query_tag=""):
            for row in rows:
                link = row.get("link") or ""
                title_key = (row.get("title") or "").strip().lower()
                dedup_key = link if link else f"{row.get('provider', '')}|{title_key}"
                if dedup_key and dedup_key in seen_links:
                    continue
                if dedup_key:
                    seen_links.add(dedup_key)
                row["query"] = query_tag
                all_articles.append(row)

        # ── News RSS (Google / Bing) ──────────────────────────────
        for q in queries:
            rows = []
            if "google" in source_set:
                rows.extend(fetch_google_news_rss(q, max_items=args.max_per_query))
            if "bing" in source_set:
                rows.extend(fetch_bing_news_rss(q, max_items=args.max_per_query))
            _add_rows(rows, query_tag=q)
            time.sleep(0.08)

        # ── Official Announcement Sources ─────────────────────────
        # For A-stock targets, skip cninfo/eastmoney (returns target's own filings, not partners).
        # For US→A targets, search filings naming the US partner.
        is_astock_mode = _is_astock_target(canonical)
        if not is_astock_mode:
            for alias in aliases[:3]:   # limit to top-3 aliases to avoid rate-limit
                cninfo_rows = fetch_cninfo_announcements(alias, max_items=15)
                _add_rows(cninfo_rows, query_tag=f"cninfo:{alias}")
                time.sleep(0.15)
                em_rows = fetch_eastmoney_announcements(alias, max_items=15)
            _add_rows(em_rows, query_tag=f"em_announce:{alias}")
            time.sleep(0.15)

        all_articles = [a for a in all_articles if in_days(a.get("pub_date"), args.days)]

        if not all_articles:
            print(
                json.dumps(
                    {
                        "Target": args.target,
                        "CanonicalTarget": canonical,
                        "GeneratedAt": dt.datetime.now().isoformat(),
                        "ArticleCount": 0,
                        "Results": [],
                        "Note": "未抓到相关新闻，可增加 days 或更换目标名称重试",
                    },
                    ensure_ascii=False,
                )
            )
            return

        # Build a set of target aliases to exclude from candidates (avoid self-match)
        target_names = {a.lower() for a in aliases}
        # Pre-scan all articles to detect the target's own stock code
        target_codes = set()
        if is_astock_mode:
            for a in all_articles:
                text = f"{a.get('title', '')} {a.get('description', '')}"
                # From metadata
                sc = (a.get("stock_code") or "").strip()
                sn = (a.get("stock_name") or "").strip()
                if sc and sn.lower() in target_names:
                    target_codes.add(sc)
                # From text patterns like "藏格矿业(000408)"
                for alias in aliases:
                    pat = re.escape(alias) + r"\s*[\(（](\d{6})[\)）]"
                    m = re.search(pat, text)
                    if m:
                        target_codes.add(m.group(1))

        agg = {}
        for a in all_articles:
            text = f"{a.get('title', '')} {a.get('description', '')}"
            rel_labels = detect_relation_text(text)

            source_tier = infer_tier(a.get("source", ""), a.get("title", ""))
            w = tier_weight(source_tier)

            # For official announcements that already carry the issuing company's code,
            # treat the filing company itself as a candidate (it named the US partner).
            direct_stock_code = (a.get("stock_code") or "").strip()
            direct_stock_name = (a.get("stock_name") or "").strip()
            if direct_stock_code and is_mainboard(direct_stock_code) and direct_stock_name:
                # Announcement-sourced: boost the relation count automatically
                if not rel_labels:
                    rel_labels = ["合作"]
                direct_candidates = [(direct_stock_name, direct_stock_code)]
            else:
                # For A→A mode, even without explicit relation words,
                # co-occurrence in the same article is a signal
                if not rel_labels:
                    if is_astock_mode:
                        rel_labels = ["关联"]  # implicit association
                    else:
                        continue
                direct_candidates = []

            matched_candidates = extract_candidates(text) + direct_candidates
            # Deduplicate — prefer the code-matched entry
            seen_cands = {}
            for nm, code in matched_candidates:
                k = code if code else nm
                if k not in seen_cands:
                    seen_cands[k] = (nm, code)
            matched_candidates = list(seen_cands.values())

            # Exclude the target company itself from candidates (by name and by code)
            matched_candidates = [
                (nm, code) for nm, code in matched_candidates
                if nm.lower() not in target_names and code not in target_codes
            ]

            if not matched_candidates:
                continue

            for nm, code in matched_candidates:
                key = f"{code}|{nm}" if code else f"NOCODE|{nm}"
                if key not in agg:
                    agg[key] = {
                        "Code": code,
                        "Name": nm,
                        "MentionCount": 0,
                        "ArticleLinks": set(),
                        "Relations": defaultdict(int),
                        "WeightedEvidence": 0,
                        "Evidence": [],
                        "LatestUtc": None,
                        "SourceTierCounter": defaultdict(int),
                    }

                node = agg[key]
                node["MentionCount"] += 1
                link = a.get("link") or ""
                if link:
                    node["ArticleLinks"].add(link)

                for rl in rel_labels:
                    node["Relations"][rl] += 1
                node["WeightedEvidence"] += w
                node["SourceTierCounter"][source_tier] += 1

                pub = a.get("pub_date")
                if pub is not None and (node["LatestUtc"] is None or pub > node["LatestUtc"]):
                    node["LatestUtc"] = pub

                if len(node["Evidence"]) < 4:
                    node["Evidence"].append(
                        {
                            "Title": a.get("title", ""),
                            "Source": a.get("source", ""),
                            "SourceTier": source_tier,
                            "Provider": a.get("provider", ""),
                            "Link": link,
                            "Query": a.get("query", ""),
                        }
                    )

        results = []
        for _, v in agg.items():
            article_count = len(v["ArticleLinks"])
            mention_count = v["MentionCount"]
            relation_sorted = sorted(v["Relations"].items(), key=lambda x: x[1], reverse=True)
            relations = [f"{k}:{cnt}" for k, cnt in relation_sorted]
            conf = compute_confidence(article_count, mention_count, len(relation_sorted))
            strength = relation_strength(v["Relations"], article_count, v["WeightedEvidence"])
            # Supply-chain is prioritized as strong practical correlation for trading.
            if strength == "Strong-Indirect":
                conf = min(100, max(conf, 78))

            results.append(
                {
                    "Code": v["Code"],
                    "Name": v["Name"],
                    "ArticleCount": article_count,
                    "MentionCount": mention_count,
                    "Relations": relations,
                    "RelationStrength": strength,
                    "Confidence": conf,
                    "WeightedEvidence": v["WeightedEvidence"],
                    "SourceTiers": dict(v["SourceTierCounter"]),
                    "LatestUtc": v["LatestUtc"].isoformat() if v["LatestUtc"] else None,
                    "Evidence": v["Evidence"],
                }
            )

        results.sort(key=lambda x: (x["Confidence"], x["ArticleCount"], x["MentionCount"]), reverse=True)
        results = results[: max(1, args.topn)]

        payload = {
            "Target": args.target,
            "CanonicalTarget": canonical,
            "GeneratedAt": dt.datetime.now().isoformat(),
            "SourcesUsed": sorted(list(source_set)) + ["巨潮资讯", "东财公告"],
            "QueryCount": len(queries),
            "ArticleCount": len(all_articles),
            "Results": results,
        }

        print(json.dumps(payload, ensure_ascii=False))
    except Exception as exc:
        print(
            json.dumps(
                {
                    "Target": args.target,
                    "GeneratedAt": dt.datetime.now().isoformat(),
                    "ArticleCount": 0,
                    "Results": [],
                    "Error": str(exc),
                },
                ensure_ascii=False,
            )
        )


if __name__ == "__main__":
    main()
