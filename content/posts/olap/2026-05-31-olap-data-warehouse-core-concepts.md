---
title: "一文讲透数据仓库与 OLAP 核心概念"
description: "从 ODS、维度建模到 Cube、Materialized View 与 Query Rewrite，系统梳理数据仓库与 OLAP 的核心概念、数据库实现和优化器演进。"
date: 2026-05-31
categories: [OLAP 与数据仓库]
tags: [olap, data-warehouse]
authors: ["liubang"]
lightgallery: true
---

> 从 ODS、维度建模到 Cube、Materialized View 与 Query Rewrite

数据库领域有一类概念特别容易被讲乱：ODS、DWD、事实表、维度表、Cube、Rollup、Projection、Materialized View、Query Rewrite。它们经常一起出现在数据平台架构图里，却不属于同一个层次。

ODS 和 DWD 是数仓工程中的数据分层；事实表和维度表来自维度建模；Cube、Slice 和 Dice 描述多维分析语义；数据库语境下的 Rollup、Projection 和 Materialized View（物化视图，以下简称 MV）是用于加速查询的物理机制；Query Rewrite（查询改写）和 Cost Based Optimization（基于代价的优化，以下简称 CBO）则属于优化器。

它们之所以经常同时出现，是因为都与一个问题有关：

> 当业务数据越来越多，分析需求越来越复杂时，如何避免每一次查询都从最原始的数据重新计算？

本文从一张订单表开始，按照问题出现的顺序梳理这套体系。

## 概念层次总览

在进入细节之前，先把概念放回它们所属的层次。很多误解并不是术语本身难，而是把不同层次的概念放在一起比较。

| 层次 | 核心概念 |
| --- | --- |
| 数仓分层 | ODS、DWD、DWS、ADS |
| 维度建模 | Grain、Fact、Dimension、SCD |
| 模型设计 | Star Schema、Snowflake Schema、Galaxy Schema |
| OLAP 语义 | Cube、Slice、Dice、Roll Up、Drill Down、Pivot |
| 预聚合 | Aggregate Table、Summary Table、Rollup |
| 数据库实现 | Aggregate Key、Projection、Materialized View |
| 优化器 | Query Rewrite、Statistics、Cardinality、CBO |

这些概念属于不同抽象层次。数仓分层描述数据加工流程，维度建模描述业务语义，OLAP 操作描述分析方式，数据库实现和优化器则负责控制查询成本。

理解这张图，后面的术语就不容易混淆。例如：

- DWS 中的日销售汇总表和数据库中的 MV 都可能保存聚合结果，但前者是数仓工程资产，后者是数据库对象。
- OLAP 语义中的 Roll Up 是从日上卷到月的分析动作，Doris 或 StarRocks 中的 Rollup 则是一种物化索引。
- Cube 是观察事实的逻辑空间，不等于数据库必须完整物化一个立方体。

下面从最初的问题开始。

## 数据仓库与 OLAP 全景图

整篇文章实际上都在解释下面这条链路：

```text
业务系统
    |
    v
   ODS
    |
    v
   DWD
    |
    v
Fact + Dimension
    |
    v
Star Schema
    |
    v
   Cube
    |
    +---- Slice
    |
    +---- Dice
    |
    +---- Drill Down
    |
    +---- Roll Up
    |
    v
Aggregate Table
    |
    v
  Rollup
    |
    v
Materialized View
    |
    v
Query Rewrite
    |
    v
Statistics
    |
    v
Cardinality
    |
    v
   CBO
```

这不是一条严格的处理流水线，而是一张认知地图。业务数据先经过数仓分层完成清洗和沉淀，再通过 Fact、Dimension 与 Star Schema 获得稳定语义。Cube 描述分析人员如何观察事实；Aggregate Table、Rollup 和 MV 负责避免重复计算；Query Rewrite、Statistics、Cardinality 与 CBO 则让优化器自动选择更便宜的执行路径。

图中每一次向下移动，都对应一次问题转换：从“如何保存源数据”进入“如何表达业务事实”，再进入“如何减少扫描与聚合”，最后进入“如何让优化器自动选择物理路径”。其中有些概念会在一次查询中连续出现，有些则只是不同层次上的设计工具。上半部分主要约束数据语义，下半部分主要控制执行成本；二者必须衔接，但不能混为一谈。DWS、Roll Up 和 Rollup 看起来相似，却分别属于工程分层、分析语义和数据库实现。理解它们之间的关系，比背诵孤立定义更重要。后续章节会沿着这张图逐层展开。

## 第一章 为什么需要数据仓库

### 1.1 业务数据库首先服务交易

假设我们正在开发一个电商系统。MySQL 中有三张表：

```sql
CREATE TABLE orders (
    order_id      BIGINT PRIMARY KEY,
    user_id       BIGINT NOT NULL,
    region_id     INT NOT NULL,
    status        VARCHAR(32) NOT NULL,
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
    brand_id      INT NOT NULL,
    product_name  VARCHAR(255) NOT NULL
);
```

这套模型首先要保证交易正确：

- 创建订单时，写入必须快速完成。
- 支付回调到达时，必须准确更新订单状态。
- 用户查看订单详情时，只读取少量记录。
- 库存扣减、退款和支付需要事务保证。

这类工作负载称为 **OLTP**（Online Transaction Processing，联机事务处理）。OLTP 系统通常围绕短事务、点查、小范围更新和高并发写入优化。B+ Tree 索引、行存储、Buffer Pool、锁和 MVCC 都服务于这个目标。

### 1.2 分析查询是另一种工作负载

运营同学希望查询过去一年每个省份、每个品类、每个月的销售额和购买人数：

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
WHERE o.status = 'PAID'
  AND o.order_time >= '2025-01-01'
  AND o.order_time <  '2026-01-01'
GROUP BY
    DATE_FORMAT(o.order_time, '%Y-%m'),
    o.region_id,
    p.category_id;
```

SQL 本身没有问题，但访问模式已经变了：

```text
OLTP 请求                          OLAP 查询
---------                          ---------
按订单号查几行                      扫描一年订单
更新一条支付状态                    Join 多张表
毫秒级短事务                        Group By / Distinct
延迟敏感                            吞吐敏感
大量并发小请求                      少量但昂贵的大查询
```

**OLAP**（Online Analytical Processing，联机分析处理）关注的是聚合、趋势、对比、下钻和即席分析。它与 OLTP 的主要矛盾不是 SQL 语法，而是资源模型：

1. **扫描范围不同。** 点查读取几行，年度报表可能读取数十亿行。
2. **存储偏好不同。** 行存储适合取出整条记录，分析查询通常只读取少量列的大量行。
3. **算子成本不同。** Join、Hash Aggregate、Sort、Window Function 都需要更多 CPU 和内存。
4. **历史要求不同。** 业务库关心当前状态，分析系统还要保留历史变化。
5. **资源隔离困难。** 报表查询会争抢 CPU、IO 和 Buffer Pool，最终影响支付和下单链路。

### 1.3 数仓为什么出现

最直接的解决方案是把分析负载从交易库剥离出来：

```text
MySQL / PostgreSQL        App Log        Kafka
        |                    |             |
        +--------------------+-------------+
                             |
                      CDC / Batch ETL
                             |
                             v
                      Data Warehouse
                             |
              +--------------+--------------+
              |                             |
        Hive / Spark SQL           Doris / StarRocks
        离线加工与回溯                交互式 OLAP 查询
              |                             |
              +--------------+--------------+
                             |
                       BI / API / Ad Hoc
