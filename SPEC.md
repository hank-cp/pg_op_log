# 功能描述
- 定义数据修改记录表`sys_op_log`, 表结构如下:
```sql
CREATE TABLE data_op_log (
	id bigserial primary key,
	schema_name text not null,
	table_name text not null,
	data_id bigint
	modified_at: TIMESTAMP,
	modified_by: TIMESTAMP,
	op_type: text,
	op_note: text,
	revision_id: text,
	raw_data: jsonb,
	diff: jsonb,
	json_diff: jsonb,

	relid oid not null,
	session_user_name text,
	action_tstamp_tx TIMESTAMP NOT NULL,
	action_tstamp_stm TIMESTAMP NOT NULL,
	action_tstamp_clk TIMESTAMP NOT NULL,
	transaction_id bigint,
	client_addr inet,
	client_port integer,
	client_query text,
	action TEXT NOT NULL CHECK (action IN ('I', 'D', 'U', 'T')),
	statement_only boolean not null,
);
```
- 对指定的table, 调用一个function, 声明接入保存修改记录功能
- 分别注册insert/update/delete触发器, 触发时创建一条`sys_op_log`表的记录
- 从记录本身提取`data_id`, `modified_at`, `modified_by`等字段
  - `data_id`是联合主键的话, 把多段主键拼起来, 用字符`∆`分隔
- 从`temp_op_meta`表提取`op_type`, `op_note`和`revision_id`等字段, 注意有可能临时表不存在或表是空的, 要兼容取不到值的情况
- 对于insert和delete操作, 将记录转换为json格式并保存到`raw_data`字段
- 对于update操作
  - 普通比较: 比较所有字段数据修改前后的差异, 输出以下格式的json, 保存到`diff`字段
  ```json
  {

    "diffType": "normal",
    "field_name_1": "null -> \"content\"", // 值从null修改为"content"
    "field_name_2": "\"content\" -> null", // 值从"content"修改为null
    "field_name_3": "\"content_before\" -> \"content_after\"" // 值从"content_before"修改为"content_after"
  }
  ```
  	- 进行普通比较时, 需要排除配置指定字段, json/jsonb类型字段和array类型字段
  - json/jsonb类型比较: 在调用声明function时, 需要指定每个Json字段的数据类型, 包括(object|array|objectArray|other)四种
    - 对于`object`类型, 比较每个field的差异, 结果与普通比较的格式一样
    - 对于`array`类型, 比较新旧两个数组的差异, 输出以下格式的json
    ```json
    {
      "diffType": "array",
      "newItems": ["1", "2", "3"], // 新增元素
      "removedItems": ["4", "5", "6"] // 移除元素
    }
    ```
    - 对于`objectArray`类型, 需要在调用声明function时, 指定每个对象的主键field, 可以指定多个. 比较修改前后差异并输出以下格式的json
    ```json
    {
      "diffType": "objectArray",
      "newItems": [{ // 新增元素
        "field_key": 1,
        "field_2": 1,
        "field_3": 1
      }],
      "removedItems": [{ // 移除元素
        "field_key": 3,
        "field_2": 3,
        "field_3": 3
      }],
      "modifiedItems": [{ // 修改元素
        "key": "2", // 主键field, 有多个的时候合并起来用'∆'分隔
        "field_name_1": "null -> \"content\"",
        "field_name_2": "\"content\" -> null",
        "field_name_3": "\"content_before\" -> \"content_after\"",
      }]
    }
    ```
    - 对于`other`类型, 比较修改前后差异并输出以下格式的json
    ```json
    {
      "diffType": "other",
      "content": "\"content_before\" -> \"content_after\"" // 直接比较前后差异
    }
    ```
  - array比较: 与json/jsonb的`array`类型比较相同.

  
# 技术需求
- [参考实现](https://github.com/iloveitaly/audit-trigger/blob/master/audit.sql)
- 数据库已安装plv8插件, 比较差异部分可以使用javascript语言实现, 提高代码可读性, 不要引用第三方js库
- 使用[pgTag](https://pgtap.org/documentation.html)做单元测试验证功能.


# 开发环境说明
- Postgres数据库
  - host: localhost
  - port: 5432
  - user: postgres
  - password: 无
