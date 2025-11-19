![GitHub Release](https://img.shields.io/github/v/release/hank-cp/pg_op_log)
[![Tests](https://github.com/hank-cp/pg_op_log/actions/workflows/test.yml/badge.svg)](https://github.com/hank-cp/pg_op_log/actions/workflows/test.yml)
![GitHub](https://img.shields.io/github/license/hank-cp/pg_op_log.svg)
![GitHub last commit](https://img.shields.io/github/last-commit/hank-cp/pg_op_log.svg)

`pg_op_log` is a PostgreSQL extension for saving data changes to a history log table when transactions are committed.

[中文文档](README.zh-cn.md)

# Conventions and Prerequisites

This extension is based on the following conventions:
- Each business table should contain the following fields:
	- `modified_at`: Records the timestamp of INSERT or UPDATE operations
	- `modified_by`: The user who performed the operation, provided by the business system
	- `deleted`: Flag indicating whether the record is soft-deleted
- A temporary table `temp_op_meta` exists in the database to store metadata about the current transaction operation. This table contains only one record and is automatically cleaned up after the transaction commits.
	- This table has the following fields:
		- `op_type`: Operation type, provided by the business system
		- `op_note`: Operation notes, provided by the business system
		- `revision_id`: Auto-generated UUID for marking operation batches

# pg_op_log Usage Guide

## Installation

```bash
git clone https://github.com/hank-cp/pg_op_log.git
cd pg_op_log
make install
```

## Quick Start

### 1. Create Operation Metadata Temporary Table
* This step is typically executed by the business system when starting a transaction

```sql
CREATE EXTENSION IF NOT EXISTS op_log SCHEMA "public" CASCADE;

CREATE TEMP TABLE temp_op_meta (
	op_type text,
	op_note text,
	revision_id text
);

INSERT INTO temp_op_meta (op_type, op_note, revision_id)
VALUES ('CREATE_USER', 'Create new user', gen_random_uuid()::text);
```

### 2. Enable Operation Logging for a Table

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

Parameter descriptions:
- 1st parameter: The table name to monitor
- 2nd parameter: Array of fields to exclude from comparison (optional)
- 3rd parameter: Configuration for JSON/JSONB fields (optional)
  - `object`: JSON object, compares differences in each field
  - `array`: JSON array, compares added/removed elements
  - `objectArray`: JSON object array, requires keyFields to match objects
  - `other`: Other types, compares overall differences
- 4th parameter: Regular array type fields (optional)

### 3. Perform Data Operations

```sql
INSERT INTO users (name, email, modified_by) 
VALUES ('Alice', 'alice@example.com', 'admin');
```

### 4. Query Operation Logs

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

## Field Descriptions

### data_op_log Table Fields

- `id`: Log record ID
- `schema_name`: Database schema name
- `table_name`: Table name
- `data_id`: Primary key value (composite keys separated by ∆)
- `modified_at`: Record modification timestamp
- `modified_by`: User who modified the record
- `op_type`: Operation type (from temp_op_meta)
- `op_note`: Operation notes (from temp_op_meta)
- `revision_id`: Batch ID (from temp_op_meta)
- `raw_data`: Complete data for INSERT/DELETE (JSONB)
- `diff`: Regular field differences for UPDATE (JSONB)
- `json_diff`: JSON/array field differences for UPDATE (JSONB)
- `action`: Operation type (I=INSERT, U=UPDATE, D=DELETE)
- Other audit fields...

## Difference Format Examples

### Regular Field Differences (diff)

```json
{
	"diffType": "normal",
	"name": "\"Alice\" -> \"Alice Wang\"",
	"age": "30 -> 31",
	"email": "null -> \"alice@example.com\""
}
```

### JSON Object Differences (json_diff)

```json
{
	"metadata": {
		"diffType": "object",
		"city": "\"Beijing\" -> \"Shanghai\"",
		"age": "30 -> 31"
	}
}
```

### Array Differences (json_diff)

```json
{
	"tags": {
		"diffType": "array",
		"newItems": ["premium", "vip"],
		"removedItems": ["trial"]
	}
}
```

### Object Array Differences (json_diff)

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

## Disable Operation Logging

```sql
SELECT op_log_disable('your_table_name'::regclass);
```

## Important Notes

1. Tables must contain `modified_at` and `modified_by` fields
2. The `temp_op_meta` table can be non-existent or empty; related fields will be recorded as NULL
3. If there is no primary key, the `id` field is used as data_id by default
4. Composite primary keys are concatenated with the `∆` character
5. Configuration information is saved in database parameters and requires ALTER DATABASE permission