```

数据仓库不是一块更大的磁盘，而是一套围绕分析建立的数据组织方式：

- 它从多个业务系统接住原始数据。
- 它清洗脏数据，统一字段和指标口径。
- 它保留历史，让报表能够回到过去。
- 它将交易模型转换成适合分析的模型。
- 它提前计算高频结果，让查询成本可控。

从这里开始，数据不再只是业务系统中的状态，而是分析资产。

## 第二章 数据仓库分层

### 2.1 分层是工程约定，不是数据库语法

常见的 ODS、DWD、DWS、ADS 是数仓工程中的分层约定。不同团队的命名和边界并不完全一致。本文沿用这套常见划分，因为它足以说明数据如何从原始记录逐步变成应用可直接消费的数据集。

这些分层不是数据库内核概念，也不是 SQL 标准中的对象类型。

你可以在 Hive、Iceberg、Doris、StarRocks 或 ClickHouse 中建设这些层；也可以用 Spark SQL、Flink 或调度系统完成层与层之间的加工。数据库只负责存储和执行，分层表达的是团队如何管理数据资产。

![数据仓库分层架构](/images/olap/data-warehouse-layers.svg "数据仓库分层架构")

### 2.2 ODS：忠实接住源数据

在常见的数仓分层约定中，**ODS**（Operational Data Store）是原始数据进入数仓后的第一站。ODS 首先追求可追溯，而不是模型漂亮。

```sql
CREATE TABLE ods_orders (
    order_id       BIGINT,
    user_id        BIGINT,
    region_id      INT,
    status         STRING,
    order_time     TIMESTAMP,
    update_time    TIMESTAMP,
    op_type        STRING,
    ingest_time    TIMESTAMP
);
```

CDC 数据通常会保留操作类型、摄取时间和源系统信息。后续发现口径错误时，可以从 ODS 重放，而不必重新压业务库。

### 2.3 DWD：沉淀原子事实

**DWD**（Data Warehouse Detail）负责清洗、去重、类型统一和口径统一，并形成可复用的明细数据。

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

这张表的一行表示“某个订单中的某个商品”。这个粒度一旦确定，销售额和销量才有稳定含义；订单数则需要按 `order_id` 去重计算。

### 2.4 DWS：沉淀公共汇总

**DWS**（Data Warehouse Summary）面向主题域保存可复用汇总。例如，按天、地区和品类计算销售额：

```sql
CREATE TABLE dws_sales_day_region_category AS
SELECT
    DATE(order_time) AS dt,
    region_id,
    category_id,
    SUM(amount) AS revenue,
    SUM(quantity) AS sold_quantity
FROM dwd_order_items i
JOIN dim_product p ON i.product_id = p.product_id
GROUP BY DATE(order_time), region_id, category_id;
```

DWS 不是“把所有字段都聚合一遍”，而是识别跨应用复用的公共指标。

### 2.5 ADS：面向消费场景

**ADS**（Application Data Service）直接服务报表、API 和具体应用：

```sql
CREATE TABLE ads_region_monthly_sales AS
SELECT
    DATE_FORMAT(dt, 'yyyy-MM') AS month,
    region_id,
    SUM(revenue) AS revenue
FROM dws_sales_day_region_category
GROUP BY DATE_FORMAT(dt, 'yyyy-MM'), region_id;
```

ADS 可以牺牲通用性换取查询简单、权限清晰和响应稳定。

```text
业务系统
   |
   | CDC / Log / Batch Sync
   v
  ODS     原始数据，可追溯
   |
   | 清洗、去重、统一口径
   v
  DWD     原子事实，可复用
   |
   | 面向主题聚合
   v
  DWS     公共指标，可共享
   |
   | 面向应用加工
   v
  ADS     报表、接口、特征
```

这条链路解决的是数据工程问题。但 DWD 中的一行究竟应该代表什么？维度和指标如何组织？这需要维度建模。

### 2.6 Lakehouse 在体系中的位置

数据仓库不一定建立在专用数据库中。大量历史数据也可以保存在对象存储或 HDFS 上，由 Hive 及其 Metastore 提供表目录和元数据入口。Iceberg、Hudi、Delta Lake 等 Lakehouse 表格式或平台，进一步为数据湖补充快照、元数据管理、ACID 事务、Schema Evolution、更新与删除等能力。

```text
对象存储 / HDFS
        |
        +-- Hive / Hive Metastore：表目录与元数据入口
        |
        +-- Iceberg / Hudi / Delta Lake：表格式、快照、事务与文件组织
        |
        +-- Trino / Spark：查询与计算
        |
        +-- Doris / StarRocks / ClickHouse：低延迟分析服务
```

这些系统可以组合使用，并不是简单的替代关系。Lakehouse 重点解决数据湖中的表管理和数据组织；Doris、StarRocks、ClickHouse 更强调低延迟、高吞吐分析；Trino 和 Spark 则负责在不同存储之上执行查询和计算任务。

## 第三章 维度建模

维度建模的目标，是让业务问题对应到语义稳定的数据结构。

交易系统通常按实体和更新路径设计：订单、订单项、用户、商品各自独立。分析系统则需要围绕业务过程设计：一次下单、一次支付、一次退款、一次曝光分别产生什么事实？分析人员希望从时间、用户、商品、地区还是渠道观察这些事实？

Kimball 的经典四步法是：

```text
1. Select the business process     选择业务过程
2. Declare the grain               声明粒度
3. Identify the dimensions         识别维度
4. Identify the facts              识别事实
```

### 3.1 Grain：为什么必须先声明粒度

**Grain**（粒度）定义事实表中一行数据精确代表什么。

对于订单系统，至少有三种可能粒度：

```text
订单粒度       一行 = 一个订单
订单项粒度     一行 = 一个订单中的一个商品
支付流水粒度   一行 = 一次支付或退款动作
```

如果不先声明粒度，很容易把不同层次的事实混在一起：

```text
order_id  product_id  payment_id  order_amount  item_amount
10001     2001        P001        299.00        199.00
10001     2002        P001        299.00        100.00
```

对 `order_amount` 求和会得到 `598.00`，因为订单金额在订单项粒度被重复了两次。

因此，事实表设计的第一句话不应该是“有哪些字段”，而应该是：

> `fact_order_items` 中的一行，表示一个已支付订单中的一个商品明细。

粒度决定：

- 哪些维度键可以放进事实表。
- 哪些指标可以直接求和。
- Join 是否会放大数据。
- 下钻能够到达的最细层级。
- 后续 Aggregate Table 和 MV 的语义是否正确。

Grain 不是建模文档中的一句开场白，而是所有聚合正确性的前提。

### 3.2 Fact Table：记录业务过程

**Fact Table**（事实表）描述可度量的业务过程。订单明细事实表可以写成：

```sql
CREATE TABLE fact_order_items (
    order_id         BIGINT,
    order_date_key   INT,
    user_key         BIGINT,
    product_key      BIGINT,
    region_key       INT,
    channel_key      INT,
    quantity         INT,
    amount           DECIMAL(18, 2)
);
```

事实表通常包含两类列：

- **维度键**：时间、用户、商品、地区、渠道。
- **度量值**：金额、数量、耗时、流量。

度量值还需要判断可加性：

| 类型 | 示例 | 是否可以跨所有维度求和 |
| --- | --- | --- |
| Additive | 销售额、销量 | 通常可以 |
| Semi-additive | 账户余额、库存 | 可以跨部分维度求和，但不能简单跨时间累加 |
| Non-additive | 比率、单价 | 通常需要重新计算 |

`SUM(amount)` 很自然；`AVG(price)` 则不能先算平均值，再对多个平均值直接求平均。后续设计 MV 时，这个区别非常重要。

例如，华东有 100 个订单，平均客单价为 80 元；华南只有 10 个订单，平均客单价为 200 元。直接计算 `AVG(80, 200)` 会得到 140 元，正确结果却是 `(100 * 80 + 10 * 200) / 110 = 90.91` 元。平均值丢失了分母，必须保留可继续聚合的中间状态：

```sql
SELECT
    region_key,
    SUM(amount) AS revenue,
    COUNT(DISTINCT order_id) AS order_count
