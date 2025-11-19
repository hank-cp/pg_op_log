[![GitHub release](https://img.shields.io/github/release/hank-cp/pg_og_log.svg)](https://github.com/hank-cp/pg_op_log/releases)
[![Tests](https://github.com/hank-cp/pg_op_log/actions/workflows/test.yml/badge.svg)](https://github.com/hank-cp/pg_op_log/actions/workflows/test.yml)
![GitHub](https://img.shields.io/github/license/hank-cp/pg_op_log.svg)
![GitHub last commit](https://img.shields.io/github/last-commit/hank-cp/pg_op_log.svg)

`pg_op_log`一个ProgresSQL的扩展, 用于在事务提交时, 将数据变化保存到一张历史记录表中.

# 约定前提
该扩展的使用基于以下约定前提:
- 每张业务表, 都包含以下字段
	- `modified_at`: 记录insert或update的时间
	- `modified_by`: 操作该行记录的用户, 由业务系统提交
	- `deleted`: 标记该记录是否被软删除
- 数据库中存在一张临时表`temp_op_meta`, 记录本次提交事务操作的相关元信息. 该表只有一条记录, 事务提交后会自动清理掉.
	- 该表有以下字段
		- `op_type`: 操作类型, 由业务系统提交
		- `op_note`: 操作备注, 由业务系统提交
		- `revision_id`: 提交自动生成的uuid, 用于标记操作批次

# pg_op_log 使用说明

## 安装

```bash
git clone https://github.com/hank-cp/pg_op_log.git
cd pg_op_log
make install
```

## 快速开始

### 1. 创建操作元数据临时表
* 这一步通常由业务系统在开启一个事务时执行

```sql
CREATE TEMP TABLE temp_op_meta (
	op_type text,
	op_note text,
	revision_id text
);

INSERT INTO temp_op_meta (op_type, op_note, revision_id)
VALUES ('CREATE_USER', '创建新用户', gen_random_uuid()::text);
```

### 2. 为表启用操作日志

```sql
SELECT op_log_enable(
	'your_table_name'::regclass,
	ARRAY['field_to_exclude']::text[],
	'{
		"json_field_1": {"type": "object"},
		"json_field_2": {"type": "array"},
		"json_field_3": {"type": "objectArray", "keyFields": ["id", "name"]},
		"json_field_4": {"type": "other"}
	}'::jsonb,
	ARRAY['array_field_1', 'array_field_2']::text[]
);
```

参数说明:
- 第1个参数: 要监控的表名
- 第2个参数: 需要排除比较的字段数组(可选)
- 第3个参数: JSON/JSONB字段的配置(可选)
  - `object`: JSON对象,比较每个field的差异
  - `array`: JSON数组,比较新增/移除的元素
  - `objectArray`: JSON对象数组,需要指定keyFields用于匹配对象
  - `other`: 其他类型,直接比较整体差异
- 第4个参数: 普通数组类型字段(可选)

### 3. 执行数据操作

```sql
INSERT INTO users (name, email, modified_by) 
VALUES ('Alice', 'alice@example.com', 'admin');
```

### 4. 查询操作日志

```sql
SELECT 
	id,
	schema_name,
	table_name,
	data_id,
	op_type,
	op_note,
	action,
	modified_by,
	modified_at,
	raw_data,
	diff,
	json_diff
FROM data_op_log
WHERE table_name = 'users'
ORDER BY id DESC;
```

## 字段说明

### data_op_log表字段

- `id`: 日志记录ID
- `schema_name`: 数据库schema名称
- `table_name`: 表名
- `data_id`: 数据主键值(复合主键用∆分隔)
- `modified_at`: 记录修改时间
- `modified_by`: 修改人
- `op_type`: 操作类型(从temp_op_meta获取)
- `op_note`: 操作备注(从temp_op_meta获取)
- `revision_id`: 批次ID(从temp_op_meta获取)
- `raw_data`: INSERT/DELETE的完整数据(JSONB)
- `diff`: UPDATE的普通字段差异(JSONB)
- `json_diff`: UPDATE的JSON/数组字段差异(JSONB)
- `action`: 操作类型(I=INSERT, U=UPDATE, D=DELETE)
- 其他审计字段...

## 差异格式示例

### 普通字段差异 (diff)

```json
{
	"diffType": "normal",
	"name": "\"Alice\" -> \"Alice Wang\"",
	"age": "30 -> 31",
	"email": "null -> \"alice@example.com\""
}
```

### JSON对象差异 (json_diff)

```json
{
	"metadata": {
		"diffType": "object",
		"city": "\"Beijing\" -> \"Shanghai\"",
		"age": "30 -> 31"
	}
}
```

### 数组差异 (json_diff)

```json
{
	"tags": {
		"diffType": "array",
		"newItems": ["premium", "vip"],
		"removedItems": ["trial"]
	}
}
```

### 对象数组差异 (json_diff)

```json
{
	"items": {
		"diffType": "objectArray",
		"newItems": [
			{"id": 3, "name": "item3", "value": 300}
		],
		"removedItems": [
			{"id": 1, "name": "item1", "value": 100}
		],
		"modifiedItems": [
			{
				"key": "2",
				"value": "200 -> 250",
				"name": "\"item2\" -> \"item2_updated\""
			}
		]
	}
}
```

## 禁用操作日志

```sql
SELECT op_log_disable('your_table_name'::regclass);
```

## 注意事项

1. 表必须包含`modified_at`和`modified_by`字段
2. `temp_op_meta`表可以不存在或为空,相关字段会记录为NULL
3. 如果没有主键,默认使用`id`字段作为data_id
4. 复合主键会用`∆`字符连接
5. 配置信息保存在数据库参数中,需要ALTER DATABASE权限














