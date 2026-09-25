# SSIS ObjectName hotfix

Previous generated task names contained `/`, for example:

- `02 - Extract/load CSV to staging`
- `03 - Transform/load dimensions`
- `04 - Transform/load fact`

SSIS rejects `/` in an ObjectName.

The fixed generator emits:

- `Master_Clickstream_ETL`
- `Task_01_Begin_ETL_Batch`
- `Task_02_Load_Staging`
- `Task_03_Load_Dimensions`
- `Task_04_Load_Fact`
- `Task_05_Validate_And_Close_Batch`

`ssis/validate_dtsx.py` validates every generated ObjectName before `dtexec`.

Because dataset and database preparation are already complete, use:

```bash
./resume_from_step5.sh
```