FROM fact_order_items
GROUP BY region_key;

-- 跨地区汇总时重新计算，而不是 AVG(avg_order_amount)
SELECT
    SUM(revenue) / SUM(order_count) AS avg_order_amount
FROM sales_by_region;
```

上面的地区必须互斥，才能继续累加 `order_count`。如果同一订单可能跨多个分组出现，`COUNT(DISTINCT)` 也不能直接相加，需要保留订单粒度，或者保存 Bitmap、HLL 等可合并状态。

销售额是 **Additive** 指标，可以跨时间、地区和商品直接求和。库存是 **Semi-additive** 指标：同一时点可以跨仓库相加，但不能把每天的库存快照累加成月库存。平均客单价是 **Non-additive** 指标，需要用销售额和订单数重新计算。Aggregate Table、Rollup 与 MV Rewrite 都依赖这种可加性判断：如果预聚合结果没有保留足够的中间状态，后续 Roll Up 就无法保证语义正确。

#### Fact Table 的四种常见类型

Kimball 通常将事实表归纳为三种基本粒度：Transaction、Periodic Snapshot 和 Accumulating Snapshot。工程实践中还经常单独讨论 Factless Fact Table，它是不保存数值度量的特殊事实表。

**Transaction Fact Table** 一行对应某个时点发生的一次业务事件，例如订单明细：

```sql
CREATE TABLE fact_order_items (
    order_id BIGINT,
    product_key BIGINT,
    quantity INT,
    amount DECIMAL(18, 2)
);
```

它适合回答“发生了什么”。这类表通常保留最细粒度，写入后很少更新，可以按时间、商品、用户等维度聚合，便于 Slice、Dice 和 Drill Down。订单、支付流水、点击日志都属于这一类。

**Periodic Snapshot Fact Table** 按固定周期保存状态快照，例如每日库存：

```sql
CREATE TABLE fact_inventory_daily (
    snapshot_date DATE,
    product_key BIGINT,
    warehouse_key BIGINT,
    stock_quantity BIGINT
);
```

它适合查询某日库存、月末余额和历史趋势。快照表关注某个时间截面的状态，而不是状态变化过程；即使当天没有交易，也可能需要保留一行。账户余额、设备在线数、每日活跃会员数也常用这种模型。

**Accumulating Snapshot Fact Table** 用一行跟踪具有明确起点和终点的流程，例如订单履约：

```sql
CREATE TABLE fact_order_fulfillment (
    order_id BIGINT,
    created_at TIMESTAMP,
    paid_at TIMESTAMP,
    shipped_at TIMESTAMP,
    completed_at TIMESTAMP
);
```

流程推进时更新同一行，新的里程碑时间会覆盖到对应字段。它适合分析各阶段耗时、流程瓶颈和未完成订单，但不适合保存无限延长的事件序列。理赔、工单处理、物流履约也经常采用这种表。

**Factless Fact Table** 只记录事件或覆盖关系，不保存数值度量。例如学生签到：

```sql
CREATE TABLE fact_student_attendance (
    date_key INT,
    student_key BIGINT,
    course_key BIGINT
);
```

它通过行是否存在表达事实，适合计算签到次数、活动参与人数或促销覆盖范围。另一类常见用法是记录“应当发生但未必发生”的覆盖关系，例如某门课程应到的学生，再与实际签到事件比较。

选择哪一种事实表，取决于业务问题需要观察事件、周期状态、有限生命周期，还是关系是否存在。建模时仍然要先声明 Grain，再选择事实表类型。它们不是互相替代的设计，同一主题域中往往会并存。

### 3.3 Dimension Table：提供观察视角

**Dimension Table**（维度表）回答“从什么角度观察事实”：

```sql
CREATE TABLE dim_product (
    product_key      BIGINT,
    product_id       BIGINT,
    product_name     STRING,
    category_id      INT,
    category_name    STRING,
    brand_id         INT,
    brand_name       STRING
);
```

商品维度通常比事实表更宽，包含大量可读属性。用户可以按品牌筛选，按品类聚合，再下钻到 SKU：

```sql
SELECT
    p.category_name,
    SUM(f.amount) AS revenue
FROM fact_order_items f
JOIN dim_product p ON f.product_key = p.product_key
GROUP BY p.category_name;
```

事实表负责记录“发生了什么”，维度表负责解释“它发生在什么上下文中”。

### 3.4 Conformed Dimension：让不同事实说同一种语言

当订单、支付和退款分别建设事实表时，它们都需要时间、用户和商品维度。如果每个团队各自维护一套商品分类，跨主题分析会立即失去一致性。

**Conformed Dimension**（一致性维度）是多个事实表共同使用、具有一致语义的维度。

```text
fact_order_items ----+
                    |
fact_payments -------+----> dim_date
                    +----> dim_user
fact_refunds --------+----> dim_product
```

有了一致性维度，订单和退款可以先在各自粒度上聚合，再按照同一套商品分类对齐：

```sql
WITH paid AS (
    SELECT
        product_key,
        SUM(amount) AS paid_amount
    FROM fact_order_items
    GROUP BY product_key
),
refunded AS (
    SELECT
        product_key,
        SUM(refund_amount) AS refund_amount
    FROM fact_refunds
    GROUP BY product_key
)
SELECT
    p.category_name,
    SUM(o.paid_amount) AS paid_amount,
    SUM(COALESCE(r.refund_amount, 0)) AS refund_amount
