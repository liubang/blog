---
title: "从 ODS 到 Materialized View：一文讲透 OLAP 与数据仓库中的核心概念"
description: "从业务数据进入数仓开始，系统梳理 ODS、DWD、DWS、ADS、维度建模、OLAP 多维分析、预聚合、Rollup 与 Materialized View，并结合 Doris、StarRocks、ClickHouse 分析现代 OLAP 系统的演进路径。"
date: 2026-05-31
categories: [OLAP 与数据仓库]
tags: [olap, data-warehouse, materialized-view, query-optimizer]
authors: ["liubang"]
---

如果让一个业务数据库回答“某个用户的订单是否已经支付”，它通常只需要通过主键索引读取几行数据。如果让同一个数据库回答“过去一年每个地区、每个品类、每个月的销售额和去重用户数是多少”，问题就完全不同了：它需要扫描大量订单明细，关联商品和地区信息，再执行聚合、排序甚至窗口计算。

前者是典型的 **OLTP**（Online Transaction Processing，联机事务处理），后者是典型的 **OLAP**（Online Analytical Processing，联机分析处理）。

很多数仓术语都诞生于同一个矛盾：**业务系统擅长记录事实，但不擅长反复解释事实。** ODS、DWD、DWS、ADS 是为了逐步整理事实；维度建模是为了组织分析视角；Cube、Rollup 和 Materialized View 则是在回答另一个问题：能不能不要每次查询都从最细粒度的数据重新算起？

本文从一张订单表开始，把这些概念串成一个完整体系。

## 目录

