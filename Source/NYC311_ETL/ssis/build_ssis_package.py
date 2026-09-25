#!/usr/bin/env python3
"""Generate a SQL Server 2022-compatible DTSX with Execute SQL Tasks only.

The package contains a dummy OLE DB connection. run_ssis.py overrides that
connection at runtime with /CONNECTION so no SQL password is stored in source.
"""
from __future__ import annotations

import argparse
import uuid
from pathlib import Path
from xml.sax.saxutils import escape


def guid() -> str:
    return "{" + str(uuid.uuid4()).upper() + "}"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--output", required=True)
    args = p.parse_args()

    package_id = guid()
    version_guid = guid()
    conn_id = guid()
    tasks = [
        ("01 - Begin ETL batch", "EXEC etl.usp_BeginBatch;"),
        ("02 - Extract/load CSV to staging", "EXEC etl.usp_LoadStaging;"),
        ("03 - Transform/load dimensions", "EXEC etl.usp_LoadDimensions;"),
        ("04 - Transform/load fact", "EXEC etl.usp_LoadFact;"),
        ("05 - Validate and close batch", "EXEC etl.usp_ValidateAndCloseBatch;"),
    ]
    task_ids = [guid() for _ in tasks]

    exec_xml = []
    for (name, sql), tid in zip(tasks, task_ids):
        ref = f"Package\\{name}"
        exec_xml.append(f'''    <DTS:Executable
      DTS:refId="{escape(ref)}"
      DTS:CreationName="Microsoft.ExecuteSQLTask"
      DTS:Description="Execute SQL Task"
      DTS:DTSID="{tid}"
      DTS:ExecutableType="Microsoft.ExecuteSQLTask"
      DTS:LocaleID="-1"
      DTS:ObjectName="{escape(name)}"
      DTS:TaskContact="Execute SQL Task; Microsoft Corporation; SQL Server 2022; © 2022 Microsoft Corporation; All Rights Reserved;http://www.microsoft.com/sql/support/default.asp;1"
      DTS:ThreadHint="0">
      <DTS:Variables />
      <DTS:ObjectData>
        <SQLTask:SqlTaskData
          SQLTask:Connection="{conn_id}"
          SQLTask:SqlStatementSource="{escape(sql)}"
          xmlns:SQLTask="www.microsoft.com/sqlserver/dts/tasks/sqltask" />
      </DTS:ObjectData>
    </DTS:Executable>''')

    constraints = []
    for i in range(len(tasks) - 1):
        from_ref = f"Package\\{tasks[i][0]}"
        to_ref = f"Package\\{tasks[i+1][0]}"
        constraints.append(f'''    <DTS:PrecedenceConstraint
      DTS:refId="Package.PrecedenceConstraints[Constraint {i+1}]"
      DTS:CreationName=""
      DTS:DTSID="{guid()}"
      DTS:From="{escape(from_ref)}"
      DTS:LogicalAnd="True"
      DTS:ObjectName="Constraint {i+1}"
      DTS:To="{escape(to_ref)}" />''')

    # Dummy credentials are intentionally invalid and replaced by /CONNECTION at execution time.
    dummy_conn = (
        "Data Source=localhost;Initial Catalog=NYC311_DW;Provider=SQLNCLI11.1;"
        "User ID=sa;Password=OVERRIDDEN_AT_RUNTIME;Persist Security Info=True;Auto Translate=False;"
    )

    xml = f'''<?xml version="1.0"?>
<DTS:Executable xmlns:DTS="www.microsoft.com/SqlServer/Dts"
  DTS:refId="Package"
  DTS:CreationDate="9/25/2026 12:00:00 PM"
  DTS:CreationName="Microsoft.Package"
  DTS:CreatorComputerName="LINUX"
  DTS:CreatorName="IS217-BTA12"
  DTS:DTSID="{package_id}"
  DTS:ExecutableType="Microsoft.Package"
  DTS:LastModifiedProductVersion="16.0.0.0"
  DTS:LocaleID="1033"
  DTS:ObjectName="00_Master_NYC311_ETL"
  DTS:PackageType="5"
  DTS:VersionBuild="1"
  DTS:VersionGUID="{version_guid}">
  <DTS:Property DTS:Name="PackageFormatVersion">8</DTS:Property>
  <DTS:ConnectionManagers>
    <DTS:ConnectionManager
      DTS:refId="Package.ConnectionManagers[NYC311_DW]"
      DTS:CreationName="OLEDB"
      DTS:DTSID="{conn_id}"
      DTS:ObjectName="NYC311_DW">
      <DTS:ObjectData>
        <DTS:ConnectionManager
          DTS:ConnectRetryCount="3"
          DTS:ConnectRetryInterval="3"
          DTS:ConnectionString="{escape(dummy_conn)}" />
      </DTS:ObjectData>
    </DTS:ConnectionManager>
  </DTS:ConnectionManagers>
  <DTS:Variables />
  <DTS:Executables>
{chr(10).join(exec_xml)}
  </DTS:Executables>
  <DTS:PrecedenceConstraints>
{chr(10).join(constraints)}
  </DTS:PrecedenceConstraints>
</DTS:Executable>
'''

    out = Path(args.output).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(xml, encoding="utf-8")
    print(f"[PASS] Generated SSIS package: {out}")


if __name__ == "__main__":
    main()