FROM paid o
JOIN dim_product p ON o.product_key = p.product_key
LEFT JOIN refunded r ON o.product_key = r.product_key
GROUP BY p.category_name;
```

一致性维度是跨主题域复用和 Bus Architecture 的基础。

### 3.5 Kimball Bus Architecture：让主题域可以拼接

Conformed Dimension 并不是孤立的建模技巧。Kimball Bus Architecture 的核心，是先定义企业可以共享的一致性维度，再让不同业务过程沿这些维度接入数仓。

```text
业务过程 \ 一致性维度    dim_date    dim_user    dim_product
----------------------------------------------------------
订单事实                    X           X            X
支付事实                    X           X            X
退款事实                    X           X            X
库存事实                    X                        X
```

订单、支付、退款和库存的 Grain 不同，指标也不同，但都可以复用 `dim_date`、`dim_user` 和 `dim_product`。这样既能让各主题域独立建设，又能保证跨域分析使用同一套日期口径、用户标识和商品分类。Bus Architecture 的价值不在于画出一辆“总线”，而在于建立可复用的维度契约：新的事实表接入时，不必重新发明企业语义。

### 3.6 Degenerate Dimension：只留下业务标识

有些维度没有额外描述属性，但仍然有分析价值。例如订单号：

```text
fact_order_items
+----------+-------------+----------+--------+
| order_id | product_key | quantity | amount |
+----------+-------------+----------+--------+
```

`order_id` 可以用于钻取订单、计算订单数和关联退款，但没有必要创建只有 `order_id` 一列的 `dim_order`。

这类直接保留在事实表中的业务标识称为 **Degenerate Dimension**（退化维度）。

### 3.7 Junk Dimension：收拢零散状态

事实表中经常出现一批低基数标志位：

```text
is_gift
is_first_order
payment_type
coupon_type
delivery_type
```

把它们全部散落在事实表里，会让表越来越宽；为每个字段创建独立维度表，又会让模型过度碎片化。

**Junk Dimension**（杂项维度）将这些零散属性组合在一起：

```sql
CREATE TABLE dim_order_flags (
    order_flags_key  INT,
    is_gift          BOOLEAN,
    is_first_order   BOOLEAN,
    payment_type     STRING,
    coupon_type      STRING
);
```

事实表只保存一个 `order_flags_key`，以免模型在大量低基数属性之间变得零碎。

### 3.8 Slowly Changing Dimension：业务属性会变化

维度不是静止的。用户会搬家，商品会调整品类，组织会重新划分销售区域。

假设用户 `501` 从浙江迁移到上海：

```text
user_id = 501
old region = Zhejiang
new region = Shanghai
```

问题是：去年订单应该按浙江统计，还是按上海统计？

#### Type 1：覆盖旧值

**SCD Type 1** 直接更新维度属性：

```sql
UPDATE dim_user
SET region_name = 'Shanghai'
WHERE user_id = 501;
```

适用于修正拼写错误，或者业务只关心最新状态。代价是历史被改写。

#### Type 2：新增版本

**SCD Type 2** 新增一行，使用代理键和有效时间保留历史：

```text
user_key  user_id  region_name  valid_from   valid_to     is_current
--------  -------  -----------  -----------  -----------  ----------
9001      501      Zhejiang     2024-01-01   2026-05-01   false
9327      501      Shanghai     2026-05-01   9999-12-31   true
```

订单事实在写入时绑定当时有效的 `user_key`。这样，历史订单仍然指向浙江版本，新订单指向上海版本。

```sql
SELECT
    u.region_name,
    SUM(f.amount)
FROM fact_order_items f
JOIN dim_user u ON f.user_key = u.user_key
GROUP BY u.region_name;
```

SCD Type 2 的价值，是让“按照当时事实统计”成为可能。

## 第四章 星型模型、雪花模型与星座模型

### 4.1 Star Schema：让事实处于中心

**Star Schema**（星型模型）让多个维度表直接围绕事实表：

![星型模型与雪花模型](/images/olap/star-vs-snowflake-schema.svg "星型模型与雪花模型")

```text
                 dim_date
                    |
dim_user ---- fact_order_items ---- dim_product
                    |
               dim_region
```

星型模型常见于分析系统，不只是因为容易画图，更因为它贴近查询方式：

```sql
SELECT
    d.month,
    p.category_name,
    r.province_name,
    SUM(f.amount) AS revenue
FROM fact_order_items f
JOIN dim_date d    ON f.order_date_key = d.date_key
JOIN dim_product p ON f.product_key = p.product_key
JOIN dim_region r  ON f.region_key = r.region_key
GROUP BY d.month, p.category_name, r.province_name;
```

### 4.2 为什么星型模型适合分析

Microsoft 的星型模型指南强调，它是一种成熟且被广泛采用的关系型数仓建模方式。它同时改善性能和易用性。

从执行角度看，星型模型有几个现实优势：

1. **Join 路径更短。** 事实表直接连接维度表，避免为了拿到一个品类名称继续层层 Join。
2. **维度过滤更集中。** 优化器可以先过滤较小的维度表；如果执行引擎支持动态过滤、运行时过滤器或类似机制，还能据此减少事实表的扫描范围。
3. **查询结构稳定。** 事实与维度职责清晰，聚合 SQL 更容易生成和维护。
4. **维度属性可读。** BI 和 API 不必理解交易库中的复杂规范化结构。

星型模型不是自动加速器。性能仍然取决于统计信息、存储布局、Join 策略和数据规模。但它给优化器和使用者都提供了更清晰的结构。

### 4.3 Snowflake Schema：继续规范化维度

**Snowflake Schema**（雪花模型）会拆分维度：

```text
fact_order_items
       |
  dim_product
    /      \
category  brand
```

它减少冗余，但增加 Join 数量和理解成本。对于更新频繁、层级复杂或主数据管理要求较强的维度，雪花模型仍然有价值。

### 4.4 Galaxy Schema：多个事实共享维度

当订单、支付、退款和库存共同使用一致性维度时，模型会形成 **Galaxy Schema**（星座模型，也称 Fact Constellation）：

```text
                         dim_date
                            |
          +-----------------+-----------------+
          |                 |                 |
 fact_order_items      fact_payments      fact_refunds
          |                 |                 |
          +-----------------+-----------------+
                            |
                       dim_product
```

Galaxy Schema 不是另一种完全独立的方法，而是多个星型模型通过 Conformed Dimension 连接起来。

## 第五章 OLAP 的本质

维度模型解决了数据如何组织的问题。接下来，分析人员要在这些维度上观察事实。

### 5.1 多维分析不是三维图

假设销售额可以从三个维度观察：

- 时间：日、月、季度、年。
- 地区：城市、省份、国家。
- 商品：SKU、品类、品牌。

**Cube** 是对这个多维分析空间的逻辑抽象：

![OLAP Cube 与多维分析操作](/images/olap/olap-cube-operations.svg "OLAP Cube 与多维分析操作")

Cube 不等于必须物化一个立方体，更不限制维度数量。它首先表达的是：同一组事实可以沿不同维度、不同层级被切分和聚合。

### 5.2 Slice：固定一个维度

只查看 `2026-05-01` 当天的销售额：

```sql
SELECT region_id, category_id, SUM(revenue)
FROM dws_sales_day_region_category
WHERE dt = '2026-05-01'
GROUP BY region_id, category_id;
```

这相当于从 Cube 中取出一个切片。

### 5.3 Dice：选取一个子空间

只看 5 月、浙江和江苏、家电与数码品类：

```sql
SELECT dt, region_id, category_id, SUM(revenue)
FROM dws_sales_day_region_category
WHERE dt >= '2026-05-01'
  AND dt <  '2026-06-01'
  AND region_id IN (10, 11)
  AND category_id IN (301, 302)
GROUP BY dt, region_id, category_id;
```

### 5.4 Drill Down 与 Roll Up

**Drill Down**（下钻）从粗粒度进入细粒度：

```text
年 -> 月 -> 日
省 -> 市 -> 门店
品类 -> SKU
```

**Roll Up**（上卷）则从细粒度聚合到粗粒度：

```sql
SELECT
    DATE_FORMAT(dt, 'yyyy-MM') AS month,
    region_id,
    SUM(revenue)
FROM dws_sales_day_region_category
GROUP BY DATE_FORMAT(dt, 'yyyy-MM'), region_id;
```

### 5.5 Pivot：旋转观察角度

**Pivot**（透视）并不改变事实，而是改变结果的展示轴：

```text
原始结果：
month     region    revenue
2026-05   Zhejiang  100
2026-05   Shanghai  120