- [1. 从业务数据库开始](#1-从业务数据库开始)
- [2. Data Warehouse：将分析负载从业务库剥离](#2-data-warehouse将分析负载从业务库剥离)
- [3. 数仓分层：ODS、DWD、DWS、ADS 与 DIM](#3-数仓分层odsdwddwsads-与-dim)
- [4. 维度建模：事实表与维度表](#4-维度建模事实表与维度表)
- [5. OLAP：在多个维度上观察事实](#5-olap在多个维度上观察事实)
- [6. 为什么需要预聚合](#6-为什么需要预聚合)
- [7. Rollup：一个词，两层含义](#7-rollup一个词两层含义)
- [8. Materialized View：从固定汇总表到自动查询改写](#8-materialized-view从固定汇总表到自动查询改写)
- [9. Doris、StarRocks 与 ClickHouse 的实现差异](#9-dorisstarrocks-与-clickhouse-的实现差异)
- [10. Presto 与 Trino：计算存储分离之后](#10-presto-与-trino计算存储分离之后)
- [11. 从 Cube 到 Cost Based Rewrite](#11-从-cube-到-cost-based-rewrite)
- [12. 工程实践：什么时候应该创建 MV](#12-工程实践什么时候应该创建-mv)
- [13. 术语表](#13-术语表)
- [14. 总结](#14-总结)

## 1. 从业务数据库开始

### 1.1 业务系统首先需要正确地记录状态

假设我们正在开发一个电商系统。最开始，MySQL 中可能有如下几张表：

```sql
CREATE TABLE orders (
    order_id      BIGINT PRIMARY KEY,
    user_id       BIGINT NOT NULL,
    region_id     INT NOT NULL,
    order_status  VARCHAR(32) NOT NULL,
    order_time    DATETIME NOT NULL,
    update_time   DATETIME NOT NULL,
    KEY idx_user_time (user_id, order_time)
);

CREATE TABLE order_items (
    order_id      BIGINT NOT NULL,
    product_id    BIGINT NOT NULL,
    quantity      INT NOT NULL,
    amount        DECIMAL(18, 2) NOT NULL,
    PRIMARY KEY (order_id, product_id)
);

CREATE TABLE products (
    product_id    BIGINT PRIMARY KEY,
    category_id   INT NOT NULL,
    product_name  VARCHAR(255) NOT NULL
);
```

这套模型首先服务于交易流程：

- 创建订单时，写入必须快速完成。
- 修改支付状态时，必须通过主键准确更新。
- 查询订单详情时，只需要读取少量记录。
- 库存扣减、支付和退款可能需要事务保证。

OLTP 数据库会围绕这些目标优化：B+ Tree 索引、行存储、短事务、点查、范围查、并发控制和高频小批量写入。表结构通常经过规范化，尽量减少冗余，避免修改一份数据时还要同步维护多份副本。

### 1.2 一个分析查询会发生什么

运营同学希望查看过去一年每个地区和商品品类的月销售额：

```sql
SELECT
    DATE_FORMAT(o.order_time, '%Y-%m') AS month,
    o.region_id,
    p.category_id,
    SUM(i.amount) AS revenue,
    COUNT(DISTINCT o.user_id) AS buyers
FROM orders o
JOIN order_items i ON o.order_id = i.order_id
JOIN products p ON i.product_id = p.product_id
WHERE o.order_status = 'PAID'
  AND o.order_time >= '2025-01-01'
  AND o.order_time <  '2026-01-01'
GROUP BY
    DATE_FORMAT(o.order_time, '%Y-%m'),
    o.region_id,
    p.category_id;
```

这条 SQL 对 MySQL 并不是“不合法”，但它与交易请求争抢的是同一组资源：

```text
                       MySQL
                         |
       +-----------------+-----------------+
       |                                   |
  在线交易请求                         分析查询
  点查 / 小范围更新                    大范围扫描
  毫秒级事务                           多表 Join
  少量数据页                           GROUP BY
  延迟敏感                             COUNT DISTINCT
       |                                   |
       +----------- 争抢 CPU / IO / Buffer Pool
```

复杂分析不适合直接压在 OLTP 数据库上，通常有五个原因：

1. **扫描范围太大。** 订单详情查询只读取几行，年度报表可能读取数亿行。
2. **访问模式不同。** 行存储适合拿到一条记录的全部字段；分析查询往往只读取少数列，但会读取这些列的大量行。
3. **计算链路更长。** Join、Hash Aggregate、Sort、Window Function 都需要额外 CPU 和内存。
4. **历史数据持续累积。** 业务库通常只关心当前状态，分析系统还要保留历史变化。
5. **资源隔离困难。** 一次低效报表查询可能污染 Buffer Pool，拖慢支付、下单等核心链路。

OLTP 与 OLAP 并不是两套互斥的 SQL 语法，而是两类不同的工作负载。

| 维度 | OLTP | OLAP |
| --- | --- | --- |
| 典型请求 | 下单、支付、查询详情 | 报表、趋势、归因分析 |
| 数据范围 | 少量记录 | 大量历史数据 |
| 写入方式 | 高频小事务 | 批量导入、流式写入 |
| 常用操作 | INSERT、UPDATE、点查 | Scan、Join、Aggregate |
| 存储偏好 | 行存储、索引查找 | 列存储、压缩、向量化执行 |
| 优化目标 | 低延迟事务与并发写入 | 扫描吞吐与复杂查询吞吐 |

## 2. Data Warehouse：将分析负载从业务库剥离

### 2.1 数仓不是一块更大的磁盘

**Data Warehouse**（数据仓库）的基本思路，是把分析需要的数据从业务系统抽取出来，经过清洗、建模和汇总，交给独立的分析系统处理。

```text
 MySQL / PostgreSQL       App Log        Kafka         SaaS API
        |                    |             |              |
        +--------------------+------+------+--------------+
                                  |
                       CDC / Batch ETL / Streaming
                                  |
                                  v
                         Data Warehouse / Lake
                                  |
                   +--------------+---------------+
                   |                              |
             Hive / Spark SQL             Doris / StarRocks
             离线加工与回溯                 实时 OLAP 查询
                   |                              |
                   +--------------+---------------+
                                  |
                         BI / Dashboard / API
```

数据进入数仓的常见方式包括：

- 通过 CDC 捕获 MySQL Binlog，将订单变更同步到 Kafka。
- 通过 Flink 或 Spark Streaming 做实时清洗和聚合。
- 通过 Hive、Spark SQL 做小时级或天级离线加工。
- 通过调度系统周期性执行批处理任务。
- 将结果写入对象存储上的 Parquet、ORC、Iceberg 表，或者写入 Doris、StarRocks、ClickHouse 等 OLAP 数据库。

数仓的价值不只是“把数据复制一遍”。它还要解决业务库不会主动解决的问题：

- 统一不同业务系统的字段口径。
- 保留历史快照和变更轨迹。
- 处理脏数据、迟到数据和重复数据。
- 将交易模型转换成适合分析的模型。
- 将高频查询提前汇总，控制查询成本。

### 2.2 湖、仓与 OLAP 数据库是什么关系

Hive 和 Spark SQL 更接近离线加工引擎：数据通常存储在 HDFS 或对象存储中，查询延迟可以是分钟级。Presto 和 Trino 擅长在多个数据源之上提供交互式联邦查询。Doris、StarRocks、ClickHouse 则更强调面向用户请求的低延迟分析。

这些系统并不总是互相替代。常见架构是：

```text
              Object Storage / HDFS
         Parquet / ORC / Iceberg / Hudi
                       |
          +------------+------------+
          |                         |
   Hive / Spark SQL             Presto / Trino
   离线 ETL、回溯重算            联邦查询、即席分析
          |
          v
  Doris / StarRocks / ClickHouse
  Dashboard、API、实时分析服务
```

现代数据平台的边界正在变得模糊：OLAP 数据库可以查询外部湖表，Trino 的 Connector 可以管理某些存储格式上的物化视图，Spark 也能执行复杂分析。但理解数仓时，仍然应该先从“数据如何逐层变得更适合消费”开始。

## 3. 数仓分层：ODS、DWD、DWS、ADS 与 DIM

不同公司的命名规范会有差异，但最常见的一套分层是：

![数据仓库分层架构](/images/olap/data-warehouse-layers.svg "数据仓库分层架构")

### 3.1 ODS：忠实接住源数据

**ODS**（Operational Data Store）是原始数据进入数仓后的第一站。它的目标不是设计漂亮的数据模型，而是尽量保留源系统语义，保证数据可追溯。

例如，MySQL `orders` 表经过 CDC 后，可以进入：

```sql
CREATE TABLE ods_orders (
    order_id       BIGINT,
    user_id        BIGINT,
    region_id      INT,
    order_status   STRING,
    order_time     TIMESTAMP,
    update_time    TIMESTAMP,
    op_type        STRING,
    ingest_time    TIMESTAMP
);
```

ODS 中通常会保留操作类型、摄取时间、源系统标识等元数据。后续发现统计口径错误时，可以从 ODS 回溯，而不是重新压业务库。

### 3.2 DWD：形成原子事实

**DWD**（Data Warehouse Detail）负责将原始数据清洗为可复用的明细事实。典型动作包括：

- 去重和过滤无效记录。
- 将字符串时间转换成标准时间类型。
- 统一金额单位和枚举值。
- 处理订单状态变化。
- 将订单头和订单明细整理成稳定粒度。

例如，以“一个订单中的一个商品”为粒度：

```sql
CREATE TABLE dwd_order_items (
    order_id       BIGINT,
    product_id     BIGINT,
    user_id        BIGINT,
    region_id      INT,
    order_time     TIMESTAMP,
    quantity       INT,
    amount         DECIMAL(18, 2)
);
```

粒度非常重要。建事实表之前，应该先用一句话回答：**一行数据究竟代表什么？**

### 3.3 DIM：保存分析视角

**DIM**（Dimension）保存用户、商品、地区、组织、日期等维度信息。例如：

```sql
CREATE TABLE dim_product (
    product_id      BIGINT,
    product_name    STRING,
    category_id     INT,
    category_name   STRING,
    brand_id        INT,
    brand_name      STRING
);
```

维度表不是无条件覆盖最新值。用户等级、组织归属、商品分类都可能随时间变化。如果报表需要还原历史状态，就要使用拉链表或 SCD（Slowly Changing Dimension，缓慢变化维）记录有效时间区间。

### 3.4 DWS：沉淀可复用汇总

**DWS**（Data Warehouse Summary）面向主题域沉淀公共汇总。例如，按天、地区和品类统计：

```sql
CREATE TABLE dws_sales_day_region_category AS
SELECT
    DATE(order_time) AS dt,
    region_id,
    category_id,
    SUM(amount) AS revenue,
    SUM(quantity) AS sold_quantity,
    COUNT(*) AS item_count
FROM dwd_order_items i
JOIN dim_product p ON i.product_id = p.product_id
GROUP BY DATE(order_time), region_id, category_id;
```

DWS 的关键不是“所有数据都聚合一次”，而是识别跨应用复用的主题指标。销售看板、经营日报和预算系统都需要日销售额，那么这个汇总就应该稳定沉淀。

### 3.5 ADS：直接服务应用

**ADS**（Application Data Service）面向具体消费场景。它可以是报表表、API 查询表、导出结果，也可以是推荐或风控需要的特征表。

```sql
CREATE TABLE ads_region_monthly_sales AS
SELECT
    DATE_FORMAT(dt, 'yyyy-MM') AS month,
    region_id,
    SUM(revenue) AS revenue
FROM dws_sales_day_region_category
GROUP BY DATE_FORMAT(dt, 'yyyy-MM'), region_id;
```

ADS 往往带有明确的产品语义。它可以牺牲通用性，换取查询简单、响应稳定和权限边界清晰。

## 4. 维度建模：事实表与维度表

### 4.1 Fact Table：业务过程留下的度量

**Fact Table**（事实表）描述一个可度量的业务过程，例如下单、支付、退款、曝光、点击和设备采样。

```text
fact_order_items
+----------+------------+---------+-----------+----------+--------+
| order_id | product_id | user_id | region_id | quantity | amount |
+----------+------------+---------+-----------+----------+--------+
| 10001    | 2001       | 501     | 10        | 2        | 199.00 |
+----------+------------+---------+-----------+----------+--------+
```

事实表通常包含：

- 外键：连接用户、商品、地区、日期等维度。
- 度量值：金额、数量、耗时、流量等可聚合指标。
- 退化维度：订单号、请求 ID 等直接留在事实表中的业务标识。

事实表首先要确定粒度。订单粒度、订单明细粒度和支付流水粒度不能混在一起，否则 `SUM(amount)` 很容易重复计算。

### 4.2 Dimension Table：解释事实的上下文

**Dimension Table**（维度表）回答“从什么角度看事实”。例如：

```text
dim_product                           dim_region
+------------+-------------+         +-----------+-------------+
| product_id | category_id |         | region_id | province    |
+------------+-------------+         +-----------+-------------+
| 2001       | 301         |         | 10        | Zhejiang    |
+------------+-------------+         +-----------+-------------+
```

事实表中的 `amount = 199.00` 本身没有太多含义。连接商品、地区和时间维度之后，我们才能分析“浙江省某品类在某个月的销售额”。

### 4.3 Star Schema 与 Snowflake Schema

**Star Schema**（星型模型）让多个维度表直接围绕事实表展开：

它的优点是查询路径短、容易理解、Join 数量较少。代价是维度表可能存在冗余，例如商品维度同时保存品类名称和品牌名称。

**Snowflake Schema**（雪花模型）会继续拆分维度：

![星型模型与雪花模型](/images/olap/star-vs-snowflake-schema.svg "星型模型与雪花模型")

雪花模型减少了维度冗余，但增加了 Join 数量和理解成本。在面向分析的场景中，星型模型通常更常见。现代 OLAP 系统也经常使用宽表减少运行时 Join，但宽表并不是维度建模的反义词：它往往只是将部分维度属性提前展开，以查询性能换取存储冗余和更新成本。

## 5. OLAP：在多个维度上观察事实

### 5.1 Cube 是一个逻辑模型

假设销售额由三个维度组织：

- 时间：日、月、季度、年。
- 地区：城市、省份、国家。
- 商品：SKU、品类、品牌。

那么销售额可以被想象成一个多维 **Cube**：

![OLAP Cube 与多维分析操作](/images/olap/olap-cube-operations.svg "OLAP Cube 与多维分析操作")

Cube 首先是一种分析抽象，不等于数据库必须提前物化每一种组合。如果时间、地区和商品层级较多，完全物化所有组合会产生巨大的存储和维护成本。

### 5.2 Slice 与 Dice

**Slice** 是固定一个维度，观察剩余维度。例如只看 `2026-05-01` 当天：

```sql
SELECT region_id, category_id, SUM(revenue)
FROM dws_sales_day_region_category
WHERE dt = '2026-05-01'
GROUP BY region_id, category_id;
```

**Dice** 是在多个维度上选取一个子空间。例如只看 5 月、浙江和江苏、家电与数码品类：

```sql
SELECT dt, region_id, category_id, SUM(revenue)
FROM dws_sales_day_region_category
WHERE dt >= '2026-05-01'
  AND dt <  '2026-06-01'
  AND region_id IN (10, 11)
  AND category_id IN (301, 302)
GROUP BY dt, region_id, category_id;
```

### 5.3 Drill Down 与 Roll Up

**Drill Down**（下钻）是从粗粒度走向细粒度：

```text
年销售额 -> 月销售额 -> 日销售额
省销售额 -> 市销售额 -> 门店销售额
品类销售额 -> SKU 销售额
```

**Roll Up**（上卷）则相反：从细粒度聚合到粗粒度。

```sql
-- 从日粒度上卷到月粒度
SELECT
    DATE_FORMAT(dt, 'yyyy-MM') AS month,
    region_id,
    SUM(revenue) AS revenue
FROM dws_sales_day_region_category
GROUP BY DATE_FORMAT(dt, 'yyyy-MM'), region_id;
```

SQL 标准中的 `ROLLUP` 还能一次生成多级小计：

```sql
SELECT
    region_id,
    category_id,
    SUM(revenue)
FROM dws_sales_day_region_category
GROUP BY ROLLUP(region_id, category_id);
```

这里会产生 `(region_id, category_id)`、`(region_id)` 和总计三个层级。SQL 中的 `CUBE` 则会生成更多维度组合。

## 6. 为什么需要预聚合

### 6.1 查询时聚合的成本

假设 `dwd_order_items` 每天写入 1 亿行，运营看板每 30 秒刷新一次。即使列式存储只读取 `dt`、`region_id` 和 `amount` 三列，每次从明细扫描并执行聚合仍然很浪费：

```sql
SELECT dt, region_id, SUM(amount)
FROM dwd_order_items
WHERE dt >= '2026-05-01'
GROUP BY dt, region_id;
```

执行链路大致如下：

```text
Scan 明细数据
      |
      v
Filter 分区与谓词
      |
      v
Local Hash Aggregate
      |
      v
Network Shuffle by (dt, region_id)
      |
      v
Global Hash Aggregate
      |
      v
Result
```

当查询模式稳定时，可以将 `(dt, region_id)` 的结果提前算好：

```sql
CREATE TABLE sales_day_region AS
SELECT dt, region_id, SUM(amount) AS revenue
FROM dwd_order_items
GROUP BY dt, region_id;
```

后续查询只需要扫描少量汇总行。这就是 **Pre-Aggregation**（预聚合）：将部分计算成本从查询时移动到写入、刷新或离线加工时。

![预聚合如何减少查询成本](/images/olap/pre-aggregation-query-path.svg "预聚合如何减少查询成本")

### 6.2 Aggregate Table 与 Summary Table

**Aggregate Table** 和 **Summary Table** 经常被混用。两者都保存聚合后的结果，但强调点略有不同：

- Aggregate Table 强调数据经过聚合，通常由维度键和聚合指标构成。
- Summary Table 强调它是面向某个主题或报表的摘要，可能包含聚合、派生指标和业务规则。

例如：

```sql
CREATE TABLE dws_sales_day_region (
    dt             DATE,
    region_id      INT,
    revenue        DECIMAL(18, 2),
    sold_quantity  BIGINT
);
```

它既可以被称为 Aggregate Table，也可以被称为 Summary Table。区别更多来自上下文，不需要把它们理解成严格互斥的数据库对象类型。

### 6.3 从数据库内核看性能收益

预聚合为什么有效？不是因为 `SUM` 语法消失了，而是因为进入执行引擎的数据规模变小了。

假设明细表有 30 亿行，按天和地区预聚合后只剩 3000 行：

```text
                        直接查询明细          查询预聚合结果
扫描行数                3,000,000,000         3,000
读取列数据              大量数据页             少量数据页
Hash Table 更新次数      十亿级                千级
Shuffle 数据量           大                    小
CPU Cache 局部性         较差                  较好
```

收益可以拆成五层：

1. **IO 减少。** 列式存储、分区裁剪和索引只能减少一部分读取；预聚合直接减少底层需要读取的行数。
2. **扫描行数减少。** 向量化执行可以让每行处理更快，但少处理几百万倍的行通常更重要。
3. **Hash Aggregate 减少。** 分组聚合需要更新 Hash Table，聚合状态可能占用大量内存。预聚合让 Hash Table 更小，甚至不再需要二次聚合。
4. **Network Shuffle 减少。** MPP 系统常常需要按照 Group Key 重分布数据。提前局部聚合后，网络传输的是聚合状态，不是所有明细。
5. **CPU 减少。** 表达式求值、哈希计算、序列化、反序列化和函数调用次数都会下降。

预聚合的代价同样明确：写入路径更重、存储副本更多、刷新存在延迟，并且只能加速与其粒度和指标兼容的查询。

## 7. Rollup：一个词，两层含义

Rollup 是最容易混淆的术语之一，因为它至少有两层含义。

### 7.1 OLAP 操作中的 Roll Up

在多维分析中，Roll Up 是一种分析动作：沿维度层级向上聚合。

```text
城市 -> 省份 -> 国家
日期 -> 月份 -> 年份
SKU  -> 品类 -> 全部商品
```

它描述的是查询语义。无论结果来自实时扫描、DWS 汇总表还是物化视图，只要粒度从细变粗，都可以称为 Roll Up。

### 7.2 数据库中的 Rollup Table

在一些 OLAP 数据库中，Rollup 还指一个具体的物理结构：为基表创建更粗粒度、列更少或排序顺序不同的物化索引。

```text
明细基表：order_items
(dt, region_id, category_id, product_id, user_id, amount)
             |
             | Rollup
             v
汇总索引：sales_day_region
(dt, region_id, sum(amount))
```

两者的联系是：数据库中的 Rollup Table 经常用于加速 OLAP 中的 Roll Up 操作。但两者不是同一个概念。

### 7.3 Rollup 与手工汇总表

手工维护一张 DWS 表也能达到类似目的：

```sql
INSERT OVERWRITE dws_sales_day_region
SELECT dt, region_id, SUM(amount)
FROM dwd_order_items
GROUP BY dt, region_id;
```

但手工汇总表要求业务方显式查询它，并自行维护调度、刷新、补数和一致性。数据库内建 Rollup 通常由系统维护，并由优化器透明选择。用户仍然查询基表：

```sql
SELECT dt, region_id, SUM(amount)
FROM order_items
GROUP BY dt, region_id;
```

如果命中 Rollup，执行计划会自动改为读取更小的物化索引。

## 8. Materialized View：从固定汇总表到自动查询改写

### 8.1 普通 View 为什么不够

普通 **View** 只保存 SQL 定义：

```sql
CREATE VIEW v_sales_day_region AS
SELECT dt, region_id, SUM(amount) AS revenue
FROM dwd_order_items
GROUP BY dt, region_id;
```

查询普通 View 时，数据库仍然要展开定义并执行底层 SQL：

```text
普通 View = 保存查询文本
          != 保存查询结果
```

**Materialized View**（物化视图，简称 MV）则同时保存查询定义和物化结果：

```text
Materialized View
    |
    +-- 定义：SELECT dt, region_id, SUM(amount) ...
    |
    +-- 数据：已经计算好的结果
```

MV 将 View 的声明式表达能力与 Aggregate Table 的预计算能力结合起来。它可以用于聚合，也可以用于 Join、过滤、表达式计算、宽表构建和湖仓查询加速。

### 8.2 Query Rewrite：用户不必修改 SQL

MV 真正重要的能力不是“多出一张表”，而是 **Query Rewrite**（查询改写）。

假设存在一个日粒度 MV：

```sql
CREATE MATERIALIZED VIEW mv_sales_day_region_category AS
SELECT
    dt,
    region_id,
    category_id,
    SUM(amount) AS revenue
FROM dwd_order_items
GROUP BY dt, region_id, category_id;
```

用户查询月度地区销售额：

```sql
SELECT
    DATE_TRUNC('month', dt) AS month,
    region_id,
    SUM(amount) AS revenue
FROM dwd_order_items
GROUP BY DATE_TRUNC('month', dt), region_id;
```

优化器发现：

- MV 的数据来源与查询兼容。
- MV 的粒度 `(dt, region_id, category_id)` 比查询需要的 `(month, region_id)` 更细。
- `SUM` 可以继续聚合。

于是将执行计划改写为：

```sql
SELECT
    DATE_TRUNC('month', dt) AS month,
    region_id,
    SUM(revenue) AS revenue
FROM mv_sales_day_region_category
GROUP BY DATE_TRUNC('month', dt), region_id;
```

![Materialized View 查询改写](/images/olap/mv-query-rewrite.svg "Materialized View 查询改写")

这意味着物化视图不需要与查询文本完全一致。只要满足语义等价和聚合可合并条件，一个较细粒度 MV 可以服务多个较粗粒度查询。

### 8.3 增量刷新与全量刷新

MV 必须解决数据新鲜度问题。最直接的办法是定期全量重算：

```sql
REFRESH MATERIALIZED VIEW mv_sales_day_region_category;
```

但事实表越来越大时，全量刷新会越来越昂贵。因此现代系统通常尝试只刷新受影响的数据：

```text
基表新增 2026-05-31 分区
             |
             v
只刷新 MV 的 2026-05-31 分区
             |
             v
历史分区无需重新计算
```

增量刷新可以有不同实现：

- 写入基表时同步维护 MV。
- 识别变化分区，只刷新对应的 MV 分区。
- 根据变更日志处理新增、删除和更新。
- 对追加写场景，只计算新写入的数据块。

“支持增量刷新”不是一个简单的布尔值。能否增量处理，取决于基表格式、变更类型、Join 关系、聚合函数是否可合并，以及系统能否可靠判断哪些数据发生了变化。

### 8.4 同步 MV 与异步 MV

**同步 MV** 在基表写入时同步维护。它通常具有较强的一致性，适合单表、实时、固定模式的聚合：

```text
INSERT 基表
    |
    +--> 写入 Base Index
    |
    +--> 同一写入链路维护 Sync MV / Rollup
```

**异步 MV** 则通过调度或手工触发刷新：

```text
基表发生变化
    |
    v
等待刷新策略触发
    |
    v
重新计算受影响分区或完整结果
    |
    v
替换 MV 数据
```

异步 MV 可以支持更复杂的 SQL，例如多表 Join 和外部表查询，但要接受一定的数据延迟。系统还需要在查询改写时判断 MV 是否过期，或者允许用户配置可接受的 Staleness。

## 9. Doris、StarRocks 与 ClickHouse 的实现差异

不同系统都在做预计算，但它们的术语、刷新路径和优化器能力并不完全相同。理解差异比记忆语法更重要。

### 9.1 Doris：Aggregate Key、Rollup 与 MV

Apache Doris 的 **Aggregate Key** 模型允许在表定义中声明聚合规则：

```sql
CREATE TABLE sales_day_region (
    dt             DATE,
    region_id      INT,
    revenue        DECIMAL(18, 2) SUM,
    sold_quantity  BIGINT SUM
)
AGGREGATE KEY(dt, region_id)
DISTRIBUTED BY HASH(region_id) BUCKETS 16;
```

相同 Key 的记录会按照 Value 列声明的函数合并。合并不一定在写入瞬间彻底完成：数据导入、Compaction 和查询阶段都可能参与聚合，以保证最终查询结果正确。

Doris 的 Rollup 是基表之上的额外物化索引：

```sql
ALTER TABLE order_items
ADD ROLLUP rollup_day_region (
    dt,
    region_id,
    amount
);
```

对于新设计，Doris 官方更推荐使用同步 MV 语法表达类似能力：

```sql
CREATE MATERIALIZED VIEW mv_sales_day_region AS
SELECT
    dt,
    region_id,
    SUM(amount)
FROM order_items
GROUP BY dt, region_id;
```

同步 MV 与基表保持实时一致，适合单表聚合和排序优化。异步 MV 则可以服务多表 Join、分区刷新和湖仓外表加速：

```sql
CREATE MATERIALIZED VIEW mv_sales_day_category
BUILD IMMEDIATE
REFRESH AUTO ON SCHEDULE EVERY 1 HOUR
AS
SELECT
    i.dt,
    p.category_id,
    SUM(i.amount) AS revenue
FROM dwd_order_items i
JOIN dim_product p ON i.product_id = p.product_id
GROUP BY i.dt, p.category_id;
```

Doris 中的演进方向不是简单删除 Rollup，而是让同步 MV 覆盖传统 Rollup 的主要使用场景，再让异步 MV 处理复杂查询和灵活刷新。

### 9.2 StarRocks：同步 MV 本质上就是 Rollup

StarRocks 对同步 MV 的定位非常直接：它就是 Rollup，是基表上的特殊索引，而不是一张独立物理表。

```sql
CREATE MATERIALIZED VIEW mv_sales_day_region AS
SELECT
    dt,
    region_id,
    SUM(amount)
FROM order_items
GROUP BY dt, region_id;
```

数据导入基表时，同步 MV 自动刷新。查询仍然针对基表编写，优化器透明选择 Rollup。可以通过 `EXPLAIN` 查看是否命中：

```sql
EXPLAIN
SELECT dt, region_id, SUM(amount)
FROM order_items
GROUP BY dt, region_id;
```

执行计划中通常可以看到类似信息：

```text
0:OlapScanNode
   TABLE: order_items
   PREAGGREGATION: ON
   rollup: mv_sales_day_region
```

StarRocks 的异步 MV 是独立物理表，可以直接查询，并支持多表 Join、外部 Catalog、分区刷新和透明查询改写：

```sql
CREATE MATERIALIZED VIEW mv_sales_day_category
PARTITION BY dt
DISTRIBUTED BY HASH(category_id)
REFRESH ASYNC EVERY (INTERVAL 1 HOUR)
AS
SELECT
    i.dt,
    p.category_id,
    SUM(i.amount) AS revenue
FROM dwd_order_items i
JOIN dim_product p ON i.product_id = p.product_id
GROUP BY i.dt, p.category_id;
```

这说明 Rollup 没有消失，只是从最显眼的概念变成了同步 MV 的底层实现。复杂场景则逐渐交给异步 MV 和更强的 Query Rewrite。

### 9.3 ClickHouse：MV 与 Projection 解决不同问题

ClickHouse 的常见 MV 更像插入触发器：新数据块写入源表时，MV 对这些新增数据执行查询，再将结果写入目标表。

```sql
CREATE TABLE sales_day_region (
    dt Date,
    region_id UInt32,
    revenue SimpleAggregateFunction(sum, Decimal(18, 2))
)
ENGINE = AggregatingMergeTree
ORDER BY (dt, region_id);

CREATE MATERIALIZED VIEW mv_sales_day_region
TO sales_day_region
AS
SELECT
    toDate(order_time) AS dt,
    region_id,
    sum(amount) AS revenue
FROM order_items
GROUP BY dt, region_id;
```

这种增量 MV 很适合追加写入和流式聚合，但需要注意一个关键边界：它通常只处理新插入的数据块，不会因为源表 Mutation、分区删除或后台 Merge 自动重新计算历史结果。回填历史数据也需要单独执行 `INSERT INTO ... SELECT ...`。

ClickHouse 还支持 **Projection**。Projection 是表内部的一份备用物理布局，可以改变排序顺序，也可以预聚合：

```sql
ALTER TABLE order_items
ADD PROJECTION p_sales_day_region
(
    SELECT
        toDate(order_time) AS dt,
        region_id,
        sum(amount)
    GROUP BY dt, region_id
);
```

Projection 的特点是：

- 它附属于同一张表，而不是单独维护一张目标表。
- 查询优化器可以自动判断是否使用 Projection。
- 它适合为同一份数据提供额外排序和聚合布局。
- 它与表内数据生命周期结合得更紧，一致性边界更容易理解。

因此，ClickHouse 并不是“用 Projection 取代 MV”。更准确的说法是：

```text
需要插入时转换、分流、写入独立结果表
    -> Incremental Materialized View

需要周期性执行复杂查询并保存快照
    -> Refreshable Materialized View

需要同一张表的备用排序或聚合布局，并由优化器透明选择
    -> Projection
```

### 9.4 一张对照表

| 系统 | 结构 | 典型刷新方式 | 是否透明改写 | 适合场景 |
| --- | --- | --- | --- | --- |
| Doris Aggregate Key | 表模型 | 导入、Compaction、查询阶段聚合 | 不涉及 | 按 Key 合并指标 |
| Doris Rollup / Sync MV | 基表物化索引 | 写入同步维护 | 是 | 单表实时聚合、排序优化 |
| Doris Async MV | 独立物化结果 | 定时、手工、分区刷新 | 是 | 多表、湖仓、复杂聚合 |
| StarRocks Sync MV | Rollup 索引 | 导入同步维护 | 是 | 单表实时聚合 |
| StarRocks Async MV | 独立物理表 | 定时、手工、分区刷新 | 是 | 多表、外部 Catalog |
| ClickHouse Incremental MV | 写入触发器 + 目标表 | 新增数据块触发 | 通常由查询方显式使用目标表 | 流式转换、实时汇总 |
| ClickHouse Projection | 表内部备用布局 | 随表维护 | 是 | 备用排序、透明预聚合 |

## 10. Presto 与 Trino：计算存储分离之后

### 10.1 为什么预计算更重要

Presto 和 Trino 常用于查询 Hive、Iceberg、Hudi、关系数据库和其他数据源。它们的优势是计算与存储解耦、跨源查询能力强，但这也意味着查询可能面对对象存储上的大量 Parquet 文件：

```text
Trino Coordinator
       |
       v
   生成分布式 Plan
       |
       +----------+----------+
       |          |          |
       v          v          v
    Worker      Worker      Worker
       |          |          |
       +----------+----------+
                  |
                  v
       S3 / HDFS 上的大量文件
```

一次查询的代价不只有 SQL 算子，还包括文件枚举、远程 IO、解压缩、反序列化、跨节点 Shuffle 和 Spill。即使列裁剪、谓词下推和分区裁剪全部生效，从对象存储扫描 TB 级数据仍然昂贵。

因此，与其说“Presto / Trino 天然依赖 MV”，不如说：

> 在计算存储分离架构中，缺少数据库内部长期维护的索引和本地物理布局时，预计算结果、合理分区、文件组织与 Connector Pushdown 对稳定查询延迟更加重要。

### 10.2 MV 不一定由 Trino 自己完成

在 Trino 体系中，预计算可以来自多个位置：

- Hive 或 Spark SQL 周期性生成 DWS、ADS 汇总表。
- dbt、Airflow 等调度系统维护 Summary Table。
- 查询下推到具备 MV 能力的外部数据库。
- Connector 在特定表格式上提供 MV 管理能力。

例如，Trino Iceberg Connector 支持创建和刷新物化视图：

```sql
CREATE MATERIALIZED VIEW iceberg.analytics.mv_sales_day_region
WITH (
    format = 'ORC',
    partitioning = ARRAY['dt']
)
AS
SELECT dt, region_id, SUM(amount) AS revenue
FROM iceberg.dwd.order_items
GROUP BY dt, region_id;

REFRESH MATERIALIZED VIEW iceberg.analytics.mv_sales_day_region;
```

底层会保存 MV 定义和对应的 Iceberg Storage Table。刷新可能是全量，也可能在定义和源表快照历史允许时执行增量刷新。

这里的关键是 Connector 边界：Trino 是联邦查询引擎，不是一个对所有数据源都提供统一 MV 语义的存储系统。不同 Connector 的能力并不相同。

## 11. 从 Cube 到 Cost Based Rewrite

OLAP 系统的发展可以用一条简化路线来理解：

![现代 OLAP 预计算机制的演进](/images/olap/olap-evolution.svg "现代 OLAP 预计算机制的演进")

这不是严格的产品版本时间线，也不是说后一种机制完全取代前一种机制。它表达的是抽象能力逐步增强：

- Cube 强调多维分析空间。
- Aggregate Table 强调保存汇总结果。
- Rollup 强调基表之上的额外物化布局。
- MV 用 SQL 描述更一般的预计算。
- Query Rewrite 让业务 SQL 无需感知物化结构。
- Cost Based Rewrite 让优化器综合扫描行数、分区裁剪、数据新鲜度、Join 代价和 Roll Up 成本选择方案。

### 11.1 为什么 Doris 和 StarRocks 正在弱化手工 Rollup

手工 Rollup 的优势是简单、实时、一致性明确，但表达能力有限：

- 通常围绕单表工作。
- 支持的聚合函数和表达式有限。
- 难以处理多表 Join。
- 难以覆盖湖仓外表。
- 难以管理复杂刷新策略。

同步 MV 可以覆盖传统 Rollup 的大部分能力，异步 MV 则能表达更复杂的 SQL。优化器进一步负责透明改写。于是用户更愿意从“我要加一个 Rollup 索引”转向“我要声明一个可复用的物化结果”。

Rollup 仍然存在，而且在实时单表聚合中依然有效。弱化的是它作为上层用户唯一入口的地位。

### 11.2 Cost Based Rewrite 在选择什么

当多个 MV 都能服务一个查询时，优化器要比较：

```text
候选 1：扫描明细基表
候选 2：扫描日粒度 MV，再聚合到月
候选 3：扫描月粒度 MV
候选 4：扫描包含额外维度的 MV，再做 Roll Up
```

通常需要考虑：

- 扫描行数和字节数。
- 分区和分桶裁剪效果。
- 是否仍然需要 Join。
- 是否需要二次聚合。
- MV 是否足够新鲜。
- 使用过期 MV 是否在允许范围内。
- 聚合函数是否可合并。

例如 `SUM` 可以再次求和，`MIN` 和 `MAX` 也可以继续合并。`AVG` 则不能直接对多个平均值求平均，通常需要保存 `SUM` 与 `COUNT`。精确去重计数也难以直接合并，工程上常使用 Bitmap 或 HLL 等可合并状态。

## 12. 工程实践：什么时候应该创建 MV

MV 不是越多越好。每增加一个物化结构，都在用写入成本、存储空间和维护复杂度交换查询性能。

### 12.1 适合创建 MV 的场景

优先考虑以下查询：

- Dashboard 高频刷新，查询结构长期稳定。
- 明细数据量巨大，但查询只关心固定粒度汇总。
- 多个应用反复执行相同 Join 或 Aggregate。
- 对象存储上的湖表被重复扫描，延迟和成本不稳定。
- `COUNT(DISTINCT)`、分位数等指标可以保存可合并聚合状态。

例如，分钟级可观测性指标很适合预聚合：

```sql
SELECT
    DATE_TRUNC('minute', event_time) AS minute,
    service_name,
    status_code,
    COUNT(*) AS request_count,
    SUM(latency_ms) AS latency_sum
FROM request_logs
GROUP BY
    DATE_TRUNC('minute', event_time),
    service_name,
    status_code;
```

### 12.2 创建之前先回答四个问题

1. **查询粒度是什么？** 日、小时、分钟还是原始事件？
2. **维度是否稳定？** 预聚合时丢掉的维度，查询时无法凭空恢复。
3. **指标是否可继续合并？** `SUM`、`MIN`、`MAX` 较简单，`AVG`、去重数和分位数需要保存合适状态。
4. **允许多大的延迟？** 强一致、分钟级、小时级和 T+1 对应不同实现。

### 12.3 不适合创建 MV 的场景

- 查询维度组合高度随机，几乎无法复用。
- 数据规模不大，明细查询已经足够快。
- 写入吞吐是首要瓶颈，而 MV 会显著放大写入成本。
- 指标频繁变动，维护物化结构的成本高于收益。
- 业务要求绝对实时，但异步刷新窗口不可接受。

最可靠的决策方式仍然是观察真实负载：使用 `EXPLAIN`、Profile、慢查询日志和扫描字节数识别重复成本，再创建最少数量的物化结构。

## 13. 术语表

| 术语 | 含义 |
| --- | --- |
| ODS | Operational Data Store。承接源系统原始数据，强调可追溯。 |
| DWD | Data Warehouse Detail。经过清洗、去重和口径统一的原子明细层。 |
| DWS | Data Warehouse Summary。按主题沉淀可复用汇总指标。 |
| ADS | Application Data Service。直接服务报表、接口和具体应用。 |
| DIM | Dimension。用户、商品、地区、日期等分析维度。 |
| Fact Table | 事实表。描述下单、支付、点击等业务过程及其度量。 |
| Dimension Table | 维度表。提供解释事实所需的属性和层级。 |
| Cube | 多维分析的逻辑空间，不等于必须完整物化。 |
| Slice | 固定一个维度，观察剩余维度形成的切片。 |
| Dice | 在多个维度上筛选，得到一个子空间。 |
| Drill Down | 从粗粒度进入细粒度，例如从月查看到日。 |
| Roll Up | OLAP 语义中指向上聚合；数据库实现中也可指额外物化索引。 |
| Aggregate Table | 保存维度键和聚合指标的结果表。 |
| Summary Table | 面向主题或应用保存摘要结果的表。 |
| Pre-Aggregation | 将部分聚合成本从查询时移动到写入、刷新或离线加工时。 |
| View | 保存 SQL 定义，不保存查询结果。 |
| Materialized View | 同时保存查询定义和物化结果的数据库对象。 |
| Query Rewrite | 优化器将基表查询透明改写为读取 MV 等价结果。 |

## 14. 总结

从 ODS 到 Materialized View，看似跨越了数据同步、数仓建模和数据库内核，实际上围绕的是同一个问题：**如何让原始事实逐步变成低成本、可复用、可解释的分析结果。**

```text
业务系统记录状态
        |
        v
ODS 忠实接住原始数据
        |
        v
DWD 整理原子事实，DIM 提供分析视角
        |
        v
DWS 沉淀公共汇总，ADS 服务具体应用
        |
        v
OLAP 在多个维度上 Slice、Dice、Drill Down、Roll Up
        |
        v
Aggregate Table / Rollup / MV 将重复计算提前完成
        |
        v
Query Rewrite 与 CBO 自动选择更低成本的执行计划
```

理解这些概念之后，再看 Doris、StarRocks、ClickHouse、Presto、Trino、Hive 和 Spark SQL，就不再是一组互不相干的产品名词。它们只是在不同边界上回答同一组工程问题：数据放在哪里，何时计算，计算结果保存多久，如何保持新鲜，以及查询优化器能替用户做多少决策。

## 参考资料

- [Apache Doris: Preaggregation and Rollup](https://doris.apache.org/docs/dev/key-features/preaggregation-and-rollup/)
- [Apache Doris: Materialized View](https://doris.apache.org/docs/4.x/query-acceleration/materialized-view/intro/)
- [StarRocks: Synchronous Materialized View](https://docs.starrocks.io/docs/using_starrocks/Materialized_view-single_table/)
- [StarRocks: Asynchronous Materialized Views](https://docs.starrocks.io/docs/using_starrocks/async_mv/Materialized_view/)
- [StarRocks: Query Rewrite with Materialized Views](https://docs.starrocks.io/docs/using_starrocks/async_mv/use_cases/query_rewrite_with_materialized_views/)
- [ClickHouse: Using Materialized Views](https://clickhouse.com/blog/using-materialized-views-in-clickhouse)
- [Trino: Iceberg Connector - Materialized Views](https://trino.io/docs/current/connector/iceberg.html#materialized-views)