Pivot 后：
month     Zhejiang  Shanghai
2026-05   100       120
```

到这里为止，我们讨论的仍然是分析语义。接下来才进入数据库实现问题：如果用户不断执行相似的 Roll Up，为什么每次都要重新扫描明细？

### 5.6 Cube 的实现路线

Cube 首先是分析语义，但不同年代的系统采用了不同的物理实现。**MOLAP**（Multidimensional OLAP）会把多个维度组合及其聚合结果预先计算到专用多维存储中。查询时可以直接命中预计算单元，响应很快；代价是维度增多后组合数量迅速膨胀，刷新成本和存储成本都很高，也难以容纳频繁变化的明细。

**ROLAP**（Relational OLAP）将事实表、维度表和汇总表保存在关系模型中，通过 SQL、索引和执行引擎完成聚合。它更容易接住持续增长的数据，维度扩展也更灵活。ROLAP 并不意味着每次查询都必须从明细开始计算：Aggregate Table 和 Summary Table 本来就是常见优化手段，只是系统通常需要人工选择合适的汇总层。

**HOLAP**（Hybrid OLAP）在两者之间折中：高频聚合结果进入多维存储，细粒度数据仍保留在关系存储中。常见查询可以快速返回，需要下钻时再访问明细。它缓解了完整 Cube 的膨胀问题，但增加了刷新、路由和一致性维护的复杂度。

现代 Doris、StarRocks、ClickHouse 和 Trino 并没有简单复刻传统 Cube。更常见的路线是保留明细数据和灵活 SQL，只物化值得复用的布局或结果，再由优化器透明选择。Doris 和 StarRocks 提供 Rollup 与 MV，ClickHouse 提供 Projection 和不同语义的 MV，Trino 则依赖 Connector 与外部存储能力。

这种变化背后有两个原因。第一，真实查询的维度组合存在明显冷热差异，完整 Cube 会为大量低频组合支付维护成本。第二，明细数据、过滤条件和 Join 关系持续变化，固定 Cube 很难覆盖临时分析。现代系统仍然使用预聚合，但把物化对象变成可选择的候选路径：高频查询命中预计算结果，长尾查询回到明细或较细粒度结果。工程重心因此从“提前穷举完整 Cube”转向“按收益物化候选结果，再通过 Query Rewrite 复用”。

这里还存在一个稀疏性问题。理论上的维度笛卡尔积可能很大，但真实数据只覆盖其中一小部分；预计算过少无法加速查询，预计算过多又会浪费刷新时间和存储空间。现代系统不再追求一次性找到唯一物化方案，而是允许多个不同粒度、不同排序方式和不同刷新周期的候选结果并存。

## 第六章 预聚合的发展路径

### 6.1 为什么 OLAP 查询仍然昂贵

假设 `fact_order_items` 每天写入一亿行，Dashboard 每 30 秒刷新一次：

```sql
SELECT
    order_date_key,
    region_key,
    SUM(amount)
FROM fact_order_items
WHERE order_date_key >= 20260501
GROUP BY order_date_key, region_key;
```

典型 MPP 执行链路如下：

```text
Scan 明细数据
      |
      v
Filter
      |
      v
Local Hash Aggregate
      |
      v
Network Shuffle by Group Key
      |
      v
Global Hash Aggregate
      |
      v
Result
```

列存储和向量化执行可以让每一行处理得更快，但如果每次仍然扫描几十亿行，查询成本依然很高。

### 6.2 Pre-Aggregation：把重复计算搬到前面

如果查询模式稳定，可以提前保存 `(date, region)` 粒度的结果：

```sql
CREATE TABLE sales_day_region AS
SELECT
    order_date_key,
    region_key,
    SUM(amount) AS revenue
FROM fact_order_items
GROUP BY order_date_key, region_key;
```

![预聚合如何减少查询成本](/images/olap/pre-aggregation-query-path.svg "预聚合如何减少查询成本")

预聚合的本质是交换：

```text
更多写入成本 + 更多存储空间 + 一定维护复杂度
                    |
                    v
更少扫描行数 + 更少聚合计算 + 更低查询延迟
```

### 6.3 从 Cube 到 Materialized View

预聚合机制可以沿着一条演进路径理解：

![现代 OLAP 预计算机制的演进](/images/olap/olap-evolution.svg "现代 OLAP 预计算机制的演进")

```text
Cube
  |
  | 提前计算多维组合
  v
Aggregate Table
  |
  | 保存可复用聚合结果
  v
Summary Table
  |
  | 面向主题或报表保存摘要
  v
Rollup
  |
  | 将常见汇总变成数据库维护的物化索引
  v
Materialized View
  |
  | 用 SQL 表达更通用的预计算逻辑
  v
Query Rewrite + CBO
  |
  | 自动选择代价最低且语义等价的结果
```

这不是严格的产品版本历史，也不是后一种机制完全取代前一种机制。它只是一个便于理解的抽象序列：预计算结果逐渐从手工维护的表，演进为优化器可以透明复用的数据库对象。

#### Aggregate Table

**Aggregate Table** 强调保存聚合后的结果：

```text
(dt, region_id, category_id) -> SUM(revenue), SUM(quantity)
```

#### Summary Table

**Summary Table** 强调面向某个主题或应用保存摘要。它可能包含聚合、派生指标和业务规则。很多 DWS 和 ADS 表本质上就是 Summary Table。

#### Rollup

在 OLAP 语义中，Roll Up 是向上聚合的动作；在部分数据库中，Rollup 还是一种额外物化索引。两者有关联，但不是同一层概念。

#### Materialized View

MV 将预计算结果变成声明式数据库对象。用户描述“想物化什么”，优化器再判断“查询是否可以复用它”。

## 第七章 现代 OLAP 数据库实现

不同系统都在减少扫描与重复计算，但它们选择的边界不同。

### 7.1 Doris：Aggregate Key、Rollup 与 MV

Apache Doris 的 **Aggregate Key** 是一种表模型。Key 相同的行会按 Value 列声明的聚合函数合并：

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

相同 Key 的数据会在导入和 Compaction 过程中按声明的聚合函数合并。Aggregate Key 解决的是“同 Key 指标如何合并”，它不是 Cube，也不是数仓 DWS。

Doris 的 Rollup 是基表之上的额外物化索引：

```sql
ALTER TABLE order_items
ADD ROLLUP rollup_day_region (
    dt,
    region_id,
    amount
);
```

对于新设计，Doris 官方更推荐使用同步 MV 表达类似能力：

```sql
CREATE MATERIALIZED VIEW mv_sales_day_region AS
SELECT dt, region_id, SUM(amount)
FROM order_items
GROUP BY dt, region_id;
```

同步 MV 适合单表实时聚合和排序优化。异步 MV 则能够支持更复杂的 SQL、分区刷新和湖仓加速。

### 7.2 StarRocks：同步 MV 本质上是 Rollup

StarRocks 的同步 MV 是基表上的特殊 Rollup 索引。数据导入基表时，同步 MV 自动更新；查询仍然面向基表编写：

```sql
CREATE MATERIALIZED VIEW mv_sales_day_region AS
SELECT dt, region_id, SUM(amount)
FROM order_items
GROUP BY dt, region_id;

EXPLAIN
SELECT dt, region_id, SUM(amount)
FROM order_items
GROUP BY dt, region_id;
```

执行计划可能显示：

```text
0:OlapScanNode
   TABLE: order_items
   PREAGGREGATION: ON
   rollup: mv_sales_day_region
```

异步 MV 是独立物理表，适合多表 Join、外部 Catalog、分区刷新和透明 Query Rewrite。

### 7.3 ClickHouse：MV 与 Projection 职责不同

ClickHouse 的 Incremental Materialized View 更接近写入触发器：源表插入新数据块时执行查询，并将结果写入目标表。

```sql
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

它适合追加写入、流式转换和实时聚合。需要注意：它通常处理新插入的数据块，不会因为源表历史 Mutation 自动重算全部结果。

目标表的表引擎决定了后续如何合并结果。例如，`SummingMergeTree` 可以合并求和结果，`AggregatingMergeTree` 可以保存并合并聚合状态。查询侧仍然要按照目标表引擎的语义读取结果。

ClickHouse 的 **Projection** 是表内部的备用物理布局：

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

Projection 可以提供额外排序或预聚合布局，由优化器透明选择。

对于创建 Projection 之前已经存在的数据，还需要显式执行物化操作：

```sql
ALTER TABLE order_items
MATERIALIZE PROJECTION p_sales_day_region;
```

```text
写入时转换，结果进入独立目标表
    -> Incremental MV

周期性重算复杂查询，保存结果快照
    -> Refreshable MV

同一张表的备用排序或聚合布局
    -> Projection
```

### 7.4 Trino：依赖 Connector 与外部存储能力

Trino 是分布式联邦查询引擎，不是统一持有数据的存储系统。它查询 Hive、Iceberg、关系数据库和其他数据源，优化效果依赖 Connector 能否提供：

- Predicate Pushdown。
- Projection Pushdown。
- Aggregate Pushdown。
- Table Statistics。
- 存储格式上的分区和文件裁剪。

Trino Iceberg Connector 还支持创建和刷新 MV：

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

创建 MV 只会注册定义，不会自动填充数据，因此首次使用前必须执行 `REFRESH MATERIALIZED VIEW`。对于 Iceberg Connector，刷新可能是全量，也可能根据 MV 定义复杂度和源表快照历史执行增量更新。

更准确的说法不是“Trino 天然依赖 MV”，而是：

> 在计算存储分离架构中，缺少数据库内部长期维护的本地物理布局时，合理分区、文件组织、Connector Pushdown 和外部预计算结果更加重要。

## 第八章 Materialized View

### 8.1 MV 为什么不只是预计算表

普通 View 只保存查询定义：

```sql
CREATE VIEW v_sales_day_region AS
SELECT dt, region_id, SUM(amount) AS revenue
FROM order_items
GROUP BY dt, region_id;
```

查询时，数据库仍然需要展开 SQL 并扫描底层数据。

Materialized View 同时保存查询定义和物化结果：

```text
Materialized View
    |
    +-- SQL Definition
    |
    +-- Materialized Data
    |
    +-- Refresh Policy
    |
    +-- Freshness Metadata
    |
    +-- Rewrite Rules
```

手工汇总表只解决“把结果保存下来”；数据库内建 MV 还需要回答：

- 什么时候刷新？
- 哪些分区变化了？
- MV 是否足够新鲜？
- 当前查询是否与 MV 等价？
- 多个候选 MV 中哪一个成本最低？

### 8.2 Full Refresh 与 Incremental Refresh

**Full Refresh** 全量重算：

```sql
REFRESH MATERIALIZED VIEW mv_sales_day_region;
```

优点是语义直接，缺点是基表越大，刷新越昂贵。

**Incremental Refresh** 只处理变化部分：

```text
基表新增 2026-05-31 分区
             |
             v
只刷新 MV 的 2026-05-31 分区
             |
             v
历史分区保持不变
```

增量刷新是否可行，取决于：

- 基表能否识别变化分区或变更日志。
- 数据是追加写，还是包含更新和删除。
- Join 关系是否会让一个维度变化影响大量事实。
- 聚合函数是否可合并。

`SUM`、`MIN`、`MAX` 较容易增量维护；`COUNT(DISTINCT)` 常需要 Bitmap 或 HLL 等可合并状态；`AVG` 通常要保存 `SUM` 与 `COUNT`。

### 8.3 Query Rewrite：透明复用 MV

假设存在日、地区、品类粒度的 MV：

```sql
CREATE MATERIALIZED VIEW mv_sales_day_region_category AS
SELECT
    dt,
    region_id,
    category_id,
    SUM(amount) AS revenue
FROM order_items
GROUP BY dt, region_id, category_id;
```

用户查询月度地区销售额：

```sql
SELECT
    DATE_TRUNC('month', dt) AS month,
    region_id,
    SUM(amount)
FROM order_items
GROUP BY DATE_TRUNC('month', dt), region_id;
```

优化器可以将它改写为：

```sql
SELECT
    DATE_TRUNC('month', dt) AS month,
    region_id,
    SUM(revenue)
FROM mv_sales_day_region_category
GROUP BY DATE_TRUNC('month', dt), region_id;
```

![Materialized View 查询改写](/images/olap/mv-query-rewrite.svg "Materialized View 查询改写")

查询和 MV 不必逐字相同。只要 MV 粒度更细、聚合可以继续 Roll Up，优化器就有机会复用它。

Query Rewrite 能够成立，通常需要满足以下条件：

1. **MV 粒度不粗于查询粒度。** 日粒度 MV 可以继续汇总到月，月粒度 MV 无法还原日明细。
2. **聚合函数可以重聚合。** `SUM`、`MIN`、`MAX` 可以继续合并；`AVG` 通常需要拆成 `SUM` 和 `COUNT`；去重计数需要可合并状态。
3. **过滤条件可以推导。** 优化器需要证明 MV 覆盖查询所需的数据范围，或者能够在读取 MV 后继续过滤。
4. **Join 关系兼容。** 当 MV 包含 Join 时，表之间的关系、连接类型和过滤条件必须允许等价改写。

存在 MV 并不意味着优化器一定会选择它。MV 可能包含过多无关维度，扫描和二次聚合成本反而更高；异步 MV 可能已经超过允许的 Staleness；统计信息缺失或失真时，优化器也可能无法可靠判断收益。

### 8.4 Freshness 与 Staleness

**Freshness** 描述 MV 与基表的同步程度。**Staleness** 描述允许结果落后基表多久。

```text
基表最新时间：10:05
MV 最新时间： 10:00
Staleness：   5 分钟
```

不同场景对新鲜度要求不同：

| 场景 | 可接受延迟 |
| --- | --- |
| 支付风控 | 接近实时 |
| 运营 Dashboard | 分钟级 |
| 日报 | 小时级或 T+1 |
| 历史归档分析 | 更宽松 |

异步 MV 的结果可能落后于基表。系统需要根据刷新策略和允许的 Staleness，决定是否继续使用这份物化结果。

### 8.5 Cost Based Rewrite

当多个 MV 都能服务查询时，优化器要比较：

```text
候选 1：扫描明细基表
候选 2：扫描日粒度 MV，再 Roll Up 到月
候选 3：扫描月粒度 MV
候选 4：扫描包含额外维度的 MV，再二次聚合
```

代价模型通常考虑：

- 扫描行数和字节数。
- 分区裁剪效果。
- 是否仍然需要 Join。
- 是否需要二次聚合。
- MV 是否足够新鲜。
- 聚合函数是否支持 Roll Up。

MV 相比普通汇总表多出的一层能力，是进入优化器的候选计划集合，参与等价改写和代价选择。

## 第九章 为什么 OLAP 查询快

预聚合只是 OLAP 性能体系的一部分。现代分析系统通常同时使用多种优化。

### 9.1 一条查询如何逐步变小

```sql
SELECT
    region_id,
    SUM(amount)
FROM order_items
WHERE dt >= '2026-05-01'
  AND dt <  '2026-06-01'
  AND status = 'PAID'
GROUP BY region_id;
```

理想执行链路如下：

```text
Partition Pruning
只访问 2026-05 分区
        |
        v
Projection Pruning
只读取 dt / status / region_id / amount
        |
        v
Predicate Pushdown
在 Scan 阶段过滤 status = 'PAID'
        |
        v
Columnar Storage + Vectorized Execution
批量解码和计算
        |
        v
Local Pre-Aggregation
每个节点先局部聚合
        |
        v
Network Shuffle
仅传输较小聚合状态
        |
        v
Global Aggregate
```

### 9.2 优化手段分别解决什么

| 优化 | 核心作用 | 主要收益 |
| --- | --- | --- |
| Partition Pruning | 跳过无关分区 | 减少 IO、文件枚举和扫描任务 |
| Projection Pruning | 只读取需要的列 | 减少 IO、解压缩和内存占用 |
| Predicate Pushdown | 尽早过滤行 | 减少 CPU、内存和后续网络传输 |
| Aggregate Pushdown | 将聚合推到数据源 | 减少传输行数和上层计算 |
| Columnar Storage | 相同列连续存储 | 提高压缩率和扫描效率 |
| Vectorized Execution | 一批数据一起执行 | 降低函数调用开销，提高 CPU 利用率 |
| Pre-Aggregation | 提前保存可复用结果 | 大幅减少扫描、Hash Aggregate 和 Shuffle |

这里的 Projection Pruning 指关系代数中的列裁剪，不是 ClickHouse 表内的 `PROJECTION`。

### 9.3 从资源视角看收益

#### IO

分区裁剪跳过整个分区，列裁剪跳过无关列，索引和 Zone Map 跳过不可能命中的数据块，MV 则进一步让扫描对象从几十亿行明细变成几千行汇总。

#### CPU

列式编码减少解码工作，向量化执行改善 CPU Cache 局部性，预聚合减少哈希、表达式求值和序列化次数。

#### Memory

更早过滤意味着更小的 Hash Table、更少的中间结果和更低的 Spill 风险。Join 顺序错误时，内存压力可能成倍增长。

#### Network

MPP 查询最昂贵的阶段之一是 Shuffle。Local Aggregate 和 Aggregate Pushdown 让网络传输聚合状态，而不是所有明细行。

这些优化手段的共同目标，是尽可能让更少的数据进入下一个算子。

## 第十章 优化器与未来

### 10.1 优化器为什么需要统计信息

查询优化器必须估算每个算子会处理多少数据。最基础的统计信息包括：

- Row Count：表有多少行。
- NDV（Number of Distinct Values）：某列有多少不同值。
- Null Fraction：空值比例。
- Min / Max：值域范围。
- Data Size：读取数据量。

假设：

```text
fact_order_items            10,000,000,000 rows
dim_product                         1,000,000 rows
dim_region                                500 rows
```

`region_id = 10` 能过滤多少行？某个品类是否极度倾斜？小表是否适合 Broadcast Join？这些判断都依赖统计信息。

### 10.2 Cardinality 决定计划质量

**Cardinality** 是某个算子输出的估算行数。它会沿着执行计划传播：

```text
Scan
  |
  | estimate: 10B rows
  v
Filter region_id = 10
  |
  | estimate: 80M rows
  v
Join dim_product
  |
  | estimate: 60M rows
  v
Aggregate
```

如果基数估计严重错误，优化器可能：

- 选择错误的 Join 顺序。
- 将大表误判为小表并 Broadcast。
- 低估 Hash Table 内存。
- 忽略更合适的 MV。

### 10.3 Join Reorder：先缩小中间结果

多表 Join 的执行顺序会直接决定中间结果大小。假设 SQL 中存在：

```sql
SELECT ...
FROM A
JOIN B ON A.b_id = B.id
JOIN C ON A.c_id = C.id
WHERE C.region = 'Zhejiang';
```

逻辑上，下面两种顺序等价：

```text
(A JOIN B) JOIN C
(A JOIN C) JOIN B
```

但如果 `C.region = 'Zhejiang'` 只能保留很少的数据，先执行 `A JOIN C` 可以尽早缩小输入；先执行 `A JOIN B` 则可能制造庞大的中间结果，增加 Hash Table 内存、网络 Shuffle 和 CPU 消耗。

优化器不能只看 SQL 的书写顺序。它需要从 Statistics 中读取 Row Count、NDV、值域和数据分布，估算 Filter 与 Join 的 Cardinality，再比较不同 Join Reorder 方案的代价。因果关系可以概括为：

```text
Statistics
    |
    v
Cardinality
    |
    v
Join Reorder
    |
    v
   CBO
```

统计信息不可信时，后面的代价选择也很难可靠。

### 10.4 CBO、Join Reorder 与 MV Rewrite

**CBO** 会为候选计划估算 CPU、内存、网络和 IO 成本，再选择更低成本的执行路径。

Trino 官方文档给出了典型例子：Connector 提供 Table Statistics 后，优化器可以枚举 Join 顺序，并在 Partitioned Join 和 Broadcast Join 之间做选择。

```text
SQL
 |
 v
Logical Plan
 |
 +--> Predicate / Projection Pushdown
 |
 +--> Join Reorder
 |
 +--> Join Distribution Selection
 |
 +--> MV Rewrite
 |
 v
Cost Estimation
 |
 v
Physical Plan
```

现代 OLAP 系统的一个重要方向，是从依赖人工选择汇总表，转向：

```text
Query Rewrite
      +
Cost Based Optimization
```

用户继续写面向业务的 SQL。数据库负责发现可复用的 MV、Projection、Rollup 和数据源能力，并选择成本更低的计划。不同产品支持的改写范围不同，MV Rewrite 也不一定与完整的 CBO 搜索空间使用同一套实现。

这条路线并不会消灭数据建模。相反，优化器越聪明，越需要正确的 Grain、稳定的维度、合理的分区和可信的统计信息。错误模型无法被 CBO 自动修复。

## 术语表

| 术语 | 所属层次 | 含义 |
| --- | --- | --- |
| ODS | 数仓工程 | 承接源系统原始数据，强调可追溯。 |
| DWD | 数仓工程 | 清洗后的原子明细层。 |
| DWS | 数仓工程 | 面向主题沉淀公共汇总。 |
| ADS | 数仓工程 | 直接服务报表、接口和应用。 |
| Grain | 维度建模 | 事实表中一行数据精确代表什么。 |
| Fact Table | 维度建模 | 描述下单、支付、点击等业务过程及其度量。 |
| Dimension Table | 维度建模 | 提供时间、用户、商品、地区等观察视角。 |
| Conformed Dimension | 维度建模 | 被多个事实表共享、语义一致的维度。 |
| Kimball Bus Architecture | 维度建模 | 通过一致性维度连接多个业务过程的企业级复用框架。 |
| Degenerate Dimension | 维度建模 | 没有独立维度表，直接保留在事实表中的业务标识。 |
| Junk Dimension | 维度建模 | 收拢低基数零散属性的维度。 |
| SCD | 维度建模 | 处理维度属性变化和历史保留的技术。 |
| Star Schema | 维度建模 | 事实表处于中心，直接连接维度表。 |
| Snowflake Schema | 维度建模 | 继续规范化拆分维度表。 |
| Galaxy Schema | 维度建模 | 多个事实表通过一致性维度构成的星座模型。 |
| Cube | OLAP 语义 | 多维分析空间。 |
| MOLAP | OLAP 实现 | 预先计算并保存多维聚合结果。 |
| ROLAP | OLAP 实现 | 使用关系模型、SQL 和执行引擎完成多维分析。 |
| HOLAP | OLAP 实现 | 在多维预计算与关系存储之间采用混合策略。 |
| Slice | OLAP 语义 | 固定一个维度，观察剩余维度。 |
| Dice | OLAP 语义 | 从多个维度筛选一个子空间。 |
| Drill Down | OLAP 语义 | 从粗粒度进入细粒度。 |
| Roll Up | OLAP 语义 | 从细粒度向粗粒度聚合。 |
| Pivot | OLAP 语义 | 旋转结果展示轴。 |
| Aggregate Table | 预聚合 | 保存维度键和聚合指标的结果表。 |
| Summary Table | 预聚合 | 面向主题或应用保存摘要结果。 |
| Rollup | 数据库实现 | 部分 OLAP 数据库中的额外物化索引。 |
| Projection | 数据库实现 | ClickHouse 表内部的备用物理布局。 |
| Materialized View | 数据库实现 | 同时保存查询定义、物化结果和刷新语义的数据库对象。 |
| Query Rewrite | 优化器 | 将查询透明改写为读取等价物化结果。 |
| NDV | 优化器 | Number of Distinct Values，列的不同值数量。 |
| Cardinality | 优化器 | 算子输出行数的估计值。 |
| CBO | 优化器 | 基于代价选择执行计划的优化器。 |

## OLAP 技术路线演进

OLAP 技术的演进并不是后一代系统完全替换前一代系统，而是不断调整预计算、灵活性、刷新成本与查询成本之间的边界。

```text
MOLAP
   |
   v
ROLAP
   |
   v
MPP Database
   |
   v
Lakehouse
   |
   v
Materialized View
   |
   v
Query Rewrite
   |
   v
Cost Based Optimization
```

早期 **MOLAP** 倾向于预先计算 Cube。它将高频聚合搬到写入或刷新阶段，查询延迟低，但维度组合增加后容易产生 Cube Explosion：存储空间、刷新窗口和维护成本都会迅速上升。问题的核心是，系统提前计算了大量用户可能永远不会访问的组合。

**ROLAP** 将事实、维度和汇总结果放回关系模型，以 SQL 表达分析需求。它牺牲一部分固定查询的极致响应速度，换取更灵活的维度扩展和更强的明细处理能力。Aggregate Table 与 Summary Table 仍然重要，只是从“完整物化所有组合”转向“选择性保存常用聚合”。

当数据量继续增长，单机数据库不足以支撑扫描和聚合，**MPP Database** 将数据分片到多个节点并行执行。列式存储、向量化执行、局部聚合和分布式 Shuffle 让运行时计算能力显著提升。但 MPP 没有消灭成本问题：全量扫描、错误 Join 顺序和重复聚合仍然昂贵。

**Lakehouse** 解决的是另一条轴线。随着冷数据、历史数据和跨引擎数据不断增加，系统需要在对象存储上管理表、快照、Schema Evolution 和 ACID 事务。Lakehouse 不等于低延迟 OLAP 数据库，也不是 MPP Database 的线性继任者；它让开放存储与多种计算引擎可以共享同一份数据。

数据规模和查询模式都更加复杂后，**Materialized View** 再次把一部分计算搬到前面，但不再要求人工维护所有访问路径。系统可以只物化高收益结果，并用刷新策略控制 Freshness。接着，**Query Rewrite** 让用户继续查询逻辑表，由优化器判断某个 MV 是否能够等价替换原始计划。

最后，**Cost Based Optimization** 将 MV 与普通扫描、不同 Join 顺序、不同数据源能力放入候选计划集合。Statistics 和 Cardinality 估算帮助优化器选择更便宜的路径。优化器必须同时考虑扫描行数、过滤选择率、聚合后基数、网络 Shuffle 和物化结果的新鲜度。即使某个 MV 可以完成语义等价改写，也不代表它必然比直接扫描更便宜。

这条路线并不是单向时间轴。MPP Database 可以读取 Lakehouse 表，Lakehouse 上也可以建立 MV；ROLAP 系统同样会使用预聚合。现代 OLAP 的关键不再是“是否预计算”，而是“预计算什么、何时刷新、如何证明等价、何时值得使用”。这也是 Cube、Aggregate Table、Rollup、MV 与 CBO 逐步衔接起来的原因。

存算分离进一步放大了这个问题。同一条 SQL 可能读取本地列存、对象存储中的开放表格式，或者已经刷新的 MV。不同路径的 IO、网络和新鲜度成本差异很大，人工指定固定汇总表越来越难以覆盖全部场景。优化器因此需要把存储布局、统计信息、改写规则和执行代价放在同一条决策链路中考虑。

## 总结

从业务数据库到现代 OLAP 优化器，可以用一条完整链路概括：

```text
业务数据
   |
   v
ODS -> DWD -> DWS -> ADS
   |
   v
声明 Grain，建立 Fact 与 Dimension
   |
   v
Star Schema / Galaxy Schema
   |
   v
Cube 上的 Slice、Dice、Drill Down、Roll Up
   |
   v
Aggregate Table / Summary Table / Rollup
   |
   v
Materialized View
   |
   v
Query Rewrite
   |
   v
Statistics + CBO
```

这套体系背后的主线是查询成本。

业务系统擅长记录事实，但不适合反复解释海量事实。数仓分层让数据逐步变得可复用；维度建模让事实拥有稳定粒度和观察视角；OLAP 语义描述分析人员如何切分和聚合数据；预聚合与 MV 避免重复计算；Query Rewrite 与 CBO 则让数据库自动选择更便宜的执行路径。

沿着这条链路再看 Doris、StarRocks、ClickHouse、Trino、Hive 和 Spark SQL，可以更清楚地理解不同系统各自承担的职责，以及它们在写入成本、查询延迟、数据新鲜度和实现复杂度之间的取舍。

## 参考资料

- [Kimball Group: Four-Step Dimensional Design Process](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/four-4-step-design-process/)
- [Kimball Group: Dimensional Modeling Techniques](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/)
- [Kimball Group: Additive, Semi-Additive, and Non-Additive Facts](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/additive-semi-additive-non-additive-fact/)
- [Kimball Group: Enterprise Data Warehouse Bus Architecture](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/kimball-data-warehouse-bus-architecture/)
- [Kimball Group: Degenerate Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/degenerate-dimension/)
- [Kimball Group: Slowly Changing Dimensions, Part 2](https://www.kimballgroup.com/2008/09/slowly-changing-dimensions-part-2/)
- [Microsoft Learn: Understand Star Schema](https://learn.microsoft.com/en-us/power-bi/guidance/star-schema)
- [Apache Doris: Preaggregation and Rollup](https://doris.apache.org/docs/dev/key-features/preaggregation-and-rollup/)
- [Apache Doris: Materialized View](https://doris.apache.org/docs/4.x/query-acceleration/materialized-view/intro/)
- [StarRocks: Synchronous Materialized View](https://docs.starrocks.io/docs/using_starrocks/Materialized_view-single_table/)
- [StarRocks: Asynchronous Materialized Views](https://docs.starrocks.io/docs/using_starrocks/async_mv/Materialized_view/)
- [ClickHouse: Using Materialized Views](https://clickhouse.com/blog/using-materialized-views-in-clickhouse)
- [ClickHouse: Getting Started - Common Issues](https://clickhouse.com/blog/common-getting-started-issues-with-clickhouse)
- [ClickHouse: Projections as Secondary Indexes](https://clickhouse.com/blog/projections-secondary-indices)
- [Trino: Query Optimizer](https://trino.io/docs/current/optimizer.html)
- [Trino: Cost-Based Optimizations](https://trino.io/docs/current/optimizer/cost-based-optimizations.html)
- [Trino: Table Statistics](https://trino.io/docs/current/optimizer/statistics.html)
- [Trino: CREATE MATERIALIZED VIEW](https://trino.io/docs/current/sql/create-materialized-view.html)
- [Trino: Iceberg Connector](https://trino.io/docs/current/connector/iceberg.html)
- [Apache Iceberg: Table Spec](https://iceberg.apache.org/spec/)
- [Apache Hudi: Overview](https://hudi.apache.org/docs/overview)
- [Delta Lake: Introduction](https://docs.delta.io/latest/delta-intro.html)
